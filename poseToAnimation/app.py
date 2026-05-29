from __future__ import annotations

from datetime import datetime
from pathlib import Path
from uuid import uuid4

from flask import Flask, redirect, render_template, request, send_from_directory, url_for
from werkzeug.utils import secure_filename

from animate_poses import (
    DEFAULT_MODEL_VARIANT,
    IMAGE_EXTENSIONS,
    MODEL_VARIANTS,
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


@app.get("/inputs/<path:filename>")
def input_file(filename: str):
    return send_from_directory(INPUT_DIR, filename)


@app.get("/outputs/<path:filename>")
def output_file(filename: str):
    return send_from_directory(OUTPUT_DIR, filename)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=7870, debug=False)
