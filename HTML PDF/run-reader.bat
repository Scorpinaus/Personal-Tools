@echo off
setlocal

set "PORT=8765"
if not "%~1"=="" set "PORT=%~1"

cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo Python was not found on PATH.
  echo Install Python or run a local static server from this folder.
  pause
  exit /b 1
)

echo Starting PDF Reader at http://127.0.0.1:%PORT%/index.html
echo Keep this window open while using the reader.
echo Press Ctrl+C to stop the local server.

start "" powershell -NoProfile -Command "Start-Sleep -Milliseconds 800; Start-Process 'http://127.0.0.1:%PORT%/index.html'"

python -m http.server %PORT% --bind 127.0.0.1
