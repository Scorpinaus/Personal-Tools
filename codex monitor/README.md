# Codex Usage Monitor

A local dashboard for tracking Codex usage from your Codex session files. It shows rate-limit status, rolling token usage, conversation token usage, estimated token costs, and rate-limit history.

## Features

- Browser dashboard served locally, by default at `http://localhost:8787`
- Rate-limit and rolling token usage views
- Estimated token costs by model and source
- Conversation-level token summaries
- Local SQLite cache for faster repeated reads
- PowerShell implementation with a .NET 8 version in `net/`

## Requirements

- Windows PowerShell
- Codex session data in `%USERPROFILE%\.codex`, or another folder passed with `-CodexHome`
- Optional: .NET 8 SDK to run or publish the C# version

## Run

Start the monitor with the included launcher:

```bat
start_codex_monitor.cmd
```

Or run the PowerShell script directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex_usage_monitor.ps1
```

The dashboard opens automatically unless `-NoOpen` is passed.

Useful options:

```powershell
.\codex_usage_monitor.ps1 -NoOpen -DashboardPort 8787
.\codex_usage_monitor.ps1 -CodexHome "C:\path\to\.codex"
.\codex_usage_monitor.ps1 -Once -Console
```

## Stop

Use the included stop script:

```bat
stop_codex_monitor.cmd
```

## .NET Version

The `net/` folder contains a C#/.NET 8 version of the monitor:

```powershell
cd net
dotnet run -- -NoOpen -DashboardPort 8787
```

See `net/README.md` for publish and cache details.

## Project Layout

```text
dashboard/                         Static dashboard assets
codex_usage_monitor.ps1            Main PowerShell monitor and dashboard server
codex_usage_dashboard.ps1          Dashboard wrapper script
start_codex_monitor.cmd            Windows launcher
stop_codex_monitor.cmd             Stop helper
net/                               .NET 8 implementation
```

## Notes

The `codex_usage_monitor.sqlite` file is a local derived cache. It can be rebuilt from Codex session JSONL files and does not need to be committed.
