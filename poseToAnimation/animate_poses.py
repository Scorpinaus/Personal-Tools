from __future__ import annotations

import argparse
import json
import math
import re
import urllib.request
from collections.abc import Callable, Iterable
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from PIL import Image


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}
MODEL_VARIANTS = {
    "lite": {
        "path": Path("assets/pose_landmarker_lite.task"),
        "url": (
            "https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
            "pose_landmarker_lite/float16/1/pose_landmarker_lite.task"
        ),
    },
    "full": {
        "path": Path("assets/pose_landmarker_full.task"),
        "url": (
            "https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
            "pose_landmarker_full/float16/1/pose_landmarker_full.task"
        ),
    },
    "heavy": {
        "path": Path("assets/pose_landmarker_heavy.task"),
        "url": (
            "https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
            "pose_landmarker_heavy/float16/1/pose_landmarker_heavy.task"
        ),
    },
}
DEFAULT_MODEL_VARIANT = "full"
POSE_CONNECTIONS = [
    (connection.start, connection.end)
    for connection in mp.tasks.vision.PoseLandmarksConnections.POSE_LANDMARKS
]
POSE_LANDMARK = mp.tasks.vision.PoseLandmark

LINE_COLOR = (36, 95, 116)
ACCENT_COLOR = (20, 145, 120)
JOINT_COLOR = (31, 35, 34)
BACKGROUND_COLOR = (248, 249, 246)
SHADOW_COLOR = (218, 224, 220)
MAX_EXPORTED_FRAMES = 2400


@dataclass(frozen=True)
class LandmarkPoint:
    x: float
    y: float
    z: float
    visibility: float


@dataclass(frozen=True)
class PoseSample:
    source: str
    landmarks: list[LandmarkPoint]


@dataclass(frozen=True)
class SkippedImage:
    source: str
    reason: str


def natural_key(path: Path) -> list[object]:
    parts = re.split(r"(\d+)", path.as_posix().lower())
    return [int(part) if part.isdigit() else part for part in parts]


def iter_images(input_dir: Path) -> Iterable[Path]:
    for path in sorted(input_dir.rglob("*"), key=natural_key):
        if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
            yield path


def read_image(path: Path) -> np.ndarray | None:
    data = np.fromfile(str(path), dtype=np.uint8)
    if data.size == 0:
        return None
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def ensure_model(model_path: Path, model_url: str, log: Callable[[str], None] = print) -> Path:
    model_path = model_path.resolve()
    if model_path.exists():
        return model_path

    model_path.parent.mkdir(parents=True, exist_ok=True)
    log(f"Downloading pose model to {model_path}")
    urllib.request.urlretrieve(model_url, model_path)
    return model_path


def resolve_model(model_variant: str, model_path: Path | None, model_url: str | None) -> tuple[Path, str]:
    variant = MODEL_VARIANTS.get(model_variant, MODEL_VARIANTS[DEFAULT_MODEL_VARIANT])
    return model_path or variant["path"], model_url or variant["url"]


def extract_landmarks(result: object) -> list[LandmarkPoint] | None:
    all_pose_landmarks = getattr(result, "pose_landmarks", None)
    if not all_pose_landmarks:
        return None
    return [
        LandmarkPoint(lm.x, lm.y, lm.z, getattr(lm, "visibility", 1.0))
        for lm in all_pose_landmarks[0]
    ]


def person_detected(landmarks: list[LandmarkPoint], min_visibility: float) -> bool:
    visible_count = sum(point.visibility >= min_visibility for point in landmarks)
    core_indexes = [
        POSE_LANDMARK.LEFT_SHOULDER.value,
        POSE_LANDMARK.RIGHT_SHOULDER.value,
        POSE_LANDMARK.LEFT_HIP.value,
        POSE_LANDMARK.RIGHT_HIP.value,
    ]
    visible_core = sum(landmarks[index].visibility >= min_visibility for index in core_indexes)
    return visible_count >= 8 and visible_core >= 2


def average_points(points: list[LandmarkPoint]) -> tuple[float, float]:
    return (
        sum(point.x for point in points) / len(points),
        sum(point.y for point in points) / len(points),
    )


def distance(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def normalize_landmarks(
    landmarks: list[LandmarkPoint],
    min_visibility: float,
) -> list[LandmarkPoint]:
    core_indexes = [
        POSE_LANDMARK.LEFT_SHOULDER.value,
        POSE_LANDMARK.RIGHT_SHOULDER.value,
        POSE_LANDMARK.LEFT_HIP.value,
        POSE_LANDMARK.RIGHT_HIP.value,
    ]
    visible_core = [
        landmarks[index]
        for index in core_indexes
        if landmarks[index].visibility >= min_visibility
    ]
    visible = [point for point in landmarks if point.visibility >= min_visibility]
    center_x, center_y = average_points(visible_core or visible)

    left_shoulder = landmarks[POSE_LANDMARK.LEFT_SHOULDER.value]
    right_shoulder = landmarks[POSE_LANDMARK.RIGHT_SHOULDER.value]
    left_hip = landmarks[POSE_LANDMARK.LEFT_HIP.value]
    right_hip = landmarks[POSE_LANDMARK.RIGHT_HIP.value]

    spans = []
    if left_shoulder.visibility >= min_visibility and right_shoulder.visibility >= min_visibility:
        spans.append(distance((left_shoulder.x, left_shoulder.y), (right_shoulder.x, right_shoulder.y)))
    if left_hip.visibility >= min_visibility and right_hip.visibility >= min_visibility:
        spans.append(distance((left_hip.x, left_hip.y), (right_hip.x, right_hip.y)))
    if len(visible) >= 2:
        xs = [point.x for point in visible]
        ys = [point.y for point in visible]
        spans.append(max(max(xs) - min(xs), max(ys) - min(ys)) * 0.45)

    scale = max(spans or [0.2], 0.05)
    return [
        LandmarkPoint(
            x=(point.x - center_x) / scale,
            y=(point.y - center_y) / scale,
            z=point.z / scale,
            visibility=point.visibility,
        )
        for point in landmarks
    ]


def detect_pose_samples(
    input_dir: Path,
    model_path: Path,
    min_detection_confidence: float,
    min_visibility: float,
    log: Callable[[str], None] = print,
) -> tuple[list[PoseSample], list[SkippedImage], int]:
    images = list(iter_images(input_dir))
    if not images:
        return [], [], 0

    base_options = mp.tasks.BaseOptions(model_asset_path=str(model_path))
    options = mp.tasks.vision.PoseLandmarkerOptions(
        base_options=base_options,
        running_mode=mp.tasks.vision.RunningMode.IMAGE,
        num_poses=1,
        min_pose_detection_confidence=min_detection_confidence,
        min_pose_presence_confidence=min_detection_confidence,
        output_segmentation_masks=False,
    )

    samples: list[PoseSample] = []
    skipped: list[SkippedImage] = []
    with mp.tasks.vision.PoseLandmarker.create_from_options(options) as landmarker:
        for image_path in images:
            relative = image_path.relative_to(input_dir).as_posix()
            image = read_image(image_path)
            if image is None:
                skipped.append(SkippedImage(relative, "Unreadable image"))
                log(f"Skipped unreadable image: {relative}")
                continue

            rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            landmarks = extract_landmarks(landmarker.detect(mp_image))
            if landmarks is None or not person_detected(landmarks, min_visibility):
                skipped.append(SkippedImage(relative, "No person pose detected"))
                log(f"Skipped no-pose image: {relative}")
                continue

            samples.append(PoseSample(relative, normalize_landmarks(landmarks, min_visibility)))
            log(f"Detected pose: {relative}")

    return samples, skipped, len(images)


def interpolate_pose(a: PoseSample, b: PoseSample, t: float) -> list[LandmarkPoint]:
    return [
        LandmarkPoint(
            x=start.x + (end.x - start.x) * t,
            y=start.y + (end.y - start.y) * t,
            z=start.z + (end.z - start.z) * t,
            visibility=start.visibility + (end.visibility - start.visibility) * t,
        )
        for start, end in zip(a.landmarks, b.landmarks, strict=True)
    ]


def pose_for_frame(samples: list[PoseSample], frame_index: int, frame_count: int) -> list[LandmarkPoint]:
    if frame_count <= 1:
        return samples[0].landmarks

    transitions = len(samples) - 1
    position = (frame_index / (frame_count - 1)) * transitions
    start_index = min(int(math.floor(position)), transitions - 1)
    t = position - start_index
    return interpolate_pose(samples[start_index], samples[start_index + 1], t)


def landmark_to_pixel(
    point: LandmarkPoint,
    width: int,
    height: int,
    scale: float,
    floor_y: float,
) -> tuple[int, int]:
    x = int(width / 2 + point.x * scale)
    y = int(floor_y + point.y * scale)
    return x, y


def draw_stickman_frame(
    landmarks: list[LandmarkPoint],
    width: int,
    height: int,
    min_visibility: float,
) -> np.ndarray:
    canvas = np.full((height, width, 3), BACKGROUND_COLOR, dtype=np.uint8)
    scale = min(width, height) * 0.18
    floor_y = height * 0.52
    line_width = max(3, int(min(width, height) * 0.008))
    joint_radius = max(4, int(min(width, height) * 0.012))

    shadow_start = (int(width * 0.28), int(height * 0.84))
    shadow_end = (int(width * 0.72), int(height * 0.84))
    cv2.line(canvas, shadow_start, shadow_end, SHADOW_COLOR, max(2, line_width - 1), cv2.LINE_AA)

    points: list[tuple[int, int] | None] = []
    for point in landmarks:
        if point.visibility < min_visibility:
            points.append(None)
            continue
        points.append(landmark_to_pixel(point, width, height, scale, floor_y))

    for start_idx, end_idx in POSE_CONNECTIONS:
        start = points[start_idx]
        end = points[end_idx]
        if start is None or end is None:
            continue
        cv2.line(canvas, start, end, LINE_COLOR, line_width, cv2.LINE_AA)

    left_shoulder = points[POSE_LANDMARK.LEFT_SHOULDER.value]
    right_shoulder = points[POSE_LANDMARK.RIGHT_SHOULDER.value]
    nose = points[POSE_LANDMARK.NOSE.value]
    if left_shoulder and right_shoulder and nose:
        shoulder_width = max(distance(left_shoulder, right_shoulder), 1.0)
        radius = int(max(joint_radius * 2.2, min(shoulder_width * 0.42, min(width, height) * 0.07)))
        cv2.circle(canvas, nose, radius, LINE_COLOR, line_width, cv2.LINE_AA)

    for point in points:
        if point is None:
            continue
        cv2.circle(canvas, point, joint_radius, JOINT_COLOR, -1, cv2.LINE_AA)
        cv2.circle(canvas, point, max(2, joint_radius // 2), ACCENT_COLOR, -1, cv2.LINE_AA)

    return canvas


def render_frames(
    samples: list[PoseSample],
    duration_seconds: float,
    repeat_count: int,
    fps: int,
    width: int,
    height: int,
    min_visibility: float,
) -> list[np.ndarray]:
    base_frame_count = max(2, int(round(duration_seconds * fps)))
    base_frames = [
        draw_stickman_frame(
            pose_for_frame(samples, frame_index, base_frame_count),
            width,
            height,
            min_visibility,
        )
        for frame_index in range(base_frame_count)
    ]

    frames: list[np.ndarray] = []
    for _ in range(repeat_count):
        frames.extend(frame.copy() for frame in base_frames)
    return frames


def write_mp4(path: Path, frames: list[np.ndarray], fps: int, width: int, height: int) -> None:
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(path), fourcc, fps, (width, height))
    if not writer.isOpened():
        raise RuntimeError(f"Could not create MP4 writer for {path}")
    try:
        for frame in frames:
            writer.write(frame)
    finally:
        writer.release()


def write_gif(path: Path, frames: list[np.ndarray], fps: int) -> None:
    pil_frames = [
        Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)).convert("P", palette=Image.Palette.ADAPTIVE)
        for frame in frames
    ]
    duration_ms = max(20, int(round(1000 / fps)))
    pil_frames[0].save(
        path,
        save_all=True,
        append_images=pil_frames[1:],
        duration=duration_ms,
        optimize=False,
        disposal=2,
    )


def clamp_settings(
    duration_seconds: float,
    repeat_count: int,
    fps: int,
    width: int,
    height: int,
) -> tuple[float, int, int, int, int]:
    return (
        min(max(duration_seconds, 0.25), 120.0),
        min(max(repeat_count, 1), 50),
        min(max(fps, 4), 60),
        min(max(width, 240), 1920),
        min(max(height, 240), 1920),
    )


def process_animation(
    input_dir: Path,
    output_dir: Path,
    duration_seconds: float = 4.0,
    repeat_count: int = 1,
    fps: int = 24,
    width: int = 960,
    height: int = 720,
    model_variant: str = DEFAULT_MODEL_VARIANT,
    min_detection_confidence: float = 0.5,
    min_visibility: float = 0.45,
    model_path: Path | None = None,
    model_url: str | None = None,
    log: Callable[[str], None] = print,
) -> dict[str, object]:
    input_dir = input_dir.resolve()
    output_dir = output_dir.resolve()
    if not input_dir.exists():
        raise FileNotFoundError(f"Input folder does not exist: {input_dir}")

    duration_seconds, repeat_count, fps, width, height = clamp_settings(
        duration_seconds, repeat_count, fps, width, height
    )
    expected_frames = max(2, int(round(duration_seconds * fps))) * repeat_count
    if expected_frames > MAX_EXPORTED_FRAMES:
        raise RuntimeError(
            f"Settings would export {expected_frames} frames; reduce seconds, repeats, or FPS "
            f"to stay at or below {MAX_EXPORTED_FRAMES} frames."
        )

    model_path, model_url = resolve_model(model_variant, model_path, model_url)
    model_path = ensure_model(model_path, model_url, log)

    samples, skipped, source_count = detect_pose_samples(
        input_dir=input_dir,
        model_path=model_path,
        min_detection_confidence=min_detection_confidence,
        min_visibility=min_visibility,
        log=log,
    )
    if len(samples) < 2:
        raise RuntimeError("At least two images with detected poses are required for animation.")

    output_dir.mkdir(parents=True, exist_ok=True)
    frames = render_frames(
        samples=samples,
        duration_seconds=duration_seconds,
        repeat_count=repeat_count,
        fps=fps,
        width=width,
        height=height,
        min_visibility=min_visibility,
    )

    mp4_path = output_dir / "stickman_animation.mp4"
    gif_path = output_dir / "stickman_animation.gif"
    write_mp4(mp4_path, frames, fps, width, height)
    write_gif(gif_path, frames, fps)
    log(f"Wrote MP4: {mp4_path}")
    log(f"Wrote GIF: {gif_path}")

    manifest = {
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "source_count": source_count,
        "valid_pose_count": len(samples),
        "skipped_count": len(skipped),
        "duration_seconds": duration_seconds,
        "repeat_count": repeat_count,
        "fps": fps,
        "width": width,
        "height": height,
        "frame_count": len(frames),
        "mp4": mp4_path.name,
        "gif": gif_path.name,
        "poses": [sample.source for sample in samples],
        "skipped": [asdict(item) for item in skipped],
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a stickman animation from ordered pose images.")
    parser.add_argument("--input", default="input", type=Path)
    parser.add_argument("--output", default="output", type=Path)
    parser.add_argument("--duration", default=4.0, type=float)
    parser.add_argument("--repeat", default=1, type=int)
    parser.add_argument("--fps", default=24, type=int)
    parser.add_argument("--width", default=960, type=int)
    parser.add_argument("--height", default=720, type=int)
    parser.add_argument("--model-variant", choices=tuple(MODEL_VARIANTS), default=DEFAULT_MODEL_VARIANT)
    parser.add_argument("--min-detection-confidence", default=0.5, type=float)
    parser.add_argument("--min-visibility", default=0.45, type=float)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    process_animation(
        input_dir=args.input,
        output_dir=args.output,
        duration_seconds=args.duration,
        repeat_count=args.repeat,
        fps=args.fps,
        width=args.width,
        height=args.height,
        model_variant=args.model_variant,
        min_detection_confidence=args.min_detection_confidence,
        min_visibility=args.min_visibility,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
