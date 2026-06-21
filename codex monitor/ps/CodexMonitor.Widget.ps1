# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

function Format-WidgetPercent {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "--"
    }

    try {
        return ("{0:N2}%" -f [double]$Value)
    }
    catch {
        return "--"
    }
}

function Format-WidgetResetTime {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "unknown"
    }

    try {
        return ([datetime]$Value).ToString("MMM d HH:mm")
    }
    catch {
        return [string]$Value
    }
}

function Format-WidgetUpdatedTime {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return "Updated: no rate-limit event yet"
    }

    try {
        return "Updated: " + ([datetime]$Value).ToString("MMM d HH:mm:ss")
    }
    catch {
        return "Updated: " + [string]$Value
    }
}

function Compress-WidgetText {
    param(
        [string]$Value,
        [int]$MaxLength = 32
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -le $MaxLength) {
        return $Value
    }

    if ($MaxLength -lt 8) {
        return $Value.Substring(0, $MaxLength)
    }

    $side = [Math]::Max(2, [int][Math]::Floor(($MaxLength - 3) / 2))
    return $Value.Substring(0, $side) + "..." + $Value.Substring($Value.Length - $side)
}

function Get-WidgetSampleSource {
    param([object]$Snapshot)

    if ($null -eq $Snapshot) {
        return [pscustomobject]@{
            Text = "Source: unknown"
            ToolTip = $null
        }
    }

    $sourceFile = if ($Snapshot.PSObject.Properties["RateLimitSourceFile"] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.RateLimitSourceFile)) {
        [string]$Snapshot.RateLimitSourceFile
    }
    elseif ($Snapshot.PSObject.Properties["SourceFile"] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.SourceFile)) {
        [string]$Snapshot.SourceFile
    }
    else {
        $null
    }

    $session = if ($Snapshot.PSObject.Properties["RateLimitSession"] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.RateLimitSession)) {
        [string]$Snapshot.RateLimitSession
    }
    elseif ($Snapshot.PSObject.Properties["Session"] -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.Session)) {
        [string]$Snapshot.Session
    }
    else {
        $null
    }

    $sourceName = if (-not [string]::IsNullOrWhiteSpace($session)) {
        "session " + (Compress-WidgetText -Value $session -MaxLength 28)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($sourceFile)) {
        "file " + (Compress-WidgetText -Value (Split-Path -Leaf $sourceFile) -MaxLength 28)
    }
    else {
        "unknown"
    }

    return [pscustomobject]@{
        Text = "Source: " + $sourceName
        ToolTip = $sourceFile
    }
}

function Get-WidgetRateLimitRow {
    param(
        [object[]]$Rows,
        [string]$Window
    )

    foreach ($row in @($Rows)) {
        if ($null -ne $row -and [string]$row.Window -eq $Window) {
            return $row
        }
    }

    return $null
}

function Set-WidgetWindowRow {
    param(
        [hashtable]$Controls,
        [object]$Row
    )

    if ($null -eq $Row) {
        $Controls.Remaining.Text = "--"
        $Controls.Used.Text = "Used --"
        $Controls.Reset.Text = "Resets unknown"
        $Controls.Progress.Value = 0
        return
    }

    $used = 0.0
    if ($null -ne $Row.UsedPercent) {
        try {
            $used = [Math]::Max(0.0, [Math]::Min(100.0, [double]$Row.UsedPercent))
        }
        catch {
            $used = 0.0
        }
    }

    $Controls.Remaining.Text = Format-WidgetPercent $Row.RemainingPercent
    $Controls.Used.Text = "Used " + (Format-WidgetPercent $Row.UsedPercent)
    $Controls.Reset.Text = "Resets " + (Format-WidgetResetTime $Row.ResetsAt)
    $Controls.Progress.Value = [int][Math]::Round($used)
}

function New-WidgetLimitPanel {
    param(
        [string]$Window,
        [int]$Top,
        [System.Drawing.Font]$TitleFont,
        [System.Drawing.Font]$ValueFont,
        [System.Drawing.Color]$Accent,
        [System.Drawing.Color]$Muted,
        [System.Drawing.Color]$PanelBack
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Left = 12
    $panel.Top = $Top
    $panel.Width = 320
    $panel.Height = 76
    $panel.BackColor = $PanelBack

    $name = New-Object System.Windows.Forms.Label
    $name.Text = $Window.ToUpperInvariant()
    $name.Left = 10
    $name.Top = 8
    $name.Width = 88
    $name.Height = 18
    $name.Font = $TitleFont

    $remaining = New-Object System.Windows.Forms.Label
    $remaining.Text = "--"
    $remaining.Left = 10
    $remaining.Top = 28
    $remaining.Width = 118
    $remaining.Height = 30
    $remaining.Font = $ValueFont
    $remaining.ForeColor = $Accent

    $remainingCaption = New-Object System.Windows.Forms.Label
    $remainingCaption.Text = "remaining"
    $remainingCaption.Left = 132
    $remainingCaption.Top = 37
    $remainingCaption.Width = 72
    $remainingCaption.Height = 18
    $remainingCaption.ForeColor = $Muted

    $used = New-Object System.Windows.Forms.Label
    $used.Text = "Used --"
    $used.Left = 226
    $used.Top = 10
    $used.Width = 84
    $used.Height = 18
    $used.TextAlign = [System.Drawing.ContentAlignment]::TopRight
    $used.ForeColor = $Muted

    $reset = New-Object System.Windows.Forms.Label
    $reset.Text = "Resets unknown"
    $reset.Left = 226
    $reset.Top = 30
    $reset.Width = 84
    $reset.Height = 32
    $reset.TextAlign = [System.Drawing.ContentAlignment]::TopRight
    $reset.ForeColor = $Muted

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Left = 10
    $progress.Top = 62
    $progress.Width = 300
    $progress.Height = 6
    $progress.Minimum = 0
    $progress.Maximum = 100
    $progress.Value = 0
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous

    $panel.Controls.AddRange(@($name, $remaining, $remainingCaption, $used, $reset, $progress))

    return @{
        Panel = $panel
        Remaining = $remaining
        Used = $used
        Reset = $reset
        Progress = $progress
    }
}

function Start-CodexUsageWidget {
    param(
        [string]$Root,
        [switch]$Archived,
        [int]$MaxFiles,
        [int]$TailLines,
        [int]$ConversationLookbackHours,
        [int]$ConversationFallbackLookbackDays,
        [int]$ConversationFallbackMaxFiles,
        [int]$ConversationFallbackTailLines,
        [int]$RefreshSeconds = 30
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $accent = [System.Drawing.ColorTranslator]::FromHtml("#0f766e")
    $muted = [System.Drawing.ColorTranslator]::FromHtml("#666b72")
    $panelBack = [System.Drawing.ColorTranslator]::FromHtml("#fbfaf8")
    $formBack = [System.Drawing.ColorTranslator]::FromHtml("#f7f7f4")

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Codex Limits"
    $form.Width = 360
    $form.Height = 282
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.BackColor = $formBack
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(
        [Math]::Max($screen.Left, $screen.Right - $form.Width - 18),
        [Math]::Max($screen.Top, $screen.Bottom - $form.Height - 18)
    )

    $titleFont = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $valueFont = New-Object System.Drawing.Font("Segoe UI", 19.0, [System.Drawing.FontStyle]::Bold)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Current Codex Limits"
    $title.Left = 12
    $title.Top = 10
    $title.Width = 210
    $title.Height = 22
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $updatedStatus = New-Object System.Windows.Forms.Label
    $updatedStatus.Text = "Updated: loading"
    $updatedStatus.Left = 12
    $updatedStatus.Top = 200
    $updatedStatus.Width = 320
    $updatedStatus.Height = 18
    $updatedStatus.ForeColor = $muted

    $sourceStatus = New-Object System.Windows.Forms.Label
    $sourceStatus.Text = "Source: loading"
    $sourceStatus.Left = 12
    $sourceStatus.Top = 218
    $sourceStatus.Width = 320
    $sourceStatus.Height = 18
    $sourceStatus.ForeColor = $muted
    $sourceStatus.AutoEllipsis = $true

    $toolTip = New-Object System.Windows.Forms.ToolTip

    $fiveHour = New-WidgetLimitPanel -Window "5 hour" -Top 38 -TitleFont $titleFont -ValueFont $valueFont -Accent $accent -Muted $muted -PanelBack $panelBack
    $oneWeek = New-WidgetLimitPanel -Window "1 week" -Top 116 -TitleFont $titleFont -ValueFont $valueFont -Accent $accent -Muted $muted -PanelBack $panelBack

    $form.Controls.AddRange(@($title, $fiveHour.Panel, $oneWeek.Panel, $updatedStatus, $sourceStatus))

    $updateAction = {
        try {
            $snapshot = Get-LatestCodexUsageSnapshot `
                -Root $Root `
                -Archived:$Archived `
                -Limit $MaxFiles `
                -Tail $TailLines `
                -ConversationLookbackHours $ConversationLookbackHours `
                -ConversationFallbackLookbackDays $ConversationFallbackLookbackDays `
                -ConversationFallbackMaxFiles $ConversationFallbackMaxFiles `
                -ConversationFallbackTailLines $ConversationFallbackTailLines

            if ($null -eq $snapshot) {
                Set-WidgetWindowRow -Controls $fiveHour -Row $null
                Set-WidgetWindowRow -Controls $oneWeek -Row $null
                $updatedStatus.Text = "Updated: no Codex snapshot found"
                $sourceStatus.Text = "Source: unknown"
                $toolTip.SetToolTip($sourceStatus, $null)
                return
            }

            Set-WidgetWindowRow -Controls $fiveHour -Row (Get-WidgetRateLimitRow -Rows $snapshot.RateLimitRows -Window "5 hour")
            Set-WidgetWindowRow -Controls $oneWeek -Row (Get-WidgetRateLimitRow -Rows $snapshot.RateLimitRows -Window "1 week")
            $sampledAt = if ($snapshot.PSObject.Properties["RateLimitEventTimestamp"] -and $snapshot.RateLimitEventTimestamp) {
                $snapshot.RateLimitEventTimestamp
            }
            else {
                $snapshot.Timestamp
            }
            $source = Get-WidgetSampleSource $snapshot
            $updatedStatus.Text = Format-WidgetUpdatedTime $sampledAt
            $sourceStatus.Text = $source.Text
            $toolTip.SetToolTip($sourceStatus, $source.ToolTip)
        }
        catch {
            $updatedStatus.Text = "Update failed: " + $_.Exception.Message
            $sourceStatus.Text = "Source: unchanged"
        }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(5, $RefreshSeconds) * 1000
    $timer.Add_Tick($updateAction)
    $form.Add_Shown({
        & $updateAction
        $timer.Start()
    })
    $form.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
        $toolTip.Dispose()
    })

    [System.Windows.Forms.Application]::Run($form)
}

function Quote-WidgetProcessArgument {
    param([string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-CodexUsageWidgetProcess {
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
        [int]$WidgetRefreshSeconds,
        [double]$UsdToSgdRate,
        [string]$CostBasisMode,
        [string]$PricingMode,
        [switch]$IncludeArchived
    )

    if (-not (Test-Path -LiteralPath $MonitorScript -PathType Leaf)) {
        Write-Warning "Widget monitor script not found: $MonitorScript"
        return $null
    }

    $powershell = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($powershell)) {
        Write-Warning "Unable to start Codex widget because powershell.exe was not found."
        return $null
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-WidgetProcessArgument $MonitorScript),
        "-Widget",
        "-CodexHome", (Quote-WidgetProcessArgument $CodexHome),
        "-MaxFiles", $MaxFiles,
        "-TailLines", $TailLines,
        "-ConversationLookbackHours", $ConversationLookbackHours,
        "-ConversationFallbackLookbackDays", $ConversationFallbackLookbackDays,
        "-ConversationFallbackMaxFiles", $ConversationFallbackMaxFiles,
        "-ConversationFallbackTailLines", $ConversationFallbackTailLines,
        "-RollingMaxFiles", $RollingMaxFiles,
        "-RollingTailLines", $RollingTailLines,
        "-CostMaxFiles", $CostMaxFiles,
        "-CostTailLines", $CostTailLines,
        "-WidgetRefreshSeconds", $WidgetRefreshSeconds,
        "-UsdToSgdRate", $UsdToSgdRate,
        "-CostBasisMode", $CostBasisMode,
        "-PricingMode", $PricingMode,
        "-DisableRateLimitHistory"
    )

    if ($IncludeArchived) {
        $args += "-IncludeArchived"
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = ($args -join " ")
    $info.WorkingDirectory = Split-Path -Parent $MonitorScript
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    try {
        return [System.Diagnostics.Process]::Start($info)
    }
    catch {
        Write-Warning ("Unable to start Codex widget: {0}" -f $_.Exception.Message)
        return $null
    }
}
