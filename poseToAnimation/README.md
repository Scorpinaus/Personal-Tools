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

## Local API

Start the same local app:

```powershell
.\run_poseToAnimation.bat
```

Then call the synchronous animation endpoint:

```text
POST http://127.0.0.1:7870/api/animation
```

Example request with an explicit sequence:

```powershell
$body = @{
  input_folder = "C:\path\to\frames"
  sequence = @(
    "frame_001.png",
    "frame_002.png",
    "frame_003.png"
  )
  options = @{
    duration_seconds = 4
    repeat_count = 1
    fps = 24
    width = 960
    height = 720
    model_variant = "full"
    min_detection_confidence = 0.5
    min_visibility = 0.45
  }
} | ConvertTo-Json -Depth 4

Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:7870/api/animation" `
  -ContentType "application/json" `
  -Body $body
```

Example request using the folder's natural filename order:

```json
{
  "input_folder": "C:\\path\\to\\frames",
  "options": {
    "duration_seconds": 3,
    "repeat_count": 2,
    "fps": 24
  }
}
```

The API accepts local filesystem paths and local `file://` URLs. It copies the supplied sequence into an isolated API input batch before processing, so the original frame folder is not modified. When `sequence` is provided, each item must be a relative image path inside `input_folder`.

Options:

- `duration_seconds`: total duration of one animation pass
- `repeat_count`: number of times to repeat the rendered pass
- `fps`: output frames per second
- `width`: output canvas width
- `height`: output canvas height
- `model_variant`: `lite`, `full`, or `heavy`
- `min_detection_confidence`: number from `0.0` to `1.0`
- `min_visibility`: number from `0.0` to `1.0`

Successful response:

```json
{
  "ok": true,
  "operation_id": "api_20260529_110000_ab12",
  "input_folder": "C:\\path\\to\\frames",
  "input_dir": "C:\\...\\poseToAnimation\\input\\api_20260529_110000_ab12",
  "output_dir": "C:\\...\\poseToAnimation\\output\\api_20260529_110000_ab12_animation_20260529_110006_cd34",
  "output_url": "/api/outputs/api_20260529_110000_ab12_animation_20260529_110006_cd34",
  "options": {
    "duration_seconds": 4,
    "repeat_count": 1,
    "fps": 24,
    "width": 960,
    "height": 720,
    "model_variant": "full",
    "min_detection_confidence": 0.5,
    "min_visibility": 0.45
  },
  "result": {
    "source_count": 3,
    "valid_pose_count": 3,
    "skipped_count": 0,
    "frame_count": 96
  },
  "inputs": [
    {
      "sequence_index": 1,
      "source": "C:\\path\\to\\frames\\frame_001.png",
      "source_relative": "frame_001.png",
      "stored": "C:\\...\\poseToAnimation\\input\\api_...\\000001__frame_001.png"
    }
  ],
  "files": [
    {
      "name": "stickman_animation.mp4",
      "path": "C:\\...\\stickman_animation.mp4",
      "url": "/outputs/api_.../stickman_animation.mp4"
    },
    {
      "name": "stickman_animation.gif",
      "path": "C:\\...\\stickman_animation.gif",
      "url": "/outputs/api_.../stickman_animation.gif"
    },
    {
      "name": "manifest.json",
      "path": "C:\\...\\manifest.json",
      "url": "/outputs/api_.../manifest.json"
    }
  ],
  "manifest": {},
  "logs": []
}
```

Fetch output folder details later:

```text
GET http://127.0.0.1:7870/api/outputs/<output-folder-name>
```

## Output

Each generated run writes:

```text
stickman_animation.mp4
stickman_animation.gif
manifest.json
```

Repeat count is baked into both output files, so `repeat 3` writes the animation sequence three times.
