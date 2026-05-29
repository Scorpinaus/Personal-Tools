from __future__ import annotations

import shutil
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .extractor import ExtractionRequest, jobs
from .paths import INPUT_DIR, OUTPUT_DIR, VIDEO_EXTENSIONS, ensure_base_dirs, list_input_videos, sanitize_name, video_path_from_name
from .video_probe import ffmpeg_exe, probe_video


FRONTEND_DIR = Path(__file__).resolve().parents[1] / "frontend"

app = FastAPI(title="Video Frame Extractor")
ensure_base_dirs()


class ExtractPayload(BaseModel):
    video: str
    mode: str = Field(pattern="^(all|seconds|milliseconds|frames)$")
    interval: float = Field(default=1, ge=0)
    format: str = Field(default="jpg", pattern="^(jpg|png)$")
    overwrite: str = Field(default="unique", pattern="^(unique|overwrite|append)$")


@app.get("/api/health")
def health() -> dict[str, str]:
    return {
        "status": "ok",
        "ffmpeg": ffmpeg_exe(),
        "input_dir": str(INPUT_DIR),
        "output_dir": str(OUTPUT_DIR),
    }


@app.get("/api/videos")
def videos() -> dict[str, object]:
    items = []
    for path in list_input_videos():
        stat = path.stat()
        items.append(
            {
                "name": path.name,
                "size": stat.st_size,
                "modified": stat.st_mtime,
            }
        )
    return {"videos": items, "input_dir": str(INPUT_DIR)}


@app.post("/api/videos/upload")
async def upload_video(file: UploadFile = File(...)) -> dict[str, object]:
    ensure_base_dirs()
    filename = sanitize_name(Path(file.filename or "video").name)
    suffix = Path(filename).suffix.lower()
    if suffix not in VIDEO_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Unsupported video file extension.")

    target = INPUT_DIR / filename
    counter = 2
    while target.exists():
        target = INPUT_DIR / f"{Path(filename).stem}_{counter}{suffix}"
        counter += 1

    with target.open("wb") as output:
        shutil.copyfileobj(file.file, output)
    return {"name": target.name, "size": target.stat().st_size}


@app.get("/api/metadata")
def metadata(video: str) -> dict[str, object]:
    try:
        path = video_path_from_name(video)
        data = probe_video(path)
        data["large_output_warning"] = _large_warning(data.get("estimated_frame_count"))
        return data
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/extract")
def extract(payload: ExtractPayload) -> dict[str, object]:
    try:
        video_path = video_path_from_name(payload.video)
        request = ExtractionRequest(
            video_path=video_path,
            mode=payload.mode,
            interval=payload.interval,
            image_format=payload.format,
            overwrite_mode=payload.overwrite,
        )
        job = jobs.create(request)
        return job.public()
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/jobs/{job_id}")
def job_status(job_id: str) -> dict[str, object]:
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found.")
    return job.public()


@app.post("/api/jobs/{job_id}/cancel")
def cancel_job(job_id: str) -> dict[str, object]:
    job = jobs.cancel(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found.")
    return job.public()


@app.get("/")
def index() -> FileResponse:
    return FileResponse(FRONTEND_DIR / "index.html")


app.mount("/", StaticFiles(directory=FRONTEND_DIR), name="frontend")


def _large_warning(frame_count: object) -> bool:
    return isinstance(frame_count, int) and frame_count >= 100_000
