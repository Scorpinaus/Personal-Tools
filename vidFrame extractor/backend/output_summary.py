from __future__ import annotations

from pathlib import Path

from .paths import OUTPUT_DIR


IMAGE_EXTENSIONS = {".jpg", ".png"}


def output_folder_from_name(folder_name: str) -> Path:
    candidate = (OUTPUT_DIR / folder_name).resolve()
    output_root = OUTPUT_DIR.resolve()
    if output_root != candidate and output_root not in candidate.parents:
        raise ValueError("Output folder must stay inside the output folder.")
    if not candidate.exists() or not candidate.is_dir():
        raise FileNotFoundError(f"Output folder not found: {folder_name}")
    return candidate


def output_file_from_name(folder_name: str, file_name: str) -> Path:
    folder = output_folder_from_name(folder_name)
    candidate = (folder / file_name).resolve()
    if folder.resolve() not in candidate.parents:
        raise ValueError("Output file must stay inside the requested output folder.")
    if not candidate.exists() or not candidate.is_file():
        raise FileNotFoundError(f"Output file not found: {file_name}")
    if candidate.suffix.lower() not in IMAGE_EXTENSIONS:
        raise ValueError("Unsupported output file extension.")
    return candidate


def summarize_output_dir(output_dir: str | Path | None) -> dict[str, object] | None:
    if not output_dir:
        return None

    folder = Path(output_dir)
    if not folder.exists() or not folder.is_dir():
        return {
            "folder_name": folder.name,
            "folder_path": str(folder),
            "folder_url": f"/api/outputs/{folder.name}",
            "exists": False,
            "frame_count": 0,
            "total_bytes": 0,
            "files_url": f"/api/outputs/{folder.name}/files",
        }

    frames = sorted(
        path
        for path in folder.iterdir()
        if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
    )
    total_bytes = sum(path.stat().st_size for path in frames)
    sample = [path.name for path in frames[:5]]

    return {
        "folder_name": folder.name,
        "folder_path": str(folder),
        "folder_url": f"/api/outputs/{folder.name}",
        "exists": True,
        "frame_count": len(frames),
        "total_bytes": total_bytes,
        "first_frame": frames[0].name if frames else None,
        "last_frame": frames[-1].name if frames else None,
        "sample_files": sample,
        "files_url": f"/api/outputs/{folder.name}/files",
    }
