# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

function Get-PropValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Convert-ResetTime {
    param([object]$EpochSeconds)

    if ($null -eq $EpochSeconds) {
        return $null
    }

    $seconds = 0L
    if (-not [long]::TryParse([string]$EpochSeconds, [ref]$seconds)) {
        return $null
    }

    try {
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime
    }
    catch {
        return $null
    }
}

function Convert-Window {
    param(
        [string]$Name,
        [object]$Window
    )

    if ($null -eq $Window) {
        return $null
    }

    $usedPercent = Get-PropValue $Window @("used_percent", "usedPercent")
    $windowMinutes = Get-PropValue $Window @("window_minutes", "windowDurationMins", "windowMinutes")
    $windowSeconds = Get-PropValue $Window @("limit_window_seconds", "window_seconds", "windowSeconds")
    $resetEpoch = Get-PropValue $Window @("resets_at", "reset_at", "resetsAt", "resetAt")

    if ($null -eq $windowMinutes -and $null -ne $windowSeconds) {
        $windowMinutes = [double]$windowSeconds / 60
    }

    if ($null -eq $usedPercent -and $null -eq $windowMinutes -and $null -eq $resetEpoch) {
        return $null
    }

    $used = if ($null -ne $usedPercent) { [double]$usedPercent } else { 0.0 }
    $remaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - $used))
    $minutes = if ($null -ne $windowMinutes) { [double]$windowMinutes } else { $null }

    [pscustomobject]@{
        Window = $Name
        UsedPercent = [Math]::Round($used, 2)
        RawUsedPercent = $used
        RemainingPercent = [Math]::Round($remaining, 2)
        WindowMinutes = $minutes
        ResetsAt = Convert-ResetTime $resetEpoch
    }
}

function Convert-RateLimits {
    param([object]$RateLimits)

    if ($null -eq $RateLimits) {
        return @()
    }

    $rateLimit = Get-PropValue $RateLimits @("rate_limit", "rateLimit")
    $source = if ($null -ne $rateLimit) { $rateLimit } else { $RateLimits }
    $primary = Get-PropValue $source @("primary", "primary_window", "primaryWindow")
    $secondary = Get-PropValue $source @("secondary", "secondary_window", "secondaryWindow")

    $rows = @()
    $primaryRow = Convert-Window "5 hour" $primary
    if ($null -ne $primaryRow) {
        $rows += $primaryRow
    }

    $secondaryRow = Convert-Window "1 week" $secondary
    if ($null -ne $secondaryRow) {
        $rows += $secondaryRow
    }

    return $rows
}

function Convert-TokenUsage {
    param(
        [string]$Label,
        [object]$Usage
    )

    if ($null -eq $Usage) {
        return $null
    }

    $inputValue = Get-PropValue $Usage @("input_tokens", "inputTokens")
    $cachedInputValue = Get-PropValue $Usage @("cached_input_tokens", "cachedInputTokens")
    $inputTokens = Get-UsageMetric $Usage @("input_tokens", "inputTokens")
    $cachedInputTokens = Get-UsageMetric $Usage @("cached_input_tokens", "cachedInputTokens")

    [pscustomobject]@{
        Scope = $Label
        Total = Get-PropValue $Usage @("total_tokens", "totalTokens")
        Input = $inputValue
        CachedInput = $cachedInputValue
        CacheWrite = Get-PropValue $Usage @("cache_write_tokens", "cacheWriteTokens", "cache_creation_input_tokens", "cacheCreationInputTokens")
        CacheHitRatioPercent = Get-CacheHitRatioPercent -InputTokens $inputTokens -CachedInputTokens $cachedInputTokens
        Output = Get-PropValue $Usage @("output_tokens", "outputTokens")
        Reasoning = Get-PropValue $Usage @("reasoning_output_tokens", "reasoningOutputTokens")
    }
}

function Get-UsageMetric {
    param(
        [object]$Usage,
        [string[]]$Names
    )

    $value = Get-PropValue $Usage $Names
    if ($null -eq $value) {
        return 0L
    }

    $number = 0L
    if ([long]::TryParse([string]$value, [ref]$number)) {
        return $number
    }

    return 0L
}

function Get-CacheHitRatioPercent {
    param(
        [long]$InputTokens,
        [long]$CachedInputTokens
    )

    if ($InputTokens -le 0) {
        return $null
    }

    $boundedCachedInput = [Math]::Min($InputTokens, [Math]::Max(0L, $CachedInputTokens))
    return [Math]::Round(([double]$boundedCachedInput / [double]$InputTokens) * 100.0, 2)
}

function Convert-UsageToMetrics {
    param([object]$Usage)

    if ($null -eq $Usage) {
        return $null
    }

    [pscustomobject]@{
        Total = Get-UsageMetric $Usage @("total_tokens", "totalTokens")
        Input = Get-UsageMetric $Usage @("input_tokens", "inputTokens")
        CachedInput = Get-UsageMetric $Usage @("cached_input_tokens", "cachedInputTokens")
        CacheWrite = Get-UsageMetric $Usage @("cache_write_tokens", "cacheWriteTokens", "cache_creation_input_tokens", "cacheCreationInputTokens")
        Output = Get-UsageMetric $Usage @("output_tokens", "outputTokens")
        Reasoning = Get-UsageMetric $Usage @("reasoning_output_tokens", "reasoningOutputTokens")
    }
}

function New-TokenBucket {
    param(
        [string]$Window,
        [string]$Model = $null,
        [string]$PricingBand = "Short"
    )

    [pscustomobject]@{
        Window = $Window
        Model = $Model
        PricingBand = $PricingBand
        PricingMode = $PricingMode
        BillingConfidence = "Low"
        CostBasisMode = $CostBasisMode
        CostUnit = $null
        Total = 0L
        Input = 0L
        CachedInput = 0L
        CacheWrite = 0L
        Output = 0L
        Reasoning = 0L
        Events = 0
        EstimatedCost = $null
        EstimatedCostUsd = $null
        EstimatedCostCredits = $null
    }
}

function Add-TokenMetrics {
    param(
        [object]$Bucket,
        [object]$Metrics
    )

    if ($null -eq $Bucket -or $null -eq $Metrics) {
        return
    }

    $Bucket.Total += [long]$Metrics.Total
    $Bucket.Input += [long]$Metrics.Input
    $Bucket.CachedInput += [long]$Metrics.CachedInput
    $Bucket.CacheWrite += [long]$Metrics.CacheWrite
    $Bucket.Output += [long]$Metrics.Output
    $Bucket.Reasoning += [long]$Metrics.Reasoning
    $Bucket.Events += 1
}

function Get-PositiveDeltaMetrics {
    param(
        [object]$Previous,
        [object]$Current
    )

    if ($null -eq $Previous -or $null -eq $Current) {
        return $null
    }

    $total = [long]$Current.Total - [long]$Previous.Total
    $input = [long]$Current.Input - [long]$Previous.Input
    $cachedInput = [long]$Current.CachedInput - [long]$Previous.CachedInput
    $cacheWrite = [long]$Current.CacheWrite - [long]$Previous.CacheWrite
    $output = [long]$Current.Output - [long]$Previous.Output
    $reasoning = [long]$Current.Reasoning - [long]$Previous.Reasoning

    if ($total -lt 0 -or $input -lt 0 -or $cachedInput -lt 0 -or $cacheWrite -lt 0 -or $output -lt 0 -or $reasoning -lt 0) {
        return $null
    }

    if ($total -eq 0 -and $input -eq 0 -and $cachedInput -eq 0 -and $cacheWrite -eq 0 -and $output -eq 0 -and $reasoning -eq 0) {
        return $null
    }

    [pscustomobject]@{
        Total = $total
        Input = $input
        CachedInput = $cachedInput
        CacheWrite = $cacheWrite
        Output = $output
        Reasoning = $reasoning
    }
}

function Test-SameMetrics {
    param(
        [object]$Left,
        [object]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return $false
    }

    return [long]$Left.Total -eq [long]$Right.Total `
        -and [long]$Left.Input -eq [long]$Right.Input `
        -and [long]$Left.CachedInput -eq [long]$Right.CachedInput `
        -and [long]$Left.CacheWrite -eq [long]$Right.CacheWrite `
        -and [long]$Left.Output -eq [long]$Right.Output `
        -and [long]$Left.Reasoning -eq [long]$Right.Reasoning
}

function Test-AnyMetrics {
    param([object]$Metrics)

    if ($null -eq $Metrics) {
        return $false
    }

    return [long]$Metrics.Total -ne 0 `
        -or [long]$Metrics.Input -ne 0 `
        -or [long]$Metrics.CachedInput -ne 0 `
        -or [long]$Metrics.CacheWrite -ne 0 `
        -or [long]$Metrics.Output -ne 0 `
        -or [long]$Metrics.Reasoning -ne 0
}

function Get-MetricsKey {
    param([object]$Metrics)

    if ($null -eq $Metrics) {
        return "null"
    }

    return "{0}/{1}/{2}/{3}/{4}/{5}" -f `
        [long]$Metrics.Total,
        [long]$Metrics.Input,
        [long]$Metrics.CachedInput,
        [long]$Metrics.CacheWrite,
        [long]$Metrics.Output,
        [long]$Metrics.Reasoning
}

function Get-EventTime {
    param([object]$Entry)

    $timestamp = Get-PropValue $Entry @("timestamp")
    if ($null -eq $timestamp) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse([string]$timestamp).UtcDateTime
    }
    catch {
        return $null
    }
}

function Get-JsonNumberFromBody {
    param(
        [string]$Body,
        [string]$Name
    )

    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*(?<value>-?\d+)'
    if ($Body -match $pattern) {
        return [long]$Matches["value"]
    }

    return 0L
}

function Convert-UsageJsonBodyToMetrics {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }

    [pscustomobject]@{
        Total = Get-JsonNumberFromBody $Body "total_tokens"
        Input = Get-JsonNumberFromBody $Body "input_tokens"
        CachedInput = Get-JsonNumberFromBody $Body "cached_input_tokens"
        Output = Get-JsonNumberFromBody $Body "output_tokens"
        Reasoning = Get-JsonNumberFromBody $Body "reasoning_output_tokens"
    }
}

function Get-JsonLineEventTime {
    param([string]$Line)

    if ($Line -notmatch '"timestamp"\s*:\s*"(?<timestamp>[^"]+)"') {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse($Matches["timestamp"]).UtcDateTime
    }
    catch {
        return $null
    }
}

function Get-JsonStringFromLine {
    param(
        [string]$Line,
        [string]$Name
    )

    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*"(?<value>[^"]+)"'
    if ($Line -match $pattern) {
        return $Matches["value"]
    }

    return $null
}

function Get-UsageMetricsFromEntry {
    param(
        [object]$Entry,
        [string[]]$Names
    )

    $payload = Get-PropValue $Entry @("payload")
    $info = Get-PropValue $payload @("info")
    $usage = Get-PropValue $info $Names
    if ($null -eq $usage) {
        return $null
    }

    return Convert-UsageToMetrics $usage
}

function Test-TokenCountEvent {
    param([object]$Entry)

    if ($null -eq $Entry) {
        return $false
    }

    $entryType = Get-PropValue $Entry @("type")
    if ($entryType -ne "event_msg") {
        return $false
    }

    $payload = Get-PropValue $Entry @("payload")
    $payloadType = Get-PropValue $payload @("type")
    return $payloadType -eq "token_count"
}

function Get-UsageDeltaMetrics {
    param(
        [object]$PreviousTotal,
        [object]$CurrentTotal,
        [object]$LastUsage
    )

    if ($null -eq $CurrentTotal) {
        return $null
    }

    if ($null -ne $LastUsage -and (Test-AnyMetrics $LastUsage)) {
        return [pscustomobject]@{
            Metrics = $LastUsage
            Source = "last_token_usage"
        }
    }

    $delta = Get-PositiveDeltaMetrics -Previous $PreviousTotal -Current $CurrentTotal
    if ($null -eq $delta) {
        return $null
    }

    return [pscustomobject]@{
        Metrics = $delta
        Source = "total_token_usage_delta"
    }
}

function Get-SessionUsageDeltas {
    param(
        [string]$Path,
        [int]$Tail
    )

    $fileInfo = $null
    $cacheKey = $Path
    try {
        $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
        $cacheKey = $fileInfo.FullName
        $cached = $script:UsageDeltasCache[$cacheKey]
        if ($null -ne $cached -and
            $cached.Length -eq $fileInfo.Length -and
            $cached.LastWriteTimeUtc -eq $fileInfo.LastWriteTimeUtc) {
            return @($cached.Rows)
        }
    }
    catch {
        $fileInfo = $null
    }

    $currentModel = Get-SessionInitialModel $Path
    $previousTotal = $null
    $seenEvents = [System.Collections.Generic.HashSet[string]]::new()
    $rows = @()
    # Usage deltas need the pre-window cumulative baseline; tailing can undercount the first in-window event.
    $lines = @(Get-SessionLines -Path $Path -Tail 0)

    foreach ($line in $lines) {
        if ($line -like '*"turn_context"*') {
            $model = Get-JsonStringFromLine $line "model"
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                $currentModel = $model
            }
        }

        if ($line -notlike '*"total_token_usage"*' -and $line -notlike '*"last_token_usage"*') {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        if (-not (Test-TokenCountEvent $entry)) {
            continue
        }

        $eventTime = Get-EventTime $entry
        if ($null -eq $eventTime) {
            continue
        }

        $currentTotal = Get-UsageMetricsFromEntry $entry @("total_token_usage", "totalTokenUsage")
        if ($null -eq $currentTotal) {
            continue
        }

        $lastUsage = Get-UsageMetricsFromEntry $entry @("last_token_usage", "lastTokenUsage")
        $eventKey = "{0:o}|{1}|{2}" -f $eventTime, (Get-MetricsKey $currentTotal), (Get-MetricsKey $lastUsage)
        if (-not $seenEvents.Add($eventKey)) {
            continue
        }

        if (Test-SameMetrics $previousTotal $currentTotal) {
            continue
        }

        $delta = Get-UsageDeltaMetrics -PreviousTotal $previousTotal -CurrentTotal $currentTotal -LastUsage $lastUsage
        $previousTotal = $currentTotal

        if ($null -eq $delta) {
            continue
        }

        $rows += [pscustomobject]@{
            Timestamp = $eventTime
            Model = $currentModel
            Metrics = $delta.Metrics
            Source = $delta.Source
            TotalUsage = $currentTotal
            LastUsage = $lastUsage
        }
    }

    if ($null -ne $fileInfo) {
        if ($script:UsageDeltasCache.Count -gt 128) {
            $script:UsageDeltasCache.Clear()
        }

        $script:UsageDeltasCache[$cacheKey] = [pscustomobject]@{
            Length = $fileInfo.Length
            LastWriteTimeUtc = $fileInfo.LastWriteTimeUtc
            Rows = @($rows)
        }
    }

    return @($rows)
}
