param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex" }),
    [int]$RefreshSeconds = 3,
    [int]$MaxFiles = 5,
    [int]$TailLines = 500,
    [int]$ConversationLookbackHours = 24,
    [int]$ConversationFallbackLookbackDays = 7,
    [int]$ConversationFallbackMaxFiles = 5,
    [int]$ConversationFallbackTailLines = 500,
    [int]$RollingMaxFiles = 5,
    [int]$RollingTailLines = 0,
    [int]$CostMaxFiles = 5,
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
$script:NoCompactionCostPeriodCache = @{}
$script:UsageDeltasCache = @{}
$script:ConversationLookbackHours = $ConversationLookbackHours
$script:ConversationFallbackLookbackDays = $ConversationFallbackLookbackDays
$script:ConversationFallbackMaxFiles = $ConversationFallbackMaxFiles
$script:ConversationFallbackTailLines = $ConversationFallbackTailLines

$moduleRoot = Join-Path $PSScriptRoot "ps"
$monitorModules = @(
    "CodexMonitor.Core.ps1"
    "CodexMonitor.Windows.ps1"
    "CodexMonitor.Pricing.ps1"
    "CodexMonitor.Sessions.ps1"
    "CodexMonitor.RateLimits.ps1"
    "CodexMonitor.Usage.ps1"
    "CodexMonitor.Snapshot.ps1"
    "CodexMonitor.Console.ps1"
)

foreach ($module in $monitorModules) {
    $modulePath = Join-Path $moduleRoot $module
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Monitor module not found: $modulePath"
    }

    . $modulePath
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
