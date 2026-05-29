@echo off
setlocal

cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
  echo Creating Python virtual environment...
  python -m venv .venv
  if errorlevel 1 (
    echo Failed to create the virtual environment.
    pause
    exit /b 1
  )
)

echo Installing dependencies...
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
  echo Failed to install dependencies.
  pause
  exit /b 1
)

if not exist "input" mkdir "input"
if not exist "output" mkdir "output"

echo.
echo Starting Video Frame Extractor...
echo Open http://127.0.0.1:8000 if the browser does not open automatically.
echo Press Ctrl+C in this window to stop the server.
echo.

start "" "http://127.0.0.1:8000"
".venv\Scripts\python.exe" -m uvicorn backend.main:app --host 127.0.0.1 --port 8000

pause
