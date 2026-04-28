param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
    [int]$RefreshSeconds = 3,
    [int]$MaxFiles = 5,
    [int]$TailLines = 500,
    [int]$RollingMaxFiles = 0,
    [int]$RollingTailLines = 0,
    [int]$CostMaxFiles = 0,
    [int]$CostTailLines = 0,
    [int]$CostFiveHourRefreshSeconds = 60,
    [int]$CostWeekRefreshSeconds = 60,
    [int]$CostMonthRefreshSeconds = 86400,
    [double]$UsdToSgdRate = 1.274,
    [ValidateSet("Standard", "Batch", "Flex", "Priority")]
    [string]$PricingMode = "Standard",
    [switch]$Once,
    [switch]$IncludeArchived,
    [switch]$LibraryOnly,
    [switch]$Console,
    [switch]$NoOpen,
    [int]$DashboardPort = 8787
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:CostWindowCache = @{}

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
        Total = 0L
        Input = 0L
        CachedInput = 0L
        Output = 0L
        Reasoning = 0L
        Events = 0
        EstimatedCostUsd = $null
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

function Get-JsonNumberFromLine {
    param(
        [string]$Line,
        [string]$Name
    )

    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*(?<value>-?\d+)'
    if ($Line -match $pattern) {
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

function Get-UsageMetricsFromJsonLine {
    param(
        [string]$Line,
        [string]$PropertyName
    )

    $pattern = '"' + [regex]::Escape($PropertyName) + '"\s*:\s*\{(?<body>[^}]*)\}'
    if ($Line -notmatch $pattern) {
        return $null
    }

    return Convert-UsageJsonBodyToMetrics $Matches["body"]
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

function Get-ModelPricingTable {
    @(
        [pscustomobject]@{ Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 30.00 }
        [pscustomobject]@{ Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 10.00; CachedInputPerMillion = 1.00; OutputPerMillion = 45.00 }
        [pscustomobject]@{ Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Mode = "Standard"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.75; CachedInputPerMillion = 0.075; OutputPerMillion = 4.50 }
        [pscustomobject]@{ Mode = "Standard"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.20; CachedInputPerMillion = 0.02; OutputPerMillion = 1.25 }
        [pscustomobject]@{ Mode = "Standard"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 1.75; CachedInputPerMillion = 0.175; OutputPerMillion = 14.00 }

        [pscustomobject]@{ Mode = "Batch"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Mode = "Batch"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Mode = "Batch"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 1.25; CachedInputPerMillion = 0.13; OutputPerMillion = 7.50 }
        [pscustomobject]@{ Mode = "Batch"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 11.25 }
        [pscustomobject]@{ Mode = "Batch"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.375; CachedInputPerMillion = 0.0375; OutputPerMillion = 2.25 }
        [pscustomobject]@{ Mode = "Batch"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.10; CachedInputPerMillion = 0.01; OutputPerMillion = 0.625 }

        [pscustomobject]@{ Mode = "Flex"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Mode = "Flex"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Mode = "Flex"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 1.25; CachedInputPerMillion = 0.13; OutputPerMillion = 7.50 }
        [pscustomobject]@{ Mode = "Flex"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 11.25 }
        [pscustomobject]@{ Mode = "Flex"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.375; CachedInputPerMillion = 0.0375; OutputPerMillion = 2.25 }
        [pscustomobject]@{ Mode = "Flex"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.10; CachedInputPerMillion = 0.01; OutputPerMillion = 0.625 }

        [pscustomobject]@{ Mode = "Priority"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 12.50; CachedInputPerMillion = 1.25; OutputPerMillion = 75.00 }
        [pscustomobject]@{ Mode = "Priority"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 30.00 }
        [pscustomobject]@{ Mode = "Priority"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 1.50; CachedInputPerMillion = 0.15; OutputPerMillion = 9.00 }
        [pscustomobject]@{ Mode = "Priority"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 3.50; CachedInputPerMillion = 0.35; OutputPerMillion = 28.00 }
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

    if ($InputTokens -gt 272000) {
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
        Where-Object { $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq $PricingBand } |
        Select-Object -First 1

    if ($null -eq $pricing -and $PricingBand -eq "Long") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq "Short" } |
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

    $pricing = Get-ModelPricing -Model $Bucket.Model -InputTokens ([long]$Bucket.Input) -PricingBand $Bucket.PricingBand
    if ($null -eq $pricing) {
        $Bucket.BillingConfidence = "Low"
        return
    }

    $Bucket.BillingConfidence = "High"

    $cachedInput = [Math]::Max(0L, [long]$Bucket.CachedInput)
    $uncachedInput = [Math]::Max(0L, [long]$Bucket.Input - $cachedInput)
    $cost =
        ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
        ($cachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
        ([long]$Bucket.Output * [double]$pricing.OutputPerMillion / 1000000.0)

    $Bucket.EstimatedCostUsd = [Math]::Round($cost, 4)
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
    $value = $null

    if ($entryType -eq "event_msg" -and $payloadType -eq "user_message") {
        $source = "User input"
        $side = "Input"
        $value = @(
            Get-PropValue $payload @("message")
            Get-PropValue $payload @("text_elements", "textElements")
        )
    }
    elseif ($entryType -eq "response_item" -and $payloadType -eq "message") {
        $role = Get-PropValue $payload @("role")
        if ($role -eq "assistant") {
            $source = "Assistant output"
            $side = "Output"
            $value = Get-PropValue $payload @("content")
        }
    }
    elseif ($entryType -eq "response_item" -and ($payloadType -eq "function_call" -or $payloadType -eq "custom_tool_call")) {
        $source = "Tool call arguments"
        $side = "Output"
        $value = @(
            Get-PropValue $payload @("name")
            Get-PropValue $payload @("arguments", "input")
        )
    }
    elseif ($entryType -eq "response_item" -and ($payloadType -eq "function_call_output" -or $payloadType -eq "custom_tool_call_output")) {
        $source = "Tool outputs"
        $side = "Input"
        $value = Get-PropValue $payload @("output")
    }
    elseif ($entryType -eq "response_item" -and $payloadType -eq "reasoning") {
        $source = "Reasoning"
        $side = "Output"
        $value = @(
            Get-PropValue $payload @("summary")
            Get-PropValue $payload @("content")
        )
    }
    elseif (($entryType -eq "response_item" -and $payloadType -eq "summary") -or ($entryType -eq "event_msg" -and $payloadType -eq "context_compacted") -or $entryType -eq "compacted") {
        $source = "Context summaries"
        $side = "Input"
        $value = $payload
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
        return $null
    }

    $tokens = Convert-CharsToEstimatedTokens (Get-EstimatedTextChars $value)
    if ($tokens -le 0) {
        return $null
    }

    [pscustomobject]@{
        Source = $source
        Side = $side
        Tokens = $tokens
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
        Events = 0
        Attribution = "Text estimate"
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

    $Buckets[$key].Events += 1
}

function Get-SourceCostRows {
    param(
        [object[]]$EstimateRows,
        [object[]]$ModelRows
    )

    $rows = @()
    foreach ($modelRow in $ModelRows) {
        $pricing = Get-ModelPricing -Model $modelRow.Model -InputTokens ([long]$modelRow.Input) -PricingBand $modelRow.PricingBand
        $sourceRows = @($EstimateRows | Where-Object { $_.Window -eq $modelRow.Window -and $_.Model -eq $modelRow.Model })

        $inputEstimateTotal = [long](($sourceRows | Measure-Object -Property EstimatedInputTokens -Sum).Sum)
        $outputEstimateTotal = [long](($sourceRows | Measure-Object -Property EstimatedOutputTokens -Sum).Sum)

        $expandedRows = @($sourceRows)
        if ([long]$modelRow.Input -gt $inputEstimateTotal) {
            $expandedRows += [pscustomobject]@{
                Window = $modelRow.Window
                Model = $modelRow.Model
                Source = "Unattributed input/context"
                EstimatedInputTokens = [long]$modelRow.Input - $inputEstimateTotal
                EstimatedOutputTokens = 0L
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
                Events = 0
                Attribution = "Allocated remainder"
            }
            $outputEstimateTotal = [long]$modelRow.Output
        }

        foreach ($sourceRow in $expandedRows) {
            $allocatedInput = 0L
            $allocatedOutput = 0L
            if ($inputEstimateTotal -gt 0 -and [long]$sourceRow.EstimatedInputTokens -gt 0) {
                $allocatedInput = [long][Math]::Round([double]$modelRow.Input * [double]$sourceRow.EstimatedInputTokens / [double]$inputEstimateTotal)
            }

            if ($outputEstimateTotal -gt 0 -and [long]$sourceRow.EstimatedOutputTokens -gt 0) {
                $allocatedOutput = [long][Math]::Round([double]$modelRow.Output * [double]$sourceRow.EstimatedOutputTokens / [double]$outputEstimateTotal)
            }

            $allocatedCachedInput = 0L
            if ([long]$modelRow.Input -gt 0 -and $allocatedInput -gt 0) {
                $allocatedCachedInput = [long][Math]::Round([double]$modelRow.CachedInput * [double]$allocatedInput / [double]$modelRow.Input)
            }

            $cost = $null
            if ($null -ne $pricing) {
                $uncachedInput = [Math]::Max(0L, $allocatedInput - $allocatedCachedInput)
                $costValue =
                    ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
                    ($allocatedCachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
                    ($allocatedOutput * [double]$pricing.OutputPerMillion / 1000000.0)
                $cost = [Math]::Round($costValue, 4)
            }

            $rows += [pscustomobject]@{
                Window = $sourceRow.Window
                Model = $sourceRow.Model
                Source = $sourceRow.Source
                PricingMode = $PricingMode
                PricingBand = $modelRow.PricingBand
                BillingConfidence = if ($null -eq $pricing) { "Low" } elseif ($sourceRow.Attribution -eq "Allocated remainder") { "Medium" } else { $modelRow.BillingConfidence }
                EstimatedTokens = [long]$sourceRow.EstimatedInputTokens + [long]$sourceRow.EstimatedOutputTokens
                AllocatedInput = $allocatedInput
                AllocatedCachedInput = $allocatedCachedInput
                AllocatedOutput = $allocatedOutput
                Events = $sourceRow.Events
                EstimatedCostUsd = $cost
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

        $previousTotal = $null
        $lines = @(Get-SessionLines -Path $file.FullName -Tail $Tail)

        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]
            if ($line -notlike '*"total_token_usage"*') {
                continue
            }

            $eventTime = Get-JsonLineEventTime $line
            if ($null -eq $eventTime) {
                continue
            }

            $currentTotal = Get-UsageMetricsFromJsonLine $line "total_token_usage"
            if ($null -eq $currentTotal) {
                continue
            }

            if (Test-SameMetrics $previousTotal $currentTotal) {
                continue
            }

            $delta = Get-PositiveDeltaMetrics $previousTotal $currentTotal
            if ($null -eq $delta) {
                $lastMetrics = Get-UsageMetricsFromJsonLine $line "last_token_usage"
                if ($null -ne $lastMetrics -and (Test-SameMetrics $currentTotal $lastMetrics)) {
                    $delta = $lastMetrics
                }
            }

            $previousTotal = $currentTotal

            if ($null -eq $delta) {
                continue
            }

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
        if ($file.LastWriteTimeUtc -lt $oldestStart) {
            continue
        }

        $currentModel = Get-SessionInitialModel $file.FullName
        $previousTotal = $null
        $lines = @(Get-SessionLines -Path $file.FullName -Tail $Tail)

        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]

            if ($line -like '*"turn_context"*') {
                $model = Get-JsonStringFromLine $line "model"
                if (-not [string]::IsNullOrWhiteSpace($model)) {
                    $currentModel = $model
                }
            }

            if ($line -notlike '*"total_token_usage"*') {
                continue
            }

            $eventTime = Get-JsonLineEventTime $line
            if ($null -eq $eventTime -or $eventTime -lt $oldestStart) {
                continue
            }

            $currentTotal = Get-UsageMetricsFromJsonLine $line "total_token_usage"
            if ($null -eq $currentTotal) {
                continue
            }

            if (Test-SameMetrics $previousTotal $currentTotal) {
                continue
            }

            $delta = Get-PositiveDeltaMetrics $previousTotal $currentTotal
            if ($null -eq $delta) {
                $lastMetrics = Get-UsageMetricsFromJsonLine $line "last_token_usage"
                if ($null -ne $lastMetrics -and (Test-SameMetrics $currentTotal $lastMetrics)) {
                    $delta = $lastMetrics
                }
            }

            $previousTotal = $currentTotal

            if ($null -eq $delta) {
                continue
            }

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

function Get-LatestCodexUsageSnapshot {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Tail,
        [switch]$ForceCostRefresh
    )

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        $lines = @(Get-Content -LiteralPath $file.FullName -Tail $Tail)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            try {
                $entry = $lines[$index] | ConvertFrom-Json
            }
            catch {
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

            $modelRows = @(Get-CachedTokenUsageByModel -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Tail $CostTailLines -Force:$ForceCostRefresh)

            return [pscustomobject]@{
                Timestamp = Get-PropValue $entry @("timestamp")
                SourceFile = $file.FullName
                Session = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                PlanType = if (Get-PropValue $rateLimits @("plan_type", "planType")) {
                    Get-PropValue $rateLimits @("plan_type", "planType")
                }
                else {
                    Get-LatestPlanType -Root $Root -Archived:$Archived -Limit $Limit -Tail $Tail
                }
                RateLimitRows = @(Convert-RateLimits $rateLimits)
                RollingTokenRows = @(Get-RollingTokenUsage -Root $Root -Archived:$Archived -Limit $RollingMaxFiles -Tail $RollingTailLines)
                ModelTokenRows = $modelRows
                SourceCostRows = @(Get-TokenSourceCostEstimates -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Tail $CostTailLines -ModelRows $modelRows)
                CostBasis = "API-equivalent estimate for ChatGPT/Codex subscription usage"
                PricingMode = $PricingMode
                PricingSource = "https://developers.openai.com/api/docs/pricing"
                RegionalUpliftApplied = $false
                TokenRows = @(
                    Convert-TokenUsage "Conversation total" $totalUsage
                    Convert-TokenUsage "Last update" $lastUsage
                ) | Where-Object { $null -ne $_ }
                ContextWindow = $contextWindow
            }
        }
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
                Select-Object Model, PricingBand, PricingMode, BillingConfidence, Total, Input, CachedInput, Output, Reasoning, Events, EstimatedCostUsd |
                Format-Table -AutoSize

            $totalCostUsd = Get-TotalEstimatedCostUsd $windowRows
            $totalCostSgd = [Math]::Round($totalCostUsd * $UsdToSgdRate, 4)
            Write-Host ("totalCostUsd: {0:N4}" -f $totalCostUsd)
            Write-Host ("totalCostSgd: {0:N4}" -f $totalCostSgd)
            Write-Host ""
        }

        Write-Host ("Cost basis: API-equivalent estimate for ChatGPT/Codex subscription usage; pricing mode: {0}." -f $PricingMode)
        Write-Host "Pricing source: https://developers.openai.com/api/docs/pricing (reasoning tokens are shown separately and not double-counted)."
        Write-Host ("SGD conversion: 1 USD = {0} SGD. Override with -UsdToSgdRate if needed." -f $UsdToSgdRate)
        Write-Host "Regional uplift: not applied."
        Write-Host ""
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

if (-not $LibraryOnly -and -not $Console -and -not $Once) {
    $dashboardScript = Join-Path $env:USERPROFILE ".codex\tools\codex_usage_dashboard.ps1"
    if (-not (Test-Path -LiteralPath $dashboardScript)) {
        throw "Dashboard script not found: $dashboardScript"
    }

    & $dashboardScript `
        -CodexHome $CodexHome `
        -MonitorScript $PSCommandPath `
        -Port $DashboardPort `
        -MaxFiles $MaxFiles `
        -TailLines $TailLines `
        -RollingMaxFiles $RollingMaxFiles `
        -RollingTailLines $RollingTailLines `
        -CostMaxFiles $CostMaxFiles `
        -CostTailLines $CostTailLines `
        -CostFiveHourRefreshSeconds $CostFiveHourRefreshSeconds `
        -CostWeekRefreshSeconds $CostWeekRefreshSeconds `
        -CostMonthRefreshSeconds $CostMonthRefreshSeconds `
        -UsdToSgdRate $UsdToSgdRate `
        -PricingMode $PricingMode `
        -IncludeArchived:$IncludeArchived `
        -NoOpen:$NoOpen
    return
}

if (-not $LibraryOnly) {
    do {
        $snapshot = Get-LatestCodexUsageSnapshot -Root $CodexHome -Archived:$IncludeArchived -Limit $MaxFiles -Tail $TailLines -ForceCostRefresh:$Once
        Show-Snapshot $snapshot

        if ($Once) {
            break
        }

        Start-Sleep -Seconds $RefreshSeconds
    } while ($true)
}
