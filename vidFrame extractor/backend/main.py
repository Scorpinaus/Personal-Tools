from __future__ import annotations

import shutil
import time
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .extractor import ExtractionRequest, jobs
from .output_summary import output_file_from_name, output_folder_from_name, summarize_output_dir
from .paths import (
    INPUT_DIR,
    OUTPUT_DIR,
    PROJECT_ROOT,
    VIDEO_EXTENSIONS,
    ensure_base_dirs,
    list_input_videos,
    sanitize_name,
    video_path_from_name,
)
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


class ExtractOptions(BaseModel):
    mode: str = Field(default="all", pattern="^(all|seconds|milliseconds|frames)$")
    interval: float = Field(default=1, ge=0)
    format: str = Field(default="jpg", pattern="^(jpg|png)$")
    overwrite: str = Field(default="unique", pattern="^(unique|overwrite|append)$")


class LocalExtractPayload(BaseModel):
    video_path: str = Field(min_length=1)
    options: ExtractOptions = Field(default_factory=ExtractOptions)
    wait: bool = True
    timeout_seconds: float = Field(default=3600, ge=1)


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


@app.post("/api/extract/local")
def extract_local(payload: LocalExtractPayload) -> dict[str, object]:
    try:
        video_path, input_info = _import_local_video(payload.video_path)
        metadata = probe_video(video_path)
        request = ExtractionRequest(
            video_path=video_path,
            mode=payload.options.mode,
            interval=payload.options.interval,
            image_format=payload.options.format,
            overwrite_mode=payload.options.overwrite,
        )
        job = jobs.create(request)
        if payload.wait:
            _wait_for_job(job.id, payload.timeout_seconds)
        return _operation_response(job.id, input_info, metadata, payload.options)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except TimeoutError as exc:
        job_id = str(exc)
        return _operation_response(job_id, input_info, metadata, payload.options, timed_out=True)
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


@app.get("/api/outputs/{folder_name}")
def output_summary(folder_name: str) -> dict[str, object]:
    try:
        output_dir = output_folder_from_name(folder_name)
        summary = summarize_output_dir(output_dir)
        return {"output": summary}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/outputs/{folder_name}/files")
def output_files(folder_name: str) -> dict[str, object]:
    try:
        output_dir = output_folder_from_name(folder_name)
        frames = sorted(
            path
            for path in output_dir.iterdir()
            if path.is_file() and path.suffix.lower() in {".jpg", ".png"}
        )
        files = [
            {
                "name": path.name,
                "size": path.stat().st_size,
                "url": f"/api/outputs/{folder_name}/files/{path.name}",
            }
            for path in frames
        ]
        return {"folder_name": folder_name, "count": len(files), "files": files}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/outputs/{folder_name}/files/{file_name}")
def output_file(folder_name: str, file_name: str) -> FileResponse:
    try:
        return FileResponse(output_file_from_name(folder_name, file_name))
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/")
def index() -> FileResponse:
    return FileResponse(FRONTEND_DIR / "index.html")


app.mount("/", StaticFiles(directory=FRONTEND_DIR), name="frontend")


def _large_warning(frame_count: object) -> bool:
    return isinstance(frame_count, int) and frame_count >= 100_000


def _import_local_video(video_reference: str) -> tuple[Path, dict[str, object]]:
    ensure_base_dirs()

    try:
        input_video = video_path_from_name(video_reference)
        return input_video, {
            "source_path": str(input_video),
            "stored_name": input_video.name,
            "stored_path": str(input_video),
            "imported": False,
        }
    except (FileNotFoundError, ValueError):
        pass

    source = Path(video_reference).expanduser()
    if not source.is_absolute():
        source = (PROJECT_ROOT / source).resolve()
    else:
        source = source.resolve()

    if not source.exists() or not source.is_file():
        raise FileNotFoundError(f"Video not found: {video_reference}")
    if source.suffix.lower() not in VIDEO_EXTENSIONS:
        raise ValueError("Unsupported video file extension.")

    input_root = INPUT_DIR.resolve()
    if input_root in source.parents:
        return source, {
            "source_path": str(source),
            "stored_name": source.name,
            "stored_path": str(source),
            "imported": False,
        }

    target = _unique_input_path(sanitize_name(source.name), source.suffix.lower())
    shutil.copy2(source, target)
    return target, {
        "source_path": str(source),
        "stored_name": target.name,
        "stored_path": str(target),
        "imported": True,
    }


def _unique_input_path(filename: str, suffix: str) -> Path:
    target = INPUT_DIR / filename
    counter = 2
    while target.exists():
        target = INPUT_DIR / f"{Path(filename).stem}_{counter}{suffix}"
        counter += 1
    return target


def _wait_for_job(job_id: str, timeout_seconds: float) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        job = jobs.get(job_id)
        if not job:
            raise FileNotFoundError("Job not found.")
        if job.status not in {"queued", "running"}:
            return
        time.sleep(0.25)
    raise TimeoutError(job_id)


def _operation_response(
    job_id: str,
    input_info: dict[str, object],
    metadata: dict[str, Any],
    options: ExtractOptions,
    timed_out: bool = False,
) -> dict[str, object]:
    job = jobs.get(job_id)
    if not job:
        raise FileNotFoundError("Job not found.")

    elapsed = None
    if job.finished_at:
        elapsed = job.finished_at - job.started_at

    return {
        "status": "running" if timed_out else job.status,
        "timed_out": timed_out,
        "job_id": job.id,
        "poll_url": f"/api/jobs/{job.id}",
        "input_video": {
            **input_info,
            "metadata": metadata,
        },
        "options": options.model_dump(),
        "output": summarize_output_dir(job.output_dir),
        "timing": {
            "started_at": job.started_at,
            "finished_at": job.finished_at,
            "elapsed_seconds": elapsed,
        },
        "job": job.public(),
    }
