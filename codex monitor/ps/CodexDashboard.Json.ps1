# Dot-sourced by codex_usage_dashboard.ps1. Keep this file free of entry-point side effects.

function Convert-SnapshotForJson {
    param([object]$Snapshot)

    function Format-LocalDateTime {
        param([object]$Value)

        if ($null -eq $Value) {
            return $null
        }

        try {
            return ([datetime]$Value).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            return [string]$Value
        }
    }

    function Format-DisplayDateTime {
        param([object]$Value)

        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
            return $null
        }

        try {
            return ([datetime]$Value).ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            return [string]$Value
        }
    }

    $rateLimitRows = @(
        foreach ($row in $Snapshot.RateLimitRows) {
            [pscustomobject]@{
                Window = $row.Window
                UsedPercent = $row.UsedPercent
                RemainingPercent = $row.RemainingPercent
                WindowMinutes = $row.WindowMinutes
                ResetsAt = Format-DisplayDateTime $row.ResetsAt
            }
        }
    )

    $costTotals = @()
    foreach ($windowName in @("Last 5 hours", "This week", "This month")) {
        $rows = @($Snapshot.ModelTokenRows | Where-Object { $_.Window -eq $windowName })
        $totalUsd = Get-TotalEstimatedCostUsd $rows
        $totalCredits = Get-TotalEstimatedCostCredits $rows
        $costTotals += [pscustomobject]@{
            Window = $windowName
            TotalCostUsd = $totalUsd
            TotalCostSgd = [Math]::Round($totalUsd * $UsdToSgdRate, 4)
            TotalCostCredits = $totalCredits
        }
    }

    $noCompactionCostTotals = @()
    foreach ($windowName in @("Last 5 hours", "This week", "This month")) {
        $rows = @($Snapshot.NoCompactionModelTokenRows | Where-Object { $_.Window -eq $windowName })
        $totalUsd = Get-TotalEstimatedCostUsd $rows
        $noCompactionCostTotals += [pscustomobject]@{
            Window = $windowName
            TotalCostUsd = $totalUsd
            TotalCostSgd = [Math]::Round($totalUsd * $UsdToSgdRate, 4)
            TotalCostCredits = 0.0
        }
    }

    function Get-SumProperty {
        param(
            [object[]]$Rows,
            [string]$Property
        )

        if ($Rows.Count -eq 0) {
            return 0L
        }

        $sum = ($Rows | Measure-Object -Property $Property -Sum).Sum
        if ($null -eq $sum) {
            return 0L
        }

        return [long]$sum
    }

    function Get-LongPropertyValue {
        param(
            [object]$Row,
            [string]$Property
        )

        if ($null -eq $Row) {
            return 0L
        }

        $prop = $Row.PSObject.Properties[$Property]
        if ($null -eq $prop -or $null -eq $prop.Value -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return 0L
        }

        try {
            return [long]$prop.Value
        }
        catch {
            return 0L
        }
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

    function Copy-RowWithInputBreakdown {
        param(
            [object[]]$Rows,
            [string]$InputProperty = "Input",
            [string]$CachedInputProperty = "CachedInput",
            [string]$NonCachedInputProperty = "NonCachedInput",
            [string]$CacheHitRatioProperty = "CacheHitRatioPercent"
        )

        @(
            foreach ($row in @($Rows)) {
                if ($null -eq $row) {
                    continue
                }

                $copy = [ordered]@{}
                foreach ($prop in $row.PSObject.Properties) {
                    if ($prop.Name -eq $NonCachedInputProperty -or $prop.Name -eq $CacheHitRatioProperty) {
                        continue
                    }

                    $copy[$prop.Name] = $prop.Value
                    if ($prop.Name -eq $CachedInputProperty -and -not $copy.Contains($NonCachedInputProperty)) {
                        $inputValue = Get-LongPropertyValue $row $InputProperty
                        $cachedInputValue = Get-LongPropertyValue $row $CachedInputProperty
                        $copy[$NonCachedInputProperty] = [Math]::Max(0L, $inputValue - $cachedInputValue)
                        $copy[$CacheHitRatioProperty] = Get-CacheHitRatioPercent -InputTokens $inputValue -CachedInputTokens $cachedInputValue
                    }
                }

                if (-not $copy.Contains($NonCachedInputProperty)) {
                    $inputValue = Get-LongPropertyValue $row $InputProperty
                    $cachedInputValue = Get-LongPropertyValue $row $CachedInputProperty
                    $copy[$NonCachedInputProperty] = [Math]::Max(0L, $inputValue - $cachedInputValue)
                }

                if (-not $copy.Contains($CacheHitRatioProperty)) {
                    $inputValue = Get-LongPropertyValue $row $InputProperty
                    $cachedInputValue = Get-LongPropertyValue $row $CachedInputProperty
                    $copy[$CacheHitRatioProperty] = Get-CacheHitRatioPercent -InputTokens $inputValue -CachedInputTokens $cachedInputValue
                }

                [pscustomobject]$copy
            }
        )
    }

    function Copy-TurnRowsForJson {
        param([object[]]$Rows)

        @(
            foreach ($row in @(Copy-RowWithInputBreakdown @($Rows))) {
                if ($null -eq $row) {
                    continue
                }

                $copy = [ordered]@{}
                foreach ($prop in $row.PSObject.Properties) {
                    if ($prop.Name -eq "Timestamp") {
                        $copy[$prop.Name] = Format-LocalDateTime $prop.Value
                    }
                    else {
                        $copy[$prop.Name] = $prop.Value
                    }
                }

                if ($copy.Contains("EstimatedCostUsd") -and $null -ne $copy["EstimatedCostUsd"]) {
                    $copy["EstimatedCostSgd"] = [Math]::Round([double]$copy["EstimatedCostUsd"] * $UsdToSgdRate, 4)
                }
                else {
                    $copy["EstimatedCostSgd"] = $null
                }

                [pscustomobject]$copy
            }
        )
    }

    $periodCostTotals = @()
    foreach ($periodWindow in $Snapshot.ModelTokenPeriodWindows) {
        $rows = @($Snapshot.ModelTokenPeriodRows | Where-Object { $_.PeriodGroup -eq $periodWindow.Group -and $_.PeriodName -eq $periodWindow.Name })
        $totalUsd = Get-TotalEstimatedCostUsd $rows
        $totalCredits = Get-TotalEstimatedCostCredits $rows
        $totalInput = Get-SumProperty $rows "Input"
        $totalCachedInput = Get-SumProperty $rows "CachedInput"
        $periodCostTotals += [pscustomobject]@{
            PeriodGroup = $periodWindow.Group
            PeriodName = $periodWindow.Name
            PeriodLabel = $periodWindow.Label
            PeriodSortOrder = $periodWindow.SortOrder
            Total = Get-SumProperty $rows "Total"
            Input = $totalInput
            CachedInput = $totalCachedInput
            NonCachedInput = [Math]::Max(0L, $totalInput - $totalCachedInput)
            Output = Get-SumProperty $rows "Output"
            Reasoning = Get-SumProperty $rows "Reasoning"
            Events = Get-SumProperty $rows "Events"
            TotalCostUsd = $totalUsd
            TotalCostSgd = [Math]::Round($totalUsd * $UsdToSgdRate, 4)
            TotalCostCredits = $totalCredits
        }
    }

    $noCompactionPeriodCostTotals = @()
    foreach ($periodWindow in $Snapshot.ModelTokenPeriodWindows) {
        $rows = @($Snapshot.NoCompactionModelTokenPeriodRows | Where-Object { $_.PeriodGroup -eq $periodWindow.Group -and $_.PeriodName -eq $periodWindow.Name })
        $totalUsd = Get-TotalEstimatedCostUsd $rows
        $totalInput = Get-SumProperty $rows "Input"
        $totalCachedInput = Get-SumProperty $rows "CachedInput"
        $noCompactionPeriodCostTotals += [pscustomobject]@{
            PeriodGroup = $periodWindow.Group
            PeriodName = $periodWindow.Name
            PeriodLabel = $periodWindow.Label
            PeriodSortOrder = $periodWindow.SortOrder
            Total = Get-SumProperty $rows "Total"
            Input = $totalInput
            CachedInput = $totalCachedInput
            NonCachedInput = [Math]::Max(0L, $totalInput - $totalCachedInput)
            Output = Get-SumProperty $rows "Output"
            Reasoning = Get-SumProperty $rows "Reasoning"
            Events = Get-SumProperty $rows "Events"
            TotalCostUsd = $totalUsd
            TotalCostSgd = [Math]::Round($totalUsd * $UsdToSgdRate, 4)
            TotalCostCredits = 0.0
        }
    }

    $rateLimitHistoryRows = @(
        if ($Snapshot.PSObject.Properties["RateLimitHistoryRows"]) {
            $seenRateLimitSamples = @{}
            foreach ($row in $Snapshot.RateLimitHistoryRows) {
                $sampledAt = Format-LocalDateTime $row.SampledAt
                $resetsAt = Format-DisplayDateTime $row.ResetsAt
                $dedupeKey = @(
                    $sampledAt
                    $row.Window
                    [Math]::Round([double]$row.UsedPercent, 2)
                    [Math]::Round([double]$row.RemainingPercent, 2)
                    $resetsAt
                ) -join "|"

                if ($seenRateLimitSamples.ContainsKey($dedupeKey)) {
                    continue
                }

                $seenRateLimitSamples[$dedupeKey] = $true
                [pscustomobject]@{
                    SampledAt = $sampledAt
                    EventTimestamp = $row.EventTimestamp
                    PlanType = $row.PlanType
                    Window = $row.Window
                    UsedPercent = $row.UsedPercent
                    RemainingPercent = $row.RemainingPercent
                    WindowMinutes = $row.WindowMinutes
                    ResetsAt = $resetsAt
                    Session = $row.Session
                    SourceFile = $row.SourceFile
                }
            }
        }
    )

    $rateLimitHistorySummaryRows = @(
        foreach ($window in @("5 hour", "1 week")) {
            $windowRows = @($rateLimitHistoryRows | Where-Object { $_.Window -eq $window } | Sort-Object SampledAt)
            if ($windowRows.Count -eq 0) {
                continue
            }

            $latest = $windowRows[-1]
            $peak = ($windowRows | Measure-Object -Property UsedPercent -Maximum).Maximum
            $average = ($windowRows | Measure-Object -Property UsedPercent -Average).Average
            $resetCount = @($windowRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ResetsAt) } | Select-Object -ExpandProperty ResetsAt -Unique).Count

            [pscustomobject]@{
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
    )

    $rateLimitTokenUsageRows = @(
        if ($Snapshot.PSObject.Properties["RateLimitTokenUsageRows"]) {
            foreach ($row in $Snapshot.RateLimitTokenUsageRows) {
                [pscustomobject]@{
                    Window = $row.Window
                    UsedPercent = $row.UsedPercent
                    TotalTokens = $row.TotalTokens
                    InputTokens = $row.InputTokens
                    CachedInputTokens = $row.CachedInputTokens
                    OutputTokens = $row.OutputTokens
                    ReasoningTokens = $row.ReasoningTokens
                    Events = $row.Events
                    TokensPerPercent = $row.TokensPerPercent
                    ImpliedFullWindowTokens = $row.ImpliedFullWindowTokens
                    WindowStart = Format-DisplayDateTime $row.WindowStart
                    WindowEnd = Format-DisplayDateTime $row.WindowEnd
                    WindowMinutes = $row.WindowMinutes
                    Confidence = $row.Confidence
                    Notes = $row.Notes
                }
            }
        }
    )

    $conversationOverviewRows = @(
        if ($Snapshot.PSObject.Properties["ConversationOverviewRows"]) {
            foreach ($row in $Snapshot.ConversationOverviewRows) {
                $conversationCostTotals = $row.CostTotals
                $conversationTotalCostUsd = if ($null -ne $conversationCostTotals -and $null -ne $conversationCostTotals.TotalCostUsd) { [double]$conversationCostTotals.TotalCostUsd } else { 0.0 }
                $noCompactionCostTotalsForConversation = $row.NoCompactionCostTotals
                $noCompactionTotalCostUsd = if ($null -ne $noCompactionCostTotalsForConversation -and $null -ne $noCompactionCostTotalsForConversation.TotalCostUsd) { [double]$noCompactionCostTotalsForConversation.TotalCostUsd } else { 0.0 }
                [pscustomobject]@{
                    Session = $row.Session
                    LastModified = Format-DisplayDateTime $row.LastModified
                    SourceFile = $row.SourceFile
                    TokenRows = Copy-RowWithInputBreakdown @($row.TokenRows)
                    TurnTokenRows = Copy-TurnRowsForJson @($row.TurnTokenRows)
                    CostTotals = [pscustomobject]@{
                        TotalCostUsd = $conversationTotalCostUsd
                        TotalCostSgd = [Math]::Round($conversationTotalCostUsd * $UsdToSgdRate, 4)
                        TotalCostCredits = if ($null -ne $conversationCostTotals -and $null -ne $conversationCostTotals.TotalCostCredits) { $conversationCostTotals.TotalCostCredits } else { 0.0 }
                    }
                    NoCompactionTurnRows = Copy-TurnRowsForJson @($row.NoCompactionTurnRows)
                    NoCompactionCostTotals = [pscustomobject]@{
                        TotalCostUsd = $noCompactionTotalCostUsd
                        TotalCostSgd = [Math]::Round($noCompactionTotalCostUsd * $UsdToSgdRate, 4)
                        TotalCostCredits = 0.0
                    }
                    ContextWindow = $row.ContextWindow
                    LatestUsageTimestamp = Format-LocalDateTime $row.LatestUsageTimestamp
                }
            }
        }
    )

    [pscustomobject]@{
        UpdatedAtLocal = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        EventTimestamp = $Snapshot.Timestamp
        PlanType = $Snapshot.PlanType
        Session = $Snapshot.Session
        SourceFile = $Snapshot.SourceFile
        RateLimitEventTimestamp = if ($Snapshot.PSObject.Properties["RateLimitEventTimestamp"]) { $Snapshot.RateLimitEventTimestamp } else { $null }
        RateLimitSession = if ($Snapshot.PSObject.Properties["RateLimitSession"]) { $Snapshot.RateLimitSession } else { $null }
        RateLimitSourceFile = if ($Snapshot.PSObject.Properties["RateLimitSourceFile"]) { $Snapshot.RateLimitSourceFile } else { $null }
        CostBasis = $Snapshot.CostBasis
        CostBasisMode = $Snapshot.CostBasisMode
        PricingMode = $Snapshot.PricingMode
        PricingSource = $Snapshot.PricingSource
        RegionalUpliftApplied = $Snapshot.RegionalUpliftApplied
        RateLimitRows = $rateLimitRows
        RateLimitHistoryRows = $rateLimitHistoryRows
        RateLimitHistorySummaryRows = $rateLimitHistorySummaryRows
        RateLimitTokenUsageRows = $rateLimitTokenUsageRows
        RateLimitHistoryDays = if ($Snapshot.PSObject.Properties["RateLimitHistoryDays"]) { $Snapshot.RateLimitHistoryDays } else { $RateLimitHistoryDays }
        RateLimitHistorySampleSeconds = if ($Snapshot.PSObject.Properties["RateLimitHistorySampleSeconds"]) { $Snapshot.RateLimitHistorySampleSeconds } else { $RateLimitHistorySampleSeconds }
        RollingTokenRows = Copy-RowWithInputBreakdown @($Snapshot.RollingTokenRows)
        DailyTokenUsageRows = Copy-RowWithInputBreakdown @($Snapshot.DailyTokenUsageRows)
        ModelTokenRows = Copy-RowWithInputBreakdown @($Snapshot.ModelTokenRows)
        NoCompactionModelTokenRows = Copy-RowWithInputBreakdown @($Snapshot.NoCompactionModelTokenRows)
        ModelTokenPeriodRows = Copy-RowWithInputBreakdown @($Snapshot.ModelTokenPeriodRows)
        NoCompactionModelTokenPeriodRows = Copy-RowWithInputBreakdown @($Snapshot.NoCompactionModelTokenPeriodRows)
        ModelTokenPeriodWindows = $Snapshot.ModelTokenPeriodWindows
        SourceCostRows = Copy-RowWithInputBreakdown @($Snapshot.SourceCostRows) "AllocatedInput" "AllocatedCachedInput" "AllocatedNonCachedInput"
        ModelCostTotals = $costTotals
        NoCompactionModelCostTotals = $noCompactionCostTotals
        ModelPeriodCostTotals = @($periodCostTotals | Sort-Object PeriodGroup, PeriodSortOrder)
        NoCompactionModelPeriodCostTotals = @($noCompactionPeriodCostTotals | Sort-Object PeriodGroup, PeriodSortOrder)
        TokenRows = Copy-RowWithInputBreakdown @($Snapshot.TokenRows)
        ConversationOverviewRows = $conversationOverviewRows
        ContextWindow = $Snapshot.ContextWindow
        UsdToSgdRate = $UsdToSgdRate
    }
}
