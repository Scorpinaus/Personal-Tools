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

    function Copy-RowWithInputBreakdown {
        param(
            [object[]]$Rows,
            [string]$InputProperty = "Input",
            [string]$CachedInputProperty = "CachedInput",
            [string]$NonCachedInputProperty = "NonCachedInput"
        )

        @(
            foreach ($row in @($Rows)) {
                if ($null -eq $row) {
                    continue
                }

                $copy = [ordered]@{}
                foreach ($prop in $row.PSObject.Properties) {
                    if ($prop.Name -eq $NonCachedInputProperty) {
                        continue
                    }

                    $copy[$prop.Name] = $prop.Value
                    if ($prop.Name -eq $CachedInputProperty -and -not $copy.Contains($NonCachedInputProperty)) {
                        $copy[$NonCachedInputProperty] = [Math]::Max(0L, (Get-LongPropertyValue $row $InputProperty) - (Get-LongPropertyValue $row $CachedInputProperty))
                    }
                }

                if (-not $copy.Contains($NonCachedInputProperty)) {
                    $copy[$NonCachedInputProperty] = [Math]::Max(0L, (Get-LongPropertyValue $row $InputProperty) - (Get-LongPropertyValue $row $CachedInputProperty))
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
        CostBasis = $Snapshot.CostBasis
        CostBasisMode = $Snapshot.CostBasisMode
        PricingMode = $Snapshot.PricingMode
        PricingSource = $Snapshot.PricingSource
        RegionalUpliftApplied = $Snapshot.RegionalUpliftApplied
        RateLimitRows = $rateLimitRows
        RateLimitHistoryRows = $rateLimitHistoryRows
        RateLimitHistorySummaryRows = $rateLimitHistorySummaryRows
        RateLimitHistoryDays = if ($Snapshot.PSObject.Properties["RateLimitHistoryDays"]) { $Snapshot.RateLimitHistoryDays } else { $RateLimitHistoryDays }
        RateLimitHistorySampleSeconds = if ($Snapshot.PSObject.Properties["RateLimitHistorySampleSeconds"]) { $Snapshot.RateLimitHistorySampleSeconds } else { $RateLimitHistorySampleSeconds }
        RollingTokenRows = Copy-RowWithInputBreakdown @($Snapshot.RollingTokenRows)
        ModelTokenRows = Copy-RowWithInputBreakdown @($Snapshot.ModelTokenRows)
        NoCompactionModelTokenRows = Copy-RowWithInputBreakdown @($Snapshot.NoCompactionModelTokenRows)
        ModelTokenPeriodRows = Copy-RowWithInputBreakdown @($Snapshot.ModelTokenPeriodRows)
        ModelTokenPeriodWindows = $Snapshot.ModelTokenPeriodWindows
        SourceCostRows = Copy-RowWithInputBreakdown @($Snapshot.SourceCostRows) "AllocatedInput" "AllocatedCachedInput" "AllocatedNonCachedInput"
        ModelCostTotals = $costTotals
        NoCompactionModelCostTotals = $noCompactionCostTotals
        ModelPeriodCostTotals = @($periodCostTotals | Sort-Object PeriodGroup, PeriodSortOrder)
        TokenRows = Copy-RowWithInputBreakdown @($Snapshot.TokenRows)
        ConversationOverviewRows = $conversationOverviewRows
        ContextWindow = $Snapshot.ContextWindow
        UsdToSgdRate = $UsdToSgdRate
    }
}

$prefix = "http://127.0.0.1:$Port/"

function Open-DashboardUrl {
    param([string]$Url)

    $candidates = @(
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:ProgramFiles "Mozilla Firefox\firefox.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Mozilla Firefox\firefox.exe")
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            Start-Process -FilePath $candidate -ArgumentList @($Url)
            return $true
        }
    }

    foreach ($commandName in @("msedge.exe", "chrome.exe", "firefox.exe")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            Start-Process -FilePath $command.Source -ArgumentList @($Url)
            return $true
        }
    }

    return $false
}

function Write-TcpHttpResponse {
    param(
        [System.Net.Sockets.TcpClient]$Client,
        [int]$StatusCode,
        [string]$ContentType,
        [string]$Body
    )

    $reason = switch ($StatusCode) {
        200 { "OK" }
        404 { "Not Found" }
        405 { "Method Not Allowed" }
        500 { "Internal Server Error" }
        default { "OK" }
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream = $Client.GetStream()
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Flush()
}

function Get-TcpHttpRequest {
    param([System.Net.Sockets.TcpClient]$Client)

    $stream = $Client.GetStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
    $requestLine = $reader.ReadLine()
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line -or $line -eq "") {
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($requestLine)) {
        return [pscustomobject]@{
            Method = "GET"
            Path = "/"
        }
    }

    $parts = $requestLine -split "\s+"
    if ($parts.Count -lt 2) {
        return [pscustomobject]@{
            Method = "GET"
            Path = "/"
        }
    }

    $path = "/"
    try {
        $path = ([System.Uri]::new(("http://localhost" + $parts[1]))).AbsolutePath
    }
    catch {
        $path = "/"
    }

    return [pscustomobject]@{
        Method = $parts[0].ToUpperInvariant()
        Path = $path
    }
}

function Get-DashboardAsset {
    param([string]$Path)

    switch ($Path) {
        "/" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "index.html"
                ContentType = "text/html; charset=utf-8"
            }
        }
        "/index.html" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "index.html"
                ContentType = "text/html; charset=utf-8"
            }
        }
        "/styles.css" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "styles.css"
                ContentType = "text/css; charset=utf-8"
            }
        }
        "/app.js" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "app.js"
                ContentType = "application/javascript; charset=utf-8"
            }
        }
        default {
            return $null
        }
    }
}

function Read-DashboardAsset {
    param([string]$Path)

    $asset = Get-DashboardAsset $Path
    if ($null -eq $asset) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $asset.File -PathType Leaf)) {
        throw "Dashboard asset not found: $($asset.File)"
    }

    return [pscustomobject]@{
        Body = Get-Content -Raw -LiteralPath $asset.File
        ContentType = $asset.ContentType
    }
}

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
            $request = Get-TcpHttpRequest $client
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
