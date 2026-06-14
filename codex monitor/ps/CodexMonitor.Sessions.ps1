# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

function Get-SessionFiles {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit
    )

    $roots = @((Join-Path $Root "sessions"))
    if ($Archived) {
        $roots += (Join-Path $Root "archived_sessions")
    }

    $files = foreach ($sessionRoot in $roots) {
        if (Test-Path -LiteralPath $sessionRoot) {
            Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter "*.jsonl"
        }
    }

    $sortedFiles = @($files | Sort-Object LastWriteTime -Descending)
    if ($Limit -le 0) {
        return $sortedFiles
    }

    return @($sortedFiles | Select-Object -First $Limit)
}

function Get-SessionFilesSince {
    param(
        [string]$Root,
        [switch]$Archived,
        [datetime]$SinceUtc
    )

    return @(Get-SessionFiles -Root $Root -Archived:$Archived -Limit 0 |
        Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc } |
        Sort-Object LastWriteTime -Descending)
}

function Get-SessionLines {
    param(
        [string]$Path,
        [int]$Tail
    )

    if ($Tail -le 0) {
        return @(Get-Content -LiteralPath $Path)
    }

    return @(Get-Content -LiteralPath $Path -Tail $Tail)
}
