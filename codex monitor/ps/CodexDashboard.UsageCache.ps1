# Dot-sourced by codex_usage_dashboard.ps1. Keep this file free of entry-point side effects.

$script:UsageState = [hashtable]::Synchronized(@{
    CachedResult = $null
    RefreshInProgress = $false
    RefreshStartedAtUtc = $null
    RefreshCompletedAtUtc = $null
    LastError = $null
})
$script:UsageRefreshRunspace = $null
$script:UsageRefreshPowerShell = $null
$script:UsageRefreshHandle = $null

function Invoke-WithUsageStateLock {
    param([scriptblock]$Body)

    $lockTaken = $false
    try {
        [System.Threading.Monitor]::Enter($script:UsageState.SyncRoot, [ref]$lockTaken)
        & $Body
    }
    finally {
        if ($lockTaken) {
            [System.Threading.Monitor]::Exit($script:UsageState.SyncRoot)
        }
    }
}

function New-UsageJsonResult {
    try {
        $snapshot = Get-LatestCodexUsageSnapshot `
            -Root $CodexHome `
            -Archived:$IncludeArchived `
            -Limit $MaxFiles `
            -Tail $TailLines `
            -ConversationLookbackHours $ConversationLookbackHours `
            -ConversationFallbackLookbackDays $ConversationFallbackLookbackDays `
            -ConversationFallbackMaxFiles $ConversationFallbackMaxFiles `
            -ConversationFallbackTailLines $ConversationFallbackTailLines

        if ($null -eq $snapshot) {
            return [pscustomobject]@{
                StatusCode = 404
                ContentType = "application/json; charset=utf-8"
                Body = (@{ error = "No Codex usage snapshot found." } | ConvertTo-Json)
                CachedAtUtc = $null
            }
        }

        return [pscustomobject]@{
            StatusCode = 200
            ContentType = "application/json; charset=utf-8"
            Body = (Convert-SnapshotForJson $snapshot | ConvertTo-Json -Depth 8)
            CachedAtUtc = [DateTime]::UtcNow
        }
    }
    catch {
        return [pscustomobject]@{
            StatusCode = 500
            ContentType = "application/json; charset=utf-8"
            Body = (@{ error = $_.Exception.Message } | ConvertTo-Json)
            CachedAtUtc = $null
        }
    }
}

function Get-UsageCachedResult {
    Invoke-WithUsageStateLock {
        return $script:UsageState.CachedResult
    }
}

function Set-UsageCachedResult {
    param([object]$Result)

    if ($null -eq $Result -or $Result.StatusCode -ne 200) {
        return
    }

    Invoke-WithUsageStateLock {
        $script:UsageState.CachedResult = $Result
        $script:UsageState.RefreshCompletedAtUtc = $Result.CachedAtUtc
        $script:UsageState.LastError = $null
    }
}

function Set-UsageRefreshState {
    param(
        [bool]$InProgress,
        [string]$ErrorMessage = $null
    )

    Invoke-WithUsageStateLock {
        $script:UsageState.RefreshInProgress = $InProgress
        if ($InProgress) {
            $script:UsageState.RefreshStartedAtUtc = [DateTime]::UtcNow
        }
        else {
            $script:UsageState.RefreshCompletedAtUtc = [DateTime]::UtcNow
        }

        $script:UsageState.LastError = $ErrorMessage
    }
}

function Initialize-UsageRefreshRunspace {
    if ($null -ne $script:UsageRefreshRunspace) {
        return
    }

    $script:UsageRefreshRunspace = [runspacefactory]::CreateRunspace()
    $script:UsageRefreshRunspace.Open()

    $jsonModulePath = Join-Path $dashboardModuleRoot "CodexDashboard.Json.ps1"
    $initScript = {
        param(
            [string]$MonitorScript,
            [string]$CodexHome,
            [int]$MaxFiles,
            [int]$TailLines,
            [int]$ConversationLookbackHours,
            [int]$ConversationFallbackLookbackDays,
            [int]$ConversationFallbackMaxFiles,
            [int]$ConversationFallbackTailLines,
            [int]$RollingMaxFiles,
            [int]$RollingTailLines,
            [int]$CostMaxFiles,
            [int]$CostTailLines,
            [int]$CostFiveHourRefreshSeconds,
            [int]$CostWeekRefreshSeconds,
            [int]$CostMonthRefreshSeconds,
            [int]$RateLimitHistoryDays,
            [int]$RateLimitHistorySampleSeconds,
            [double]$UsdToSgdRate,
            [string]$CostBasisMode,
            [string]$PricingMode,
            [bool]$IncludeArchived,
            [bool]$DisableRateLimitHistory,
            [string]$JsonModulePath
        )

        . $MonitorScript `
            -CodexHome $CodexHome `
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
            -NoOpen `
            -DisableRateLimitHistory:$DisableRateLimitHistory `
            -LibraryOnly

        . $JsonModulePath
    }

    $initPowerShell = [powershell]::Create()
    try {
        $initPowerShell.Runspace = $script:UsageRefreshRunspace
        [void]$initPowerShell.AddScript($initScript.ToString()).
            AddArgument($MonitorScript).
            AddArgument($CodexHome).
            AddArgument($MaxFiles).
            AddArgument($TailLines).
            AddArgument($ConversationLookbackHours).
            AddArgument($ConversationFallbackLookbackDays).
            AddArgument($ConversationFallbackMaxFiles).
            AddArgument($ConversationFallbackTailLines).
            AddArgument($RollingMaxFiles).
            AddArgument($RollingTailLines).
            AddArgument($CostMaxFiles).
            AddArgument($CostTailLines).
            AddArgument($CostFiveHourRefreshSeconds).
            AddArgument($CostWeekRefreshSeconds).
            AddArgument($CostMonthRefreshSeconds).
            AddArgument($RateLimitHistoryDays).
            AddArgument($RateLimitHistorySampleSeconds).
            AddArgument($UsdToSgdRate).
            AddArgument($CostBasisMode).
            AddArgument($PricingMode).
            AddArgument([bool]$IncludeArchived).
            AddArgument([bool]$DisableRateLimitHistory).
            AddArgument($jsonModulePath)
        [void]$initPowerShell.Invoke()
        if ($initPowerShell.Streams.Error.Count -gt 0) {
            throw ($initPowerShell.Streams.Error[0].Exception.Message)
        }
    }
    catch {
        $script:UsageRefreshRunspace.Dispose()
        $script:UsageRefreshRunspace = $null
        throw
    }
    finally {
        $initPowerShell.Dispose()
    }
}

function Clear-CompletedUsageRefresh {
    if ($null -eq $script:UsageRefreshHandle -or -not $script:UsageRefreshHandle.IsCompleted) {
        return
    }

    try {
        [void]$script:UsageRefreshPowerShell.EndInvoke($script:UsageRefreshHandle)
        if ($script:UsageRefreshPowerShell.Streams.Error.Count -gt 0) {
            Set-UsageRefreshState -InProgress $false -ErrorMessage $script:UsageRefreshPowerShell.Streams.Error[0].Exception.Message
        }
    }
    catch {
        Set-UsageRefreshState -InProgress $false -ErrorMessage $_.Exception.Message
    }
    finally {
        $script:UsageRefreshPowerShell.Dispose()
        $script:UsageRefreshPowerShell = $null
        $script:UsageRefreshHandle = $null
    }
}

function Start-UsageCacheRefresh {
    Clear-CompletedUsageRefresh
    if ($null -ne $script:UsageRefreshHandle) {
        return
    }

    $started = Invoke-WithUsageStateLock {
        if ($script:UsageState.RefreshInProgress) {
            return $false
        }

        $script:UsageState.RefreshInProgress = $true
        $script:UsageState.RefreshStartedAtUtc = [DateTime]::UtcNow
        $script:UsageState.LastError = $null
        return $true
    }

    if (-not $started) {
        return
    }

    try {
        Initialize-UsageRefreshRunspace

        $refreshScript = {
            param([hashtable]$State)

            function Set-SharedUsageState {
                param(
                    [object]$Result,
                    [string]$ErrorMessage,
                    [bool]$ReplaceCache
                )

                $lockTaken = $false
                try {
                    [System.Threading.Monitor]::Enter($State.SyncRoot, [ref]$lockTaken)
                    if ($ReplaceCache -and $null -ne $Result) {
                        $State.CachedResult = $Result
                        $State.LastError = $null
                    }
                    else {
                        $State.LastError = $ErrorMessage
                    }

                    $State.RefreshInProgress = $false
                    $State.RefreshCompletedAtUtc = [DateTime]::UtcNow
                }
                finally {
                    if ($lockTaken) {
                        [System.Threading.Monitor]::Exit($State.SyncRoot)
                    }
                }
            }

            try {
                $snapshot = Get-LatestCodexUsageSnapshot `
                    -Root $CodexHome `
                    -Archived:$IncludeArchived `
                    -Limit $MaxFiles `
                    -Tail $TailLines `
                    -ConversationLookbackHours $ConversationLookbackHours `
                    -ConversationFallbackLookbackDays $ConversationFallbackLookbackDays `
                    -ConversationFallbackMaxFiles $ConversationFallbackMaxFiles `
                    -ConversationFallbackTailLines $ConversationFallbackTailLines

                if ($null -eq $snapshot) {
                    Set-SharedUsageState -Result $null -ErrorMessage "No Codex usage snapshot found." -ReplaceCache $false
                    return
                }

                $result = [pscustomobject]@{
                    StatusCode = 200
                    ContentType = "application/json; charset=utf-8"
                    Body = (Convert-SnapshotForJson $snapshot | ConvertTo-Json -Depth 8)
                    CachedAtUtc = [DateTime]::UtcNow
                }
                Set-SharedUsageState -Result $result -ErrorMessage $null -ReplaceCache $true
            }
            catch {
                Set-SharedUsageState -Result $null -ErrorMessage $_.Exception.Message -ReplaceCache $false
            }
        }

        $script:UsageRefreshPowerShell = [powershell]::Create()
        $script:UsageRefreshPowerShell.Runspace = $script:UsageRefreshRunspace
        [void]$script:UsageRefreshPowerShell.AddScript($refreshScript.ToString()).AddArgument($script:UsageState)
        $script:UsageRefreshHandle = $script:UsageRefreshPowerShell.BeginInvoke()
    }
    catch {
        if ($null -ne $script:UsageRefreshPowerShell) {
            $script:UsageRefreshPowerShell.Dispose()
            $script:UsageRefreshPowerShell = $null
        }
        $script:UsageRefreshHandle = $null
        Set-UsageRefreshState -InProgress $false -ErrorMessage $_.Exception.Message
        Write-Warning ("Unable to start background usage refresh: {0}" -f $_.Exception.Message)
    }
}

function Stop-UsageRefreshRunspace {
    if ($null -ne $script:UsageRefreshPowerShell) {
        try {
            $script:UsageRefreshPowerShell.Stop()
        }
        catch {
        }
        finally {
            $script:UsageRefreshPowerShell.Dispose()
            $script:UsageRefreshPowerShell = $null
            $script:UsageRefreshHandle = $null
        }
    }

    if ($null -ne $script:UsageRefreshRunspace) {
        $script:UsageRefreshRunspace.Dispose()
        $script:UsageRefreshRunspace = $null
    }
}
