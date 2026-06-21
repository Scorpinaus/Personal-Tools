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
        return "Updated: not refreshed yet"
    }

    try {
        return "Updated: " + ([datetime]$Value).ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return "Updated: " + [string]$Value
    }
}

function Get-WidgetLimitToneColor {
    param(
        [object]$RemainingPercent,
        [System.Drawing.Color]$Accent,
        [System.Drawing.Color]$Warning,
        [System.Drawing.Color]$Danger
    )

    try {
        $remaining = [double]$RemainingPercent
    }
    catch {
        return $Accent
    }

    if ($remaining -le 10) {
        return $Danger
    }

    if ($remaining -le 25) {
        return $Warning
    }

    return $Accent
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
        $Controls.Reset.Text = "unknown"
        $Controls.Remaining.ForeColor = $Controls.Accent
        $Controls.ProgressFill.BackColor = $Controls.Accent
        $Controls.ProgressFill.Width = 0
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

    $tone = Get-WidgetLimitToneColor -RemainingPercent $Row.RemainingPercent -Accent $Controls.Accent -Warning $Controls.Warning -Danger $Controls.Danger
    $Controls.Remaining.Text = Format-WidgetPercent $Row.RemainingPercent
    $Controls.Remaining.ForeColor = $tone
    $Controls.Used.Text = "Used " + (Format-WidgetPercent $Row.UsedPercent)
    $Controls.Reset.Text = Format-WidgetResetTime $Row.ResetsAt
    $Controls.ProgressFill.BackColor = $tone
    $Controls.ProgressFill.Width = [int][Math]::Round(($Controls.ProgressTrack.Width * $used) / 100.0)
}

function New-WidgetLimitPanel {
    param(
        [string]$Window,
        [int]$Top,
        [System.Drawing.Font]$TitleFont,
        [System.Drawing.Font]$ValueFont,
        [System.Drawing.Color]$Accent,
        [System.Drawing.Color]$Warning,
        [System.Drawing.Color]$Danger,
        [System.Drawing.Color]$Muted,
        [System.Drawing.Color]$PanelBack,
        [System.Drawing.Color]$TrackBack
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Left = 14
    $panel.Top = $Top
    $panel.Width = 334
    $panel.Height = 82
    $panel.BackColor = $PanelBack
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $name = New-Object System.Windows.Forms.Label
    $name.Text = $Window.ToUpperInvariant()
    $name.Left = 12
    $name.Top = 9
    $name.Width = 92
    $name.Height = 18
    $name.Font = $TitleFont
    $name.ForeColor = $Muted

    $remaining = New-Object System.Windows.Forms.Label
    $remaining.Text = "--"
    $remaining.Left = 12
    $remaining.Top = 29
    $remaining.Width = 142
    $remaining.Height = 30
    $remaining.Font = $ValueFont
    $remaining.ForeColor = $Accent

    $remainingCaption = New-Object System.Windows.Forms.Label
    $remainingCaption.Text = "remaining"
    $remainingCaption.Left = 154
    $remainingCaption.Top = 38
    $remainingCaption.Width = 62
    $remainingCaption.Height = 18
    $remainingCaption.ForeColor = $Muted

    $used = New-Object System.Windows.Forms.Label
    $used.Text = "Used --"
    $used.Left = 226
    $used.Top = 11
    $used.Width = 94
    $used.Height = 18
    $used.TextAlign = [System.Drawing.ContentAlignment]::TopRight
    $used.ForeColor = $Muted

    $resetCaption = New-Object System.Windows.Forms.Label
    $resetCaption.Text = "Resets"
    $resetCaption.Left = 230
    $resetCaption.Top = 32
    $resetCaption.Width = 90
    $resetCaption.Height = 14
    $resetCaption.TextAlign = [System.Drawing.ContentAlignment]::TopRight
    $resetCaption.ForeColor = $Muted

    $reset = New-Object System.Windows.Forms.Label
    $reset.Text = "unknown"
    $reset.Left = 206
    $reset.Top = 48
    $reset.Width = 114
    $reset.Height = 16
    $reset.TextAlign = [System.Drawing.ContentAlignment]::TopRight
    $reset.ForeColor = $Muted

    $progressTrack = New-Object System.Windows.Forms.Panel
    $progressTrack.Left = 12
    $progressTrack.Top = 67
    $progressTrack.Width = 308
    $progressTrack.Height = 7
    $progressTrack.BackColor = $TrackBack

    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.Left = 0
    $progressFill.Top = 0
    $progressFill.Width = 0
    $progressFill.Height = 7
    $progressFill.BackColor = $Accent
    $progressTrack.Controls.Add($progressFill)

    $panel.Controls.AddRange(@($name, $remaining, $remainingCaption, $used, $resetCaption, $reset, $progressTrack))

    return @{
        Panel = $panel
        Remaining = $remaining
        Used = $used
        Reset = $reset
        ProgressTrack = $progressTrack
        ProgressFill = $progressFill
        Accent = $Accent
        Warning = $Warning
        Danger = $Danger
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
    $warning = [System.Drawing.ColorTranslator]::FromHtml("#b7791f")
    $danger = [System.Drawing.ColorTranslator]::FromHtml("#b42318")
    $muted = [System.Drawing.ColorTranslator]::FromHtml("#66736f")
    $panelBack = [System.Drawing.ColorTranslator]::FromHtml("#ffffff")
    $trackBack = [System.Drawing.ColorTranslator]::FromHtml("#dce8e4")
    $formBack = [System.Drawing.ColorTranslator]::FromHtml("#eef2f1")
    $accentSoft = [System.Drawing.ColorTranslator]::FromHtml("#e0f4f0")

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Codex Limits"
    $form.Width = 376
    $form.Height = 306
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
    $valueFont = New-Object System.Drawing.Font("Segoe UI", 20.0, [System.Drawing.FontStyle]::Bold)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Codex Limits"
    $title.Left = 14
    $title.Top = 10
    $title.Width = 170
    $title.Height = 20
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Live rate-limit windows"
    $subtitle.Left = 14
    $subtitle.Top = 29
    $subtitle.Width = 190
    $subtitle.Height = 17
    $subtitle.ForeColor = $muted

    $live = New-Object System.Windows.Forms.Label
    $live.Text = "LIVE"
    $live.Left = 300
    $live.Top = 13
    $live.Width = 48
    $live.Height = 20
    $live.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $live.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
    $live.ForeColor = $accent
    $live.BackColor = $accentSoft
    $live.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $updatedStatus = New-Object System.Windows.Forms.Label
    $updatedStatus.Text = "Updated: loading"
    $updatedStatus.Left = 14
    $updatedStatus.Top = 222
    $updatedStatus.Width = 334
    $updatedStatus.Height = 18
    $updatedStatus.ForeColor = $muted

    $sourceStatus = New-Object System.Windows.Forms.Label
    $sourceStatus.Text = "Source: loading"
    $sourceStatus.Left = 14
    $sourceStatus.Top = 241
    $sourceStatus.Width = 334
    $sourceStatus.Height = 18
    $sourceStatus.ForeColor = $muted
    $sourceStatus.AutoEllipsis = $true

    $toolTip = New-Object System.Windows.Forms.ToolTip

    $fiveHour = New-WidgetLimitPanel -Window "5 hour" -Top 50 -TitleFont $titleFont -ValueFont $valueFont -Accent $accent -Warning $warning -Danger $danger -Muted $muted -PanelBack $panelBack -TrackBack $trackBack
    $oneWeek = New-WidgetLimitPanel -Window "1 week" -Top 135 -TitleFont $titleFont -ValueFont $valueFont -Accent $accent -Warning $warning -Danger $danger -Muted $muted -PanelBack $panelBack -TrackBack $trackBack

    $form.Controls.AddRange(@($title, $subtitle, $live, $fiveHour.Panel, $oneWeek.Panel, $updatedStatus, $sourceStatus))

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
            $source = Get-WidgetSampleSource $snapshot
            $updatedStatus.Text = Format-WidgetUpdatedTime (Get-Date)
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
