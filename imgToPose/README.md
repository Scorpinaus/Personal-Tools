# Image To Pose

Batch-process images and draw a person skeleton/wireframe when a person is detected.

## What it does

- Reads every image in the `input` folder.
- Detects a person pose with MediaPipe Pose.
- Writes processed images to the `output` folder.
- Copies the original image unchanged when no person is detected, so there is no wireframe in the output.
- Supports `front`, `side`, `back`, or `all` view rendering.
- Supports `Lite`, `Full`, and `Heavy` MediaPipe model variants.
- Downloads the MediaPipe Pose Landmarker model to `assets/` automatically the first time it runs.

The `front`, `side`, and `back` views render clean wireframe-only skeletons on a white canvas. Side/back rendering uses MediaPipe `pose_world_landmarks` when available, with normalized image landmarks as a fallback. Since one image cannot reveal hidden body geometry, side/back views are still estimated projections rather than true novel-camera reconstructions.

## Setup

```powershell
cd "C:\Users\Admin\Personal Tools\imgToPose"
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## Usage

Put images in:

```text
input/
```

Run:

```powershell
python .\process_poses.py --view front
```

Choose model quality:

```powershell
python .\process_poses.py --model-variant heavy --view all
```

Render all angles:

```powershell
python .\process_poses.py --view all
```

Use custom folders:

```powershell
python .\process_poses.py --input "C:\path\to\images" --output "C:\path\to\pose-output" --view side
```

Skip output when no person is detected:

```powershell
python .\process_poses.py --no-person skip
```

Use a specific local model:

```powershell
python .\process_poses.py --model "C:\path\to\pose_landmarker.task"
```

## Frontend UI

Start the local app:

```powershell
.\run_imgToPose.bat
```

Then open:

```text
http://127.0.0.1:7860
```

In the UI:

1. Choose one or more images.
2. Click `Upload`.
3. Select `Front`, `Side`, `Back`, or `All`.
4. Select `Lite`, `Full`, or `Heavy`.
5. Click `Generate`.

Each upload creates a separate input batch folder:

```text
input/batch_YYYYMMDD_HHMMSS_abcdef/
```

The frontend only processes the active uploaded batch. It does not reprocess every image in `input/`.

Each generate run creates a separate output batch folder:

```text
output/batch_YYYYMMDD_HHMMSS_abcdef_run_YYYYMMDD_HHMMSS_ab12/
```

The UI gallery shows the latest output batch.

## Model variants

- `Lite`: fastest, lowest quality.
- `Full`: balanced default.
- `Heavy`: slowest, usually best pose estimation quality for real photos.

## Output names

- Person detected: `image_pose_front.jpg`, `image_pose_side.jpg`, `image_pose_back.jpg`
- No person detected: `image_no_person.jpg`

## Notes

This project uses the MediaPipe Tasks Pose Landmarker API. MediaPipe returns 33 body landmarks with normalized image coordinates plus depth values, which are used here to draw and rotate the skeleton views.
