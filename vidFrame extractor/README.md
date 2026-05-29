# Video Frame Extractor

A local CPU-first web app for splitting videos into image frames.

## Setup

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## Run

```powershell
.\.venv\Scripts\python.exe -m uvicorn backend.main:app --reload
```

Open:

```text
http://127.0.0.1:8000
```

## Folders

Place videos in:

```text
input/
```

Extracted frames are written to:

```text
output/<video_name>/
```

Example:

```text
input/my test video.mp4
output/my_test_video/frame_000001.jpg
```

## Modes

- Every frame
- Every N seconds
- Every N milliseconds
- Every N frames

The app uses the FFmpeg executable bundled by `imageio-ffmpeg`, prefers CPU decoding, and streams frames directly to disk.

## API

The web UI uses the same backend API that external callers can use. For a full local-file operation, call:

```text
POST /api/extract/local
```

The video path must exist on the same machine that is running this FastAPI server. If the path is outside `input/`, the server copies it into `input/` first and then extracts frames into `output/`.

### Request

```json
{
  "video_path": "C:\\Users\\Admin\\Videos\\clip.mp4",
  "options": {
    "mode": "seconds",
    "interval": 1,
    "format": "jpg",
    "overwrite": "unique"
  },
  "wait": true,
  "timeout_seconds": 3600
}
```

Options:

- `mode`: `all`, `seconds`, `milliseconds`, or `frames`
- `interval`: the interval value for every mode except `all`
- `format`: `jpg` or `png`
- `overwrite`: `unique`, `overwrite`, or `append`
- `wait`: `true` waits for completion before returning; `false` returns immediately with a job ID
- `timeout_seconds`: maximum wait time when `wait` is `true`

### PowerShell Example

```powershell
$body = @{
  video_path = "C:\Users\Admin\Videos\clip.mp4"
  options = @{
    mode = "seconds"
    interval = 1
    format = "jpg"
    overwrite = "unique"
  }
  wait = $true
  timeout_seconds = 3600
} | ConvertTo-Json -Depth 4

Invoke-RestMethod `
  -Uri "http://127.0.0.1:8000/api/extract/local" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body
```

### Response

The response includes the job ID, copied input details, metadata, output folder link, frame count, and operation timing:

```json
{
  "status": "completed",
  "timed_out": false,
  "job_id": "abc123",
  "poll_url": "/api/jobs/abc123",
  "input_video": {
    "source_path": "C:\\Users\\Admin\\Videos\\clip.mp4",
    "stored_name": "clip.mp4",
    "stored_path": "C:\\...\\vidFrame extractor\\input\\clip.mp4",
    "imported": true,
    "metadata": {
      "duration": 12.3,
      "fps": 30.0,
      "width": 1920,
      "height": 1080,
      "estimated_frame_count": 369
    }
  },
  "output": {
    "folder_name": "clip",
    "folder_path": "C:\\...\\vidFrame extractor\\output\\clip",
    "folder_url": "/api/outputs/clip",
    "frame_count": 13,
    "files_url": "/api/outputs/clip/files"
  }
}
```

If `wait` is `false`, poll the job:

```text
GET /api/jobs/{job_id}
```

Output helpers:

```text
GET /api/outputs/{folder_name}
GET /api/outputs/{folder_name}/files
GET /api/outputs/{folder_name}/files/{file_name}
```
