# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

function Get-RateLimitHistoryPath {
    param([string]$Root)

    return (Join-Path $Root "usage-history\rate_limit_samples.jsonl")
}

function Convert-ToIsoUtcString {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return ([datetime]$Value).ToUniversalTime().ToString("o")
    }
    catch {
        return [string]$Value
    }
}

function Convert-FromHistoryDate {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse([string]$Value).UtcDateTime
    }
    catch {
        return $null
    }
}

function Format-RateLimitResetTime {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return ([datetime]$Value).ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return [string]$Value
    }
}

function Get-RateLimitHistoryRows {
    param(
        [string]$Root,
        [int]$Days = $RateLimitHistoryDays
    )

    $path = Get-RateLimitHistoryPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    $cutoffUtc = [DateTime]::UtcNow.AddDays(-1 * [Math]::Max(1, $Days))
    $rows = @()
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $row = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        $sampledAt = Convert-FromHistoryDate (Get-PropValue $row @("sampled_at", "SampledAt"))
        if ($null -eq $sampledAt -or $sampledAt -lt $cutoffUtc) {
            continue
        }

        $rows += [pscustomobject]@{
            SampledAt = $sampledAt
            EventTimestamp = Get-PropValue $row @("event_timestamp", "EventTimestamp")
            PlanType = Get-PropValue $row @("plan_type", "PlanType")
            Window = Get-PropValue $row @("window", "Window")
            UsedPercent = [double](Get-PropValue $row @("used_percent", "UsedPercent"))
            RemainingPercent = [double](Get-PropValue $row @("remaining_percent", "RemainingPercent"))
            WindowMinutes = Get-PropValue $row @("window_minutes", "WindowMinutes")
            ResetsAt = Get-PropValue $row @("resets_at", "ResetsAt")
            Session = Get-PropValue $row @("session", "Session")
            SourceFile = Get-PropValue $row @("source_file", "SourceFile")
        }
    }

    return @($rows | Sort-Object SampledAt)
}

function Save-RateLimitHistoryRows {
    param(
        [string]$Root,
        [object[]]$Rows
    )

    $path = Get-RateLimitHistoryPath -Root $Root
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $lines = @(
        foreach ($row in $Rows) {
            [pscustomobject]@{
                sampled_at = Convert-ToIsoUtcString $row.SampledAt
                event_timestamp = $row.EventTimestamp
                plan_type = $row.PlanType
                window = $row.Window
                used_percent = $row.UsedPercent
                remaining_percent = $row.RemainingPercent
                window_minutes = $row.WindowMinutes
                resets_at = $row.ResetsAt
                session = $row.Session
                source_file = $row.SourceFile
            } | ConvertTo-Json -Compress
        }
    )

    try {
        Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    }
    catch {
        Write-Warning ("Unable to save rate-limit history to {0}: {1}" -f $path, $_.Exception.Message)
    }
}

function Write-RateLimitHistorySamples {
    param(
        [string]$Root,
        [object]$Snapshot,
        [int]$RetentionDays = $RateLimitHistoryDays,
        [int]$SampleSeconds = $RateLimitHistorySampleSeconds
    )

    if ($DisableRateLimitHistory -or $null -eq $Snapshot -or $Snapshot.RateLimitRows.Count -eq 0) {
        return
    }

    $nowUtc = [DateTime]::UtcNow
    $rows = @(Get-RateLimitHistoryRows -Root $Root -Days $RetentionDays)
    $changed = $false

    foreach ($rateRow in $Snapshot.RateLimitRows) {
        $currentResetsAt = Format-RateLimitResetTime $rateRow.ResetsAt
        $last = @($rows | Where-Object { $_.Window -eq $rateRow.Window } | Sort-Object SampledAt -Descending | Select-Object -First 1)
        $shouldAppend = $true
        if ($last.Count -gt 0) {
            $lastRow = $last[0]
            $ageSeconds = ($nowUtc - [datetime]$lastRow.SampledAt).TotalSeconds
            $sameUsed = [Math]::Abs([double]$lastRow.UsedPercent - [double]$rateRow.UsedPercent) -lt 0.01
            $sameReset = [string]$lastRow.ResetsAt -eq [string]$currentResetsAt
            $shouldAppend = -not ($sameUsed -and $sameReset -and $ageSeconds -lt [Math]::Max(1, $SampleSeconds))
        }

        if (-not $shouldAppend) {
            continue
        }

        $rows += [pscustomobject]@{
            SampledAt = $nowUtc
            EventTimestamp = $Snapshot.Timestamp
            PlanType = $Snapshot.PlanType
            Window = $rateRow.Window
            UsedPercent = $rateRow.UsedPercent
            RemainingPercent = $rateRow.RemainingPercent
            WindowMinutes = $rateRow.WindowMinutes
            ResetsAt = $currentResetsAt
            Session = $Snapshot.Session
            SourceFile = $Snapshot.SourceFile
        }
        $changed = $true
    }

    if ($changed) {
        Save-RateLimitHistoryRows -Root $Root -Rows @(Compress-RateLimitHistoryRows -Rows $rows -SampleSeconds $SampleSeconds)
    }
}

function Get-RateLimitHistorySummary {
    param([object[]]$Rows)

    $summary = @()
    foreach ($window in @("5 hour", "1 week")) {
        $windowRows = @($Rows | Where-Object { $_.Window -eq $window } | Sort-Object SampledAt)
        if ($windowRows.Count -eq 0) {
            continue
        }

        $latest = $windowRows[-1]
        $peak = ($windowRows | Measure-Object -Property UsedPercent -Maximum).Maximum
        $average = ($windowRows | Measure-Object -Property UsedPercent -Average).Average
        $resetCount = @($windowRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ResetsAt) } | Select-Object -ExpandProperty ResetsAt -Unique).Count

        $summary += [pscustomobject]@{
            Window = $window
            LatestUsedPercent = [Math]::Round([double]$latest.UsedPercent, 2)
            PeakUsedPercent = [Math]::Round([double]$peak, 2)
            AverageUsedPercent = [Math]::Round([double]$average, 2)
            Samples = $windowRows.Count
            ResetCount = $resetCount
            FirstSampledAt = $windowRows[0].SampledAt
            LastSampledAt = $latest.SampledAt
        }
    }

    return @($summary)
}

function Compress-RateLimitHistoryRows {
    param(
        [object[]]$Rows,
        [int]$SampleSeconds = $RateLimitHistorySampleSeconds
    )

    $kept = @()
    foreach ($row in @($Rows | Sort-Object SampledAt, Window)) {
        $last = @($kept |
            Where-Object { $_.Window -eq $row.Window } |
            Sort-Object SampledAt -Descending |
            Select-Object -First 1)

        if ($last.Count -gt 0) {
            $lastRow = $last[0]
            $ageSeconds = ([datetime]$row.SampledAt - [datetime]$lastRow.SampledAt).TotalSeconds
            $sameUsed = [Math]::Abs([double]$lastRow.UsedPercent - [double]$row.UsedPercent) -lt 0.01
            $sameReset = [string]$lastRow.ResetsAt -eq [string]$row.ResetsAt
            if ($sameUsed -and $sameReset -and $ageSeconds -ge 0 -and $ageSeconds -lt [Math]::Max(1, $SampleSeconds)) {
                continue
            }
        }

        $kept += $row
    }

    return @($kept)
}

function New-RateLimitHistoryRow {
    param(
        [datetime]$SampledAt,
        [object]$EventTimestamp,
        [object]$PlanType,
        [object]$RateRow,
        [string]$Session,
        [string]$SourceFile
    )

    [pscustomobject]@{
        SampledAt = $SampledAt
        EventTimestamp = $EventTimestamp
        PlanType = $PlanType
        Window = $RateRow.Window
        UsedPercent = $RateRow.UsedPercent
        RemainingPercent = $RateRow.RemainingPercent
        WindowMinutes = $RateRow.WindowMinutes
        ResetsAt = Format-RateLimitResetTime $RateRow.ResetsAt
        Session = $Session
        SourceFile = $SourceFile
    }
}

function Get-RateLimitHistoryRowsFromSessions {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Days = $RateLimitHistoryDays
    )

    $cutoffUtc = [DateTime]::UtcNow.AddDays(-1 * [Math]::Max(1, $Days))
    $rows = @()

    foreach ($file in (Get-SessionFilesSince -Root $Root -Archived:$Archived -SinceUtc $cutoffUtc)) {
        $session = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        foreach ($line in (Get-SessionLines -Path $file.FullName -Tail 0)) {
            if ($line -notlike '*"rate_limits"*' -and
                $line -notlike '*"rateLimitStatus"*' -and
                $line -notlike '*"rate_limit_status"*') {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $eventTime = Get-EventTime $entry
            if ($null -eq $eventTime -or $eventTime -lt $cutoffUtc) {
                continue
            }

            $payload = Get-PropValue $entry @("payload")
            if ($null -eq $payload) {
                continue
            }

            $rateLimits = Get-PropValue $payload @("rate_limits", "rateLimitStatus", "rate_limit_status")
            if ($null -eq $rateLimits) {
                continue
            }

            $planType = Get-PropValue $rateLimits @("plan_type", "planType")
            foreach ($rateRow in @(Convert-RateLimits $rateLimits)) {
                $rows += New-RateLimitHistoryRow `
                    -SampledAt $eventTime `
                    -EventTimestamp (Get-PropValue $entry @("timestamp")) `
                    -PlanType $planType `
                    -RateRow $rateRow `
                    -Session $session `
                    -SourceFile $file.FullName
            }
        }
    }

    return @($rows)
}

function Import-RateLimitHistoryFromSessions {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Days = $RateLimitHistoryDays,
        [int]$SampleSeconds = $RateLimitHistorySampleSeconds
    )

    if ($DisableRateLimitHistory) {
        return [pscustomobject]@{
            Imported = 0
            Saved = 0
            Path = Get-RateLimitHistoryPath -Root $Root
            Disabled = $true
        }
    }

    $existingRows = @(Get-RateLimitHistoryRows -Root $Root -Days $Days)
    $backfillRows = @(Get-RateLimitHistoryRowsFromSessions -Root $Root -Archived:$Archived -Days $Days)
    $mergedRows = @(Compress-RateLimitHistoryRows -Rows @($existingRows + $backfillRows) -SampleSeconds $SampleSeconds)
    Save-RateLimitHistoryRows -Root $Root -Rows $mergedRows

    return [pscustomobject]@{
        Imported = $backfillRows.Count
        Saved = $mergedRows.Count
        Path = Get-RateLimitHistoryPath -Root $Root
        Disabled = $false
    }
}

function Get-LatestPlanType {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail
    )

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        $lines = @(Get-SessionLines -Path $file.FullName -Tail $Tail)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            if ($lines[$index] -notlike '*"plan_type"*' -and $lines[$index] -notlike '*"planType"*') {
                continue
            }

            try {
                $entry = $lines[$index] | ConvertFrom-Json
            }
            catch {
                continue
            }

            $payload = Get-PropValue $entry @("payload")
            $rateLimits = Get-PropValue $payload @("rate_limits", "rateLimitStatus", "rate_limit_status")
            $planType = Get-PropValue $rateLimits @("plan_type", "planType")
            if ($planType) {
                return $planType
            }
        }
    }

    return $null
}
