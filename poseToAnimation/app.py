from __future__ import annotations

import json
import shutil
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import url2pathname
from uuid import uuid4

from flask import Flask, jsonify, redirect, render_template, request, send_from_directory, url_for
from werkzeug.utils import secure_filename

from animate_poses import (
    DEFAULT_MODEL_VARIANT,
    IMAGE_EXTENSIONS,
    MODEL_VARIANTS,
    iter_images,
    process_animation,
)


ROOT = Path(__file__).resolve().parent
INPUT_DIR = ROOT / "input"
OUTPUT_DIR = ROOT / "output"

app = Flask(__name__)
app.secret_key = "pose-to-animation-local"

last_run: dict[str, object] = {
    "summary": None,
    "logs": [],
    "active_batch_id": None,
    "active_input_dir": None,
    "latest_output_dir": None,
    "manifest": None,
    "settings": {
        "duration_seconds": 4.0,
        "repeat_count": 1,
        "fps": 24,
        "width": 960,
        "height": 720,
        "model_variant": DEFAULT_MODEL_VARIANT,
        "min_detection_confidence": 0.5,
        "min_visibility": 0.45,
    },
}


def timestamp() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def new_batch_id() -> str:
    return f"batch_{timestamp()}_{uuid4().hex[:6]}"


def unique_file_path(folder: Path, filename: str) -> Path:
    candidate = folder / filename
    if not candidate.exists():
        return candidate

    stem = Path(filename).stem
    suffix = Path(filename).suffix
    counter = 2
    while True:
        candidate = folder / f"{stem}_{counter}{suffix}"
        if not candidate.exists():
            return candidate
        counter += 1


def api_error(message: str, status_code: int = 400, **details: object):
    payload: dict[str, object] = {"ok": False, "error": message}
    if details:
        payload["details"] = details
    return jsonify(payload), status_code


def parse_local_folder_link(value: object) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("input_folder must be a non-empty local folder path.")

    text = value.strip()
    parsed = urlparse(text)

    is_windows_drive_path = len(parsed.scheme) == 1 and len(text) > 2 and text[1] == ":"
    if parsed.scheme and not is_windows_drive_path:
        if parsed.scheme.lower() != "file":
            raise ValueError("Only local folder paths or file:// URLs are supported.")
        if parsed.netloc and parsed.netloc.lower() != "localhost":
            raise ValueError("Only local file:// URLs are supported.")
        path_text = url2pathname(parsed.path)
    else:
        path_text = text

    path = Path(path_text).expanduser()
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


def parse_api_number(value: object, field_name: str, fallback: float) -> float:
    if value is None:
        return fallback
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be a number.") from exc


def parse_api_int(value: object, field_name: str, fallback: int) -> int:
    if value is None:
        return fallback
    try:
        return int(float(value))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be an integer.") from exc


def parse_confidence(value: object, field_name: str, fallback: float) -> float:
    confidence = parse_api_number(value, field_name, fallback)
    if confidence < 0.0 or confidence > 1.0:
        raise ValueError(f"{field_name} must be from 0.0 to 1.0.")
    return confidence


def api_animation_options(payload: dict[str, object]) -> dict[str, object]:
    raw_options = payload.get("options", {})
    if raw_options is None:
        raw_options = {}
    if not isinstance(raw_options, dict):
        raise ValueError("options must be an object.")

    model_variant = str(raw_options.get("model_variant", DEFAULT_MODEL_VARIANT)).lower()
    if model_variant not in MODEL_VARIANTS:
        raise ValueError(f"model_variant must be one of: {', '.join(sorted(MODEL_VARIANTS))}.")

    duration_seconds = parse_api_number(raw_options.get("duration_seconds"), "duration_seconds", 4.0)
    repeat_count = parse_api_int(raw_options.get("repeat_count"), "repeat_count", 1)
    fps = parse_api_int(raw_options.get("fps"), "fps", 24)
    width = parse_api_int(raw_options.get("width"), "width", 960)
    height = parse_api_int(raw_options.get("height"), "height", 720)

    if duration_seconds <= 0:
        raise ValueError("duration_seconds must be greater than 0.")
    if repeat_count < 1:
        raise ValueError("repeat_count must be at least 1.")
    if fps < 1:
        raise ValueError("fps must be at least 1.")
    if width < 1 or height < 1:
        raise ValueError("width and height must be positive integers.")

    return {
        "duration_seconds": duration_seconds,
        "repeat_count": repeat_count,
        "fps": fps,
        "width": width,
        "height": height,
        "model_variant": model_variant,
        "min_detection_confidence": parse_confidence(
            raw_options.get("min_detection_confidence"),
            "min_detection_confidence",
            0.5,
        ),
        "min_visibility": parse_confidence(raw_options.get("min_visibility"), "min_visibility", 0.45),
    }


def validate_input_folder(path: Path) -> None:
    if not path.exists():
        raise FileNotFoundError(f"Input folder does not exist: {path}")
    if not path.is_dir():
        raise ValueError(f"Input folder is not a directory: {path}")


def sequence_source_paths(input_folder: Path, payload: dict[str, object]) -> list[Path]:
    validate_input_folder(input_folder)

    raw_sequence = payload.get("sequence")
    if raw_sequence is None:
        paths = list(iter_images(input_folder))
        if not paths:
            raise ValueError(
                f"Input folder has no supported images. Supported extensions: {', '.join(sorted(IMAGE_EXTENSIONS))}."
            )
        return paths

    if not isinstance(raw_sequence, list):
        raise ValueError("sequence must be a list of relative image paths.")
    if not raw_sequence:
        raise ValueError("sequence must include at least two image paths.")

    input_root = input_folder.resolve()
    paths: list[Path] = []
    for index, item in enumerate(raw_sequence, start=1):
        if not isinstance(item, str) or not item.strip():
            raise ValueError(f"sequence item {index} must be a non-empty relative image path.")

        relative = Path(item.strip().replace("\\", "/"))
        if relative.is_absolute():
            raise ValueError(f"sequence item {index} must be relative to input_folder.")

        source = (input_root / relative).resolve()
        try:
            source.relative_to(input_root)
        except ValueError as exc:
            raise ValueError(f"sequence item {index} points outside input_folder.") from exc

        if not source.exists():
            raise FileNotFoundError(f"Sequence image does not exist: {source}")
        if not source.is_file():
            raise ValueError(f"Sequence path is not a file: {source}")
        if source.suffix.lower() not in IMAGE_EXTENSIONS:
            raise ValueError(
                f"Unsupported image extension for {source.name}. "
                f"Supported extensions: {', '.join(sorted(IMAGE_EXTENSIONS))}."
            )
        paths.append(source)

    return paths


def copy_api_sequence_inputs(paths: list[Path], input_folder: Path, operation_id: str) -> tuple[Path, list[dict[str, object]]]:
    batch_input_dir = INPUT_DIR / operation_id
    copied: list[dict[str, object]] = []

    for index, source in enumerate(paths, start=1):
        filename = secure_filename(source.name) or f"image{source.suffix.lower()}"
        ordered_filename = f"{index:06d}__{filename}"
        batch_input_dir.mkdir(parents=True, exist_ok=True)
        destination = unique_file_path(batch_input_dir, ordered_filename)
        shutil.copy2(source, destination)

        try:
            relative_source = source.relative_to(input_folder).as_posix()
        except ValueError:
            relative_source = source.name

        copied.append(
            {
                "sequence_index": index,
                "source": str(source),
                "source_relative": relative_source,
                "stored": str(destination),
            }
        )

    return batch_input_dir, copied


def animation_output_files(output_dir: Path) -> list[dict[str, str]]:
    files: list[dict[str, str]] = []
    if not output_dir.exists():
        return files

    for path in sorted(output_dir.rglob("*")):
        if not path.is_file():
            continue
        relative_to_output_root = path.relative_to(OUTPUT_DIR).as_posix()
        files.append(
            {
                "name": path.relative_to(output_dir).as_posix(),
                "path": str(path),
                "url": url_for("output_file", filename=relative_to_output_root),
            }
        )
    return files


def read_manifest(output_dir: Path) -> dict[str, object] | None:
    manifest_path = output_dir / "manifest.json"
    if not manifest_path.exists():
        return None
    try:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def parse_float(name: str, fallback: float) -> float:
    try:
        return float(request.form.get(name, fallback))
    except (TypeError, ValueError):
        return fallback


def parse_int(name: str, fallback: int) -> int:
    try:
        return int(float(request.form.get(name, fallback)))
    except (TypeError, ValueError):
        return fallback


def folder_images(folder: Path | None) -> list[dict[str, object]]:
    if folder is None or not folder.exists():
        return []

    images = []
    for path in sorted(folder.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        relative = path.relative_to(folder).as_posix()
        input_relative = path.relative_to(INPUT_DIR).as_posix()
        images.append(
            {
                "name": relative,
                "url": url_for("input_file", filename=input_relative, v=int(path.stat().st_mtime)),
            }
        )
    return images


def newest_output_dir() -> Path | None:
    if not OUTPUT_DIR.exists():
        return None
    folders = [path for path in OUTPUT_DIR.iterdir() if path.is_dir()]
    if not folders:
        return None
    return max(folders, key=lambda path: path.stat().st_mtime)


def output_links(folder: Path | None) -> dict[str, str | None]:
    links: dict[str, str | None] = {"mp4": None, "gif": None, "manifest": None}
    if folder is None or not folder.exists():
        return links

    for key, filename in [("mp4", "stickman_animation.mp4"), ("gif", "stickman_animation.gif"), ("manifest", "manifest.json")]:
        path = folder / filename
        if path.exists():
            relative = path.relative_to(OUTPUT_DIR).as_posix()
            links[key] = url_for("output_file", filename=relative, v=int(path.stat().st_mtime))
    return links


@app.get("/")
def index():
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    active_input_dir = Path(str(last_run["active_input_dir"])) if last_run["active_input_dir"] else None
    latest_output_dir = Path(str(last_run["latest_output_dir"])) if last_run["latest_output_dir"] else newest_output_dir()

    return render_template(
        "index.html",
        input_dir=INPUT_DIR,
        output_dir=OUTPUT_DIR,
        active_batch_id=last_run["active_batch_id"],
        active_input_dir=active_input_dir,
        uploaded_images=folder_images(active_input_dir),
        latest_output_dir=latest_output_dir,
        output_links=output_links(latest_output_dir),
        last_run=last_run,
        image_extensions=", ".join(sorted(IMAGE_EXTENSIONS)),
        model_variants=MODEL_VARIANTS,
    )


@app.post("/upload")
def upload():
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    uploaded = request.files.getlist("images")
    batch_id = new_batch_id()
    batch_input_dir = INPUT_DIR / batch_id
    saved = 0

    for file in uploaded:
        if not file or not file.filename:
            continue
        raw_name = file.filename.replace("\\", "/").split("/")[-1]
        filename = secure_filename(raw_name)
        if not filename or Path(filename).suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        batch_input_dir.mkdir(parents=True, exist_ok=True)
        file.save(unique_file_path(batch_input_dir, filename))
        saved += 1

    if saved:
        last_run["active_batch_id"] = batch_id
        last_run["active_input_dir"] = str(batch_input_dir)
        last_run["latest_output_dir"] = None
        last_run["manifest"] = None
        last_run["summary"] = f"Saved {saved} image{'s' if saved != 1 else ''} to {batch_id}."
    else:
        last_run["summary"] = "No supported images were uploaded."
    last_run["logs"] = []
    return redirect(url_for("index"))


@app.post("/generate")
def generate():
    settings = {
        "duration_seconds": parse_float("duration_seconds", 4.0),
        "repeat_count": parse_int("repeat_count", 1),
        "fps": parse_int("fps", 24),
        "width": parse_int("width", 960),
        "height": parse_int("height", 720),
        "model_variant": request.form.get("model_variant", DEFAULT_MODEL_VARIANT),
        "min_detection_confidence": parse_float("min_detection_confidence", 0.5),
        "min_visibility": parse_float("min_visibility", 0.45),
    }
    if settings["model_variant"] not in MODEL_VARIANTS:
        settings["model_variant"] = DEFAULT_MODEL_VARIANT

    logs: list[str] = []
    active_input_dir = Path(str(last_run["active_input_dir"])) if last_run["active_input_dir"] else None
    active_batch_id = str(last_run["active_batch_id"]) if last_run["active_batch_id"] else None

    try:
        if active_input_dir is None or active_batch_id is None or not active_input_dir.exists():
            raise RuntimeError("Upload an image batch before generating an animation.")

        output_batch_dir = OUTPUT_DIR / f"{active_batch_id}_animation_{timestamp()}_{uuid4().hex[:4]}"
        model_variant = str(settings["model_variant"])
        manifest = process_animation(
            input_dir=active_input_dir,
            output_dir=output_batch_dir,
            duration_seconds=float(settings["duration_seconds"]),
            repeat_count=int(settings["repeat_count"]),
            fps=int(settings["fps"]),
            width=int(settings["width"]),
            height=int(settings["height"]),
            model_variant=model_variant,
            min_detection_confidence=float(settings["min_detection_confidence"]),
            min_visibility=float(settings["min_visibility"]),
            model_path=ROOT / MODEL_VARIANTS[model_variant]["path"],
            model_url=str(MODEL_VARIANTS[model_variant]["url"]),
            log=logs.append,
        )
        last_run["latest_output_dir"] = str(output_batch_dir)
        last_run["manifest"] = manifest
        summary = (
            f"Generated {manifest['frame_count']} frames from {manifest['valid_pose_count']} poses; "
            f"exported MP4 and GIF to {output_batch_dir.name}."
        )
        if manifest["skipped_count"]:
            summary += f" Skipped images: {manifest['skipped_count']}."
    except Exception as exc:
        summary = f"Generation failed: {exc}"

    last_run["summary"] = summary
    last_run["logs"] = logs[-120:]
    last_run["settings"] = settings
    return redirect(url_for("index"))


@app.post("/api/animation")
def api_animation():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return api_error("Request body must be a JSON object.")

    try:
        input_folder = parse_local_folder_link(payload.get("input_folder"))
        source_paths = sequence_source_paths(input_folder, payload)
        if len(source_paths) < 2:
            raise ValueError("At least two source images are required for animation.")
        settings = api_animation_options(payload)
    except FileNotFoundError as exc:
        return api_error(str(exc), 404)
    except ValueError as exc:
        return api_error(str(exc), 400)

    operation_id = f"api_{timestamp()}_{uuid4().hex[:4]}"
    logs: list[str] = []

    try:
        active_input_dir, copied_inputs = copy_api_sequence_inputs(source_paths, input_folder, operation_id)
        output_batch_dir = OUTPUT_DIR / f"{operation_id}_animation_{timestamp()}_{uuid4().hex[:4]}"
        model_variant = str(settings["model_variant"])
        manifest = process_animation(
            input_dir=active_input_dir,
            output_dir=output_batch_dir,
            duration_seconds=float(settings["duration_seconds"]),
            repeat_count=int(settings["repeat_count"]),
            fps=int(settings["fps"]),
            width=int(settings["width"]),
            height=int(settings["height"]),
            model_variant=model_variant,
            min_detection_confidence=float(settings["min_detection_confidence"]),
            min_visibility=float(settings["min_visibility"]),
            model_path=ROOT / MODEL_VARIANTS[model_variant]["path"],
            model_url=str(MODEL_VARIANTS[model_variant]["url"]),
            log=logs.append,
        )
    except Exception as exc:
        return api_error("Animation generation failed.", 422, exception=str(exc), logs=logs[-120:])

    last_run["active_batch_id"] = operation_id
    last_run["active_input_dir"] = str(active_input_dir)
    last_run["latest_output_dir"] = str(output_batch_dir)
    last_run["manifest"] = manifest
    last_run["settings"] = settings
    last_run["logs"] = logs[-120:]
    last_run["summary"] = (
        f"Generated {manifest['frame_count']} frames from {manifest['valid_pose_count']} poses; "
        f"exported MP4 and GIF to {output_batch_dir.name}."
    )

    return jsonify(
        {
            "ok": True,
            "operation_id": operation_id,
            "input_folder": str(input_folder),
            "input_dir": str(active_input_dir),
            "output_dir": str(output_batch_dir),
            "output_url": url_for("api_output_folder", folder=output_batch_dir.name),
            "options": settings,
            "result": {
                "source_count": manifest["source_count"],
                "valid_pose_count": manifest["valid_pose_count"],
                "skipped_count": manifest["skipped_count"],
                "frame_count": manifest["frame_count"],
            },
            "inputs": copied_inputs,
            "files": animation_output_files(output_batch_dir),
            "manifest": manifest,
            "logs": logs[-120:],
        }
    )


@app.get("/api/outputs/<path:folder>")
def api_output_folder(folder: str):
    output_dir = (OUTPUT_DIR / folder).resolve()
    try:
        output_dir.relative_to(OUTPUT_DIR.resolve())
    except ValueError:
        return api_error("Output folder must be inside the app output directory.", 400)

    if not output_dir.exists() or not output_dir.is_dir():
        return api_error(f"Output folder does not exist: {folder}", 404)

    return jsonify(
        {
            "ok": True,
            "output_dir": str(output_dir),
            "files": animation_output_files(output_dir),
            "manifest": read_manifest(output_dir),
        }
    )


@app.get("/inputs/<path:filename>")
def input_file(filename: str):
    return send_from_directory(INPUT_DIR, filename)


@app.get("/outputs/<path:filename>")
def output_file(filename: str):
    return send_from_directory(OUTPUT_DIR, filename)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=7870, debug=False)
