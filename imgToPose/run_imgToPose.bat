@echo off
setlocal

cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    python -m venv .venv
)

call ".venv\Scripts\activate.bat"
python -m pip install -r requirements.txt

start "" "http://127.0.0.1:7860"
python app.py

pause
