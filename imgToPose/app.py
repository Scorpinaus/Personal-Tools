from __future__ import annotations

from datetime import datetime
from pathlib import Path
from uuid import uuid4

from flask import Flask, redirect, render_template, request, send_from_directory, url_for
from werkzeug.utils import secure_filename

from process_poses import DEFAULT_MODEL_PATH, DEFAULT_MODEL_URL, IMAGE_EXTENSIONS, process_folder


ROOT = Path(__file__).resolve().parent
INPUT_DIR = ROOT / "input"
OUTPUT_DIR = ROOT / "output"

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


def folder_images(folder: Path) -> list[dict[str, object]]:
    if not folder.exists():
        return []

    images = []
    for path in sorted(folder.rglob("*"), key=lambda item: item.stat().st_mtime, reverse=True):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        relative = path.relative_to(folder).as_posix()
        images.append(
            {
                "name": relative,
                "url": url_for("output_file", filename=relative, v=int(path.stat().st_mtime)),
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
    settings = {
        "view": request.form.get("view", "front"),
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
            model_path=ROOT / DEFAULT_MODEL_PATH,
            model_url=DEFAULT_MODEL_URL,
            log=logs.append,
        )
        last_run["latest_output_dir"] = str(output_batch_dir)
        summary = (
            f"Processed {result['images']} image{'s' if result['images'] != 1 else ''} from {active_batch_id}; "
            f"wrote {result['written']} output{'s' if result['written'] != 1 else ''}."
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


@app.get("/outputs/<path:filename>")
def output_file(filename: str):
    return send_from_directory(OUTPUT_DIR, filename)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=7860, debug=False)
