    const refreshMs = 60000;
    document.getElementById("refresh").textContent = `Refresh: ${refreshMs / 1000}s`;

    const number = new Intl.NumberFormat();
    const money = new Intl.NumberFormat(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 4 });
    const activeTabs = { costs: "modelCosts", rateHistory: "historyFiveHour" };
    const stopMonitorButton = document.getElementById("stopMonitor");
    let stopped = false;
    let refreshTimer = null;

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
      return `<div class="table-scroll"><table><thead>${head}</thead><tbody>${body}</tbody></table></div>`;
    }

    function parseTime(value) {
      if (!value) return null;
      if (value instanceof Date) return value;
      const dotNet = String(value).match(/^\/Date\((\d+)\)\/$/);
      if (dotNet) return new Date(Number(dotNet[1]));
      const parsed = new Date(value);
      return Number.isNaN(parsed.getTime()) ? null : parsed;
    }

    function localDayKey(date) {
      const pad = (part) => String(part).padStart(2, "0");
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
    }

    function average(values) {
      const clean = values.filter((value) => Number.isFinite(value));
      if (clean.length === 0) return null;
      return clean.reduce((sum, value) => sum + value, 0) / clean.length;
    }

    function latestRowsForResetWindows(rows, windowName, windowCount) {
      const sorted = (rows || [])
        .filter((row) => row.Window === windowName)
        .map((row) => ({ ...row, _time: parseTime(row.SampledAt) }))
        .filter((row) => row._time)
        .sort((left, right) => left._time - right._time);
      const keys = [];
      sorted.forEach((row) => {
        const key = row.ResetsAt || "unknown";
        if (!keys.includes(key)) keys.push(key);
      });
      const keep = new Set(keys.slice(-windowCount));
      return sorted.filter((row) => keep.has(row.ResetsAt || "unknown"));
    }

    function rowsForCurrentResetWindow(rows, windowName) {
      const sorted = (rows || [])
        .filter((row) => row.Window === windowName)
        .map((row) => ({ ...row, _time: parseTime(row.SampledAt) }))
        .filter((row) => row._time)
        .sort((left, right) => left._time - right._time);
      if (sorted.length === 0) return [];

      const latest = sorted[sorted.length - 1];
      const currentReset = latest.ResetsAt || "unknown";
      return sorted.filter((row) => (row.ResetsAt || "unknown") === currentReset);
    }

    function rowsFromLastDays(rows, windowName, dayCount) {
      const cutoff = new Date(Date.now() - dayCount * 24 * 60 * 60 * 1000);
      return (rows || [])
        .filter((row) => row.Window === windowName)
        .map((row) => ({ ...row, _time: parseTime(row.SampledAt) }))
        .filter((row) => row._time && row._time >= cutoff)
        .sort((left, right) => left._time - right._time);
    }

    function summarizeRemaining(rows) {
      const values = (rows || []).map((row) => Number(row.RemainingPercent)).filter((value) => Number.isFinite(value));
      if (values.length === 0) {
        return { latest: null, low: null, average: null, samples: 0 };
      }
      return {
        latest: values[values.length - 1],
        low: Math.min(...values),
        average: average(values),
        samples: values.length
      };
    }

    function makeRemainingBuckets(rows, bucketMode) {
      const groups = new Map();
      (rows || [])
        .map((row) => ({ ...row, _time: row._time || parseTime(row.SampledAt) }))
        .filter((row) => row._time)
        .sort((left, right) => left._time - right._time)
        .forEach((row) => {
          const time = row._time;
          const key = bucketMode === "day"
            ? localDayKey(time)
            : `${localDayKey(time)} ${String(time.getHours()).padStart(2, "0")}:00`;
          const label = bucketMode === "day"
            ? `${time.getMonth() + 1}/${time.getDate()}`
            : `${String(time.getHours()).padStart(2, "0")}:00`;
          if (!groups.has(key)) groups.set(key, { key, label, rows: [] });
          groups.get(key).rows.push(row);
        });

      return Array.from(groups.values()).map((bucket) => {
        const sorted = bucket.rows.sort((left, right) => left._time - right._time);
        const latest = sorted[sorted.length - 1];
        return {
          key: bucket.key,
          label: bucket.label,
          value: Number(latest.RemainingPercent) || 0,
          samples: sorted.length
        };
      });
    }

    function renderRemainingBarChart(rows, title, description, bucketMode) {
      const buckets = makeRemainingBuckets(rows, bucketMode);

      if (buckets.length === 0) {
        return `<div class="usage-chart"><h3>${esc(title)}</h3><p class="muted">No history samples yet.</p></div>`;
      }

      const width = 640;
      const height = 200;
      const padLeft = 36;
      const padRight = 12;
      const padTop = 12;
      const padBottom = 42;
      const plotWidth = width - padLeft - padRight;
      const plotHeight = height - padTop - padBottom;
      const gap = buckets.length > 1 ? 10 : 0;
      const slotWidth = plotWidth / buckets.length;
      const barWidth = Math.max(10, Math.min(54, slotWidth - gap));
      const baseline = padTop + plotHeight;
      const stat = summarizeRemaining(rows);

      const bars = buckets.map((bucket, index) => {
          const clamped = Math.max(0, Math.min(100, bucket.value));
          const barHeight = (clamped / 100) * plotHeight;
          const x = padLeft + index * slotWidth + (slotWidth - barWidth) / 2;
          const y = baseline - barHeight;
          const labelX = padLeft + index * slotWidth + slotWidth / 2;
          return `
            <rect class="chart-bar" x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${barWidth.toFixed(1)}" height="${barHeight.toFixed(1)}" rx="3"></rect>
            <text class="chart-value" x="${labelX.toFixed(1)}" y="${Math.max(10, y - 5).toFixed(1)}">${fmt(bucket.value)}%</text>
            <text class="chart-axis-label" x="${labelX.toFixed(1)}" y="${height - 12}">${esc(bucket.label)}</text>
          `;
        })
        .join("");

      return `
        <div class="usage-chart">
          <h3>${esc(title)}</h3>
          <p class="chart-note">${esc(description)}</p>
          <svg viewBox="0 0 ${width} ${height}" role="img" aria-label="${esc(title)} remaining percentage history">
            <line class="chart-grid-line" x1="${padLeft}" y1="${padTop}" x2="${padLeft + plotWidth}" y2="${padTop}"></line>
            <line class="chart-grid-line" x1="${padLeft}" y1="${padTop + plotHeight / 2}" x2="${padLeft + plotWidth}" y2="${padTop + plotHeight / 2}"></line>
            <line class="chart-grid-line" x1="${padLeft}" y1="${padTop + plotHeight}" x2="${padLeft + plotWidth}" y2="${padTop + plotHeight}"></line>
            <text x="0" y="${padTop + 4}" font-size="11" fill="#666b72">100%</text>
            <text x="8" y="${padTop + plotHeight / 2 + 4}" font-size="11" fill="#666b72">50%</text>
            <text x="14" y="${padTop + plotHeight + 4}" font-size="11" fill="#666b72">0%</text>
            ${bars}
          </svg>
          <div class="total">
            <span>remaining: <strong>${fmt(stat.latest)}%</strong></span>
            <span>low: <strong>${fmt(stat.low)}%</strong></span>
            <span>average: <strong>${fmt(stat.average === null ? null : Math.round(stat.average * 100) / 100)}%</strong></span>
            <span>samples: <strong>${fmt(stat.samples)}</strong></span>
          </div>
        </div>
      `;
    }

    function renderFiveHourBuckets(rows) {
      const groups = new Map();
      (rows || []).forEach((row) => {
        const key = row.ResetsAt || "unknown";
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(row);
      });
      const bucketRows = Array.from(groups.entries()).map(([reset, group]) => {
        const sorted = group.sort((left, right) => (left._time || parseTime(left.SampledAt)) - (right._time || parseTime(right.SampledAt)));
        const stat = summarizeRemaining(sorted);
        return {
          "ResetWindow": reset,
          "LatestRemainingPercent": stat.latest,
          "LowestRemainingPercent": stat.low,
          "AverageRemainingPercent": stat.average === null ? null : Math.round(stat.average * 100) / 100,
          "Samples": stat.samples,
          "FirstSampledAt": sorted[0]?.SampledAt,
          "LastSampledAt": sorted[sorted.length - 1]?.SampledAt
        };
      }).sort((left, right) => {
        const leftTime = parseTime(left.LastSampledAt)?.getTime() || 0;
        const rightTime = parseTime(right.LastSampledAt)?.getTime() || 0;
        return rightTime - leftTime;
      });

      return table(bucketRows, [
        { key: "ResetWindow", label: "Resets at", date: true },
        { key: "LatestRemainingPercent", label: "Latest remaining %", number: true },
        { key: "LowestRemainingPercent", label: "Lowest remaining %", number: true },
        { key: "AverageRemainingPercent", label: "Average remaining %", number: true },
        { key: "Samples", label: "Samples", number: true },
        { key: "FirstSampledAt", label: "First sample", date: true },
        { key: "LastSampledAt", label: "Last sample", date: true }
      ]);
    }

    function renderWeeklyDailyBuckets(rows) {
      const groups = new Map();
      (rows || []).forEach((row) => {
        const time = row._time || parseTime(row.SampledAt);
        if (!time) return;
        const key = localDayKey(time);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(row);
      });
      const bucketRows = Array.from(groups.entries()).map(([day, group]) => {
        const sorted = group.sort((left, right) => (left._time || parseTime(left.SampledAt)) - (right._time || parseTime(right.SampledAt)));
        const stat = summarizeRemaining(sorted);
        return {
          "Day": day,
          "LatestRemainingPercent": stat.latest,
          "LowestRemainingPercent": stat.low,
          "AverageRemainingPercent": stat.average === null ? null : Math.round(stat.average * 100) / 100,
          "Samples": stat.samples
        };
      }).sort((left, right) => right.Day.localeCompare(left.Day));

      return table(bucketRows, [
        { key: "Day", label: "Day" },
        { key: "LatestRemainingPercent", label: "Latest remaining %", number: true },
        { key: "LowestRemainingPercent", label: "Lowest remaining %", number: true },
        { key: "AverageRemainingPercent", label: "Average remaining %", number: true },
        { key: "Samples", label: "Samples", number: true }
      ]);
    }

    function renderRateLimitHistory(rows, summary, days) {
      const sorted = [...(rows || [])].sort((left, right) => {
        const leftTime = parseTime(left.SampledAt)?.getTime() || 0;
        const rightTime = parseTime(right.SampledAt)?.getTime() || 0;
        return rightTime - leftTime;
      });
      const summaryRows = summary || [];
      const currentFiveHourRows = rowsForCurrentResetWindow(rows, "5 hour");
      const recentFiveHourRows = latestRowsForResetWindows(rows, "5 hour", 5);
      const weekRows = rowsFromLastDays(rows, "1 week", 7);
      const chartHtml = `
        <div class="chart-grid">
          ${renderRemainingBarChart(currentFiveHourRows, "5 hour remaining", "Current 5-hour rate-limit window, grouped hourly.", "hour")}
          ${renderRemainingBarChart(weekRows, "1 week remaining", "Samples from the previous 7 days, grouped daily.", "day")}
        </div>
      `;

      const historyTab = activeTabs.rateHistory || "historyFiveHour";

      return chartHtml + table(summaryRows, [
        { key: "Window", label: "Window" },
        { key: "LatestUsedPercent", label: "Latest used %", number: true },
        { key: "PeakUsedPercent", label: "Peak used %", number: true },
        { key: "AverageUsedPercent", label: "Average used %", number: true },
        { key: "Samples", label: "Samples", number: true },
        { key: "ResetCount", label: "Resets", number: true },
        { key: "FirstSampledAt", label: "First sample", date: true },
        { key: "LastSampledAt", label: "Last sample", date: true }
      ]) + `<h4>Recent 5-hour reset windows</h4>` + renderFiveHourBuckets(recentFiveHourRows) +
      `<h4>Weekly daily buckets</h4>` + renderWeeklyDailyBuckets(weekRows) +
      `<h4>Recent samples</h4>
      <div class="tabs" role="tablist">
        <button class="tab ${historyTab === "historyFiveHour" ? "active" : ""}" type="button" data-tab-scope="rateHistory" data-tab="historyFiveHour">5 hour</button>
        <button class="tab ${historyTab === "historyOneWeek" ? "active" : ""}" type="button" data-tab-scope="rateHistory" data-tab="historyOneWeek">1 week</button>
      </div>
      <div id="historyFiveHour" class="tab-panel" data-tab-scope="rateHistory" ${historyTab === "historyFiveHour" ? "" : "hidden"}>` + table(sorted.filter((row) => row.Window === "5 hour").slice(0, 30), [
        { key: "SampledAt", label: "Sampled", date: true },
        { key: "RemainingPercent", label: "Remaining %", number: true },
        { key: "UsedPercent", label: "Used %", number: true },
        { key: "ResetsAt", label: "Resets at", date: true }
      ]) + `</div>
      <div id="historyOneWeek" class="tab-panel" data-tab-scope="rateHistory" ${historyTab === "historyOneWeek" ? "" : "hidden"}>` + table(sorted.filter((row) => row.Window === "1 week").slice(0, 30), [
        { key: "SampledAt", label: "Sampled", date: true },
        { key: "RemainingPercent", label: "Remaining %", number: true },
        { key: "UsedPercent", label: "Used %", number: true },
        { key: "ResetsAt", label: "Resets at", date: true }
      ]) + `</div>
      <p class="source">Showing observed rate-limit samples from the last ${esc(days || 7)} days. Samples are captured while this monitor is running.</p>`;
    }

    function renderPeriodTotals(rows, usdToSgdRate) {
      if (!rows || rows.length === 0) return "";
      const sorted = [...rows].sort((left, right) => (left.PeriodSortOrder || 0) - (right.PeriodSortOrder || 0));
      return table(sorted, [
        { key: "PeriodLabel", label: "Period" },
        { key: "Total", label: "Total", number: true },
        { key: "Input", label: "Input", number: true },
        { key: "CachedInput", label: "Cached input", number: true },
        { key: "Output", label: "Output", number: true },
        { key: "Reasoning", label: "Reasoning", number: true },
        { key: "Events", label: "Events", number: true },
        { key: "TotalCostUsd", label: "Cost USD", money: true },
        { key: "TotalCostSgd", label: "Cost SGD", money: true },
        { key: "TotalCostCredits", label: "Credits", number: true }
      ]);
    }

    function renderCosts(rows, totals, usdToSgdRate, modelPeriodRows, periodTotals) {
      const periods = ["Last 5 hours", "This week", "This month"];
      return periods.map((period) => {
        const periodRows = (rows || []).filter((row) => row.Window === period);
        const total = (totals || []).find((row) => row.Window === period) || {};
        const historyRows = (modelPeriodRows || []).filter((row) => row.PeriodGroup === period);
        const historyTotals = (periodTotals || []).filter((row) => row.PeriodGroup === period);
        return `
          <h3>${esc(period)}</h3>
          ${table(periodRows, [
            { key: "Model", label: "Model" },
            { key: "PricingBand", label: "Pricing band" },
            { key: "PricingMode", label: "Mode" },
            { key: "CostUnit", label: "Unit" },
            { key: "BillingConfidence", label: "Confidence" },
            { key: "Total", label: "Total", number: true },
            { key: "Input", label: "Input", number: true },
            { key: "CachedInput", label: "Cached input", number: true },
            { key: "Output", label: "Output", number: true },
            { key: "Reasoning", label: "Reasoning", number: true },
            { key: "Events", label: "Events", number: true },
            { key: "EstimatedCostUsd", label: "Cost USD", money: true },
            { key: "EstimatedCostCredits", label: "Credits", number: true }
          ])}
          <div class="total">
            <span>totalCostUsd: <strong>${fmtMoney(total.TotalCostUsd || 0)}</strong></span>
            <span>totalCostSgd: <strong>${fmtMoney(total.TotalCostSgd || 0)}</strong></span>
            <span>totalCostCredits: <strong>${fmt(total.TotalCostCredits || 0)}</strong></span>
          </div>
          <h4>${period === "Last 5 hours" ? "Previous 5-hour buckets" : period === "This week" ? "Daily buckets" : "Weekly buckets"}</h4>
          ${table(historyRows, [
            { key: "PeriodLabel", label: "Period" },
            { key: "Model", label: "Model" },
            { key: "PricingBand", label: "Pricing band" },
            { key: "PricingMode", label: "Mode" },
            { key: "CostUnit", label: "Unit" },
            { key: "BillingConfidence", label: "Confidence" },
            { key: "Total", label: "Total", number: true },
            { key: "Input", label: "Input", number: true },
            { key: "CachedInput", label: "Cached input", number: true },
            { key: "Output", label: "Output", number: true },
            { key: "Reasoning", label: "Reasoning", number: true },
            { key: "Events", label: "Events", number: true },
            { key: "EstimatedCostUsd", label: "Cost USD", money: true },
            { key: "EstimatedCostCredits", label: "Credits", number: true }
          ])}
          <h4>Period totals</h4>
          ${renderPeriodTotals(historyTotals, usdToSgdRate)}
        `;
      }).join("") + `<p class="source">SGD conversion: 1 USD = ${esc(usdToSgdRate)} SGD.</p>`;
    }

    function renderSourceCosts(rows, usdToSgdRate) {
      const periods = ["Last 5 hours", "This week", "This month"];
      return periods.map((period) => {
        const periodRows = (rows || []).filter((row) => row.Window === period);
        const totalUsd = periodRows.reduce((sum, row) => sum + (Number(row.EstimatedCostUsd) || 0), 0);
        const totalCredits = periodRows.reduce((sum, row) => sum + (Number(row.EstimatedCostCredits) || 0), 0);
        return `
          <h3>${esc(period)}</h3>
          ${table(periodRows, [
            { key: "Model", label: "Model" },
            { key: "Source", label: "Source" },
            { key: "PricingBand", label: "Band" },
            { key: "PricingMode", label: "Mode" },
            { key: "CostUnit", label: "Unit" },
            { key: "BillingConfidence", label: "Confidence" },
            { key: "EstimatedChars", label: "Est. chars", number: true },
            { key: "EstimatedTokens", label: "Est. tokens", number: true },
            { key: "EstimatedInputTokens", label: "Est. input", number: true },
            { key: "EstimatedOutputTokens", label: "Est. output", number: true },
            { key: "AllocatedInput", label: "Alloc. input", number: true },
            { key: "AllocatedCachedInput", label: "Cached input", number: true },
            { key: "AllocatedOutput", label: "Alloc. output", number: true },
            { key: "AllocatedTokens", label: "Alloc. tokens", number: true },
            { key: "ReconciliationDelta", label: "Recon delta", number: true },
            { key: "Events", label: "Events", number: true },
            { key: "EstimatedCostUsd", label: "Cost USD", money: true },
            { key: "EstimatedCostCredits", label: "Credits", number: true },
            { key: "Attribution", label: "Attribution" }
          ])}
          <div class="total">
            <span>totalCostUsd: <strong>${fmtMoney(totalUsd)}</strong></span>
            <span>totalCostSgd: <strong>${fmtMoney(totalUsd * Number(usdToSgdRate || 0))}</strong></span>
            <span>totalCostCredits: <strong>${fmt(totalCredits)}</strong></span>
          </div>
        `;
      }).join("") + `<p class="source">Source attribution is estimated from logged text lengths and reconciled against exact-ish model/period token totals.</p>`;
    }

    function activateTab(tab) {
      const tabId = tab.dataset.tab;
      const scope = tab.dataset.tabScope || "";
      activeTabs[scope] = tabId;
      document.querySelectorAll(`.tab[data-tab-scope="${scope}"]`).forEach((item) => {
        item.classList.toggle("active", item.dataset.tab === tabId);
      });
      document.querySelectorAll(`.tab-panel[data-tab-scope="${scope}"]`).forEach((panel) => {
        panel.hidden = panel.id !== tabId;
      });
    }

    function showStatusMessage(message, kind) {
      const error = document.getElementById("error");
      error.textContent = message;
      error.className = kind === "info" ? "notice" : "error";
      error.style.display = "block";
    }

    document.addEventListener("click", (event) => {
      const tab = event.target.closest(".tab");
      if (!tab) return;
      activateTab(tab);
    });

    stopMonitorButton.addEventListener("click", async () => {
      stopMonitorButton.disabled = true;
      stopMonitorButton.textContent = "Stopping";
      try {
        const res = await fetch("/api/shutdown", { method: "POST", cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        stopped = true;
        if (refreshTimer) clearInterval(refreshTimer);
        document.getElementById("monitorState").textContent = "Stopped";
        document.getElementById("refresh").textContent = "Refresh: stopped";
        stopMonitorButton.textContent = "Stopped";
        showStatusMessage("Monitor stopped. You can close this tab.", "info");
      } catch (err) {
        stopMonitorButton.disabled = false;
        stopMonitorButton.textContent = "Stop";
        showStatusMessage(`Unable to stop monitor: ${err.message}`, "error");
      }
    });

    async function load() {
      if (stopped) return;
      const error = document.getElementById("error");
      try {
        const res = await fetch("/api/usage", { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        document.getElementById("monitorState").textContent = "Running";
        error.style.display = "none";
        document.getElementById("updated").textContent = `Updated: ${data.UpdatedAtLocal}`;
        document.getElementById("plan").textContent = `Plan: ${data.PlanType || "unknown"}`;
        document.getElementById("source").textContent = `Session: ${data.Session || ""} | Source: ${data.SourceFile || ""}`;
        document.getElementById("costAssumptions").textContent =
          `Cost basis: ${data.CostBasis || "API-equivalent estimate"} | Pricing mode: ${data.PricingMode || "Standard"} | Pricing source: ${data.PricingSource || ""} | SGD conversion: ${data.CostBasisMode === "CodexCredits" ? "not applied to credits" : `1 USD = ${data.UsdToSgdRate}`}`;

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
        document.getElementById("rateLimitHistory").innerHTML = renderRateLimitHistory(data.RateLimitHistoryRows, data.RateLimitHistorySummaryRows, data.RateLimitHistoryDays);
        document.getElementById("modelCosts").innerHTML = renderCosts(data.ModelTokenRows, data.ModelCostTotals, data.UsdToSgdRate, data.ModelTokenPeriodRows, data.ModelPeriodCostTotals);
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
    refreshTimer = setInterval(load, refreshMs);
