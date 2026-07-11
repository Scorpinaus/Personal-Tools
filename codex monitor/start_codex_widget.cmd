@echo off
set "EXE=%~dp0net\bin\Release\net10.0-windows\win-x64\publish\codex-usage-monitor.exe"

if not exist "%EXE%" (
  echo Published Codex usage monitor not found:
  echo %EXE%
  echo Run publish-monitor.ps1 first.
  pause
  exit /b 1
)

start "" "%EXE%" -Widget
