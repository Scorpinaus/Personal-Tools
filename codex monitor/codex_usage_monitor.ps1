param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex" }),
    [int]$RefreshSeconds = 3,
    [int]$MaxFiles = 5,
    [int]$TailLines = 500,
    [int]$ConversationLookbackHours = 24,
    [int]$ConversationFallbackLookbackDays = 7,
    [int]$ConversationFallbackMaxFiles = 5,
    [int]$ConversationFallbackTailLines = 500,
    [int]$RollingMaxFiles = 0,
    [int]$RollingTailLines = 0,
    [int]$CostMaxFiles = 0,
    [int]$CostTailLines = 0,
    [int]$CostFiveHourRefreshSeconds = 30,
    [int]$CostWeekRefreshSeconds = 30,
    [int]$CostMonthRefreshSeconds = 86400,
    [int]$RateLimitHistoryDays = 8,
    [int]$RateLimitHistorySampleSeconds = 30,
    [double]$UsdToSgdRate = 1.274,
    [ValidateSet("ApiUsdEstimate", "CodexCredits")]
    [string]$CostBasisMode = "ApiUsdEstimate",
    [ValidateSet("Standard", "Batch", "Flex", "Priority")]
    [string]$PricingMode = "Standard",
    [switch]$Once,
    [switch]$IncludeArchived,
    [switch]$LibraryOnly,
    [switch]$Console,
    [switch]$NoOpen,
    [switch]$DisableRateLimitHistory,
    [switch]$BackfillRateLimitHistory,
    [int]$DashboardPort = 8787
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:LongContextThresholdTokens = 270000
$script:CostWindowCache = @{}
$script:NoCompactionCostWindowCache = @{}
$script:CostPeriodCache = @{}

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

    [pscustomobject]@{
        Scope = $Label
        Total = Get-PropValue $Usage @("total_tokens", "totalTokens")
        Input = Get-PropValue $Usage @("input_tokens", "inputTokens")
        CachedInput = Get-PropValue $Usage @("cached_input_tokens", "cachedInputTokens")
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

function Convert-UsageToMetrics {
    param([object]$Usage)

    if ($null -eq $Usage) {
        return $null
    }

    [pscustomobject]@{
        Total = Get-UsageMetric $Usage @("total_tokens", "totalTokens")
        Input = Get-UsageMetric $Usage @("input_tokens", "inputTokens")
        CachedInput = Get-UsageMetric $Usage @("cached_input_tokens", "cachedInputTokens")
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
    $output = [long]$Current.Output - [long]$Previous.Output
    $reasoning = [long]$Current.Reasoning - [long]$Previous.Reasoning

    if ($total -lt 0 -or $input -lt 0 -or $cachedInput -lt 0 -or $output -lt 0 -or $reasoning -lt 0) {
        return $null
    }

    if ($total -eq 0 -and $input -eq 0 -and $cachedInput -eq 0 -and $output -eq 0 -and $reasoning -eq 0) {
        return $null
    }

    [pscustomobject]@{
        Total = $total
        Input = $input
        CachedInput = $cachedInput
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
        -or [long]$Metrics.Output -ne 0 `
        -or [long]$Metrics.Reasoning -ne 0
}

function Get-MetricsKey {
    param([object]$Metrics)

    if ($null -eq $Metrics) {
        return "null"
    }

    return "{0}/{1}/{2}/{3}/{4}" -f `
        [long]$Metrics.Total,
        [long]$Metrics.Input,
        [long]$Metrics.CachedInput,
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

    return @($rows)
}

function Get-LocalWindowStartUtc {
    param([string]$Window)

    $now = Get-Date
    switch ($Window) {
        "Last 5 hours" {
            return [DateTime]::UtcNow.AddHours(-5)
        }
        "This week" {
            $startOfToday = $now.Date
            $daysSinceMonday = ([int]$startOfToday.DayOfWeek + 6) % 7
            return $startOfToday.AddDays(-$daysSinceMonday).ToUniversalTime()
        }
        "This month" {
            return (Get-Date -Year $now.Year -Month $now.Month -Day 1 -Hour 0 -Minute 0 -Second 0).ToUniversalTime()
        }
        default {
            return [DateTime]::MinValue
        }
    }
}

function Get-CostWindowDefinitions {
    param([string[]]$Names = @("Last 5 hours", "This week", "This month"))

    $allWindows = @(
        [pscustomobject]@{ Name = "Last 5 hours"; StartUtc = Get-LocalWindowStartUtc "Last 5 hours"; RefreshSeconds = $CostFiveHourRefreshSeconds }
        [pscustomobject]@{ Name = "This week"; StartUtc = Get-LocalWindowStartUtc "This week"; RefreshSeconds = $CostWeekRefreshSeconds }
        [pscustomobject]@{ Name = "This month"; StartUtc = Get-LocalWindowStartUtc "This month"; RefreshSeconds = $CostMonthRefreshSeconds }
    )

    return @($allWindows | Where-Object { $Names -contains $_.Name })
}

function New-PeriodWindow {
    param(
        [string]$Group,
        [string]$Name,
        [string]$Label,
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [int]$SortOrder,
        [int]$RefreshSeconds
    )

    [pscustomobject]@{
        Group = $Group
        Name = $Name
        Label = $Label
        StartUtc = $StartUtc
        EndUtc = $EndUtc
        SortOrder = $SortOrder
        RefreshSeconds = $RefreshSeconds
    }
}

function Format-PeriodRangeLabel {
    param(
        [datetime]$StartLocal,
        [datetime]$EndLocal,
        [switch]$IncludeTime
    )

    if ($IncludeTime) {
        return ("{0:MMM d HH:mm}-{1:HH:mm}" -f $StartLocal, $EndLocal)
    }

    $inclusiveEnd = $EndLocal.AddSeconds(-1)
    if ($StartLocal.Date -eq $inclusiveEnd.Date) {
        return ("{0:MMM d}" -f $StartLocal)
    }

    return ("{0:MMM d}-{1:MMM d}" -f $StartLocal, $inclusiveEnd)
}

function Get-ModelPeriodWindowDefinitions {
    $nowLocal = Get-Date
    $windows = @()

    for ($index = 0; $index -lt 5; $index++) {
        $endLocal = $nowLocal.AddHours(-5 * $index)
        $startLocal = $endLocal.AddHours(-5)
        $label = if ($index -eq 0) {
            "Last 5h"
        }
        else {
            "{0}-{1}h ago" -f (5 * $index), (5 * ($index + 1))
        }

        $windows += New-PeriodWindow `
            -Group "Last 5 hours" `
            -Name ("5h-{0}" -f $index) `
            -Label $label `
            -StartUtc $startLocal.ToUniversalTime() `
            -EndUtc $endLocal.ToUniversalTime() `
            -SortOrder $index `
            -RefreshSeconds $CostFiveHourRefreshSeconds
    }

    $todayLocal = $nowLocal.Date
    for ($index = 0; $index -lt 7; $index++) {
        $startLocal = $todayLocal.AddDays(-1 * $index)
        $endLocal = $startLocal.AddDays(1)
        $label = if ($index -eq 0) {
            "Today"
        }
        elseif ($index -eq 1) {
            "Yesterday"
        }
        else {
            "{0:MMM d}" -f $startLocal
        }

        $windows += New-PeriodWindow `
            -Group "This week" `
            -Name ("day-{0}" -f $index) `
            -Label $label `
            -StartUtc $startLocal.ToUniversalTime() `
            -EndUtc $endLocal.ToUniversalTime() `
            -SortOrder $index `
            -RefreshSeconds $CostWeekRefreshSeconds
    }

    for ($index = 0; $index -lt 4; $index++) {
        $endLocal = $nowLocal.Date.AddDays(1).AddDays(-7 * $index)
        $startLocal = $endLocal.AddDays(-7)
        $windows += New-PeriodWindow `
            -Group "This month" `
            -Name ("week-{0}" -f $index) `
            -Label (Format-PeriodRangeLabel -StartLocal $startLocal -EndLocal $endLocal) `
            -StartUtc $startLocal.ToUniversalTime() `
            -EndUtc $endLocal.ToUniversalTime() `
            -SortOrder $index `
            -RefreshSeconds $CostMonthRefreshSeconds
    }

    return @($windows)
}

function Get-ModelPricingTable {
    @(
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 30.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 10.00; CachedInputPerMillion = 1.00; OutputPerMillion = 45.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.75; CachedInputPerMillion = 0.075; OutputPerMillion = 4.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.20; CachedInputPerMillion = 0.02; OutputPerMillion = 1.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 1.75; CachedInputPerMillion = 0.175; OutputPerMillion = 14.00 }

        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 1.25; CachedInputPerMillion = 0.125; OutputPerMillion = 7.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 11.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.375; CachedInputPerMillion = 0.0375; OutputPerMillion = 2.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.10; CachedInputPerMillion = 0.01; OutputPerMillion = 0.625 }

        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 1.25; CachedInputPerMillion = 0.125; OutputPerMillion = 7.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 11.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.375; CachedInputPerMillion = 0.0375; OutputPerMillion = 2.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.10; CachedInputPerMillion = 0.01; OutputPerMillion = 0.625 }

        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 12.50; CachedInputPerMillion = 1.25; OutputPerMillion = 75.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 30.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 1.50; CachedInputPerMillion = 0.15; OutputPerMillion = 9.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 3.50; CachedInputPerMillion = 0.35; OutputPerMillion = 28.00 }

        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 125.00; CachedInputPerMillion = 12.50; OutputPerMillion = 750.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 62.50; CachedInputPerMillion = 6.25; OutputPerMillion = 375.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 18.75; CachedInputPerMillion = 1.875; OutputPerMillion = 113.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 43.75; CachedInputPerMillion = 4.375; OutputPerMillion = 350.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.2"; ContextBand = "Short"; InputPerMillion = 43.75; CachedInputPerMillion = 4.375; OutputPerMillion = 350.00 }
    )
}

function Get-PricingBand {
    param(
        [string]$Model,
        [long]$InputTokens
    )

    if ($Model -notin @("gpt-5.5", "gpt-5.4")) {
        return "Short"
    }

    if ($InputTokens -ge $script:LongContextThresholdTokens) {
        return "Long"
    }

    return "Short"
}

function Get-ApiModelPricing {
    param(
        [string]$Model,
        [string]$PricingBand = "Short"
    )

    $pricing = Get-ModelPricingTable |
        Where-Object { $_.Basis -eq "ApiUsdEstimate" -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq $PricingBand } |
        Select-Object -First 1

    if ($null -eq $pricing -and $PricingBand -eq "Long") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq "ApiUsdEstimate" -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq "Short" } |
            Select-Object -First 1
    }

    return $pricing
}

function Get-NoCompactionPricingBand {
    param(
        [string]$Model,
        [long]$CumulativeInputTokens
    )

    if ($CumulativeInputTokens -lt $script:LongContextThresholdTokens) {
        return "Short"
    }

    $longPricing = Get-ModelPricingTable |
        Where-Object { $_.Basis -eq "ApiUsdEstimate" -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq "Long" } |
        Select-Object -First 1

    if ($null -ne $longPricing) {
        return "Long"
    }

    return "Short"
}

function Get-ModelPricing {
    param(
        [string]$Model,
        [long]$InputTokens = 0,
        [string]$PricingBand = $null
    )

    if ([string]::IsNullOrWhiteSpace($PricingBand)) {
        $PricingBand = Get-PricingBand -Model $Model -InputTokens $InputTokens
    }

    $pricing = Get-ModelPricingTable |
        Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq $PricingBand } |
        Select-Object -First 1

    if ($null -eq $pricing -and $PricingBand -eq "Long") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq "Short" } |
            Select-Object -First 1
    }

    if ($null -eq $pricing -and $CostBasisMode -eq "CodexCredits" -and $PricingMode -ne "Standard") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq "Standard" -and $_.Model -eq $Model -and $_.ContextBand -eq $PricingBand } |
            Select-Object -First 1
    }

    if ($null -eq $pricing -and $CostBasisMode -eq "CodexCredits" -and $PricingBand -eq "Long") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq "Standard" -and $_.Model -eq $Model -and $_.ContextBand -eq "Short" } |
            Select-Object -First 1
    }

    return $pricing
}

function Get-SessionInitialModel {
    param([string]$Path)

    foreach ($line in (Get-Content -LiteralPath $Path -TotalCount 200)) {
        if ($line -notlike '*"turn_context"*') {
            continue
        }

        $model = Get-JsonStringFromLine $line "model"
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            return $model
        }
    }

    return "unknown"
}

function Set-EstimatedCost {
    param([object]$Bucket)

    if ($null -eq $Bucket -or [string]::IsNullOrWhiteSpace($Bucket.Model)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($Bucket.PricingBand)) {
        $Bucket.PricingBand = Get-PricingBand -Model $Bucket.Model -InputTokens ([long]$Bucket.Input)
    }
    $Bucket.PricingMode = $PricingMode
    $Bucket.CostBasisMode = $CostBasisMode

    $pricing = Get-ModelPricing -Model $Bucket.Model -InputTokens ([long]$Bucket.Input) -PricingBand $Bucket.PricingBand
    if ($null -eq $pricing) {
        $Bucket.BillingConfidence = "Low"
        return
    }

    $Bucket.BillingConfidence = "High"
    $Bucket.CostUnit = $pricing.Unit

    $cachedInput = [Math]::Max(0L, [long]$Bucket.CachedInput)
    $uncachedInput = [Math]::Max(0L, [long]$Bucket.Input - $cachedInput)
    $cost =
        ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
        ($cachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
        ([long]$Bucket.Output * [double]$pricing.OutputPerMillion / 1000000.0)

    $roundedCost = [Math]::Round($cost, 4)
    $Bucket.EstimatedCost = $roundedCost
    if ($pricing.Unit -eq "USD") {
        $Bucket.EstimatedCostUsd = $roundedCost
        $Bucket.EstimatedCostCredits = $null
    }
    elseif ($pricing.Unit -eq "credits") {
        $Bucket.EstimatedCostUsd = $null
        $Bucket.EstimatedCostCredits = $roundedCost
    }
}

function Set-NoCompactionEstimatedCost {
    param([object]$Bucket)

    if ($null -eq $Bucket -or [string]::IsNullOrWhiteSpace($Bucket.Model)) {
        return
    }

    $Bucket.PricingMode = $PricingMode
    $Bucket.CostBasisMode = "ApiNoCompactionUsdEstimate"
    $pricing = Get-ApiModelPricing -Model $Bucket.Model -PricingBand $Bucket.PricingBand
    if ($null -eq $pricing) {
        $Bucket.BillingConfidence = "Low"
        return
    }

    $cachedInput = [Math]::Max(0L, [long]$Bucket.CachedInput)
    $uncachedInput = [Math]::Max(0L, [long]$Bucket.Input - $cachedInput)
    $cost =
        ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
        ($cachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
        ([long]$Bucket.Output * [double]$pricing.OutputPerMillion / 1000000.0)

    $roundedCost = [Math]::Round($cost, 4)
    $Bucket.CostUnit = $pricing.Unit
    $Bucket.EstimatedCost = $roundedCost
    $Bucket.EstimatedCostUsd = $roundedCost
    $Bucket.EstimatedCostCredits = $null
    $Bucket.BillingConfidence = "Scenario"
}

function Get-EstimatedTextChars {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0L
    }

    if ($Value -is [string]) {
        return [long]$Value.Length
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $total = 0L
        foreach ($key in $Value.Keys) {
            if ([string]$key -eq "encrypted_content") {
                continue
            }

            $total += Get-EstimatedTextChars $Value[$key]
        }

        return $total
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $total = 0L
        foreach ($item in $Value) {
            $total += Get-EstimatedTextChars $item
        }

        return $total
    }

    if ($Value.PSObject -and $Value.PSObject.Properties) {
        $total = 0L
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -eq "encrypted_content") {
                continue
            }

            $total += Get-EstimatedTextChars $property.Value
        }

        return $total
    }

    return 0L
}

function Convert-CharsToEstimatedTokens {
    param([long]$Chars)

    if ($Chars -le 0) {
        return 0L
    }

    return [long][Math]::Ceiling([double]$Chars / 4.0)
}

function Get-TextFieldChars {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0L
    }

    if ($Value -is [string]) {
        return [long]$Value.Length
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $total = 0L
        foreach ($item in $Value) {
            $total += Get-TextFieldChars $item
        }

        return $total
    }

    $text = Get-PropValue $Value @("text")
    if ($null -ne $text) {
        return Get-TextFieldChars $text
    }

    $content = Get-PropValue $Value @("content")
    if ($null -ne $content) {
        return Get-TextFieldChars $content
    }

    return 0L
}

function Get-SourceEstimateFromEntry {
    param([object]$Entry)

    $payload = Get-PropValue $Entry @("payload")
    if ($null -eq $payload) {
        return $null
    }

    $entryType = Get-PropValue $Entry @("type")
    $payloadType = Get-PropValue $payload @("type")
    $source = $null
    $side = $null
    $chars = 0L
    $attribution = "Field text estimate"

    if ($entryType -eq "event_msg" -and $payloadType -eq "user_message") {
        $source = "User input"
        $side = "Input"
        $chars =
            (Get-TextFieldChars (Get-PropValue $payload @("message"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("text_elements", "textElements")))
    }
    elseif ($entryType -eq "response_item" -and $payloadType -eq "message") {
        $role = Get-PropValue $payload @("role")
        if ($role -eq "assistant") {
            $source = "Assistant output"
            $side = "Output"
            $chars = Get-TextFieldChars (Get-PropValue $payload @("content"))
        }
        elseif ($role -eq "user") {
            $source = "User context"
            $side = "Input"
            $chars = Get-TextFieldChars (Get-PropValue $payload @("content"))
        }
        elseif ($role -eq "developer" -or $role -eq "system") {
            $source = "System/developer context"
            $side = "Input"
            $chars = Get-TextFieldChars (Get-PropValue $payload @("content"))
        }
    }
    elseif ($entryType -eq "response_item" -and ($payloadType -eq "function_call" -or $payloadType -eq "custom_tool_call")) {
        $source = "Tool call arguments"
        $side = "Output"
        $chars = Get-TextFieldChars (Get-PropValue $payload @("arguments", "input"))
    }
    elseif ($entryType -eq "response_item" -and ($payloadType -eq "function_call_output" -or $payloadType -eq "custom_tool_call_output")) {
        $source = "Tool outputs"
        $side = "Input"
        $chars = Get-TextFieldChars (Get-PropValue $payload @("output"))
    }
    elseif ($entryType -eq "response_item" -and $payloadType -eq "reasoning") {
        $source = "Reasoning"
        $side = "Output"
        $chars =
            (Get-TextFieldChars (Get-PropValue $payload @("summary"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("content")))
        $attribution = "Visible reasoning text estimate"
    }
    elseif (($entryType -eq "response_item" -and $payloadType -eq "summary") -or ($entryType -eq "event_msg" -and $payloadType -eq "context_compacted") -or $entryType -eq "compacted") {
        $source = "Context summaries"
        $side = "Input"
        $chars =
            (Get-TextFieldChars (Get-PropValue $payload @("summary"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("content"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("message", "text")))
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
        return $null
    }

    $tokens = Convert-CharsToEstimatedTokens $chars
    if ($tokens -le 0) {
        return $null
    }

    [pscustomobject]@{
        Source = $source
        Side = $side
        Tokens = $tokens
        Chars = $chars
        Attribution = $attribution
    }
}

function New-SourceEstimateBucket {
    param(
        [string]$Window,
        [string]$Model,
        [string]$Source
    )

    [pscustomobject]@{
        Window = $Window
        Model = $Model
        Source = $Source
        EstimatedInputTokens = 0L
        EstimatedOutputTokens = 0L
        EstimatedChars = 0L
        Events = 0
        Attribution = "Field text estimate"
    }
}

function Add-SourceEstimate {
    param(
        [hashtable]$Buckets,
        [string]$Window,
        [string]$Model,
        [object]$Estimate
    )

    if ($null -eq $Estimate) {
        return
    }

    $key = "{0}|{1}|{2}" -f $Window, $Model, $Estimate.Source
    if (-not $Buckets.ContainsKey($key)) {
        $Buckets[$key] = New-SourceEstimateBucket $Window $Model $Estimate.Source
    }

    if ($Estimate.Side -eq "Input") {
        $Buckets[$key].EstimatedInputTokens += [long]$Estimate.Tokens
    }
    else {
        $Buckets[$key].EstimatedOutputTokens += [long]$Estimate.Tokens
    }

    $Buckets[$key].EstimatedChars += [long]$Estimate.Chars
    if ($Estimate.Attribution -and $Buckets[$key].Attribution -ne $Estimate.Attribution) {
        $Buckets[$key].Attribution = "Mixed text estimate"
    }
    elseif ($Estimate.Attribution) {
        $Buckets[$key].Attribution = $Estimate.Attribution
    }
    $Buckets[$key].Events += 1
}

function Get-SourceCostRows {
    param(
        [object[]]$EstimateRows,
        [object[]]$ModelRows
    )

    function Get-MeasureSumOrZero {
        param(
            [object[]]$Rows,
            [string]$Property
        )

        if ($Rows.Count -eq 0) {
            return 0L
        }

        $measure = $Rows | Measure-Object -Property $Property -Sum
        if ($null -eq $measure -or $null -eq $measure.PSObject.Properties["Sum"] -or $null -eq $measure.Sum) {
            return 0L
        }

        return [long]$measure.Sum
    }

    $rows = @()
    foreach ($modelRow in $ModelRows) {
        $pricing = Get-ModelPricing -Model $modelRow.Model -InputTokens ([long]$modelRow.Input) -PricingBand $modelRow.PricingBand
        $sourceRows = @($EstimateRows | Where-Object { $_.Window -eq $modelRow.Window -and $_.Model -eq $modelRow.Model })

        $inputEstimateTotal = Get-MeasureSumOrZero -Rows $sourceRows -Property "EstimatedInputTokens"
        $outputEstimateTotal = Get-MeasureSumOrZero -Rows $sourceRows -Property "EstimatedOutputTokens"

        $expandedRows = @($sourceRows)
        if ([long]$modelRow.Input -gt $inputEstimateTotal) {
            $expandedRows += [pscustomobject]@{
                Window = $modelRow.Window
                Model = $modelRow.Model
                Source = "Unattributed input/context"
                EstimatedInputTokens = [long]$modelRow.Input - $inputEstimateTotal
                EstimatedOutputTokens = 0L
                EstimatedChars = 0L
                Events = 0
                Attribution = "Allocated remainder"
            }
            $inputEstimateTotal = [long]$modelRow.Input
        }

        if ([long]$modelRow.Output -gt $outputEstimateTotal) {
            $expandedRows += [pscustomobject]@{
                Window = $modelRow.Window
                Model = $modelRow.Model
                Source = "Unattributed output"
                EstimatedInputTokens = 0L
                EstimatedOutputTokens = [long]$modelRow.Output - $outputEstimateTotal
                EstimatedChars = 0L
                Events = 0
                Attribution = "Allocated remainder"
            }
            $outputEstimateTotal = [long]$modelRow.Output
        }

        foreach ($sourceRow in $expandedRows) {
            $rawInput = [long]$sourceRow.EstimatedInputTokens
            $rawOutput = [long]$sourceRow.EstimatedOutputTokens
            $rawTokens = $rawInput + $rawOutput
            $allocatedInput = 0L
            $allocatedOutput = 0L
            if ($inputEstimateTotal -gt 0 -and $rawInput -gt 0) {
                $allocatedInput = [long][Math]::Round([double]$modelRow.Input * [double]$rawInput / [double]$inputEstimateTotal)
            }

            if ($outputEstimateTotal -gt 0 -and $rawOutput -gt 0) {
                $allocatedOutput = [long][Math]::Round([double]$modelRow.Output * [double]$rawOutput / [double]$outputEstimateTotal)
            }

            $allocatedCachedInput = 0L
            if ([long]$modelRow.Input -gt 0 -and $allocatedInput -gt 0) {
                $allocatedCachedInput = [long][Math]::Round([double]$modelRow.CachedInput * [double]$allocatedInput / [double]$modelRow.Input)
            }

            $cost = $null
            $costUsd = $null
            $costCredits = $null
            if ($null -ne $pricing) {
                $uncachedInput = [Math]::Max(0L, $allocatedInput - $allocatedCachedInput)
                $costValue =
                    ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
                    ($allocatedCachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
                    ($allocatedOutput * [double]$pricing.OutputPerMillion / 1000000.0)
                $cost = [Math]::Round($costValue, 4)
                if ($pricing.Unit -eq "USD") {
                    $costUsd = $cost
                }
                elseif ($pricing.Unit -eq "credits") {
                    $costCredits = $cost
                }
            }

            $rows += [pscustomobject]@{
                Window = $sourceRow.Window
                Model = $sourceRow.Model
                Source = $sourceRow.Source
                PricingMode = $PricingMode
                CostBasisMode = $CostBasisMode
                CostUnit = if ($null -ne $pricing) { $pricing.Unit } else { $null }
                PricingBand = $modelRow.PricingBand
                BillingConfidence = if ($null -eq $pricing) { "Low" } elseif ($sourceRow.Attribution -eq "Allocated remainder") { "Medium" } else { $modelRow.BillingConfidence }
                EstimatedChars = if ($null -ne $sourceRow.EstimatedChars) { [long]$sourceRow.EstimatedChars } else { 0L }
                EstimatedInputTokens = $rawInput
                EstimatedOutputTokens = $rawOutput
                EstimatedTokens = $rawTokens
                AllocatedInput = $allocatedInput
                AllocatedCachedInput = $allocatedCachedInput
                AllocatedOutput = $allocatedOutput
                AllocatedTokens = $allocatedInput + $allocatedOutput
                ReconciliationDelta = ($allocatedInput + $allocatedOutput) - $rawTokens
                Events = $sourceRow.Events
                EstimatedCost = $cost
                EstimatedCostUsd = $costUsd
                EstimatedCostCredits = $costCredits
                Attribution = $sourceRow.Attribution
            }
        }
    }

    return @($rows | Sort-Object Window, Model, Source)
}

function Get-TotalEstimatedCostUsd {
    param([object[]]$Rows)

    $total = 0.0
    foreach ($row in $Rows) {
        if ($null -ne $row.EstimatedCostUsd) {
            $total += [double]$row.EstimatedCostUsd
        }
    }

    return [Math]::Round($total, 4)
}

function Get-TotalEstimatedCostCredits {
    param([object[]]$Rows)

    $total = 0.0
    foreach ($row in $Rows) {
        if ($null -ne $row.EstimatedCostCredits) {
            $total += [double]$row.EstimatedCostCredits
        }
    }

    return [Math]::Round($total, 4)
}

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

    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
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

function Get-RollingTokenUsage {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail
    )

    $now = [DateTime]::UtcNow
    $fiveHourCutoff = $now.AddHours(-5)
    $weekCutoff = Get-LocalWindowStartUtc "This week"
    $monthCutoff = Get-LocalWindowStartUtc "This month"
    $fiveHour = New-TokenBucket "Last 5 hours"
    $week = New-TokenBucket "This week"
    $month = New-TokenBucket "This month"

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        if ($file.LastWriteTimeUtc -lt $monthCutoff) {
            continue
        }

        foreach ($usageEvent in (Get-SessionUsageDeltas -Path $file.FullName -Tail $Tail)) {
            $eventTime = $usageEvent.Timestamp
            $delta = $usageEvent.Metrics

            if ($eventTime -ge $weekCutoff) {
                Add-TokenMetrics $week $delta
            }

            if ($eventTime -ge $monthCutoff) {
                Add-TokenMetrics $month $delta
            }

            if ($eventTime -ge $fiveHourCutoff) {
                Add-TokenMetrics $fiveHour $delta
            }
        }
    }

    return @($fiveHour, $week, $month)
}

function Get-TokenUsageByModel {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail,
        [string[]]$WindowNames = @("Last 5 hours", "This week", "This month")
    )

    $windows = @(Get-CostWindowDefinitions $WindowNames)
    if ($windows.Count -eq 0) {
        return @()
    }

    $oldestStart = ($windows | Sort-Object StartUtc | Select-Object -First 1).StartUtc
    $buckets = @{}

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        # LastWriteTimeUtc is only a candidate-file filter; event timestamps decide window membership.
        if ($file.LastWriteTimeUtc -lt $oldestStart) {
            continue
        }

        foreach ($usageEvent in (Get-SessionUsageDeltas -Path $file.FullName -Tail $Tail)) {
            $eventTime = $usageEvent.Timestamp
            if ($null -eq $eventTime -or $eventTime -lt $oldestStart) {
                continue
            }

            $delta = $usageEvent.Metrics
            $currentModel = $usageEvent.Model

            foreach ($window in $windows) {
                if ($eventTime -lt $window.StartUtc) {
                    continue
                }

                $pricingBand = Get-PricingBand -Model $currentModel -InputTokens ([long]$delta.Input)
                $key = "{0}|{1}|{2}" -f $window.Name, $currentModel, $pricingBand
                if (-not $buckets.ContainsKey($key)) {
                    $buckets[$key] = New-TokenBucket $window.Name $currentModel $pricingBand
                }

                Add-TokenMetrics $buckets[$key] $delta
            }
        }
    }

    foreach ($bucket in $buckets.Values) {
        Set-EstimatedCost $bucket
    }

    return @($buckets.Values | Sort-Object Window, Model)
}

function Get-NoCompactionTokenUsageByModel {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [string[]]$WindowNames = @("Last 5 hours", "This week", "This month")
    )

    $windows = @(Get-CostWindowDefinitions $WindowNames)
    if ($windows.Count -eq 0) {
        return @()
    }

    $oldestStart = ($windows | Sort-Object StartUtc | Select-Object -First 1).StartUtc
    $buckets = @{}

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        if ($file.LastWriteTimeUtc -lt $oldestStart) {
            continue
        }

        $cumulativeInput = 0L
        foreach ($usageEvent in (Get-SessionUsageDeltas -Path $file.FullName -Tail 0)) {
            $delta = $usageEvent.Metrics
            $cumulativeInput += [long]$delta.Input

            $eventTime = $usageEvent.Timestamp
            if ($null -eq $eventTime -or $eventTime -lt $oldestStart) {
                continue
            }

            $currentModel = $usageEvent.Model
            $pricingBand = Get-NoCompactionPricingBand -Model $currentModel -CumulativeInputTokens $cumulativeInput

            foreach ($window in $windows) {
                if ($eventTime -lt $window.StartUtc) {
                    continue
                }

                $key = "{0}|{1}|{2}" -f $window.Name, $currentModel, $pricingBand
                if (-not $buckets.ContainsKey($key)) {
                    $bucket = New-TokenBucket $window.Name $currentModel $pricingBand
                    $bucket.CostBasisMode = "ApiNoCompactionUsdEstimate"
                    $buckets[$key] = $bucket
                }

                Add-TokenMetrics $buckets[$key] $delta
            }
        }
    }

    foreach ($bucket in $buckets.Values) {
        Set-NoCompactionEstimatedCost $bucket
    }

    return @($buckets.Values | Sort-Object Window, Model, PricingBand)
}

function Get-TokenUsageByModelPeriod {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail,
        [object[]]$Windows
    )

    if ($Windows.Count -eq 0) {
        return @()
    }

    $oldestStart = ($Windows | Sort-Object StartUtc | Select-Object -First 1).StartUtc
    $newestEnd = ($Windows | Sort-Object EndUtc -Descending | Select-Object -First 1).EndUtc
    $buckets = @{}

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        if ($file.LastWriteTimeUtc -lt $oldestStart) {
            continue
        }

        foreach ($usageEvent in (Get-SessionUsageDeltas -Path $file.FullName -Tail $Tail)) {
            $eventTime = $usageEvent.Timestamp
            if ($null -eq $eventTime -or $eventTime -lt $oldestStart -or $eventTime -ge $newestEnd) {
                continue
            }

            $delta = $usageEvent.Metrics
            $currentModel = $usageEvent.Model

            foreach ($window in $Windows) {
                if ($eventTime -lt $window.StartUtc -or $eventTime -ge $window.EndUtc) {
                    continue
                }

                $pricingBand = Get-PricingBand -Model $currentModel -InputTokens ([long]$delta.Input)
                $key = "{0}|{1}|{2}" -f $window.Name, $currentModel, $pricingBand
                if (-not $buckets.ContainsKey($key)) {
                    $bucket = New-TokenBucket $window.Group $currentModel $pricingBand
                    $bucket | Add-Member -NotePropertyName PeriodGroup -NotePropertyValue $window.Group
                    $bucket | Add-Member -NotePropertyName PeriodName -NotePropertyValue $window.Name
                    $bucket | Add-Member -NotePropertyName PeriodLabel -NotePropertyValue $window.Label
                    $bucket | Add-Member -NotePropertyName PeriodStartUtc -NotePropertyValue $window.StartUtc
                    $bucket | Add-Member -NotePropertyName PeriodEndUtc -NotePropertyValue $window.EndUtc
                    $bucket | Add-Member -NotePropertyName PeriodSortOrder -NotePropertyValue $window.SortOrder
                    $buckets[$key] = $bucket
                }

                Add-TokenMetrics $buckets[$key] $delta
            }
        }
    }

    foreach ($bucket in $buckets.Values) {
        Set-EstimatedCost $bucket
    }

    return @($buckets.Values | Sort-Object PeriodGroup, PeriodSortOrder, Model)
}

function Get-TokenSourceCostEstimates {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail,
        [object[]]$ModelRows
    )

    $windows = @(Get-CostWindowDefinitions)
    if ($windows.Count -eq 0 -or $ModelRows.Count -eq 0) {
        return @()
    }

    $oldestStart = ($windows | Sort-Object StartUtc | Select-Object -First 1).StartUtc
    $buckets = @{}

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        if ($file.LastWriteTimeUtc -lt $oldestStart) {
            continue
        }

        $currentModel = Get-SessionInitialModel $file.FullName
        $lines = @(Get-SessionLines -Path $file.FullName -Tail $Tail)

        foreach ($line in $lines) {
            $eventTime = Get-JsonLineEventTime $line
            if ($null -eq $eventTime -or $eventTime -lt $oldestStart) {
                continue
            }

            if ($line -like '*"turn_context"*') {
                $model = Get-JsonStringFromLine $line "model"
                if (-not [string]::IsNullOrWhiteSpace($model)) {
                    $currentModel = $model
                }
            }

            if ($line -notlike '*"user_message"*' `
                -and $line -notlike '*"function_call"*' `
                -and $line -notlike '*"custom_tool_call"*' `
                -and $line -notlike '*"reasoning"*' `
                -and $line -notlike '*"summary"*' `
                -and $line -notlike '*"context_compacted"*' `
                -and $line -notlike '*"message"*') {
                continue
            }

            try {
                $entry = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $estimate = Get-SourceEstimateFromEntry $entry
            if ($null -eq $estimate) {
                continue
            }

            foreach ($window in $windows) {
                if ($eventTime -lt $window.StartUtc) {
                    continue
                }

                Add-SourceEstimate -Buckets $buckets -Window $window.Name -Model $currentModel -Estimate $estimate
            }
        }
    }

    return @(Get-SourceCostRows -EstimateRows @($buckets.Values) -ModelRows $ModelRows)
}

function Get-CachedTokenUsageByModel {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail,
        [switch]$Force
    )

    $now = Get-Date
    $windows = @(Get-CostWindowDefinitions)
    $dueWindows = @()

    foreach ($window in $windows) {
        $cache = $script:CostWindowCache[$window.Name]
        $isDue = $Force -or $null -eq $cache
        if (-not $isDue) {
            $ageSeconds = ($now - [datetime]$cache.UpdatedAt).TotalSeconds
            $isDue = $ageSeconds -ge [double]$window.RefreshSeconds
        }

        if ($isDue) {
            $dueWindows += $window.Name
        }
    }

    if ($dueWindows.Count -gt 0) {
        $freshRows = @(Get-TokenUsageByModel -Root $Root -Archived:$Archived -Limit $Limit -Tail $Tail -WindowNames $dueWindows)
        foreach ($windowName in $dueWindows) {
            $script:CostWindowCache[$windowName] = [pscustomobject]@{
                UpdatedAt = $now
                Rows = @($freshRows | Where-Object { $_.Window -eq $windowName })
            }
        }
    }

    $rows = @()
    foreach ($window in $windows) {
        $cache = $script:CostWindowCache[$window.Name]
        if ($null -ne $cache) {
            $rows += $cache.Rows
        }
    }

    return @($rows)
}

function Get-CachedNoCompactionTokenUsageByModel {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [switch]$Force
    )

    $now = Get-Date
    $windows = @(Get-CostWindowDefinitions)
    $dueWindows = @()

    foreach ($window in $windows) {
        $cache = $script:NoCompactionCostWindowCache[$window.Name]
        $isDue = $Force -or $null -eq $cache
        if (-not $isDue) {
            $ageSeconds = ($now - [datetime]$cache.UpdatedAt).TotalSeconds
            $isDue = $ageSeconds -ge [double]$window.RefreshSeconds
        }

        if ($isDue) {
            $dueWindows += $window.Name
        }
    }

    if ($dueWindows.Count -gt 0) {
        $freshRows = @(Get-NoCompactionTokenUsageByModel -Root $Root -Archived:$Archived -Limit $Limit -WindowNames $dueWindows)
        foreach ($windowName in $dueWindows) {
            $script:NoCompactionCostWindowCache[$windowName] = [pscustomobject]@{
                UpdatedAt = $now
                Rows = @($freshRows | Where-Object { $_.Window -eq $windowName })
            }
        }
    }

    $rows = @()
    foreach ($window in $windows) {
        $cache = $script:NoCompactionCostWindowCache[$window.Name]
        if ($null -ne $cache) {
            $rows += $cache.Rows
        }
    }

    return @($rows)
}

function Get-CachedTokenUsageByModelPeriods {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail,
        [switch]$Force
    )

    $now = Get-Date
    $windows = @(Get-ModelPeriodWindowDefinitions)
    $groups = @($windows | Select-Object -ExpandProperty Group -Unique)
    $dueGroups = @()

    foreach ($group in $groups) {
        $groupWindows = @($windows | Where-Object { $_.Group -eq $group })
        $refreshSeconds = ($groupWindows | Select-Object -First 1).RefreshSeconds
        $cache = $script:CostPeriodCache[$group]
        $isDue = $Force -or $null -eq $cache
        if (-not $isDue) {
            $ageSeconds = ($now - [datetime]$cache.UpdatedAt).TotalSeconds
            $isDue = $ageSeconds -ge [double]$refreshSeconds
        }

        if ($isDue) {
            $dueGroups += $group
        }
    }

    if ($dueGroups.Count -gt 0) {
        $dueWindows = @($windows | Where-Object { $dueGroups -contains $_.Group })
        $freshRows = @(Get-TokenUsageByModelPeriod -Root $Root -Archived:$Archived -Limit $Limit -Tail $Tail -Windows $dueWindows)
        foreach ($group in $dueGroups) {
            $script:CostPeriodCache[$group] = [pscustomobject]@{
                UpdatedAt = $now
                Rows = @($freshRows | Where-Object { $_.PeriodGroup -eq $group })
            }
        }
    }

    $rows = @()
    foreach ($group in $groups) {
        $cache = $script:CostPeriodCache[$group]
        if ($null -ne $cache) {
            $rows += $cache.Rows
        }
    }

    return @($rows)
}

function New-ConversationUsageMatch {
    param(
        [object]$Entry,
        [object]$File,
        [object]$RateLimits,
        [object]$Info,
        [object]$TotalUsage,
        [object]$LastUsage,
        [object]$ContextWindow
    )

    [pscustomobject]@{
        Entry = $Entry
        Timestamp = Get-EventTime $Entry
        SourceFile = $File.FullName
        Session = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        RateLimits = $RateLimits
        Info = $Info
        TotalUsage = $TotalUsage
        LastUsage = $LastUsage
        ContextWindow = $ContextWindow
    }
}

function Convert-ConversationUsageRows {
    param([object]$UsageMatch)

    if ($null -eq $UsageMatch) {
        return @()
    }

    return @(
        Convert-TokenUsage "Conversation total" $UsageMatch.TotalUsage
        Convert-TokenUsage "Last update" $UsageMatch.LastUsage
    ) | Where-Object { $null -ne $_ }
}

function Get-ConversationTurnTokenRows {
    param([string]$Path)

    $turn = 0
    return @(
        foreach ($row in @(Get-SessionUsageDeltas -Path $Path -Tail 0)) {
            $metrics = $row.Metrics
            if ($null -eq $metrics) {
                continue
            }

            $turn += 1
            $model = $row.Model
            if ([string]::IsNullOrWhiteSpace([string]$model)) {
                $model = "unknown"
            }
            $pricingBand = Get-PricingBand -Model $model -InputTokens ([long]$metrics.Input)
            $costBucket = New-TokenBucket -Window "Conversation" -Model $model -PricingBand $pricingBand
            Add-TokenMetrics -Bucket $costBucket -Metrics $metrics
            Set-EstimatedCost $costBucket

            [pscustomobject]@{
                Turn = $turn
                Timestamp = $row.Timestamp
                Model = $model
                PricingBand = $costBucket.PricingBand
                PricingMode = $costBucket.PricingMode
                CostUnit = $costBucket.CostUnit
                BillingConfidence = $costBucket.BillingConfidence
                Total = $metrics.Total
                Input = $metrics.Input
                CachedInput = $metrics.CachedInput
                NonCachedInput = [Math]::Max(0L, [long]$metrics.Input - [long]$metrics.CachedInput)
                Output = $metrics.Output
                Reasoning = $metrics.Reasoning
                EstimatedCost = $costBucket.EstimatedCost
                EstimatedCostUsd = $costBucket.EstimatedCostUsd
                EstimatedCostCredits = $costBucket.EstimatedCostCredits
            }
        }
    )
}

function Get-NoCompactionTurnTokenRows {
    param([object[]]$Rows)

    $cumulativeInput = 0L
    return @(
        foreach ($row in @($Rows | Sort-Object Turn)) {
            $input = [long]$row.Input
            $before = $cumulativeInput
            $cumulativeInput += $input
            $pricingBand = Get-NoCompactionPricingBand -Model $row.Model -CumulativeInputTokens $cumulativeInput
            $pricing = Get-ApiModelPricing -Model $row.Model -PricingBand $pricingBand
            $cost = $null
            $costUsd = $null
            if ($null -ne $pricing) {
                $costValue =
                    ([long]$row.NonCachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
                    ([long]$row.CachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
                    ([long]$row.Output * [double]$pricing.OutputPerMillion / 1000000.0)
                $cost = [Math]::Round($costValue, 4)
                $costUsd = $cost
            }

            [pscustomobject]@{
                Turn = $row.Turn
                Timestamp = $row.Timestamp
                Model = $row.Model
                PricingBand = $pricingBand
                PricingMode = $PricingMode
                CostUnit = if ($null -ne $pricing) { $pricing.Unit } else { $null }
                BillingConfidence = if ($null -ne $pricing) { "Scenario" } else { "Low" }
                Total = $row.Total
                Input = $row.Input
                CachedInput = $row.CachedInput
                NonCachedInput = $row.NonCachedInput
                Output = $row.Output
                Reasoning = $row.Reasoning
                CumulativeInputBeforeTurn = $before
                CumulativeInput = $cumulativeInput
                ThresholdTokens = $script:LongContextThresholdTokens
                EstimatedCost = $cost
                EstimatedCostUsd = $costUsd
                EstimatedCostCredits = $null
            }
        }
    )
}

function Get-ConversationCostTotals {
    param([object[]]$Rows)

    [pscustomobject]@{
        TotalCostUsd = Get-TotalEstimatedCostUsd -Rows @($Rows)
        TotalCostCredits = Get-TotalEstimatedCostCredits -Rows @($Rows)
    }
}

function Get-LatestConversationUsageMatches {
    param(
        [object[]]$Files,
        [int]$Tail,
        [datetime]$SinceUtc = [DateTime]::MinValue
    )

    $latestUsage = $null
    $latestRateLimit = $null

    foreach ($file in $Files) {
        $lines = @(Get-SessionLines -Path $file.FullName -Tail $Tail)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            try {
                $entry = $lines[$index] | ConvertFrom-Json
            }
            catch {
                continue
            }

            $eventTime = Get-EventTime $entry
            if ($SinceUtc -ne [DateTime]::MinValue -and $null -ne $eventTime -and $eventTime -lt $SinceUtc) {
                continue
            }

            $payload = Get-PropValue $entry @("payload")
            if ($null -eq $payload) {
                continue
            }

            $rateLimits = Get-PropValue $payload @("rate_limits", "rateLimitStatus", "rate_limit_status")
            $info = Get-PropValue $payload @("info")
            $totalUsage = Get-PropValue $info @("total_token_usage", "totalTokenUsage")
            $lastUsage = Get-PropValue $info @("last_token_usage", "lastTokenUsage")
            $contextWindow = Get-PropValue $info @("model_context_window", "modelContextWindow")

            if ($null -eq $rateLimits -and $null -eq $totalUsage -and $null -eq $lastUsage) {
                continue
            }

            $match = New-ConversationUsageMatch `
                -Entry $entry `
                -File $file `
                -RateLimits $rateLimits `
                -Info $info `
                -TotalUsage $totalUsage `
                -LastUsage $lastUsage `
                -ContextWindow $contextWindow

            if (($null -ne $totalUsage -or $null -ne $lastUsage) -and
                ($null -eq $latestUsage -or $match.Timestamp -ge $latestUsage.Timestamp)) {
                $latestUsage = $match
            }

            if ($null -ne $rateLimits -and
                ($null -eq $latestRateLimit -or $match.Timestamp -ge $latestRateLimit.Timestamp)) {
                $latestRateLimit = $match
            }
        }
    }

    [pscustomobject]@{
        Usage = $latestUsage
        RateLimit = $latestRateLimit
    }
}

function Get-ConversationOverviewRows {
    param(
        [object[]]$Files
    )

    return @(
        foreach ($file in @($Files)) {
            $matches = Get-LatestConversationUsageMatches -Files @($file) -Tail 0
            $usageMatch = $matches.Usage
            $turnTokenRows = @(Get-ConversationTurnTokenRows -Path $file.FullName)
            $noCompactionTurnRows = @(Get-NoCompactionTurnTokenRows -Rows $turnTokenRows)

            [pscustomobject]@{
                Session = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                LastModified = $file.LastWriteTime
                SourceFile = $file.FullName
                TokenRows = @(Convert-ConversationUsageRows $usageMatch)
                TurnTokenRows = $turnTokenRows
                CostTotals = Get-ConversationCostTotals -Rows $turnTokenRows
                NoCompactionTurnRows = $noCompactionTurnRows
                NoCompactionCostTotals = Get-ConversationCostTotals -Rows $noCompactionTurnRows
                ContextWindow = if ($null -ne $usageMatch) { $usageMatch.ContextWindow } else { $null }
                LatestUsageTimestamp = if ($null -ne $usageMatch) { $usageMatch.Timestamp } else { $null }
            }
        }
    )
}

function Get-LatestCodexUsageSnapshot {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail,
        [int]$ConversationLookbackHours = $script:ConversationLookbackHours,
        [int]$ConversationFallbackLookbackDays = $script:ConversationFallbackLookbackDays,
        [int]$ConversationFallbackMaxFiles = $script:ConversationFallbackMaxFiles,
        [int]$ConversationFallbackTailLines = $script:ConversationFallbackTailLines,
        [switch]$ForceCostRefresh
    )

    $nowUtc = [DateTime]::UtcNow
    $searches = @()
    $overviewFiles = @()
    if ($ConversationLookbackHours -gt 0) {
        $sinceUtc = $nowUtc.AddHours(-1 * $ConversationLookbackHours)
        $overviewFiles = @(Get-SessionFilesSince -Root $Root -Archived:$Archived -SinceUtc $sinceUtc)
        $searches += [pscustomobject]@{
            Files = $overviewFiles
            Tail = 0
            SinceUtc = $sinceUtc
        }
    }

    if ($ConversationFallbackLookbackDays -gt 0) {
        $sinceUtc = $nowUtc.AddDays(-1 * $ConversationFallbackLookbackDays)
        $searches += [pscustomobject]@{
            Files = @(Get-SessionFilesSince -Root $Root -Archived:$Archived -SinceUtc $sinceUtc)
            Tail = 0
            SinceUtc = $sinceUtc
        }
    }

    $legacyLimit = if ($ConversationFallbackMaxFiles -gt 0) { $ConversationFallbackMaxFiles } else { $Limit }
    $legacyTail = if ($ConversationFallbackTailLines -gt 0) { $ConversationFallbackTailLines } else { $Tail }
    $searches += [pscustomobject]@{
        Files = @(Get-SessionFiles -Root $Root -Archived:$Archived -Limit $legacyLimit)
        Tail = $legacyTail
        SinceUtc = [DateTime]::MinValue
    }

    foreach ($search in $searches) {
        if ($search.Files.Count -eq 0) {
            continue
        }

        $matches = Get-LatestConversationUsageMatches -Files $search.Files -Tail $search.Tail -SinceUtc $search.SinceUtc
        $usageMatch = $matches.Usage
        $rateLimitMatch = $matches.RateLimit
        $sourceMatch = if ($null -ne $usageMatch) { $usageMatch } else { $rateLimitMatch }

        if ($null -eq $sourceMatch) {
            continue
        }

        $rateLimits = if ($null -ne $rateLimitMatch) { $rateLimitMatch.RateLimits } else { $usageMatch.RateLimits }
        $modelRows = @(Get-CachedTokenUsageByModel -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Tail $CostTailLines -Force:$ForceCostRefresh)
        $noCompactionModelRows = @(Get-CachedNoCompactionTokenUsageByModel -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Force:$ForceCostRefresh)
        $modelPeriodRows = @(Get-CachedTokenUsageByModelPeriods -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Tail $CostTailLines -Force:$ForceCostRefresh)
        $modelPeriodWindows = @(Get-ModelPeriodWindowDefinitions)

        $snapshot = [pscustomobject]@{
            Timestamp = Get-PropValue $sourceMatch.Entry @("timestamp")
            SourceFile = $sourceMatch.SourceFile
            Session = $sourceMatch.Session
            PlanType = if (Get-PropValue $rateLimits @("plan_type", "planType")) {
                Get-PropValue $rateLimits @("plan_type", "planType")
            }
            else {
                Get-LatestPlanType -Root $Root -Archived:$Archived -Limit $legacyLimit -Tail $legacyTail
            }
            RateLimitRows = @(Convert-RateLimits $rateLimits)
            RollingTokenRows = @(Get-RollingTokenUsage -Root $Root -Archived:$Archived -Limit $RollingMaxFiles -Tail $RollingTailLines)
            ModelTokenRows = $modelRows
            NoCompactionModelTokenRows = $noCompactionModelRows
            ModelTokenPeriodRows = $modelPeriodRows
            ModelTokenPeriodWindows = $modelPeriodWindows
            SourceCostRows = @(Get-TokenSourceCostEstimates -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Tail $CostTailLines -ModelRows $modelRows)
            CostBasis = if ($CostBasisMode -eq "CodexCredits") { "Codex credit equivalent for paid/extra usage" } else { "API-equivalent USD estimate for ChatGPT/Codex subscription usage" }
            CostBasisMode = $CostBasisMode
            PricingMode = $PricingMode
            PricingSource = if ($CostBasisMode -eq "CodexCredits") { "https://help.openai.com/en/articles/20001106-codex-rate-card" } else { "https://openai.com/api/pricing/" }
            RegionalUpliftApplied = $false
            TokenRows = if ($null -ne $usageMatch) {
                @(Convert-ConversationUsageRows $usageMatch)
            }
            else {
                @()
            }
            ContextWindow = if ($null -ne $usageMatch) { $usageMatch.ContextWindow } else { $null }
            ConversationOverviewRows = @(Get-ConversationOverviewRows -Files $overviewFiles)
        }

        Write-RateLimitHistorySamples -Root $Root -Snapshot $snapshot
        $rateLimitHistoryRows = @(Get-RateLimitHistoryRows -Root $Root -Days $RateLimitHistoryDays)
        $snapshot | Add-Member -NotePropertyName RateLimitHistoryRows -NotePropertyValue $rateLimitHistoryRows
        $snapshot | Add-Member -NotePropertyName RateLimitHistorySummaryRows -NotePropertyValue @(Get-RateLimitHistorySummary -Rows $rateLimitHistoryRows)
        $snapshot | Add-Member -NotePropertyName RateLimitHistoryDays -NotePropertyValue $RateLimitHistoryDays
        $snapshot | Add-Member -NotePropertyName RateLimitHistorySampleSeconds -NotePropertyValue $RateLimitHistorySampleSeconds

        return $snapshot
    }

    return $null
}

function Show-Snapshot {
    param([object]$Snapshot)

    Clear-Host
    Write-Host "Codex usage monitor"
    Write-Host ("Updated   : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

    if ($null -eq $Snapshot) {
        Write-Host ""
        Write-Host ("No Codex usage snapshot found under {0}" -f $CodexHome)
        return
    }

    Write-Host ("Event     : {0}" -f $Snapshot.Timestamp)
    Write-Host ("Plan      : {0}" -f ($(if ($Snapshot.PlanType) { $Snapshot.PlanType } else { "unknown" })))
    Write-Host ("Session   : {0}" -f $Snapshot.Session)
    Write-Host ("Source    : {0}" -f $Snapshot.SourceFile)
    Write-Host ""

    if ($Snapshot.RateLimitRows.Count -gt 0) {
        Write-Host "Rate limits"
        $Snapshot.RateLimitRows |
            Select-Object Window, UsedPercent, RemainingPercent, WindowMinutes, ResetsAt |
            Format-Table -AutoSize

        if ($Snapshot.PSObject.Properties["RateLimitHistorySummaryRows"] -and $Snapshot.RateLimitHistorySummaryRows.Count -gt 0) {
            Write-Host ("Rate-limit history, last {0} days" -f $Snapshot.RateLimitHistoryDays)
            $Snapshot.RateLimitHistorySummaryRows |
                Select-Object Window, LatestUsedPercent, PeakUsedPercent, AverageUsedPercent, Samples, ResetCount, FirstSampledAt, LastSampledAt |
                Format-Table -AutoSize
        }
    }
    else {
        Write-Host "Rate limits: no rate-limit payload in latest usage event."
        Write-Host ""
    }

    if ($Snapshot.RollingTokenRows.Count -gt 0) {
        Write-Host "Rolling token usage, local estimate"
        $Snapshot.RollingTokenRows |
            Select-Object Window, Total, Input, CachedInput, Output, Reasoning, Events |
            Format-Table -AutoSize
    }

    if ($Snapshot.ModelTokenRows.Count -gt 0) {
        Write-Host "Estimated token cost by model, local estimate"
        foreach ($windowName in @("Last 5 hours", "This week", "This month")) {
            $windowRows = @($Snapshot.ModelTokenRows | Where-Object { $_.Window -eq $windowName })
            if ($windowRows.Count -eq 0) {
                continue
            }

            Write-Host $windowName
            $windowRows |
                Select-Object Model, PricingBand, PricingMode, CostUnit, BillingConfidence, Total, Input, CachedInput, Output, Reasoning, Events, EstimatedCost, EstimatedCostUsd, EstimatedCostCredits |
                Format-Table -AutoSize

            $totalCostUsd = Get-TotalEstimatedCostUsd $windowRows
            $totalCostCredits = Get-TotalEstimatedCostCredits $windowRows
            if ($CostBasisMode -eq "CodexCredits") {
                Write-Host ("totalCostCredits: {0:N4}" -f $totalCostCredits)
            }
            else {
                $totalCostSgd = [Math]::Round($totalCostUsd * $UsdToSgdRate, 4)
                Write-Host ("totalCostUsd: {0:N4}" -f $totalCostUsd)
                Write-Host ("totalCostSgd: {0:N4}" -f $totalCostSgd)
            }
            Write-Host ""
        }

        Write-Host ("Cost basis: {0}; pricing mode: {1}." -f $Snapshot.CostBasis, $PricingMode)
        Write-Host ("Pricing source: {0} (reasoning tokens are shown separately and not double-counted)." -f $Snapshot.PricingSource)
        if ($CostBasisMode -eq "CodexCredits") {
            Write-Host "SGD conversion: not applied to Codex credits."
        }
        else {
            Write-Host ("SGD conversion: 1 USD = {0} SGD. Override with -UsdToSgdRate if needed." -f $UsdToSgdRate)
            Write-Host "Regional uplift: not applied."
        }
        Write-Host ""
    }

    if ($Snapshot.PSObject.Properties["NoCompactionModelTokenRows"] -and $Snapshot.NoCompactionModelTokenRows.Count -gt 0) {
        Write-Host "API no-compaction scenario by model"
        foreach ($windowName in @("Last 5 hours", "This week", "This month")) {
            $windowRows = @($Snapshot.NoCompactionModelTokenRows | Where-Object { $_.Window -eq $windowName })
            if ($windowRows.Count -eq 0) {
                continue
            }

            Write-Host $windowName
            $windowRows |
                Select-Object Model, PricingBand, PricingMode, CostUnit, BillingConfidence, Total, Input, CachedInput, Output, Reasoning, Events, EstimatedCost, EstimatedCostUsd |
                Format-Table -AutoSize

            $totalCostUsd = Get-TotalEstimatedCostUsd $windowRows
            $totalCostSgd = [Math]::Round($totalCostUsd * $UsdToSgdRate, 4)
            Write-Host ("totalCostUsd: {0:N4}" -f $totalCostUsd)
            Write-Host ("totalCostSgd: {0:N4}" -f $totalCostSgd)
            Write-Host ""
        }
    }

    if ($Snapshot.TokenRows.Count -gt 0) {
        Write-Host "Conversation token usage"
        $Snapshot.TokenRows |
            Select-Object Scope, Total, Input, CachedInput, Output, Reasoning |
            Format-Table -AutoSize
    }
    else {
        Write-Host "Conversation token usage: no token payload in latest usage event."
        Write-Host ""
    }

    if ($null -ne $Snapshot.ContextWindow) {
        Write-Host ("Model context window: {0} tokens" -f $Snapshot.ContextWindow)
    }

    if (-not $Once) {
        Write-Host ""
        Write-Host ("Refreshing every {0}s. Press Ctrl+C to stop." -f $RefreshSeconds)
        Write-Host ("Cost refresh cadence: 5h every {0}s, week every {1}s, month every {2}s." -f $CostFiveHourRefreshSeconds, $CostWeekRefreshSeconds, $CostMonthRefreshSeconds)
    }
}

if ($BackfillRateLimitHistory) {
    $backfill = Import-RateLimitHistoryFromSessions `
        -Root $CodexHome `
        -Archived:$IncludeArchived `
        -Days $RateLimitHistoryDays `
        -SampleSeconds $RateLimitHistorySampleSeconds

    Write-Host ("Rate-limit history backfill imported {0} observed rows and saved {1} compressed samples." -f $backfill.Imported, $backfill.Saved)
    Write-Host ("History file: {0}" -f $backfill.Path)

    if ($Once) {
        return
    }
}

if (-not $LibraryOnly -and -not $Console -and -not $Once) {
    $dashboardScript = Join-Path $PSScriptRoot "codex_usage_dashboard.ps1"
    if (-not (Test-Path -LiteralPath $dashboardScript)) {
        throw "Dashboard script not found: $dashboardScript"
    }

    & $dashboardScript `
        -CodexHome $CodexHome `
        -MonitorScript $PSCommandPath `
        -Port $DashboardPort `
        -MaxFiles $MaxFiles `
        -TailLines $TailLines `
        -ConversationLookbackHours $ConversationLookbackHours `
        -ConversationFallbackLookbackDays $ConversationFallbackLookbackDays `
        -ConversationFallbackMaxFiles $ConversationFallbackMaxFiles `
        -ConversationFallbackTailLines $ConversationFallbackTailLines `
        -RollingMaxFiles $RollingMaxFiles `
        -RollingTailLines $RollingTailLines `
        -CostMaxFiles $CostMaxFiles `
        -CostTailLines $CostTailLines `
        -CostFiveHourRefreshSeconds $CostFiveHourRefreshSeconds `
        -CostWeekRefreshSeconds $CostWeekRefreshSeconds `
        -CostMonthRefreshSeconds $CostMonthRefreshSeconds `
        -RateLimitHistoryDays $RateLimitHistoryDays `
        -RateLimitHistorySampleSeconds $RateLimitHistorySampleSeconds `
        -UsdToSgdRate $UsdToSgdRate `
        -CostBasisMode $CostBasisMode `
        -PricingMode $PricingMode `
        -IncludeArchived:$IncludeArchived `
        -NoOpen:$NoOpen `
        -DisableRateLimitHistory:$DisableRateLimitHistory
    return
}

if (-not $LibraryOnly) {
    do {
        $snapshot = Get-LatestCodexUsageSnapshot `
            -Root $CodexHome `
            -Archived:$IncludeArchived `
            -Limit $MaxFiles `
            -Tail $TailLines `
            -ConversationLookbackHours $ConversationLookbackHours `
            -ConversationFallbackLookbackDays $ConversationFallbackLookbackDays `
            -ConversationFallbackMaxFiles $ConversationFallbackMaxFiles `
            -ConversationFallbackTailLines $ConversationFallbackTailLines `
            -ForceCostRefresh:$Once
        Show-Snapshot $snapshot

        if ($Once) {
            break
        }

        Start-Sleep -Seconds $RefreshSeconds
    } while ($true)
}
