from __future__ import annotations

import shutil
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import url2pathname
from uuid import uuid4

from flask import Flask, jsonify, redirect, render_template, request, send_from_directory, url_for
from werkzeug.utils import secure_filename

from process_poses import DEFAULT_MODEL_VARIANT, IMAGE_EXTENSIONS, MODEL_VARIANTS, process_folder


ROOT = Path(__file__).resolve().parent
INPUT_DIR = ROOT / "input"
OUTPUT_DIR = ROOT / "output"
VALID_VIEWS = {"front", "side", "back", "all"}
VALID_NO_PERSON_MODES = {"copy", "skip"}

app = Flask(__name__)
app.secret_key = "img-to-pose-local"

last_run: dict[str, object] = {
    "summary": None,
    "logs": [],
    "active_batch_id": None,
    "active_input_dir": None,
    "latest_output_dir": None,
    "settings": {
        "view": "front",
        "model_variant": DEFAULT_MODEL_VARIANT,
        "no_person": "copy",
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
    payload = {"ok": False, "error": message}
    if details:
        payload["details"] = details
    return jsonify(payload), status_code


def parse_local_image_link(value: object) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Image path must be a non-empty string.")

    text = value.strip()
    parsed = urlparse(text)

    is_windows_drive_path = len(parsed.scheme) == 1 and len(text) > 2 and text[1] == ":"
    if parsed.scheme and not is_windows_drive_path:
        if parsed.scheme.lower() != "file":
            raise ValueError("Only local file paths or file:// URLs are supported.")
        if parsed.netloc and parsed.netloc.lower() != "localhost":
            raise ValueError("Only local file:// URLs are supported.")
        path_text = url2pathname(parsed.path)
    else:
        path_text = text

    path = Path(path_text).expanduser()
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


def validate_image_paths(payload: dict[str, object]) -> list[Path]:
    image_values: list[object] = []
    if "image_path" in payload:
        image_values.append(payload["image_path"])

    if "image_paths" in payload:
        values = payload["image_paths"]
        if not isinstance(values, list):
            raise ValueError("image_paths must be a list of local image paths.")
        image_values.extend(values)

    if not image_values:
        raise ValueError("Provide image_path or image_paths.")

    paths = [parse_local_image_link(value) for value in image_values]
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f"Image does not exist: {path}")
        if not path.is_file():
            raise ValueError(f"Image path is not a file: {path}")
        if path.suffix.lower() not in IMAGE_EXTENSIONS:
            raise ValueError(
                f"Unsupported image extension for {path.name}. "
                f"Supported extensions: {', '.join(sorted(IMAGE_EXTENSIONS))}."
            )

    return paths


def parse_confidence(value: object, field_name: str) -> float:
    try:
        confidence = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be a number from 0.0 to 1.0.") from exc

    if confidence < 0.0 or confidence > 1.0:
        raise ValueError(f"{field_name} must be from 0.0 to 1.0.")
    return confidence


def api_options(payload: dict[str, object]) -> dict[str, object]:
    raw_options = payload.get("options", {})
    if raw_options is None:
        raw_options = {}
    if not isinstance(raw_options, dict):
        raise ValueError("options must be an object.")

    model_variant = str(raw_options.get("model_variant", DEFAULT_MODEL_VARIANT)).lower()
    if model_variant not in MODEL_VARIANTS:
        raise ValueError(
            f"model_variant must be one of: {', '.join(sorted(MODEL_VARIANTS))}."
        )

    view = str(raw_options.get("view", "front")).lower()
    if view not in VALID_VIEWS:
        raise ValueError(f"view must be one of: {', '.join(sorted(VALID_VIEWS))}.")

    no_person = str(raw_options.get("no_person", "copy")).lower()
    if no_person not in VALID_NO_PERSON_MODES:
        raise ValueError(
            f"no_person must be one of: {', '.join(sorted(VALID_NO_PERSON_MODES))}."
        )

    return {
        "view": view,
        "model_variant": model_variant,
        "no_person": no_person,
        "min_detection_confidence": parse_confidence(
            raw_options.get("min_detection_confidence", 0.5),
            "min_detection_confidence",
        ),
        "min_visibility": parse_confidence(raw_options.get("min_visibility", 0.45), "min_visibility"),
    }


def copy_api_inputs(paths: list[Path], batch_id: str) -> tuple[Path, list[dict[str, str]]]:
    batch_input_dir = INPUT_DIR / batch_id
    copied: list[dict[str, str]] = []

    for source in paths:
        filename = secure_filename(source.name) or f"image{source.suffix.lower()}"
        batch_input_dir.mkdir(parents=True, exist_ok=True)
        destination = unique_file_path(batch_input_dir, filename)
        shutil.copy2(source, destination)
        copied.append({"source": str(source), "stored": str(destination)})

    return batch_input_dir, copied


def folder_images(folder: Path) -> list[dict[str, object]]:
    if not folder.exists():
        return []

    images = []
    for path in sorted(folder.rglob("*"), key=lambda item: item.stat().st_mtime, reverse=True):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        relative = path.relative_to(folder).as_posix()
        output_relative = path.relative_to(OUTPUT_DIR).as_posix()
        images.append(
            {
                "name": relative,
                "url": url_for("output_file", filename=output_relative, v=int(path.stat().st_mtime)),
            }
        )
    return images


def output_files(output_dir: Path) -> list[dict[str, str]]:
    files: list[dict[str, str]] = []
    if not output_dir.exists():
        return files

    for path in sorted(output_dir.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        relative_to_output = path.relative_to(OUTPUT_DIR).as_posix()
        files.append(
            {
                "name": path.relative_to(output_dir).as_posix(),
                "path": str(path),
                "url": url_for("output_file", filename=relative_to_output),
            }
        )
    return files


def newest_output_dir() -> Path | None:
    if not OUTPUT_DIR.exists():
        return None

    folders = [path for path in OUTPUT_DIR.iterdir() if path.is_dir()]
    if not folders:
        return None
    return max(folders, key=lambda path: path.stat().st_mtime)


def input_count() -> int:
    return sum(1 for _ in (path for path in INPUT_DIR.rglob("*") if path.suffix.lower() in IMAGE_EXTENSIONS))


@app.get("/")
def index():
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    latest_output_dir = Path(str(last_run["latest_output_dir"])) if last_run["latest_output_dir"] else newest_output_dir()
    outputs = folder_images(latest_output_dir) if latest_output_dir else []

    return render_template(
        "index.html",
        input_dir=INPUT_DIR,
        output_dir=OUTPUT_DIR,
        active_input_dir=last_run["active_input_dir"],
        active_batch_id=last_run["active_batch_id"],
        latest_output_dir=latest_output_dir,
        input_count=input_count(),
        outputs=outputs,
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
        filename = secure_filename(file.filename)
        if not filename or Path(filename).suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        batch_input_dir.mkdir(parents=True, exist_ok=True)
        file.save(unique_file_path(batch_input_dir, filename))
        saved += 1

    if saved:
        last_run["active_batch_id"] = batch_id
        last_run["active_input_dir"] = str(batch_input_dir)
        last_run["summary"] = (
            f"Saved {saved} image{'s' if saved != 1 else ''} to input batch {batch_id}."
        )
    else:
        last_run["summary"] = "No supported images were uploaded."
    last_run["logs"] = []
    return redirect(url_for("index"))


@app.post("/run")
def run_pose():
    model_variant = request.form.get("model_variant", DEFAULT_MODEL_VARIANT)
    if model_variant not in MODEL_VARIANTS:
        model_variant = DEFAULT_MODEL_VARIANT

    settings = {
        "view": request.form.get("view", "front"),
        "model_variant": model_variant,
        "no_person": request.form.get("no_person", "copy"),
        "min_detection_confidence": float(request.form.get("min_detection_confidence", "0.5")),
        "min_visibility": float(request.form.get("min_visibility", "0.45")),
    }
    logs: list[str] = []
    active_input_dir = Path(str(last_run["active_input_dir"])) if last_run["active_input_dir"] else None
    active_batch_id = str(last_run["active_batch_id"]) if last_run["active_batch_id"] else None

    try:
        if active_input_dir is None or active_batch_id is None or not active_input_dir.exists():
            raise RuntimeError("Upload an image batch before generating wireframes.")

        output_batch_dir = OUTPUT_DIR / f"{active_batch_id}_run_{timestamp()}_{uuid4().hex[:4]}"
        result = process_folder(
            input_dir=active_input_dir,
            output_dir=output_batch_dir,
            view=str(settings["view"]),
            min_detection_confidence=float(settings["min_detection_confidence"]),
            min_visibility=float(settings["min_visibility"]),
            no_person_mode=str(settings["no_person"]),
            model_variant=str(settings["model_variant"]),
            model_path=ROOT / MODEL_VARIANTS[str(settings["model_variant"])]["path"],
            model_url=str(MODEL_VARIANTS[str(settings["model_variant"])]["url"]),
            log=logs.append,
        )
        last_run["latest_output_dir"] = str(output_batch_dir)
        summary = (
            f"Processed {result['images']} image{'s' if result['images'] != 1 else ''} from {active_batch_id}; "
            f"wrote {result['written']} output{'s' if result['written'] != 1 else ''} "
            f"with the {settings['model_variant']} model."
        )
        if result["failed"]:
            summary += f" Failed images: {result['failed']}."
        summary += f" Output batch: {output_batch_dir.name}."
    except Exception as exc:
        summary = f"Run failed: {exc}"

    last_run["summary"] = summary
    last_run["logs"] = logs[-80:]
    last_run["settings"] = settings
    return redirect(url_for("index"))


@app.post("/api/pose")
def api_pose():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return api_error("Request body must be a JSON object.")

    try:
        image_paths = validate_image_paths(payload)
        settings = api_options(payload)
    except FileNotFoundError as exc:
        return api_error(str(exc), 404)
    except ValueError as exc:
        return api_error(str(exc), 400)

    operation_id = f"api_{timestamp()}_{uuid4().hex[:4]}"
    logs: list[str] = []

    try:
        active_input_dir, copied_inputs = copy_api_inputs(image_paths, operation_id)
        output_batch_dir = OUTPUT_DIR / f"{operation_id}_run_{timestamp()}_{uuid4().hex[:4]}"

        result = process_folder(
            input_dir=active_input_dir,
            output_dir=output_batch_dir,
            view=str(settings["view"]),
            min_detection_confidence=float(settings["min_detection_confidence"]),
            min_visibility=float(settings["min_visibility"]),
            no_person_mode=str(settings["no_person"]),
            model_variant=str(settings["model_variant"]),
            model_path=ROOT / MODEL_VARIANTS[str(settings["model_variant"])]["path"],
            model_url=str(MODEL_VARIANTS[str(settings["model_variant"])]["url"]),
            log=logs.append,
        )
    except Exception as exc:
        return api_error("Pose generation failed.", 500, exception=str(exc), logs=logs[-80:])

    return jsonify(
        {
            "ok": True,
            "operation_id": operation_id,
            "input_dir": str(active_input_dir),
            "output_dir": str(output_batch_dir),
            "output_url": url_for("api_output_folder", folder=output_batch_dir.name),
            "options": settings,
            "result": result,
            "inputs": copied_inputs,
            "files": output_files(output_batch_dir),
            "logs": logs[-80:],
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
            "files": output_files(output_dir),
        }
    )


@app.get("/outputs/<path:filename>")
def output_file(filename: str):
    return send_from_directory(OUTPUT_DIR, filename)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=7860, debug=False)
