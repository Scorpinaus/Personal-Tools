param(
    [string]$MonitorExecutable = (Join-Path $PSScriptRoot "net\bin\Release\net10.0-windows\win-x64\publish\codex-usage-monitor.exe"),
    [int]$CheckSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$signature = @"
using System;
using System.Runtime.InteropServices;

public static class ForegroundWindow {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

if (-not ("ForegroundWindow" -as [type])) {
    Add-Type -TypeDefinition $signature
}

function Test-VSCodeForeground {
    $handle = [ForegroundWindow]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) {
        return $false
    }

    $processId = 0
    [void][ForegroundWindow]::GetWindowThreadProcessId($handle, [ref]$processId)
    if ($processId -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
    }
    catch {
        return $false
    }

    return $process.ProcessName -in @("Code", "Code - Insiders")
}

function Start-MonitorWindow {
    if (-not (Test-Path -LiteralPath $MonitorExecutable)) {
        throw "Published monitor not found: $MonitorExecutable. Run publish-monitor.ps1 first."
    }

    Start-Process -FilePath $MonitorExecutable
}

$started = $false
while ($true) {
    if (-not $started -and (Test-VSCodeForeground)) {
        Start-MonitorWindow
        $started = $true
    }

    if ($started) {
        $running = Get-Process codex-usage-monitor -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.Equals($MonitorExecutable, [StringComparison]::OrdinalIgnoreCase) }
        if ($null -eq $running) {
            $started = $false
        }
    }

    Start-Sleep -Seconds $CheckSeconds
}
