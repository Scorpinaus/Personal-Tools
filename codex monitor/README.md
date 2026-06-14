# Codex Usage Monitor

Codex Usage Monitor is a local Windows dashboard and console monitor for Codex session usage. It reads Codex JSONL session files, summarizes rate-limit and token activity, and serves a browser dashboard from `127.0.0.1`.

The project currently has two implementations:

- `codex_usage_monitor.ps1`: the PowerShell monitor entry point, backed by dot-sourced modules in `ps/`.
- `net/`: a .NET 8 port with SQLite-backed indexing and a self-contained Windows publish target.

## What It Shows

- Current Codex rate-limit windows, remaining percentage, and reset times.
- Rolling token usage for recent activity windows.
- Daily token usage with a 90 day, 180 day, and 1 year heatmap view.
- Conversation-level token usage, cache hit ratio, and context-window details.
- Estimated token cost by model, source estimate, and no-compaction scenario.
- Rate-limit history sampled over time.

Cost values are local estimates. They are useful for trend analysis, but they should not be treated as billing records.

## Requirements

- Windows.
- PowerShell for the script implementation.
- Codex session data under `%USERPROFILE%\.codex`, or another folder passed with `-CodexHome`.
- Optional: .NET 8 SDK if you want to run or publish the C# version.

The published .NET executable is self-contained for Windows x64 and does not require the .NET runtime to be installed.

## Quick Start

From the repository root:

```bat
start_codex_monitor.cmd
```

By default the dashboard starts at:

```text
http://127.0.0.1:8787/
```

If port `8787` is busy, the monitor tries the next available local port. The dashboard opens automatically unless `-NoOpen` is passed.

To stop the PowerShell monitor:

```bat
stop_codex_monitor.cmd
```

The dashboard also has a `Stop` button that calls the local shutdown endpoint.

## Running the PowerShell Monitor

Start the browser dashboard:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex_usage_monitor.ps1
```

Run without opening the browser:

```powershell
.\codex_usage_monitor.ps1 -NoOpen -DashboardPort 8787
```

Print one snapshot to the console:

```powershell
.\codex_usage_monitor.ps1 -Once -Console
```

Use a custom Codex home:

```powershell
.\codex_usage_monitor.ps1 -CodexHome "C:\path\to\.codex"
```

Backfill rate-limit history from existing session files:

```powershell
.\codex_usage_monitor.ps1 -BackfillRateLimitHistory -Once
```

Run the dashboard wrapper directly:

```powershell
.\codex_usage_dashboard.ps1 -Port 8787
```

Start hidden with Windows Script Host:

```powershell
wscript.exe .\start_codex_monitor.vbs
```

Start the monitor when VS Code becomes the foreground app:

```powershell
.\start_codex_usage_monitor_when_vscode_active.ps1
```

## Running the .NET Monitor

Run from source:

```powershell
cd .\net
dotnet run -- -NoOpen -DashboardPort 8787
```

Run the published Windows executable:

```powershell
.\net\bin\Release\net8.0\win-x64\publish\codex-usage-monitor.exe
```

Publish a fresh self-contained executable:

```powershell
cd .\net
dotnet publish -c Release
```

The publish output must keep the executable and dashboard assets together:

```text
net\bin\Release\net8.0\win-x64\publish\
  codex-usage-monitor.exe
  dashboard\
    index.html
    daily.html
    styles.css
    app.js
    daily.js
```

## Tests

Run the PowerShell smoke suite from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\powershell_monitor_smoke.ps1
```

The suite creates temporary synthetic Codex session data and verifies library snapshot generation, `-Once -Console`, dashboard `/api/usage`, and `/api/shutdown`.

## Common Options

| Option | Default | Notes |
| --- | --- | --- |
| `-CodexHome` | `%USERPROFILE%\.codex` or `CODEX_HOME` | Root folder that contains Codex session data. |
| `-DashboardPort` / `-Port` | `8787` | Local dashboard port. `-Port` is accepted by the dashboard wrapper and .NET app. |
| `-NoOpen` | off | Start the server without launching a browser. |
| `-Once` | off | Generate one snapshot and exit. Useful with `-Console` or `-BackfillRateLimitHistory`. |
| `-Console` | off | Print monitor output in the terminal instead of serving the dashboard. |
| `-RefreshSeconds` | `3` | Console refresh interval. |
| `-IncludeArchived` | off | Include `%CODEX_HOME%\archived_sessions` in scans. |
| `-MaxFiles` | `5` | Number of recent session files used for the latest snapshot search. |
| `-TailLines` | `500` | Number of lines read from each recent session file for latest snapshot search. |
| `-RollingMaxFiles` | `5` | Number of recent session files used for rolling token scans. Use `0` for all files. |
| `-RollingTailLines` | `0` | Optional override for rolling token scan depth. |
| `-CostMaxFiles` | `5` | Number of recent session files used for cost, period, and daily scans. Use `0` for all files. |
| `-CostTailLines` | `0` | Optional override for cost scan depth. |
| `-RateLimitHistoryDays` | `8` | Retention window for sampled rate-limit history. |
| `-RateLimitHistorySampleSeconds` | `30` | Minimum spacing for duplicate-ish rate-limit samples. |
| `-DisableRateLimitHistory` | off | Do not write or display rate-limit history samples. |
| `-BackfillRateLimitHistory` | off | Rebuild rate-limit history from existing sessions. |
| `-CostBasisMode` | `ApiUsdEstimate` | `ApiUsdEstimate` or `CodexCredits`. |
| `-PricingMode` | `Standard` | `Standard`, `Batch`, `Flex`, or `Priority`. |
| `-UsdToSgdRate` | `1.274` | Exchange-rate multiplier used by the dashboard display. |

.NET-only cache options:

| Option | Default | Notes |
| --- | --- | --- |
| `-DisableSqliteCache` | off | Read session files without using the SQLite index. |
| `-RebuildCache` | off | Recreate the SQLite cache before reading. |
| `-CacheDbPath` | `codex_usage_monitor.sqlite` near the monitor | Override the SQLite cache file path. |
| `-DashboardRoot` | app base `dashboard` folder | Override the static asset folder served by the .NET dashboard. |

## Dashboard Pages and Endpoints

- `/index.html`: overview dashboard with rate limits, rolling usage, costs, and conversation usage.
- `/daily.html`: daily token usage heatmap and recent daily breakdown.
- `/api/usage`: JSON snapshot consumed by the dashboard.
- `/api/shutdown`: local dashboard shutdown endpoint.

The server binds to loopback only, so the dashboard is intended for local use on the same machine.

## Data and Cache Files

The monitor reads Codex session JSONL files from:

```text
%CODEX_HOME%\sessions
%CODEX_HOME%\archived_sessions       # only with -IncludeArchived
```

The monitor can write derived local data:

```text
codex_usage_monitor.sqlite                         # .NET SQLite cache
%CODEX_HOME%\usage-history\rate_limit_samples.jsonl # rate-limit history samples
```

The SQLite database and rate-limit samples are derived from Codex session data. They can be deleted and rebuilt if they become stale.

## Development Notes

- The PowerShell dashboard serves assets from `dashboard/`.
- The PowerShell entry points dot-source implementation files from `ps/`.
- The .NET app serves and publishes assets from `net/dashboard/`.
- Keep both dashboard folders in sync when changing the UI.
- `net/CodexUsageMonitor.csproj` publishes a Windows x64, self-contained, single-file executable and copies `net/dashboard/**` beside it.
- The repository intentionally commits the published Windows executable and dashboard publish assets under `net/bin/Release/net8.0/win-x64/publish/`.
- Local SQLite cache files are ignored by git.

## Project Layout

```text
README.md
codex_usage_monitor.ps1                         PowerShell monitor entry point
codex_usage_dashboard.ps1                       PowerShell dashboard entry point
ps/                                             PowerShell monitor/dashboard modules
tests/powershell_monitor_smoke.ps1             PowerShell smoke tests
start_codex_monitor.cmd                         Visible PowerShell launcher
start_codex_monitor.vbs                         Hidden-window launcher
stop_codex_monitor.cmd                          Stop helper for PowerShell monitor/port 8787
start_codex_usage_monitor_when_vscode_active.ps1
                                                 Starts monitor when VS Code is foreground
dashboard/                                      Static assets for PowerShell dashboard
net/                                            .NET 8 implementation
net/README.md                                   .NET-specific notes
net/Program.cs                                  .NET monitor, parser, cache, and server
net/CodexUsageMonitor.csproj                    .NET publish configuration
net/dashboard/                                  Static assets for .NET dashboard
net/bin/Release/net8.0/win-x64/publish/         Committed Windows publish output
```

## Troubleshooting

If the dashboard says no snapshot was found, confirm that `-CodexHome` points at a folder containing `sessions`.

If port `8787` is unavailable, check the terminal output for the fallback port or pass a different `-DashboardPort`.

If dashboard assets are missing in the .NET publish output, run `dotnet publish -c Release` from `net/` and keep the generated `dashboard/` folder beside the executable.

If data looks stale in the .NET monitor, retry with:

```powershell
.\net\bin\Release\net8.0\win-x64\publish\codex-usage-monitor.exe -RebuildCache
```

If PowerShell blocks script execution, launch with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\codex_usage_monitor.ps1
```
