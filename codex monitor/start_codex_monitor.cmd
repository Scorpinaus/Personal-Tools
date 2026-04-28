@echo off
set "SCRIPT=%USERPROFILE%\.codex\tools\codex_usage_monitor.ps1"

if not exist "%SCRIPT%" (
  echo Codex usage monitor script not found:
  echo %SCRIPT%
  pause
  exit /b 1
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
