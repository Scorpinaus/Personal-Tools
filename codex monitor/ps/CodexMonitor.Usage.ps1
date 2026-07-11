# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

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

function Get-DailyTokenUsageRows {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [int]$Days = 365
    )

    $safeDays = [Math]::Max(1, $Days)
    $todayLocal = (Get-Date).Date
    $startLocal = $todayLocal.AddDays(-1 * ($safeDays - 1))
    $endLocal = $todayLocal.AddDays(1)
    $startUtc = $startLocal.ToUniversalTime()
    $endUtc = $endLocal.ToUniversalTime()
    $buckets = [ordered]@{}

    for ($index = 0; $index -lt $safeDays; $index++) {
        $date = $startLocal.AddDays($index).ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
        $buckets[$date] = [pscustomobject]@{
            Date = $date
            Total = 0L
            Input = 0L
            CachedInput = 0L
            Output = 0L
            Reasoning = 0L
            Events = 0
        }
    }

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        if ($file.LastWriteTimeUtc -lt $startUtc) {
            continue
        }

        foreach ($usageEvent in (Get-SessionUsageDeltas -Path $file.FullName -Tail 0)) {
            $eventTime = $usageEvent.Timestamp
            if ($null -eq $eventTime -or $eventTime -lt $startUtc -or $eventTime -ge $endUtc) {
                continue
            }

            $date = $eventTime.ToLocalTime().Date.ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
            if (-not $buckets.Contains($date)) {
                continue
            }

            $bucket = $buckets[$date]
            $bucket.Total += [long]$usageEvent.Metrics.Total
            $bucket.Input += [long]$usageEvent.Metrics.Input
            $bucket.CachedInput += [long]$usageEvent.Metrics.CachedInput
            $bucket.Output += [long]$usageEvent.Metrics.Output
            $bucket.Reasoning += [long]$usageEvent.Metrics.Reasoning
            $bucket.Events += 1
        }
    }

    return @($buckets.Values)
}

function Get-RateLimitTokenUsageRows {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [object[]]$RateLimitRows
    )

    $nowUtc = [DateTime]::UtcNow
    $specs = @()

    foreach ($rateRow in @($RateLimitRows)) {
        if ($null -eq $rateRow -or $rateRow.Window -notin @("5 hour", "1 week")) {
            continue
        }

        $minutes = if ($null -ne $rateRow.WindowMinutes) { [double]$rateRow.WindowMinutes } elseif ($rateRow.Window -eq "5 hour") { 300.0 } else { 10080.0 }
        if ($minutes -le 0) {
            continue
        }

        $windowEndUtc = $nowUtc
        $confidence = "Duration fallback local estimate"
        if ($null -ne $rateRow.ResetsAt) {
            try {
                $windowEndUtc = ([datetime]$rateRow.ResetsAt).ToUniversalTime()
                $confidence = "Reset-aligned local estimate"
            }
            catch {
                $windowEndUtc = $nowUtc
            }
        }

        $windowStartUtc = $windowEndUtc.AddMinutes(-1 * $minutes)

        $rawUsedProp = $rateRow.PSObject.Properties["RawUsedPercent"]
        $usedPercent = if ($null -ne $rawUsedProp -and $null -ne $rawUsedProp.Value) { [double]$rawUsedProp.Value } else { [double]$rateRow.UsedPercent }
        $specs += [pscustomobject]@{
            RateRow = $rateRow
            UsedPercent = $usedPercent
            WindowStartUtc = $windowStartUtc
            WindowEndUtc = $windowEndUtc
            WindowMinutes = $minutes
            Confidence = $confidence
            Bucket = New-TokenBucket $rateRow.Window
        }
    }

    if ($specs.Count -eq 0) {
        return @()
    }

    $oldestStartUtc = ($specs | Sort-Object WindowStartUtc | Select-Object -First 1).WindowStartUtc
    $newestEndUtc = ($specs | Sort-Object WindowEndUtc -Descending | Select-Object -First 1).WindowEndUtc

    foreach ($file in (Get-SessionFiles -Root $Root -Archived:$Archived -Limit $Limit)) {
        if ($file.LastWriteTimeUtc -lt $oldestStartUtc) {
            break
        }

        foreach ($usageEvent in (Get-SessionUsageDeltas -Path $file.FullName -Tail 0)) {
            $eventTime = $usageEvent.Timestamp
            if ($eventTime -lt $oldestStartUtc -or $eventTime -ge $newestEndUtc) {
                continue
            }

            foreach ($spec in $specs) {
                if ($eventTime -lt $spec.WindowStartUtc -or $eventTime -ge $spec.WindowEndUtc) {
                    continue
                }

                Add-TokenMetrics $spec.Bucket $usageEvent.Metrics
            }
        }
    }

    $rows = @()
    foreach ($spec in $specs) {
        $bucket = $spec.Bucket
        $usedPercent = [double]$spec.UsedPercent
        $tokensPerPercent = $null
        $impliedFullWindowTokens = $null
        $note = $null
        if ($usedPercent -gt 0 -and $bucket.Total -gt 0) {
            $tokensPerPercent = [Math]::Round([double]$bucket.Total / $usedPercent, 0)
            $impliedFullWindowTokens = [Math]::Round(([double]$bucket.Total / $usedPercent) * 100.0, 0)
        }
        elseif ($usedPercent -le 0 -and $bucket.Total -gt 0) {
            $note = "Waiting for non-zero used %"
        }

        $rows += [pscustomobject]@{
            Window = $spec.RateRow.Window
            UsedPercent = [Math]::Round($usedPercent, 2)
            TotalTokens = $bucket.Total
            InputTokens = $bucket.Input
            CachedInputTokens = $bucket.CachedInput
            OutputTokens = $bucket.Output
            ReasoningTokens = $bucket.Reasoning
            Events = $bucket.Events
            TokensPerPercent = $tokensPerPercent
            ImpliedFullWindowTokens = $impliedFullWindowTokens
            WindowStart = $spec.WindowStartUtc.ToLocalTime()
            WindowEnd = $spec.WindowEndUtc.ToLocalTime()
            WindowMinutes = $spec.WindowMinutes
            Confidence = $spec.Confidence
            Notes = $note
        }
    }

    return @($rows)
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

function Get-NoCompactionTokenUsageByModelPeriod {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
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

        $cumulativeInput = 0L
        foreach ($usageEvent in (Get-SessionUsageDeltas -Path $file.FullName -Tail 0)) {
            $delta = $usageEvent.Metrics
            $cumulativeInput += [long]$delta.Input

            $eventTime = $usageEvent.Timestamp
            if ($null -eq $eventTime -or $eventTime -lt $oldestStart -or $eventTime -ge $newestEnd) {
                continue
            }

            $currentModel = $usageEvent.Model
            $pricingBand = Get-NoCompactionPricingBand -Model $currentModel -CumulativeInputTokens $cumulativeInput

            foreach ($window in $Windows) {
                if ($eventTime -lt $window.StartUtc -or $eventTime -ge $window.EndUtc) {
                    continue
                }

                $key = "{0}|{1}|{2}" -f $window.Name, $currentModel, $pricingBand
                if (-not $buckets.ContainsKey($key)) {
                    $bucket = New-TokenBucket $window.Group $currentModel $pricingBand
                    $bucket.CostBasisMode = "ApiNoCompactionUsdEstimate"
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
        Set-NoCompactionEstimatedCost $bucket
    }

    return @($buckets.Values | Sort-Object PeriodGroup, PeriodSortOrder, Model, PricingBand)
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

function Get-CachedNoCompactionTokenUsageByModelPeriods {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$Limit,
        [switch]$Force
    )

    $now = Get-Date
    $windows = @(Get-ModelPeriodWindowDefinitions)
    $groups = @($windows | Select-Object -ExpandProperty Group -Unique)
    $dueGroups = @()

    foreach ($group in $groups) {
        $groupWindows = @($windows | Where-Object { $_.Group -eq $group })
        $refreshSeconds = ($groupWindows | Select-Object -First 1).RefreshSeconds
        $cache = $script:NoCompactionCostPeriodCache[$group]
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
        $freshRows = @(Get-NoCompactionTokenUsageByModelPeriod -Root $Root -Archived:$Archived -Limit $Limit -Windows $dueWindows)
        foreach ($group in $dueGroups) {
            $script:NoCompactionCostPeriodCache[$group] = [pscustomobject]@{
                UpdatedAt = $now
                Rows = @($freshRows | Where-Object { $_.PeriodGroup -eq $group })
            }
        }
    }

    $rows = @()
    foreach ($group in $groups) {
        $cache = $script:NoCompactionCostPeriodCache[$group]
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
                CacheWrite = $metrics.CacheWrite
                CacheHitRatioPercent = Get-CacheHitRatioPercent -InputTokens ([long]$metrics.Input) -CachedInputTokens ([long]$metrics.CachedInput)
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
                    ([long]$row.CacheWrite * [double]$pricing.CacheWritePerMillion / 1000000.0) +
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
                CacheWrite = $row.CacheWrite
                CacheHitRatioPercent = Get-CacheHitRatioPercent -InputTokens ([long]$row.Input) -CachedInputTokens ([long]$row.CachedInput)
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
