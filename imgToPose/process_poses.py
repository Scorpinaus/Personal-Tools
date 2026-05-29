from __future__ import annotations

import argparse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from math import cos, radians, sin
from pathlib import Path
from typing import Iterable

import cv2
import mediapipe as mp
import numpy as np


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
DEFAULT_MODEL_PATH = MODEL_VARIANTS[DEFAULT_MODEL_VARIANT]["path"]
DEFAULT_MODEL_URL = MODEL_VARIANTS[DEFAULT_MODEL_VARIANT]["url"]
POSE_CONNECTIONS = [
    (connection.start, connection.end)
    for connection in mp.tasks.vision.PoseLandmarksConnections.POSE_LANDMARKS
]
POSE_LANDMARK = mp.tasks.vision.PoseLandmark

FRONT_COLOR = (0, 230, 255)
SIDE_COLOR = (255, 160, 40)
BACK_COLOR = (80, 220, 120)
JOINT_COLOR = (30, 30, 30)
NO_PERSON_SUFFIX = "_no_person"


@dataclass(frozen=True)
class LandmarkPoint:
    x: float
    y: float
    z: float
    visibility: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Detect people in images and generate pose wireframe outputs."
    )
    parser.add_argument(
        "--input",
        default="input",
        type=Path,
        help="Folder containing source images. Defaults to ./input.",
    )
    parser.add_argument(
        "--output",
        default="output",
        type=Path,
        help="Folder for processed images. Defaults to ./output.",
    )
    parser.add_argument(
        "--view",
        choices=("front", "side", "back", "all"),
        default="front",
        help="Wireframe view to render. Use 'all' to create front, side, and back outputs.",
    )
    parser.add_argument(
        "--min-detection-confidence",
        default=0.5,
        type=float,
        help="MediaPipe minimum person detection confidence.",
    )
    parser.add_argument(
        "--min-visibility",
        default=0.45,
        type=float,
        help="Minimum landmark visibility used before drawing a joint or limb.",
    )
    parser.add_argument(
        "--no-person",
        choices=("copy", "skip"),
        default="copy",
        help="When no person is detected, copy the original image or skip writing output.",
    )
    parser.add_argument(
        "--model-variant",
        choices=tuple(MODEL_VARIANTS),
        default=DEFAULT_MODEL_VARIANT,
        help="Pose Landmarker model size. Heavy is slower but usually more accurate.",
    )
    parser.add_argument(
        "--model",
        default=None,
        type=Path,
        help="Optional path to a custom MediaPipe Pose Landmarker .task model.",
    )
    parser.add_argument(
        "--model-url",
        default=None,
        help="Optional URL used to download a missing custom .task model.",
    )
    return parser.parse_args()


def read_image(path: Path) -> np.ndarray | None:
    data = np.fromfile(str(path), dtype=np.uint8)
    if data.size == 0:
        return None
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def write_image(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    success, encoded = cv2.imencode(path.suffix, image)
    if not success:
        raise RuntimeError(f"Could not encode output image: {path}")
    encoded.tofile(str(path))


def iter_images(input_dir: Path) -> Iterable[Path]:
    for path in sorted(input_dir.rglob("*")):
        if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
            yield path


def extract_landmarks(result: object, attribute: str) -> list[LandmarkPoint] | None:
    all_pose_landmarks = getattr(result, attribute, None)
    if not all_pose_landmarks:
        return None
    pose_landmarks = all_pose_landmarks[0]
    return [
        LandmarkPoint(lm.x, lm.y, lm.z, getattr(lm, "visibility", 1.0))
        for lm in pose_landmarks
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


def ensure_model(model_path: Path, model_url: str) -> Path:
    model_path = model_path.resolve()
    if model_path.exists():
        return model_path

    model_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading pose model to {model_path}")
    urllib.request.urlretrieve(model_url, model_path)
    return model_path


def resolve_model(model_variant: str, model_path: Path | None, model_url: str | None) -> tuple[Path, str]:
    variant = MODEL_VARIANTS[model_variant]
    return model_path or variant["path"], model_url or variant["url"]


def output_path_for(input_path: Path, input_dir: Path, output_dir: Path, view: str, no_person: bool) -> Path:
    relative = input_path.relative_to(input_dir)
    suffix = NO_PERSON_SUFFIX if no_person else f"_pose_{view}"
    return output_dir / relative.parent / f"{relative.stem}{suffix}{relative.suffix}"


def render_rotated_skeleton(
    image_shape: tuple[int, int, int],
    landmarks: list[LandmarkPoint],
    view: str,
    min_visibility: float,
    normalized_coordinates: bool,
) -> np.ndarray:
    height, width = image_shape[:2]
    canvas = np.full((height, width, 3), 255, dtype=np.uint8)
    angle_by_view = {"front": 0, "side": 90, "back": 180}
    color_by_view = {"front": FRONT_COLOR, "side": SIDE_COLOR, "back": BACK_COLOR}
    angle = radians(angle_by_view[view])

    projected: list[tuple[float, float] | None] = []
    visible_points: list[tuple[float, float]] = []

    for point in landmarks:
        if point.visibility < min_visibility:
            projected.append(None)
            continue

        x = point.x - 0.5 if normalized_coordinates else point.x
        y = point.y - 0.5 if normalized_coordinates else point.y
        z = point.z
        rotated_x = x * cos(angle) + z * sin(angle)
        rotated_y = y
        projected_point = (rotated_x, rotated_y)
        projected.append(projected_point)
        visible_points.append(projected_point)

    if not visible_points:
        return canvas

    xs = np.array([point[0] for point in visible_points], dtype=np.float32)
    ys = np.array([point[1] for point in visible_points], dtype=np.float32)
    min_x, max_x = float(xs.min()), float(xs.max())
    min_y, max_y = float(ys.min()), float(ys.max())
    span_x = max(max_x - min_x, 1e-6)
    span_y = max(max_y - min_y, 1e-6)

    margin = int(min(width, height) * 0.12)
    fit_width = max(width - (margin * 2), 1)
    fit_height = max(height - (margin * 2), 1)
    scale = min(fit_width / span_x, fit_height / span_y)

    def to_pixel(point: tuple[float, float]) -> tuple[int, int]:
        x, y = point
        px = int((x - min_x) * scale + ((width - span_x * scale) / 2))
        py = int((y - min_y) * scale + ((height - span_y * scale) / 2))
        return px, py

    line_color = color_by_view[view]
    for start_idx, end_idx in POSE_CONNECTIONS:
        start = projected[start_idx]
        end = projected[end_idx]
        if start is None or end is None:
            continue
        cv2.line(canvas, to_pixel(start), to_pixel(end), line_color, 4, cv2.LINE_AA)

    for point in projected:
        if point is None:
            continue
        center = to_pixel(point)
        cv2.circle(canvas, center, 6, JOINT_COLOR, -1, cv2.LINE_AA)
        cv2.circle(canvas, center, 3, line_color, -1, cv2.LINE_AA)

    return canvas


def render_view(
    image: np.ndarray,
    image_landmarks: list[LandmarkPoint],
    world_landmarks: list[LandmarkPoint] | None,
    view: str,
    min_visibility: float,
) -> np.ndarray:
    if view == "front":
        return render_rotated_skeleton(
            image.shape,
            image_landmarks,
            view,
            min_visibility,
            normalized_coordinates=True,
        )

    skeleton_landmarks = world_landmarks or image_landmarks
    return render_rotated_skeleton(
        image.shape,
        skeleton_landmarks,
        view,
        min_visibility,
        normalized_coordinates=world_landmarks is None,
    )


def process_image(
    image_path: Path,
    input_dir: Path,
    output_dir: Path,
    landmarker: object,
    views: list[str],
    min_visibility: float,
    no_person_mode: str,
    log: Callable[[str], None] = print,
) -> tuple[int, int]:
    image = read_image(image_path)
    if image is None:
        log(f"Skipped unreadable image: {image_path}")
        return 0, 1

    rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
    result = landmarker.detect(mp_image)
    landmarks = extract_landmarks(result, "pose_landmarks")
    world_landmarks = extract_landmarks(result, "pose_world_landmarks")

    if landmarks is None or not person_detected(landmarks, min_visibility):
        if no_person_mode == "copy":
            output_path = output_path_for(image_path, input_dir, output_dir, "front", no_person=True)
            write_image(output_path, image)
            log(f"No person detected, copied original: {output_path}")
            return 1, 0
        log(f"No person detected, skipped: {image_path}")
        return 0, 0

    for view in views:
        rendered = render_view(image, landmarks, world_landmarks, view, min_visibility)
        output_path = output_path_for(image_path, input_dir, output_dir, view, no_person=False)
        write_image(output_path, rendered)
        log(f"Wrote {view} pose: {output_path}")

    return len(views), 0


def process_folder(
    input_dir: Path,
    output_dir: Path,
    view: str = "front",
    min_detection_confidence: float = 0.5,
    min_visibility: float = 0.45,
    no_person_mode: str = "copy",
    model_variant: str = DEFAULT_MODEL_VARIANT,
    model_path: Path | None = None,
    model_url: str | None = None,
    log: Callable[[str], None] = print,
) -> dict[str, int]:
    input_dir = input_dir.resolve()
    output_dir = output_dir.resolve()
    model_path, model_url = resolve_model(model_variant, model_path, model_url)
    model_path = ensure_model(model_path, model_url)

    if not input_dir.exists():
        raise FileNotFoundError(f"Input folder does not exist: {input_dir}")

    views = ["front", "side", "back"] if view == "all" else [view]
    images = list(iter_images(input_dir))
    if not images:
        log(f"No images found in {input_dir}")
        return {"images": 0, "written": 0, "failed": 0}

    output_dir.mkdir(parents=True, exist_ok=True)

    written = 0
    failed = 0
    base_options = mp.tasks.BaseOptions(model_asset_path=str(model_path))
    options = mp.tasks.vision.PoseLandmarkerOptions(
        base_options=base_options,
        running_mode=mp.tasks.vision.RunningMode.IMAGE,
        num_poses=1,
        min_pose_detection_confidence=min_detection_confidence,
        min_pose_presence_confidence=min_detection_confidence,
        output_segmentation_masks=False,
    )

    with mp.tasks.vision.PoseLandmarker.create_from_options(options) as landmarker:
        for image_path in images:
            image_written, image_failed = process_image(
                image_path=image_path,
                input_dir=input_dir,
                output_dir=output_dir,
                landmarker=landmarker,
                views=views,
                min_visibility=min_visibility,
                no_person_mode=no_person_mode,
                log=log,
            )
            written += image_written
            failed += image_failed

    log(f"Done. Output images written: {written}. Failed images: {failed}.")
    return {"images": len(images), "written": written, "failed": failed}


def main() -> int:
    args = parse_args()
    result = process_folder(
        input_dir=args.input,
        output_dir=args.output,
        view=args.view,
        min_detection_confidence=args.min_detection_confidence,
        min_visibility=args.min_visibility,
        no_person_mode=args.no_person,
        model_variant=args.model_variant,
        model_path=args.model,
        model_url=args.model_url,
    )
    return 1 if result["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
