param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex" }),
    [string]$MonitorScript = (Join-Path $PSScriptRoot "codex_usage_monitor.ps1"),
    [string]$DashboardRoot = "",
    [int]$Port = 8787,
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
    [switch]$IncludeArchived,
    [switch]$NoOpen,
    [switch]$DisableRateLimitHistory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $MonitorScript)) {
    throw "Monitor script not found: $MonitorScript"
}

if ([string]::IsNullOrWhiteSpace($DashboardRoot)) {
    $DashboardRoot = Join-Path $PSScriptRoot "dashboard"
}

if (-not (Test-Path -LiteralPath $DashboardRoot -PathType Container)) {
    throw "Dashboard asset folder not found: $DashboardRoot"
}

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
    -NoOpen:$NoOpen `
    -DisableRateLimitHistory:$DisableRateLimitHistory `
    -LibraryOnly

$dashboardModuleRoot = Join-Path $PSScriptRoot "ps"
$dashboardModules = @(
    "CodexDashboard.Json.ps1"
    "CodexDashboard.Http.ps1"
    "CodexDashboard.Assets.ps1"
)

foreach ($module in $dashboardModules) {
    $modulePath = Join-Path $dashboardModuleRoot $module
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Dashboard module not found: $modulePath"
    }

    . $modulePath
}

$prefix = "http://127.0.0.1:$Port/"
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)

try {
    $listener.Start()
}
catch [System.Net.Sockets.SocketException] {
    $startError = $_
    $requestedPort = $Port
    try {
        $existingApi = Invoke-WebRequest -UseBasicParsing ($prefix + "api/usage") -TimeoutSec 10
        if ($existingApi.Content -like '*/Date(*') {
            $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
            foreach ($connection in $connections) {
                if ($connection.OwningProcess -ne $PID) {
                    Stop-Process -Id $connection.OwningProcess -Force -ErrorAction SilentlyContinue
                }
            }

            Start-Sleep -Milliseconds 500
            $listener.Start()
        }
        else {
            $existing = Invoke-WebRequest -UseBasicParsing $prefix -TimeoutSec 3
            if ($existing.StatusCode -ge 200 -and $existing.StatusCode -lt 500) {
                if (-not $NoOpen) {
                    if (-not (Open-DashboardUrl $prefix)) {
                        Write-Host ("Dashboard is already running at {0}" -f $prefix)
                    }
                }

                Write-Host "Codex usage dashboard is already running at $prefix"
                return
            }
        }
    }
    catch {
    }

    $listener = $null
    foreach ($candidatePort in (($Port + 1)..($Port + 20))) {
        $candidateListener = $null
        try {
            $candidateListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidatePort)
            $candidateListener.Start()
            $listener = $candidateListener
            $Port = $candidatePort
            $prefix = "http://127.0.0.1:$Port/"
            Write-Host ("Port {0} is unavailable; using {1} instead." -f $requestedPort, $prefix)
            break
        }
        catch [System.Net.Sockets.SocketException] {
            if ($null -ne $candidateListener) {
                $candidateListener.Stop()
            }
        }
    }

    if ($null -eq $listener) {
        throw $startError
    }
}

if (-not $NoOpen) {
    if (-not (Open-DashboardUrl $prefix)) {
        Write-Host ("Open this URL in your browser: {0}" -f $prefix)
    }
}

Write-Host "Codex usage dashboard running at $prefix"
Write-Host "Press Ctrl+C to stop."

$shutdownRequested = $false
try {
    while (-not $shutdownRequested) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.SendTimeout = 10000
            $request = Get-TcpHttpRequest $client
            if ($null -eq $request) {
                continue
            }

            $path = $request.Path
            if ($path -eq "/api/usage") {
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
                    Write-TcpHttpResponse $client 404 "application/json; charset=utf-8" (@{ error = "No Codex usage snapshot found." } | ConvertTo-Json)
                }
                else {
                    $json = Convert-SnapshotForJson $snapshot | ConvertTo-Json -Depth 8
                    Write-TcpHttpResponse $client 200 "application/json; charset=utf-8" $json
                }
            }
            elseif ($path -eq "/api/shutdown") {
                if ($request.Method -ne "POST") {
                    Write-TcpHttpResponse $client 405 "application/json; charset=utf-8" (@{ error = "Use POST to stop the dashboard." } | ConvertTo-Json)
                }
                else {
                    $shutdownRequested = $true
                    Write-TcpHttpResponse $client 200 "application/json; charset=utf-8" (@{ status = "stopping" } | ConvertTo-Json)
                    Write-Host "Shutdown requested from dashboard."
                }
            }
            else {
                $asset = Read-DashboardAsset $path
                if ($null -ne $asset) {
                    Write-TcpHttpResponse $client 200 $asset.ContentType $asset.Body
                }
                else {
                    Write-TcpHttpResponse $client 404 "text/plain; charset=utf-8" "Not found"
                }
            }
        }
        catch [System.IO.IOException] {
            if (-not (Test-TcpTimeoutException $_.Exception)) {
                Write-TcpHttpResponse $client 500 "application/json; charset=utf-8" (@{ error = $_.Exception.Message } | ConvertTo-Json)
            }
        }
        catch {
            Write-TcpHttpResponse $client 500 "application/json; charset=utf-8" (@{ error = $_.Exception.Message } | ConvertTo-Json)
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}
