# Codex Usage Monitor (.NET)

This folder contains the C#/.NET 8 conversion of the original PowerShell Codex usage monitor.

## Run

```powershell
dotnet run -- -NoOpen -DashboardPort 8787
```

Double-clicking the published exe starts the dashboard without opening a console window.

## Publish Self-Contained Exe

```powershell
dotnet publish -c Release
```

The published Windows x64 self-contained executable is written to:

```text
bin\Release\net8.0\win-x64\publish\codex-usage-monitor.exe
```

The app accepts the same main dashboard options as the PowerShell monitor, including `-CodexHome`, `-NoOpen`, `-DashboardPort`, `-IncludeArchived`, `-CostBasisMode`, `-PricingMode`, and rate-limit history options.

## SQLite Cache

The .NET monitor stores parsed token usage deltas, rate-limit observations, and source attribution estimates in a local SQLite cache named:

```text
codex_usage_monitor.sqlite
```

By default, the cache is placed in the monitor folder when the source tree/start scripts are present; otherwise it is placed beside the executable. The cache is derived data and can be rebuilt from Codex session JSONL files. The current schema uses `session_files`, `token_events`, `rate_limit_events`, and `source_estimate_events`.

Useful options:

```powershell
dotnet run -- -RebuildCache
dotnet run -- -DisableSqliteCache
dotnet run -- -CacheDbPath "C:\path\to\codex_usage_monitor.sqlite"
```
