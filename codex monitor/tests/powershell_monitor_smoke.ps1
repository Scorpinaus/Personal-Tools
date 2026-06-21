param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [int]$DashboardStartupTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Failures = @()

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw ("{0} Expected: {1}; Actual: {2}" -f $Message, $Expected, $Actual)
    }
}

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    Write-Host ("[TEST] {0}" -f $Name)
    try {
        & $Body
        Write-Host ("[PASS] {0}" -f $Name)
    }
    catch {
        $script:Failures += [pscustomobject]@{
            Name = $Name
            Error = $_.Exception.Message
        }
        Write-Host ("[FAIL] {0}: {1}" -f $Name, $_.Exception.Message)
    }
}

function New-Usage {
    param(
        [long]$Total,
        [long]$InputTokens,
        [long]$CachedInput,
        [long]$Output,
        [long]$Reasoning
    )

    [ordered]@{
        total_tokens = $Total
        input_tokens = $InputTokens
        cached_input_tokens = $CachedInput
        output_tokens = $Output
        reasoning_output_tokens = $Reasoning
    }
}

function New-TokenCountEvent {
    param(
        [datetime]$TimestampUtc,
        [object]$TotalUsage,
        [object]$LastUsage,
        [object]$RateLimits
    )

    [ordered]@{
        timestamp = $TimestampUtc.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
        type = "event_msg"
        payload = [ordered]@{
            type = "token_count"
            info = [ordered]@{
                total_token_usage = $TotalUsage
                last_token_usage = $LastUsage
                model_context_window = 400000
            }
            rate_limits = $RateLimits
        }
    } | ConvertTo-Json -Compress -Depth 10
}

function New-TestCodexHome {
    param([string]$Root)

    $codexHome = Join-Path $Root "codex-home"
    $sessions = Join-Path $codexHome "sessions"
    New-Item -ItemType Directory -Force -Path $sessions | Out-Null

    $now = [DateTime]::UtcNow
    $resetPrimary = [DateTimeOffset]::new($now.AddHours(3)).ToUnixTimeSeconds()
    $resetSecondary = [DateTimeOffset]::new($now.AddDays(2)).ToUnixTimeSeconds()
    $rateLimits = [ordered]@{
        plan_type = "pro"
        primary = [ordered]@{
            used_percent = 25.5
            window_minutes = 300
            resets_at = $resetPrimary
        }
        secondary = [ordered]@{
            used_percent = 10
            limit_window_seconds = 604800
            resets_at = $resetSecondary
        }
    }

    $turnContext = @{
        timestamp = $now.AddMinutes(-12).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
        type = "turn_context"
        model = "gpt-5"
    } | ConvertTo-Json -Compress

    $firstUsage = New-TokenCountEvent `
        -TimestampUtc $now.AddMinutes(-10) `
        -TotalUsage (New-Usage -Total 1000 -InputTokens 700 -CachedInput 100 -Output 250 -Reasoning 50) `
        -LastUsage (New-Usage -Total 1000 -InputTokens 700 -CachedInput 100 -Output 250 -Reasoning 50) `
        -RateLimits $rateLimits

    $secondUsage = New-TokenCountEvent `
        -TimestampUtc $now.AddMinutes(-5) `
        -TotalUsage (New-Usage -Total 1500 -InputTokens 1000 -CachedInput 200 -Output 420 -Reasoning 80) `
        -LastUsage (New-Usage -Total 500 -InputTokens 300 -CachedInput 100 -Output 170 -Reasoning 30) `
        -RateLimits $rateLimits

    $lines = @($turnContext, $firstUsage, $secondUsage)

    $sessionFile = Join-Path $sessions "smoke-session.jsonl"
    Set-Content -LiteralPath $sessionFile -Value $lines -Encoding UTF8
    return $codexHome
}

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Wait-ForDashboardUsage {
    param(
        [string]$Url,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-RestMethod -UseBasicParsing -Uri $Url -TimeoutSec 2
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    } while ((Get-Date) -lt $deadline)

    throw "Dashboard did not respond at $Url within $TimeoutSeconds seconds."
}

function Quote-ProcessArgument {
    param([string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

$monitorScript = Join-Path $RepoRoot "codex_usage_monitor.ps1"
$dashboardScript = Join-Path $RepoRoot "codex_usage_dashboard.ps1"
$tempRoot = Join-Path $RepoRoot ".test-tmp\powershell-monitor-smoke"

if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$dashboardProcess = $null

try {
    $codexHome = New-TestCodexHome -Root $tempRoot

    Invoke-Test "library snapshot returns expected monitor data" {
        . $monitorScript `
            -CodexHome $codexHome `
            -LibraryOnly `
            -NoOpen `
            -CostFiveHourRefreshSeconds 1 `
            -CostWeekRefreshSeconds 1 `
            -CostMonthRefreshSeconds 1 `
            -RateLimitHistorySampleSeconds 1

        $snapshot = Get-LatestCodexUsageSnapshot `
            -Root $codexHome `
            -Limit 5 `
            -Tail 500 `
            -ConversationLookbackHours 24 `
            -ConversationFallbackLookbackDays 7 `
            -ConversationFallbackMaxFiles 5 `
            -ConversationFallbackTailLines 500 `
            -ForceCostRefresh

        Assert-True ($null -ne $snapshot) "Expected a usage snapshot."
        Assert-Equal "pro" $snapshot.PlanType "Plan type should come from rate limits."
        Assert-Equal 2 @($snapshot.RateLimitRows).Count "Expected primary and secondary rate-limit rows."
        Assert-Equal 25.5 ([double]$snapshot.RateLimitRows[0].UsedPercent) "Primary rate limit used percent should match fixture."
        Assert-Equal 2 @($snapshot.TokenRows).Count "Expected conversation total and last update rows."
        Assert-Equal 1500 ([long]$snapshot.TokenRows[0].Total) "Conversation total tokens should match fixture."
        Assert-Equal 500 ([long]$snapshot.TokenRows[1].Total) "Last update total tokens should match fixture."
        Assert-True (@($snapshot.RollingTokenRows | Where-Object { $_.Window -eq "Last 5 hours" -and $_.Total -eq 1500 }).Count -eq 1) "Rolling 5 hour bucket should include both fixture events."
        Assert-True (@($snapshot.DailyTokenUsageRows | Where-Object { $_.Total -ge 1500 }).Count -ge 1) "Daily usage should include fixture tokens."
        Assert-True (Test-Path -LiteralPath (Join-Path $codexHome "usage-history\rate_limit_samples.jsonl")) "Snapshot should write rate-limit history."
    }

    Invoke-Test "session file cache reuses listing until reset" {
        $cacheHome = Join-Path $tempRoot "cache-home"
        $cacheSessions = Join-Path $cacheHome "sessions"
        New-Item -ItemType Directory -Force -Path $cacheSessions | Out-Null

        Set-Content -LiteralPath (Join-Path $cacheSessions "first.jsonl") -Value "" -Encoding UTF8

        . $monitorScript `
            -CodexHome $cacheHome `
            -LibraryOnly `
            -NoOpen

        Reset-SessionFilesCache
        $firstListing = @(Get-SessionFiles -Root $cacheHome -Limit 0)
        Assert-Equal 1 $firstListing.Count "Initial session listing should include one file."

        Set-Content -LiteralPath (Join-Path $cacheSessions "second.jsonl") -Value "" -Encoding UTF8

        $cachedListing = @(Get-SessionFiles -Root $cacheHome -Limit 0)
        Assert-Equal 1 $cachedListing.Count "Cached session listing should be reused until reset."

        Reset-SessionFilesCache
        $freshListing = @(Get-SessionFiles -Root $cacheHome -Limit 0)
        Assert-Equal 2 $freshListing.Count "Reset session listing should see new files."
    }

    Invoke-Test "public monitor entrypoint supports once console mode" {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitorScript `
            -CodexHome $codexHome `
            -Once `
            -Console `
            -NoOpen `
            -CostFiveHourRefreshSeconds 1 `
            -CostWeekRefreshSeconds 1 `
            -CostMonthRefreshSeconds 1 `
            -RateLimitHistorySampleSeconds 1 2>&1

        Assert-Equal 0 $LASTEXITCODE "Monitor entrypoint should exit cleanly."
        $text = ($output | Out-String)
        Assert-True ($text -like "*Plan      : pro*") "Console output should include the plan type."
        Assert-True ($text -like "*Rate limits*") "Console output should include rate limits."
        Assert-True ($text -like "*Conversation token usage*") "Console output should include conversation usage."
    }

    Invoke-Test "dashboard server returns usage JSON and shuts down" {
        $port = Get-FreeLoopbackPort
        $usageUrl = "http://127.0.0.1:$port/api/usage"
        $shutdownUrl = "http://127.0.0.1:$port/api/shutdown"

        $dashboardProcess = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", (Quote-ProcessArgument $dashboardScript),
                "-CodexHome", (Quote-ProcessArgument $codexHome),
                "-Port", $port,
                "-NoOpen",
                "-CostFiveHourRefreshSeconds", "1",
                "-CostWeekRefreshSeconds", "1",
                "-CostMonthRefreshSeconds", "1",
                "-RateLimitHistorySampleSeconds", "1"
            ) `
            -PassThru `
            -WindowStyle Hidden

        try {
            $data = Wait-ForDashboardUsage -Url $usageUrl -TimeoutSeconds $DashboardStartupTimeoutSeconds
        }
        catch {
            $exitDetail = if ($dashboardProcess.HasExited) { " Dashboard process exited with code $($dashboardProcess.ExitCode)." } else { "" }
            throw ($_.Exception.Message + $exitDetail)
        }

        Assert-Equal "pro" $data.PlanType "Dashboard API should include the plan type."
        Assert-Equal 2 @($data.RateLimitRows).Count "Dashboard API should include rate-limit rows."
        Assert-True (@($data.TokenRows | Where-Object { $_.Scope -eq "Conversation total" -and $_.Total -eq 1500 }).Count -eq 1) "Dashboard API should include conversation totals."

        $sessionFile = Join-Path $codexHome "sessions\smoke-session.jsonl"
        $newUsage = New-TokenCountEvent `
            -TimestampUtc ([DateTime]::UtcNow.AddMinutes(1)) `
            -TotalUsage (New-Usage -Total 2200 -InputTokens 1500 -CachedInput 300 -Output 600 -Reasoning 100) `
            -LastUsage (New-Usage -Total 700 -InputTokens 500 -CachedInput 100 -Output 180 -Reasoning 20) `
            -RateLimits $null
        Add-Content -LiteralPath $sessionFile -Value $newUsage -Encoding UTF8

        $staleData = Invoke-RestMethod -UseBasicParsing -Uri $usageUrl -TimeoutSec 5
        Assert-True (@($staleData.TokenRows | Where-Object { $_.Scope -eq "Conversation total" -and $_.Total -eq 1500 }).Count -eq 1) "Dashboard API should return cached usage while background refresh starts."

        $freshData = $null
        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $candidate = Invoke-RestMethod -UseBasicParsing -Uri $usageUrl -TimeoutSec 5
            if (@($candidate.TokenRows | Where-Object { $_.Scope -eq "Conversation total" -and $_.Total -eq 2200 }).Count -eq 1) {
                $freshData = $candidate
                break
            }
        } while ((Get-Date) -lt $deadline)

        Assert-True ($null -ne $freshData) "Dashboard API should update cached usage after background refresh."

        $shutdown = Invoke-RestMethod -UseBasicParsing -Method Post -Uri $shutdownUrl -TimeoutSec 5
        Assert-Equal "stopping" $shutdown.status "Dashboard shutdown endpoint should acknowledge shutdown."

        if (-not $dashboardProcess.WaitForExit(5000)) {
            throw "Dashboard process did not exit after shutdown."
        }

        Assert-Equal 0 $dashboardProcess.ExitCode "Dashboard process should exit cleanly after shutdown."
        $script:dashboardProcess = $null
    }
}
finally {
    if ($null -ne $dashboardProcess -and -not $dashboardProcess.HasExited) {
        Stop-Process -Id $dashboardProcess.Id -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures:"
    foreach ($failure in $script:Failures) {
        Write-Host ("- {0}: {1}" -f $failure.Name, $failure.Error)
    }
    exit 1
}

Write-Host ""
Write-Host "All PowerShell monitor smoke tests passed."
