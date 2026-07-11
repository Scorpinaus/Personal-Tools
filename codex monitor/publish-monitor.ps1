[CmdletBinding()]
param(
    [switch]$NoRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspace = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$project = Join-Path $workspace "net\CodexUsageMonitor.csproj"
$publishRoot = Join-Path $workspace "net\bin\Release\net10.0-windows\win-x64\publish"
$productionExe = Join-Path $publishRoot "codex-usage-monitor.exe"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("CodexUsageMonitorPublish\" + [guid]::NewGuid().ToString("N"))
$tempArtifacts = Join-Path $tempRoot "artifacts"
$tempPublish = Join-Path $tempRoot "publish"
$backup = Join-Path $tempRoot "previous-publish"
$replacementStarted = $false

$running = @(Get-Process codex-usage-monitor -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($publishRoot, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    throw "Close the published Codex Usage Monitor before publishing a replacement."
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $arguments = @(
        "publish", $project,
        "-c", "Release",
        "--self-contained", "false",
        "--artifacts-path", $tempArtifacts,
        "-o", $tempPublish
    )
    if ($NoRestore) { $arguments += "--no-restore" }

    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

    $required = @(
        "codex-usage-monitor.exe",
        "codex-usage-monitor.dll",
        "codex-usage-monitor.runtimeconfig.json",
        "Microsoft.Data.Sqlite.dll",
        "e_sqlite3.dll",
        "dashboard\index.html",
        "dashboard\app.js"
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $tempPublish $relative) -PathType Leaf)) {
            throw "Published package is missing required file: $relative"
        }
    }

    if (Test-Path -LiteralPath $publishRoot) {
        Copy-Item -LiteralPath $publishRoot -Destination $backup -Recurse -Force
    }

    $replacementStarted = $true
    if (Test-Path -LiteralPath $publishRoot) {
        Get-ChildItem -LiteralPath $publishRoot -Force | Remove-Item -Recurse -Force
    }
    else {
        New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $tempPublish '*') -Destination $publishRoot -Recurse -Force

    if (-not (Test-Path -LiteralPath $productionExe -PathType Leaf)) {
        throw "Production executable verification failed after replacement."
    }

    $files = Get-ChildItem -LiteralPath $publishRoot -Recurse -File
    $bytes = ($files | Measure-Object Length -Sum).Sum
    Write-Host ("Published {0} files ({1:N2} MB) to {2}" -f $files.Count, ($bytes / 1MB), $publishRoot)
}
catch {
    if ($replacementStarted -and (Test-Path -LiteralPath $backup)) {
        if (Test-Path -LiteralPath $publishRoot) {
            Get-ChildItem -LiteralPath $publishRoot -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path (Join-Path $backup '*') -Destination $publishRoot -Recurse -Force
        Write-Warning "The previous production package was restored."
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
