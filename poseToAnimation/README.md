# Pose To Animation

Create a stickman animation from an ordered batch of pose images.

## What it does

- Reads uploaded images from an input batch folder.
- Detects one person pose in each image with MediaPipe Pose.
- Sorts images by filename.
- Interpolates between detected poses.
- Exports both `stickman_animation.mp4` and `stickman_animation.gif`.
- Supports total animation duration, repeat count, FPS, canvas size, model quality, and detection thresholds.

At least two images with detected poses are required.

## Setup

```powershell
cd "folder path"
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## Usage

Start the local app:

```powershell
.\run_poseToAnimation.bat
```

Open:

```text
http://127.0.0.1:7870
```

In the UI:

1. Choose images or a folder.
2. Upload the batch.
3. Set seconds, repeats, FPS, and canvas size.
4. Create the animation.
5. Preview or download MP4/GIF output.

## CLI

```powershell
python .\animate_poses.py --input .\input\my_batch --output .\output\my_animation --duration 4 --repeat 2 --fps 24
```

## Output

Each generated run writes:

```text
stickman_animation.mp4
stickman_animation.gif
manifest.json
```

Repeat count is baked into both output files, so `repeat 3` writes the animation sequence three times.
