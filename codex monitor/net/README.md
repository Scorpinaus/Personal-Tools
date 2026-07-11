# Codex Usage Monitor (.NET)

This folder contains the C#/.NET 10 Windows conversion of the original PowerShell Codex usage monitor.

## Run

```powershell
dotnet run -- -NoOpen -DashboardPort 8787
```

Normal launch starts the dashboard and the floating Windows desktop limits widget. Double-clicking the published exe starts both without opening a console window. Use `-NoWidget` to suppress the widget, or `-Widget` to run only the widget.

## Publish Compact App

From the repository root, use the protected publisher:

```powershell
.\publish-monitor.ps1
```

The published Windows x64 framework-dependent application is written to:

```text
bin\Release\net10.0-windows\win-x64\publish\codex-usage-monitor.exe
```

Double-click `codex-usage-monitor.exe` to start the dashboard and widget. Keep the other published files and the `dashboard` folder beside the executable: the patched native SQLite library is intentionally not bundled into the executable because single-file packaging can hang during startup.

This default publish is small, but requires the .NET 10 Windows Desktop Runtime on the machine that runs it. The publisher uses temporary intermediate directories and cleans them automatically. To publish a portable self-contained application instead:

```powershell
dotnet publish -c Release --self-contained true -p:SelfContained=true -p:EnableCompressionInSingleFile=true
```

The app accepts the same main dashboard options as the PowerShell monitor, including `-CodexHome`, `-NoOpen`, `-NoWidget`, `-Widget`, `-WidgetRefreshSeconds`, `-DashboardPort`, `-IncludeArchived`, `-CostBasisMode`, `-PricingMode`, and rate-limit history options.

## SQLite Cache

The .NET monitor stores parsed token usage deltas, rate-limit observations, and source attribution estimates in a local SQLite cache named:

```text
codex_usage_monitor.sqlite
```

By default, the cache is placed in the monitor folder when the source tree/start scripts are present; otherwise it is placed beside the executable. The cache is derived data and can be rebuilt from Codex session JSONL files. The current schema uses `session_files`, `token_events`, `rate_limit_events`, and `source_estimate_events`. Schema v3 stores event timestamps as Unix millisecond integers, references sessions through `session_file_id`, and uses compact composite event keys.

Useful options:

```powershell
dotnet run -- -RebuildCache
dotnet run -- -DisableSqliteCache
dotnet run -- -CacheDbPath "C:\path\to\codex_usage_monitor.sqlite"
```
