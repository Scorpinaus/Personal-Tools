[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$IncludeCache,
    [switch]$IncludePublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspace = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$netRoot = Join-Path $workspace "net"
$publishRoot = Join-Path $netRoot "bin\Release\net10.0-windows\win-x64\publish"
$publishExe = Join-Path $publishRoot "codex-usage-monitor.exe"

function Assert-WorkspacePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside workspace: $full"
    }
    return $full
}

function Get-PathBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) { return [int64]$item.Length }
    return [int64]((Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum)
}

function Add-Target([Collections.Generic.List[string]]$List, [string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $full = Assert-WorkspacePath $Path
        if (-not $List.Contains($full)) { $List.Add($full) }
    }
}

$targets = [Collections.Generic.List[string]]::new()
foreach ($relative in @(
    ".test-tmp",
    "net\.artifacts",
    "net\.publish-artifacts",
    "net\.diagnostic-artifacts",
    "net\CodexUsageMonitor-App",
    "net\CodexUsageMonitor-Fixed",
    "net\obj",
    "net\bin\Debug"
)) {
    Add-Target $targets (Join-Path $workspace $relative)
}

$releaseRoot = Join-Path $netRoot "bin\Release"
if (Test-Path -LiteralPath $releaseRoot) {
    Get-ChildItem -LiteralPath $releaseRoot -Force | Where-Object { $_.Name -ne "net10.0-windows" } |
        ForEach-Object { Add-Target $targets $_.FullName }
}

$frameworkRoot = Join-Path $releaseRoot "net10.0-windows"
if (Test-Path -LiteralPath $frameworkRoot) {
    Get-ChildItem -LiteralPath $frameworkRoot -Force | Where-Object { $_.Name -ne "win-x64" } |
        ForEach-Object { Add-Target $targets $_.FullName }
}

$ridRoot = Join-Path $frameworkRoot "win-x64"
if (Test-Path -LiteralPath $ridRoot) {
    Get-ChildItem -LiteralPath $ridRoot -Force | Where-Object { $_.Name -ne "publish" } |
        ForEach-Object { Add-Target $targets $_.FullName }
}

if ($IncludePublish) {
    $running = @(Get-Process codex-usage-monitor -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($publishRoot, [StringComparison]::OrdinalIgnoreCase) })
    if ($running.Count -gt 0) {
        throw "Close the published monitor before removing its application folder."
    }
    Add-Target $targets $publishRoot
}

if ($IncludeCache) {
    if (Get-Process codex-usage-monitor -ErrorAction SilentlyContinue) {
        throw "Close the .NET monitor before removing its SQLite cache."
    }
    foreach ($name in @("codex_usage_monitor.sqlite", "codex_usage_monitor.sqlite-shm", "codex_usage_monitor.sqlite-wal")) {
        Add-Target $targets (Join-Path $workspace $name)
    }
}

$totalBytes = [int64]0
foreach ($target in $targets) { $totalBytes += Get-PathBytes $target }

if ($targets.Count -eq 0) {
    Write-Host "No removable generated artifacts were found."
    exit 0
}

Write-Host ("Generated cleanup candidates: {0} item(s), {1:N2} MB" -f $targets.Count, ($totalBytes / 1MB))
foreach ($target in $targets) {
    Write-Host ("  {0} ({1:N2} MB)" -f $target, ((Get-PathBytes $target) / 1MB))
}

foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess($target, "Remove generated artifact")) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

if (-not $IncludePublish -and -not (Test-Path -LiteralPath $publishExe)) {
    Write-Warning "The protected production executable was not present before or after cleanup."
}

