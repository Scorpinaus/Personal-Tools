from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from .paths import frame_pattern, prepare_output_dir
from .video_probe import ffmpeg_exe, probe_video


VALID_MODES = {"all", "seconds", "milliseconds", "frames"}
VALID_FORMATS = {"jpg", "png"}
VALID_OVERWRITE = {"unique", "overwrite", "append"}


@dataclass
class ExtractionRequest:
    video_path: Path
    mode: str
    interval: float
    image_format: str
    overwrite_mode: str


@dataclass
class Job:
    id: str
    video_name: str
    output_dir: str | None = None
    status: str = "queued"
    progress: float | None = None
    frame: int = 0
    current_time: float | None = None
    duration: float | None = None
    started_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    error: str | None = None
    command: list[str] = field(default_factory=list)
    recent_output: deque[str] = field(default_factory=lambda: deque(maxlen=30))
    cancel_requested: bool = False
    process: subprocess.Popen[str] | None = None

    def public(self) -> dict[str, object]:
        return {
            "id": self.id,
            "video_name": self.video_name,
            "output_dir": self.output_dir,
            "status": self.status,
            "progress": self.progress,
            "frame": self.frame,
            "current_time": self.current_time,
            "duration": self.duration,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "error": self.error,
            "recent_output": list(self.recent_output),
        }


class JobManager:
    def __init__(self) -> None:
        self._jobs: dict[str, Job] = {}
        self._lock = threading.Lock()

    def create(self, request: ExtractionRequest) -> Job:
        job = Job(id=uuid.uuid4().hex, video_name=request.video_path.name)
        with self._lock:
            self._jobs[job.id] = job
        thread = threading.Thread(target=self._run, args=(job, request), daemon=True)
        thread.start()
        return job

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def cancel(self, job_id: str) -> Job | None:
        job = self.get(job_id)
        if not job:
            return None
        job.cancel_requested = True
        if job.process and job.status == "running":
            try:
                job.process.terminate()
            except OSError:
                pass
        return job

    def _run(self, job: Job, request: ExtractionRequest) -> None:
        try:
            validate_request(request)
            metadata = probe_video(request.video_path)
            job.duration = metadata.get("duration") if isinstance(metadata.get("duration"), float) else None

            output_dir = prepare_output_dir(request.video_path, request.overwrite_mode)
            job.output_dir = str(output_dir)
            pattern, start_number = frame_pattern(
                output_dir,
                request.image_format,
                append=request.overwrite_mode == "append",
            )
            command = build_ffmpeg_command(request, pattern, start_number)
            job.command = command
            job.status = "running"

            creation_flags = 0
            if os.name == "nt":
                creation_flags = subprocess.CREATE_NEW_PROCESS_GROUP

            job.process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                creationflags=creation_flags,
            )

            assert job.process.stdout is not None
            for line in job.process.stdout:
                line = line.strip()
                if line:
                    job.recent_output.append(line)
                    update_progress(job, line)
                if job.cancel_requested:
                    terminate_process(job.process)
                    break

            return_code = job.process.wait()
            if job.cancel_requested:
                job.status = "cancelled"
            elif return_code == 0:
                job.status = "completed"
                job.progress = 1.0
            else:
                job.status = "failed"
                job.error = "FFmpeg exited with code {0}.".format(return_code)
        except Exception as exc:
            job.status = "failed"
            job.error = str(exc)
        finally:
            job.finished_at = time.time()
            job.process = None


def validate_request(request: ExtractionRequest) -> None:
    if request.mode not in VALID_MODES:
        raise ValueError("Invalid extraction mode.")
    if request.image_format not in VALID_FORMATS:
        raise ValueError("Invalid image format.")
    if request.overwrite_mode not in VALID_OVERWRITE:
        raise ValueError("Invalid overwrite mode.")
    if request.mode != "all" and request.interval <= 0:
        raise ValueError("Interval must be greater than zero.")


def build_ffmpeg_command(request: ExtractionRequest, pattern: str, start_number: int) -> list[str]:
    command = [
        ffmpeg_exe(),
        "-hide_banner",
        "-nostdin",
        "-y",
        "-i",
        str(request.video_path),
    ]

    filters: list[str] = []
    if request.mode == "seconds":
        filters.append(f"fps={1 / request.interval:.8f}")
    elif request.mode == "milliseconds":
        filters.append(f"fps={1000 / request.interval:.8f}")
    elif request.mode == "frames":
        step = max(1, int(request.interval))
        filters.append(f"select='not(mod(n,{step}))'")

    if filters:
        command.extend(["-vf", ",".join(filters)])

    if request.mode == "frames":
        command.extend(["-vsync", "vfr"])
    elif request.mode == "all":
        command.extend(["-vsync", "0"])

    if request.image_format == "jpg":
        command.extend(["-q:v", "2"])

    command.extend(
        [
            "-start_number",
            str(start_number),
            "-progress",
            "pipe:1",
            "-nostats",
            pattern,
        ]
    )
    return command


def update_progress(job: Job, line: str) -> None:
    if "=" not in line:
        return
    key, value = line.split("=", 1)
    if key == "frame":
        try:
            job.frame = int(value)
        except ValueError:
            pass
    elif key == "out_time_ms":
        try:
            seconds = int(value) / 1_000_000
            job.current_time = seconds
            if job.duration and job.duration > 0:
                job.progress = min(0.999, max(0.0, seconds / job.duration))
        except ValueError:
            pass
    elif key == "progress" and value == "end":
        job.progress = 1.0


def terminate_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "nt":
            process.send_signal(signal.CTRL_BREAK_EVENT)
        else:
            process.terminate()
    except OSError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


jobs = JobManager()
