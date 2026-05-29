from __future__ import annotations

import re
import shutil
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
INPUT_DIR = PROJECT_ROOT / "input"
OUTPUT_DIR = PROJECT_ROOT / "output"

VIDEO_EXTENSIONS = {
    ".mp4",
    ".mov",
    ".avi",
    ".mkv",
    ".webm",
    ".m4v",
    ".wmv",
    ".flv",
    ".mpeg",
    ".mpg",
}


def ensure_base_dirs() -> None:
    INPUT_DIR.mkdir(exist_ok=True)
    OUTPUT_DIR.mkdir(exist_ok=True)


def sanitize_name(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", name.strip())
    safe = safe.strip("._-")
    return safe or "video"


def video_path_from_name(video_name: str) -> Path:
    ensure_base_dirs()
    candidate = (INPUT_DIR / video_name).resolve()
    if INPUT_DIR.resolve() not in candidate.parents:
        raise ValueError("Video path must stay inside the input folder.")
    if not candidate.exists() or not candidate.is_file():
        raise FileNotFoundError(f"Video not found: {video_name}")
    if candidate.suffix.lower() not in VIDEO_EXTENSIONS:
        raise ValueError("Unsupported video file extension.")
    return candidate


def list_input_videos() -> list[Path]:
    ensure_base_dirs()
    return sorted(
        [
            path
            for path in INPUT_DIR.iterdir()
            if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
        ],
        key=lambda path: path.name.lower(),
    )


def prepare_output_dir(video_path: Path, overwrite_mode: str) -> Path:
    ensure_base_dirs()
    base_name = sanitize_name(video_path.stem)
    output_dir = OUTPUT_DIR / base_name

    if overwrite_mode == "overwrite":
        if output_dir.exists():
            shutil.rmtree(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        return output_dir

    if overwrite_mode == "append":
        output_dir.mkdir(parents=True, exist_ok=True)
        return output_dir

    if overwrite_mode != "unique":
        raise ValueError("Invalid overwrite mode.")

    if not output_dir.exists():
        output_dir.mkdir(parents=True)
        return output_dir

    counter = 2
    while True:
        candidate = OUTPUT_DIR / f"{base_name}_{counter}"
        if not candidate.exists():
            candidate.mkdir(parents=True)
            return candidate
        counter += 1


def frame_pattern(output_dir: Path, image_format: str, append: bool) -> str:
    extension = image_format.lower()
    if extension not in {"jpg", "png"}:
        raise ValueError("Invalid image format.")

    start_index = 1
    if append:
        indexes = []
        for path in output_dir.glob(f"frame_*.{extension}"):
            match = re.fullmatch(r"frame_(\d+)\." + re.escape(extension), path.name)
            if match:
                indexes.append(int(match.group(1)))
        if indexes:
            start_index = max(indexes) + 1

    return str(output_dir / f"frame_%06d.{extension}"), start_index
