# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

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

function New-PeriodWindow {
    param(
        [string]$Group,
        [string]$Name,
        [string]$Label,
        [datetime]$StartUtc,
        [datetime]$EndUtc,
        [int]$SortOrder,
        [int]$RefreshSeconds
    )

    [pscustomobject]@{
        Group = $Group
        Name = $Name
        Label = $Label
        StartUtc = $StartUtc
        EndUtc = $EndUtc
        SortOrder = $SortOrder
        RefreshSeconds = $RefreshSeconds
    }
}

function Format-PeriodRangeLabel {
    param(
        [datetime]$StartLocal,
        [datetime]$EndLocal,
        [switch]$IncludeTime
    )

    if ($IncludeTime) {
        return ("{0:MMM d HH:mm}-{1:HH:mm}" -f $StartLocal, $EndLocal)
    }

    $inclusiveEnd = $EndLocal.AddSeconds(-1)
    if ($StartLocal.Date -eq $inclusiveEnd.Date) {
        return ("{0:MMM d}" -f $StartLocal)
    }

    return ("{0:MMM d}-{1:MMM d}" -f $StartLocal, $inclusiveEnd)
}

function Get-ModelPeriodWindowDefinitions {
    $nowLocal = Get-Date
    $windows = @()

    for ($index = 0; $index -lt 5; $index++) {
        $endLocal = $nowLocal.AddHours(-5 * $index)
        $startLocal = $endLocal.AddHours(-5)
        $label = if ($index -eq 0) {
            "Last 5h"
        }
        else {
            "{0}-{1}h ago" -f (5 * $index), (5 * ($index + 1))
        }

        $windows += New-PeriodWindow `
            -Group "Last 5 hours" `
            -Name ("5h-{0}" -f $index) `
            -Label $label `
            -StartUtc $startLocal.ToUniversalTime() `
            -EndUtc $endLocal.ToUniversalTime() `
            -SortOrder $index `
            -RefreshSeconds $CostFiveHourRefreshSeconds
    }

    $todayLocal = $nowLocal.Date
    for ($index = 0; $index -lt 7; $index++) {
        $startLocal = $todayLocal.AddDays(-1 * $index)
        $endLocal = $startLocal.AddDays(1)
        $label = if ($index -eq 0) {
            "Today"
        }
        elseif ($index -eq 1) {
            "Yesterday"
        }
        else {
            "{0:MMM d}" -f $startLocal
        }

        $windows += New-PeriodWindow `
            -Group "This week" `
            -Name ("day-{0}" -f $index) `
            -Label $label `
            -StartUtc $startLocal.ToUniversalTime() `
            -EndUtc $endLocal.ToUniversalTime() `
            -SortOrder $index `
            -RefreshSeconds $CostWeekRefreshSeconds
    }

    for ($index = 0; $index -lt 4; $index++) {
        $endLocal = $nowLocal.Date.AddDays(1).AddDays(-7 * $index)
        $startLocal = $endLocal.AddDays(-7)
        $windows += New-PeriodWindow `
            -Group "This month" `
            -Name ("week-{0}" -f $index) `
            -Label (Format-PeriodRangeLabel -StartLocal $startLocal -EndLocal $endLocal) `
            -StartUtc $startLocal.ToUniversalTime() `
            -EndUtc $endLocal.ToUniversalTime() `
            -SortOrder $index `
            -RefreshSeconds $CostMonthRefreshSeconds
    }

    return @($windows)
}
