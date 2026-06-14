# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

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
    if ($Snapshot.RateLimitRows.Count -gt 0 -and
        $Snapshot.PSObject.Properties["RateLimitEventTimestamp"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Snapshot.RateLimitEventTimestamp)) {
        Write-Host ("RateLimit : {0}" -f $Snapshot.RateLimitEventTimestamp)
    }
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

        if ($Snapshot.PSObject.Properties["RateLimitTokenUsageRows"] -and $Snapshot.RateLimitTokenUsageRows.Count -gt 0) {
            Write-Host "1% token usage tracker"
            $Snapshot.RateLimitTokenUsageRows |
                Select-Object Window, UsedPercent, TotalTokens, TokensPerPercent, ImpliedFullWindowTokens, Events, WindowStart, WindowEnd, Confidence |
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
            Select-Object Scope, Total, Input, CachedInput, CacheHitRatioPercent, Output, Reasoning |
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
