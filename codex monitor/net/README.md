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
