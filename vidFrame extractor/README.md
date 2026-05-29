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
