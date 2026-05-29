from __future__ import annotations

import math
from pathlib import Path
from typing import Any

import imageio_ffmpeg


def ffmpeg_exe() -> str:
    return imageio_ffmpeg.get_ffmpeg_exe()


def probe_video(video_path: Path) -> dict[str, Any]:
    generator = None
    try:
        generator = imageio_ffmpeg.read_frames(str(video_path))
        metadata = next(generator)
        duration = _positive_float(metadata.get("duration"))
        fps = _positive_float(metadata.get("fps"))
        size = metadata.get("source_size") or metadata.get("size") or (None, None)
        width, height = size if len(size) == 2 else (None, None)
        frame_count = None
        if duration and fps:
            frame_count = math.floor(duration * fps)
        return {
            "name": video_path.name,
            "duration": duration,
            "fps": fps,
            "width": _coerce_int(width),
            "height": _coerce_int(height),
            "estimated_frame_count": frame_count,
        }
    except Exception as exc:
        return {
            "name": video_path.name,
            "duration": None,
            "fps": None,
            "width": None,
            "height": None,
            "estimated_frame_count": None,
            "error": str(exc),
        }
    finally:
        if generator is not None:
            generator.close()


def _positive_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number <= 0:
        return None
    return number


def _coerce_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _coerce_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
