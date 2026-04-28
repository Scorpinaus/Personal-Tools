param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
    [string]$MonitorScript = (Join-Path $env:USERPROFILE ".codex\tools\codex_usage_monitor.ps1"),
    [int]$Port = 8787,
    [int]$MaxFiles = 5,
    [int]$TailLines = 500,
    [int]$RollingMaxFiles = 0,
    [int]$RollingTailLines = 0,
    [int]$CostMaxFiles = 0,
    [int]$CostTailLines = 0,
    [int]$CostFiveHourRefreshSeconds = 60,
    [int]$CostWeekRefreshSeconds = 60,
    [int]$CostMonthRefreshSeconds = 86400,
    [double]$UsdToSgdRate = 1.274,
    [ValidateSet("Standard", "Batch", "Flex", "Priority")]
    [string]$PricingMode = "Standard",
    [switch]$IncludeArchived,
    [switch]$NoOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $MonitorScript)) {
    throw "Monitor script not found: $MonitorScript"
}

. $MonitorScript `
    -CodexHome $CodexHome `
    -MaxFiles $MaxFiles `
    -TailLines $TailLines `
    -RollingMaxFiles $RollingMaxFiles `
    -RollingTailLines $RollingTailLines `
    -CostMaxFiles $CostMaxFiles `
    -CostTailLines $CostTailLines `
    -CostFiveHourRefreshSeconds $CostFiveHourRefreshSeconds `
    -CostWeekRefreshSeconds $CostWeekRefreshSeconds `
    -CostMonthRefreshSeconds $CostMonthRefreshSeconds `
    -UsdToSgdRate $UsdToSgdRate `
    -PricingMode $PricingMode `
    -IncludeArchived:$IncludeArchived `
    -LibraryOnly

function New-DashboardHtml {
    @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Codex Usage Monitor</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f7f7f4;
      --panel: #ffffff;
      --ink: #202124;
      --muted: #666b72;
      --line: #ddd8cf;
      --accent: #0f766e;
      --accent-soft: #dff3ef;
      --warn: #a16207;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--ink);
    }
    header {
      position: sticky;
      top: 0;
      z-index: 2;
      background: rgba(247, 247, 244, 0.94);
      border-bottom: 1px solid var(--line);
      backdrop-filter: blur(10px);
    }
    .bar {
      max-width: 1320px;
      margin: 0 auto;
      padding: 16px 20px;
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 16px;
      align-items: center;
    }
    h1 {
      margin: 0;
      font-size: 22px;
      letter-spacing: 0;
    }
    .status {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      justify-content: flex-end;
      color: var(--muted);
      font-size: 13px;
    }
    .pill {
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 6px 10px;
      background: var(--panel);
    }
    main {
      max-width: 1320px;
      margin: 0 auto;
      padding: 20px;
      display: grid;
      gap: 18px;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 18px;
    }
    section {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      overflow: hidden;
    }
    h2 {
      margin: 0 0 12px;
      font-size: 15px;
      letter-spacing: 0;
    }
    h3 {
      margin: 18px 0 10px;
      font-size: 14px;
      color: var(--accent);
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      padding: 9px 8px;
      border-bottom: 1px solid var(--line);
      text-align: right;
      white-space: nowrap;
    }
    th:first-child, td:first-child { text-align: left; }
    th {
      color: var(--muted);
      font-weight: 650;
      background: #fbfaf8;
    }
    .total {
      display: flex;
      gap: 14px;
      flex-wrap: wrap;
      margin: 10px 0 4px;
      font-size: 13px;
    }
    .total strong {
      color: var(--accent);
    }
    .muted { color: var(--muted); }
    .source {
      color: var(--muted);
      font-size: 12px;
      line-height: 1.5;
    }
    .tabs {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      margin: 4px 0 14px;
      border-bottom: 1px solid var(--line);
    }
    .tab {
      border: 1px solid var(--line);
      border-bottom: 0;
      background: #fbfaf8;
      color: var(--muted);
      padding: 8px 12px;
      border-radius: 8px 8px 0 0;
      cursor: pointer;
      font: inherit;
      font-size: 13px;
    }
    .tab.active {
      background: var(--panel);
      color: var(--accent);
      font-weight: 650;
    }
    .tab-panel[hidden] {
      display: none;
    }
    .error {
      color: #991b1b;
      background: #fee2e2;
      border: 1px solid #fecaca;
      padding: 12px;
      border-radius: 8px;
      display: none;
    }
    @media (max-width: 900px) {
      .bar, .grid { grid-template-columns: 1fr; }
      .status { justify-content: flex-start; }
      section { overflow-x: auto; }
    }
  </style>
</head>
<body>
  <header>
    <div class="bar">
      <h1>Codex Usage Monitor</h1>
      <div class="status">
        <span class="pill" id="updated">Updated: loading</span>
        <span class="pill" id="plan">Plan: unknown</span>
        <span class="pill" id="refresh">Refresh: 5s</span>
      </div>
    </div>
  </header>
  <main>
    <div id="error" class="error"></div>
    <div class="grid">
      <section>
        <h2>Rate Limits</h2>
        <div id="rateLimits"></div>
      </section>
      <section>
        <h2>Rolling Token Usage</h2>
        <div id="rollingTokens"></div>
      </section>
    </div>
    <section>
      <h2>Estimated Token Cost By Model</h2>
      <p class="source" id="costAssumptions">Cost basis: loading</p>
      <div class="tabs" role="tablist">
        <button class="tab active" type="button" data-tab="modelCosts">By model</button>
        <button class="tab" type="button" data-tab="sourceCosts">By source estimate</button>
      </div>
      <div id="modelCosts" class="tab-panel"></div>
      <div id="sourceCosts" class="tab-panel" hidden></div>
      <p class="source">
        Pricing source: https://developers.openai.com/api/docs/pricing. Reasoning tokens are shown separately and not double-counted.
        Source costs are local estimates allocated from the model/period totals.
      </p>
    </section>
    <section>
      <h2>Conversation Token Usage</h2>
      <div id="conversationTokens"></div>
      <p class="source" id="source"></p>
    </section>
  </main>
  <script>
    const refreshMs = 60000;
    document.getElementById("refresh").textContent = `Refresh: ${refreshMs / 1000}s`;

    const number = new Intl.NumberFormat();
    const money = new Intl.NumberFormat(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 4 });

    function esc(value) {
      return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      }[ch]));
    }

    function fmt(value) {
      return value === null || value === undefined || value === "" ? "" : number.format(value);
    }

    function fmtMoney(value) {
      return value === null || value === undefined || value === "" ? "" : money.format(value);
    }

    function fmtDate(value) {
      if (typeof value !== "string") return value ?? "";
      const match = value.match(/^\/Date\((\d+)\)\/$/);
      if (!match) return value;
      const date = new Date(Number(match[1]));
      const pad = (part) => String(part).padStart(2, "0");
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
    }

    function table(rows, columns) {
      if (!rows || rows.length === 0) return `<p class="muted">No data yet.</p>`;
      const head = `<tr>${columns.map((col) => `<th>${esc(col.label)}</th>`).join("")}</tr>`;
      const body = rows.map((row) => `<tr>${columns.map((col) => {
        const raw = row[col.key];
        const value = col.date ? esc(fmtDate(raw)) : col.money ? fmtMoney(raw) : col.number ? fmt(raw) : esc(raw);
        return `<td>${value}</td>`;
      }).join("")}</tr>`).join("");
      return `<table><thead>${head}</thead><tbody>${body}</tbody></table>`;
    }

    function renderCosts(rows, totals, usdToSgdRate) {
      const periods = ["Last 5 hours", "This week", "This month"];
      return periods.map((period) => {
        const periodRows = (rows || []).filter((row) => row.Window === period);
        const total = (totals || []).find((row) => row.Window === period) || {};
        return `
          <h3>${esc(period)}</h3>
          ${table(periodRows, [
            { key: "Model", label: "Model" },
            { key: "PricingBand", label: "Pricing band" },
            { key: "PricingMode", label: "Mode" },
            { key: "BillingConfidence", label: "Confidence" },
            { key: "Total", label: "Total", number: true },
            { key: "Input", label: "Input", number: true },
            { key: "CachedInput", label: "Cached input", number: true },
            { key: "Output", label: "Output", number: true },
            { key: "Reasoning", label: "Reasoning", number: true },
            { key: "Events", label: "Events", number: true },
            { key: "EstimatedCostUsd", label: "Cost USD", money: true }
          ])}
          <div class="total">
            <span>totalCostUsd: <strong>${fmtMoney(total.TotalCostUsd || 0)}</strong></span>
            <span>totalCostSgd: <strong>${fmtMoney(total.TotalCostSgd || 0)}</strong></span>
          </div>
        `;
      }).join("") + `<p class="source">SGD conversion: 1 USD = ${esc(usdToSgdRate)} SGD.</p>`;
    }

    function renderSourceCosts(rows, usdToSgdRate) {
      const periods = ["Last 5 hours", "This week", "This month"];
      return periods.map((period) => {
        const periodRows = (rows || []).filter((row) => row.Window === period);
        const totalUsd = periodRows.reduce((sum, row) => sum + (Number(row.EstimatedCostUsd) || 0), 0);
        return `
          <h3>${esc(period)}</h3>
          ${table(periodRows, [
            { key: "Model", label: "Model" },
            { key: "Source", label: "Source" },
            { key: "PricingBand", label: "Pricing band" },
            { key: "PricingMode", label: "Mode" },
            { key: "BillingConfidence", label: "Confidence" },
            { key: "EstimatedTokens", label: "Est. source tokens", number: true },
            { key: "AllocatedInput", label: "Allocated input", number: true },
            { key: "AllocatedCachedInput", label: "Cached input", number: true },
            { key: "AllocatedOutput", label: "Allocated output", number: true },
            { key: "Events", label: "Events", number: true },
            { key: "EstimatedCostUsd", label: "Cost USD", money: true },
            { key: "Attribution", label: "Attribution" }
          ])}
          <div class="total">
            <span>totalCostUsd: <strong>${fmtMoney(totalUsd)}</strong></span>
            <span>totalCostSgd: <strong>${fmtMoney(totalUsd * Number(usdToSgdRate || 0))}</strong></span>
          </div>
        `;
      }).join("") + `<p class="source">Source attribution is estimated from logged text lengths and reconciled against exact-ish model/period token totals.</p>`;
    }

    function activateTab(tabId) {
      document.querySelectorAll(".tab").forEach((tab) => {
        tab.classList.toggle("active", tab.dataset.tab === tabId);
      });
      document.querySelectorAll(".tab-panel").forEach((panel) => {
        panel.hidden = panel.id !== tabId;
      });
    }

    document.querySelectorAll(".tab").forEach((tab) => {
      tab.addEventListener("click", () => activateTab(tab.dataset.tab));
    });

    async function load() {
      const error = document.getElementById("error");
      try {
        const res = await fetch("/api/usage", { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        error.style.display = "none";
        document.getElementById("updated").textContent = `Updated: ${data.UpdatedAtLocal}`;
        document.getElementById("plan").textContent = `Plan: ${data.PlanType || "unknown"}`;
        document.getElementById("source").textContent = `Session: ${data.Session || ""} | Source: ${data.SourceFile || ""}`;
        document.getElementById("costAssumptions").textContent =
          `Cost basis: ${data.CostBasis || "API-equivalent estimate"} | Pricing mode: ${data.PricingMode || "Standard"} | Regional uplift: ${data.RegionalUpliftApplied ? "applied" : "not applied"} | SGD: 1 USD = ${data.UsdToSgdRate}`;

        document.getElementById("rateLimits").innerHTML = table(data.RateLimitRows, [
          { key: "Window", label: "Window" },
          { key: "UsedPercent", label: "Used %", number: true },
          { key: "RemainingPercent", label: "Remaining %", number: true },
          { key: "WindowMinutes", label: "Minutes", number: true },
          { key: "ResetsAt", label: "Resets at", date: true }
        ]);
        document.getElementById("rollingTokens").innerHTML = table(data.RollingTokenRows, [
          { key: "Window", label: "Window" },
          { key: "Total", label: "Total", number: true },
          { key: "Input", label: "Input", number: true },
          { key: "CachedInput", label: "Cached input", number: true },
          { key: "Output", label: "Output", number: true },
          { key: "Reasoning", label: "Reasoning", number: true },
          { key: "Events", label: "Events", number: true }
        ]);
        document.getElementById("modelCosts").innerHTML = renderCosts(data.ModelTokenRows, data.ModelCostTotals, data.UsdToSgdRate);
        document.getElementById("sourceCosts").innerHTML = renderSourceCosts(data.SourceCostRows, data.UsdToSgdRate);
        document.getElementById("conversationTokens").innerHTML = table(data.TokenRows, [
          { key: "Scope", label: "Scope" },
          { key: "Total", label: "Total", number: true },
          { key: "Input", label: "Input", number: true },
          { key: "CachedInput", label: "Cached input", number: true },
          { key: "Output", label: "Output", number: true },
          { key: "Reasoning", label: "Reasoning", number: true }
        ]);
      } catch (err) {
        error.textContent = `Unable to refresh usage data: ${err.message}`;
        error.style.display = "block";
      }
    }

    load();
    setInterval(load, refreshMs);
  </script>
</body>
</html>
'@
}

function Convert-SnapshotForJson {
    param([object]$Snapshot)

    $rateLimitRows = @(
        foreach ($row in $Snapshot.RateLimitRows) {
            [pscustomobject]@{
                Window = $row.Window
                UsedPercent = $row.UsedPercent
                RemainingPercent = $row.RemainingPercent
                WindowMinutes = $row.WindowMinutes
                ResetsAt = if ($null -ne $row.ResetsAt) { ([datetime]$row.ResetsAt).ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            }
        }
    )

    $costTotals = @()
    foreach ($windowName in @("Last 5 hours", "This week", "This month")) {
        $rows = @($Snapshot.ModelTokenRows | Where-Object { $_.Window -eq $windowName })
        $totalUsd = Get-TotalEstimatedCostUsd $rows
        $costTotals += [pscustomobject]@{
            Window = $windowName
            TotalCostUsd = $totalUsd
            TotalCostSgd = [Math]::Round($totalUsd * $UsdToSgdRate, 4)
        }
    }

    [pscustomobject]@{
        UpdatedAtLocal = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        EventTimestamp = $Snapshot.Timestamp
        PlanType = $Snapshot.PlanType
        Session = $Snapshot.Session
        SourceFile = $Snapshot.SourceFile
        CostBasis = $Snapshot.CostBasis
        PricingMode = $Snapshot.PricingMode
        PricingSource = $Snapshot.PricingSource
        RegionalUpliftApplied = $Snapshot.RegionalUpliftApplied
        RateLimitRows = $rateLimitRows
        RollingTokenRows = $Snapshot.RollingTokenRows
        ModelTokenRows = $Snapshot.ModelTokenRows
        SourceCostRows = $Snapshot.SourceCostRows
        ModelCostTotals = $costTotals
        TokenRows = $Snapshot.TokenRows
        ContextWindow = $Snapshot.ContextWindow
        UsdToSgdRate = $UsdToSgdRate
    }
}

function Write-HttpResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [string]$Body
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
}
catch [System.Net.HttpListenerException] {
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
                    Start-Process $prefix
                }

                Write-Host "Codex usage dashboard is already running at $prefix"
                return
            }
        }
    }
    catch {
    }

    throw
}

if (-not $NoOpen) {
    Start-Process $prefix
}

Write-Host "Codex usage dashboard running at $prefix"
Write-Host "Press Ctrl+C to stop."

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $path = $context.Request.Url.AbsolutePath
            if ($path -eq "/" -or $path -eq "/index.html") {
                Write-HttpResponse $context 200 "text/html; charset=utf-8" (New-DashboardHtml)
            }
            elseif ($path -eq "/api/usage") {
                $snapshot = Get-LatestCodexUsageSnapshot -Root $CodexHome -Archived:$IncludeArchived -Limit $MaxFiles -Tail $TailLines
                if ($null -eq $snapshot) {
                    Write-HttpResponse $context 404 "application/json; charset=utf-8" (@{ error = "No Codex usage snapshot found." } | ConvertTo-Json)
                }
                else {
                    $json = Convert-SnapshotForJson $snapshot | ConvertTo-Json -Depth 8
                    Write-HttpResponse $context 200 "application/json; charset=utf-8" $json
                }
            }
            else {
                Write-HttpResponse $context 404 "text/plain; charset=utf-8" "Not found"
            }
        }
        catch {
            Write-HttpResponse $context 500 "application/json; charset=utf-8" (@{ error = $_.Exception.Message } | ConvertTo-Json)
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
