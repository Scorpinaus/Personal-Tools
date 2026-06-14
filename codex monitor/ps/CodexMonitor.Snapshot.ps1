# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

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

    Reset-SessionFilesCache

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
        $noCompactionModelPeriodRows = @(Get-CachedNoCompactionTokenUsageByModelPeriods -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Force:$ForceCostRefresh)
        $modelPeriodWindows = @(Get-ModelPeriodWindowDefinitions)

        $snapshot = [pscustomobject]@{
            Timestamp = Get-PropValue $sourceMatch.Entry @("timestamp")
            SourceFile = $sourceMatch.SourceFile
            Session = $sourceMatch.Session
            RateLimitEventTimestamp = if ($null -ne $rateLimitMatch) { Get-PropValue $rateLimitMatch.Entry @("timestamp") } else { $null }
            RateLimitSourceFile = if ($null -ne $rateLimitMatch) { $rateLimitMatch.SourceFile } else { $null }
            RateLimitSession = if ($null -ne $rateLimitMatch) { $rateLimitMatch.Session } else { $null }
            PlanType = if (Get-PropValue $rateLimits @("plan_type", "planType")) {
                Get-PropValue $rateLimits @("plan_type", "planType")
            }
            else {
                Get-LatestPlanType -Root $Root -Archived:$Archived -Limit $legacyLimit -Tail $legacyTail
            }
            RateLimitRows = @(Convert-RateLimits $rateLimits)
            RateLimitTokenUsageRows = @()
            RollingTokenRows = @(Get-RollingTokenUsage -Root $Root -Archived:$Archived -Limit $RollingMaxFiles -Tail $RollingTailLines)
            DailyTokenUsageRows = @(Get-DailyTokenUsageRows -Root $Root -Archived:$Archived -Limit $CostMaxFiles -Days 365)
            ModelTokenRows = $modelRows
            NoCompactionModelTokenRows = $noCompactionModelRows
            ModelTokenPeriodRows = $modelPeriodRows
            NoCompactionModelTokenPeriodRows = $noCompactionModelPeriodRows
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

        $snapshot.RateLimitTokenUsageRows = @(Get-RateLimitTokenUsageRows -Root $Root -Archived:$Archived -Limit $RollingMaxFiles -RateLimitRows $snapshot.RateLimitRows)

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
