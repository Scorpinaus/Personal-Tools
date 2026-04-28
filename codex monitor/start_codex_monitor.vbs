Set shell = CreateObject("WScript.Shell")
script = shell.ExpandEnvironmentStrings("%USERPROFILE%\.codex\tools\codex_usage_monitor.ps1")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """", 0, False
