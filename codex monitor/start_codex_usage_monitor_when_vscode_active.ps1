param(
    [string]$MonitorScript = (Join-Path $env:USERPROFILE ".codex\tools\codex_usage_monitor.ps1"),
    [int]$CheckSeconds = 5,
    [int]$RefreshSeconds = 3
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
    if (-not (Test-Path -LiteralPath $MonitorScript)) {
        throw "Monitor script not found: $MonitorScript"
    }

    $argumentList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-NoExit",
        "-File", "`"$MonitorScript`"",
        "-RefreshSeconds", "$RefreshSeconds"
    )

    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -WindowStyle Normal
}

$started = $false
while ($true) {
    if (-not $started -and (Test-VSCodeForeground)) {
        Start-MonitorWindow
        $started = $true
    }

    if ($started) {
        $running = Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
            Where-Object { $_.CommandLine -like "*codex_usage_monitor.ps1*" }
        if ($null -eq $running) {
            $started = $false
        }
    }

    Start-Sleep -Seconds $CheckSeconds
}
