    const refreshMs = 30000;
    document.getElementById("refresh").textContent = `Refresh: ${refreshMs / 1000}s`;

    const number = new Intl.NumberFormat();
    const money = new Intl.NumberFormat(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 4 });
    const activeTabs = { costs: "modelCosts", modelCostPeriod: "modelCostsOverall", noCompactionCostPeriod: "noCompactionCostsOverall", rateHistory: "historyFiveHour", conversation: "conversationOverview", conversationCostMode: "conversationNormalTurns" };
    const stopMonitorButton = document.getElementById("stopMonitor");
    const turnPageSize = 10;
    let stopped = false;
    let refreshTimer = null;
    let conversationRows = [];
    let selectedConversationKey = null;
    let selectedConversationPage = 1;
    let currentCostBasisMode = "ApiUsdEstimate";

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

    function asArray(value) {
      if (!value) return [];
      return Array.isArray(value) ? value : [value];
    }

    function normalizeUsageData(data) {
      const normalized = { ...(data || {}) };
      [
        "RateLimitRows",
        "RateLimitHistoryRows",
        "RateLimitHistorySummaryRows",
        "RollingTokenRows",
        "ModelTokenRows",
        "NoCompactionModelTokenRows",
        "ModelTokenPeriodRows",
        "NoCompactionModelTokenPeriodRows",
        "ModelTokenPeriodWindows",
        "SourceCostRows",
        "ModelCostTotals",
        "NoCompactionModelCostTotals",
        "ModelPeriodCostTotals",
        "NoCompactionModelPeriodCostTotals",
        "TokenRows"
      ].forEach((key) => {
        normalized[key] = asArray(normalized[key]);
      });

      normalized.ConversationOverviewRows = asArray(normalized.ConversationOverviewRows).map((row) => ({
        ...(row || {}),
        TokenRows: asArray(row?.TokenRows),
        TurnTokenRows: asArray(row?.TurnTokenRows),
        NoCompactionTurnRows: asArray(row?.NoCompactionTurnRows)
      }));

      return normalized;
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
      const safeRows = asArray(rows);
      if (safeRows.length === 0) return `<p class="muted">No data yet.</p>`;
      const head = `<tr>${columns.map((col) => `<th>${esc(col.label)}</th>`).join("")}</tr>`;
      const body = safeRows.map((row) => `<tr>${columns.map((col) => {
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
        { key: "Input", label: "Total input", number: true },
        { key: "CachedInput", label: "Cached input", number: true },
        { key: "NonCachedInput", label: "Non-cached input", number: true },
        { key: "Output", label: "Output", number: true },
        { key: "Reasoning", label: "Reasoning", number: true },
        { key: "Events", label: "Events", number: true },
        { key: "TotalCostUsd", label: "Cost USD", money: true },
        { key: "TotalCostSgd", label: "Cost SGD", money: true },
        { key: "TotalCostCredits", label: "Credits", number: true }
      ]);
    }

    function modelCostTable(rows) {
      return table(rows, [
        { key: "Model", label: "Model" },
        { key: "PricingBand", label: "Pricing band" },
        { key: "PricingMode", label: "Mode" },
        { key: "CostUnit", label: "Unit" },
        { key: "BillingConfidence", label: "Confidence" },
        { key: "Total", label: "Total", number: true },
        { key: "Input", label: "Total input", number: true },
        { key: "CachedInput", label: "Cached input", number: true },
        { key: "NonCachedInput", label: "Non-cached input", number: true },
        { key: "Output", label: "Output", number: true },
        { key: "Reasoning", label: "Reasoning", number: true },
        { key: "Events", label: "Events", number: true },
        { key: "EstimatedCostUsd", label: "Cost USD", money: true },
        { key: "EstimatedCostCredits", label: "Credits", number: true }
      ]);
    }

    function modelCostPeriodId(prefix, period) {
      return `${prefix}${period.replace(/[^A-Za-z0-9]/g, "")}`;
    }

    function modelCostHistoryTitle(period) {
      return period === "Last 5 hours" ? "Previous 5-hour buckets" : period === "This week" ? "Daily buckets" : "Weekly buckets";
    }

    function renderModelCostTotals(total) {
      return `<div class="total">
        <span>totalCostUsd: <strong>${fmtMoney(total.TotalCostUsd || 0)}</strong></span>
        <span>totalCostSgd: <strong>${fmtMoney(total.TotalCostSgd || 0)}</strong></span>
        <span>totalCostCredits: <strong>${fmt(total.TotalCostCredits || 0)}</strong></span>
      </div>`;
    }

    function renderModelCostOverviewPeriod(period, rows, totals) {
      const periodRows = rows.filter((row) => row.Window === period);
      const total = totals.find((row) => row.Window === period) || {};
      return `
        <h3>${esc(period)}</h3>
        ${modelCostTable(periodRows)}
        ${renderModelCostTotals(total)}
      `;
    }

    function renderModelCostPeriod(period, rows, totals, usdToSgdRate, modelPeriodRows, periodTotals) {
      const periodRows = rows.filter((row) => row.Window === period);
      const total = totals.find((row) => row.Window === period) || {};
      const historyRows = modelPeriodRows.filter((row) => row.PeriodGroup === period);
      const historyTotals = periodTotals.filter((row) => row.PeriodGroup === period);
      return `
        <h3>${esc(period)}</h3>
        ${modelCostTable(periodRows)}
        ${renderModelCostTotals(total)}
        <h4>${modelCostHistoryTitle(period)}</h4>
        ${table(historyRows, [
          { key: "PeriodLabel", label: "Period" },
          { key: "Model", label: "Model" },
          { key: "PricingBand", label: "Pricing band" },
          { key: "PricingMode", label: "Mode" },
          { key: "CostUnit", label: "Unit" },
          { key: "BillingConfidence", label: "Confidence" },
          { key: "Total", label: "Total", number: true },
          { key: "Input", label: "Total input", number: true },
          { key: "CachedInput", label: "Cached input", number: true },
          { key: "NonCachedInput", label: "Non-cached input", number: true },
          { key: "Output", label: "Output", number: true },
          { key: "Reasoning", label: "Reasoning", number: true },
          { key: "Events", label: "Events", number: true },
          { key: "EstimatedCostUsd", label: "Cost USD", money: true },
          { key: "EstimatedCostCredits", label: "Credits", number: true }
        ])}
        <h4>Period totals</h4>
        ${renderPeriodTotals(historyTotals, usdToSgdRate)}
      `;
    }

    function renderCostTabs(rows, totals, usdToSgdRate, modelPeriodRows, periodTotals, scope, prefix) {
      rows = asArray(rows);
      totals = asArray(totals);
      modelPeriodRows = asArray(modelPeriodRows);
      periodTotals = asArray(periodTotals);
      const periods = ["Last 5 hours", "This week", "This month"];
      const overallId = `${prefix}Overall`;
      const active = activeTabs[scope] || overallId;
      const tabButtons = [
        { id: overallId, label: "Overall" },
        ...periods.map((period) => ({ id: modelCostPeriodId(prefix, period), label: period }))
      ].map((tab) => `<button class="tab ${active === tab.id ? "active" : ""}" type="button" data-tab-scope="${scope}" data-tab="${tab.id}">${esc(tab.label)}</button>`).join("");
      const overview = periods.map((period) => renderModelCostOverviewPeriod(period, rows, totals)).join("");
      const panels = [
        `<div id="${overallId}" class="tab-panel" data-tab-scope="${scope}" ${active === overallId ? "" : "hidden"}>${overview}</div>`,
        ...periods.map((period) => {
          const id = modelCostPeriodId(prefix, period);
          return `<div id="${id}" class="tab-panel" data-tab-scope="${scope}" ${active === id ? "" : "hidden"}>${renderModelCostPeriod(period, rows, totals, usdToSgdRate, modelPeriodRows, periodTotals)}</div>`;
        })
      ].join("");

      return `<div class="tabs" role="tablist">${tabButtons}</div>${panels}`;
    }

    function renderCosts(rows, totals, usdToSgdRate, modelPeriodRows, periodTotals) {
      return `${renderCostTabs(rows, totals, usdToSgdRate, modelPeriodRows, periodTotals, "modelCostPeriod", "modelCosts")}<p class="source">SGD conversion: 1 USD = ${esc(usdToSgdRate)} SGD.</p>`;
    }

    function renderNoCompactionCosts(rows, totals, usdToSgdRate, modelPeriodRows, periodTotals) {
      return `${renderCostTabs(rows, totals, usdToSgdRate, modelPeriodRows, periodTotals, "noCompactionCostPeriod", "noCompactionCosts")}` +
        `<p class="source">Conservative API no-compaction scenario. Cumulative conversation input switches eligible models to long-context pricing at 270,000 tokens. SGD conversion: 1 USD = ${esc(usdToSgdRate)} SGD.</p>`;
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
            { key: "EstimatedInputTokens", label: "Est. total input", number: true },
            { key: "EstimatedOutputTokens", label: "Est. output", number: true },
            { key: "AllocatedInput", label: "Alloc. total input", number: true },
            { key: "AllocatedCachedInput", label: "Alloc. cached input", number: true },
            { key: "AllocatedNonCachedInput", label: "Alloc. non-cached input", number: true },
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

    function conversationKey(row) {
      return row?.SourceFile || row?.Session || "";
    }

    function renderConversationOverview(rows) {
      if (!rows || rows.length === 0) {
        return `<p class="muted">No session files modified in the last 24 hours.</p>`;
      }

      const body = rows.map((row) => {
        const key = conversationKey(row);
        return `<tr>
          <td>${esc(row.Session)}</td>
          <td>${esc(row.LastModified)}</td>
          <td class="action-cell"><button class="row-action conversation-analyze" type="button" data-conversation-key="${esc(key)}">Analyze</button></td>
        </tr>`;
      }).join("");

      return `<div class="table-scroll"><table>
        <thead><tr><th>Session ID</th><th>Last modified</th><th></th></tr></thead>
        <tbody>${body}</tbody>
      </table></div>`;
    }

    function findSelectedConversation() {
      if (!selectedConversationKey) return null;
      return conversationRows.find((row) => conversationKey(row) === selectedConversationKey) || null;
    }

    function conversationCostValue(row) {
      if (currentCostBasisMode === "CodexCredits") {
        return row?.EstimatedCostCredits ?? null;
      }
      return row?.EstimatedCostUsd ?? null;
    }

    function renderConversationCostSummary(row) {
      const totals = row?.CostTotals || {};
      if (currentCostBasisMode === "CodexCredits") {
        return `<div class="total">
          <span>totalCostCredits: <strong>${fmt(totals.TotalCostCredits || 0)}</strong></span>
        </div>`;
      }

      return `<div class="total">
        <span>totalCostUsd: <strong>${fmtMoney(totals.TotalCostUsd || 0)}</strong></span>
        <span>totalCostSgd: <strong>${fmtMoney(totals.TotalCostSgd || 0)}</strong></span>
      </div>`;
    }

    function renderTurnBreakdown(row) {
      const rows = row?.TurnTokenRows || [];
      if (rows.length === 0) {
        return `<h3>Turn Breakdown</h3><p class="muted">No turn-level token usage found for this session.</p>`;
      }

      const totalPages = Math.max(1, Math.ceil(rows.length / turnPageSize));
      selectedConversationPage = Math.max(1, Math.min(selectedConversationPage, totalPages));
      const start = (selectedConversationPage - 1) * turnPageSize;
      const pageRows = rows.slice(start, start + turnPageSize).map((turn) => ({
        ...turn,
        Cost: conversationCostValue(turn)
      }));
      const costColumn = currentCostBasisMode === "CodexCredits"
        ? { key: "Cost", label: "Turn credits", number: true }
        : { key: "Cost", label: "Turn cost USD", money: true };

      const turnTable = table(pageRows, [
        { key: "Turn", label: "Turn", number: true },
        { key: "Timestamp", label: "Timestamp", date: true },
        { key: "Model", label: "Model" },
        { key: "Input", label: "Total input", number: true },
        { key: "NonCachedInput", label: "Non-cached input", number: true },
        { key: "CachedInput", label: "Cached input", number: true },
        { key: "Output", label: "Output", number: true },
        { key: "Reasoning", label: "Reasoning", number: true },
        costColumn
      ]);

      return `<h3>Turn Breakdown</h3>
        ${renderConversationCostSummary(row)}
        ${turnTable}
        <div class="pager">
          <button class="pager-button conversation-page" type="button" data-page="prev" ${selectedConversationPage <= 1 ? "disabled" : ""}>Previous</button>
          <span class="pager-status">Page ${fmt(selectedConversationPage)} of ${fmt(totalPages)}</span>
          <button class="pager-button conversation-page" type="button" data-page="next" ${selectedConversationPage >= totalPages ? "disabled" : ""}>Next</button>
        </div>`;
    }

    function renderNoCompactionCostSummary(row) {
      const totals = row?.NoCompactionCostTotals || {};
      return `<div class="total">
        <span>totalCostUsd: <strong>${fmtMoney(totals.TotalCostUsd || 0)}</strong></span>
        <span>totalCostSgd: <strong>${fmtMoney(totals.TotalCostSgd || 0)}</strong></span>
      </div>`;
    }

    function renderConversationNoCompaction(row) {
      const rows = row?.NoCompactionTurnRows || [];
      if (rows.length === 0) {
        return `<h3>No-compaction API Scenario</h3><p class="muted">No turn-level token usage found for this session.</p>`;
      }

      const totalPages = Math.max(1, Math.ceil(rows.length / turnPageSize));
      selectedConversationPage = Math.max(1, Math.min(selectedConversationPage, totalPages));
      const start = (selectedConversationPage - 1) * turnPageSize;
      const pageRows = rows.slice(start, start + turnPageSize);
      return `<h3>No-compaction API Scenario</h3>
        ${renderNoCompactionCostSummary(row)}
        ${table(pageRows, [
          { key: "Turn", label: "Turn", number: true },
          { key: "Timestamp", label: "Timestamp", date: true },
          { key: "Model", label: "Model" },
          { key: "PricingBand", label: "Pricing band" },
          { key: "CumulativeInput", label: "Cumulative input", number: true },
          { key: "Input", label: "Turn input", number: true },
          { key: "NonCachedInput", label: "Non-cached input", number: true },
          { key: "CachedInput", label: "Cached input", number: true },
          { key: "Output", label: "Output", number: true },
          { key: "EstimatedCostUsd", label: "Cost USD", money: true },
          { key: "EstimatedCostSgd", label: "Cost SGD", money: true }
        ])}
        <div class="pager">
          <button class="pager-button conversation-page" type="button" data-page="prev" ${selectedConversationPage <= 1 ? "disabled" : ""}>Previous</button>
          <span class="pager-status">Page ${fmt(selectedConversationPage)} of ${fmt(totalPages)}</span>
          <button class="pager-button conversation-page" type="button" data-page="next" ${selectedConversationPage >= totalPages ? "disabled" : ""}>Next</button>
        </div>
        <p class="source">Scenario assumes no compaction and applies API USD pricing. Eligible models switch to long-context pricing when cumulative conversation input reaches 270,000 tokens.</p>`;
    }

    function renderConversationCostMode(row) {
      const active = activeTabs.conversationCostMode || "conversationNormalTurns";
      const tabButtons = [
        { id: "conversationNormalTurns", label: "Normal" },
        { id: "conversationNoCompactionTurns", label: "No-compaction API" }
      ].map((tab) => `<button class="tab ${active === tab.id ? "active" : ""}" type="button" data-tab-scope="conversationCostMode" data-tab="${tab.id}">${esc(tab.label)}</button>`).join("");

      return `<div class="tabs" role="tablist">${tabButtons}</div>
        <div id="conversationNormalTurns" class="tab-panel" data-tab-scope="conversationCostMode" ${active === "conversationNormalTurns" ? "" : "hidden"}>${renderTurnBreakdown(row)}</div>
        <div id="conversationNoCompactionTurns" class="tab-panel" data-tab-scope="conversationCostMode" ${active === "conversationNoCompactionTurns" ? "" : "hidden"}>${renderConversationNoCompaction(row)}</div>`;
    }

    function renderConversationAnalysis(row) {
      const source = document.getElementById("source");
      if (!row) {
        source.textContent = "";
        return `<p class="muted">Choose a session from Overview to analyze its token usage.</p>`;
      }

      source.textContent = "";
      const sourceLine = `<div class="source">
        <div>Session: ${esc(row.Session || "")}</div>
        <div>Source: ${esc(row.SourceFile || "")}</div>
      </div>`;
      const summary = table(row.TokenRows, [
        { key: "Scope", label: "Scope" },
        { key: "Total", label: "Total", number: true },
        { key: "Input", label: "Total input", number: true },
        { key: "CachedInput", label: "Cached input", number: true },
        { key: "NonCachedInput", label: "Non-cached input", number: true },
        { key: "Output", label: "Output", number: true },
        { key: "Reasoning", label: "Reasoning", number: true }
      ]);

      return `${sourceLine}<h3>Overall</h3>${summary}${renderConversationCostMode(row)}`;
    }

    function setConversationTab(tabId) {
      if (!findSelectedConversation() && tabId !== "conversationOverview") {
        tabId = "conversationOverview";
      }
      activeTabs.conversation = tabId;
      document.querySelectorAll(`.tab[data-tab-scope="conversation"]`).forEach((item) => {
        item.classList.toggle("active", item.dataset.tab === tabId);
      });
      const hasSelection = !!findSelectedConversation();
      ["conversationAnalysisTab"].forEach((id) => {
        const tab = document.getElementById(id);
        if (!tab) return;
        tab.disabled = !hasSelection;
        tab.classList.toggle("tab-disabled", !hasSelection);
        tab.classList.toggle("active", tab.dataset.tab === tabId);
      });
      document.querySelectorAll(`.tab-panel[data-tab-scope="conversation"]`).forEach((panel) => {
        panel.hidden = panel.id !== tabId;
      });
    }

    function renderConversationSection() {
      const selected = findSelectedConversation();
      document.getElementById("conversationOverview").innerHTML = renderConversationOverview(conversationRows);
      document.getElementById("conversationTokens").innerHTML = renderConversationAnalysis(selected);
      setConversationTab(activeTabs.conversation || "conversationOverview");
    }

    function activateTab(tab) {
      const tabId = tab.dataset.tab;
      if (!tabId || tab.disabled) return;
      const scope = tab.dataset.tabScope || "";
      if (scope === "conversation") {
        setConversationTab(tabId);
        return;
      }
      activeTabs[scope] = tabId;
      document.querySelectorAll(`.tab[data-tab-scope="${scope}"]`).forEach((item) => {
        item.classList.toggle("active", item.dataset.tab === tabId);
      });
      document.querySelectorAll(`.tab-panel[data-tab-scope="${scope}"]`).forEach((panel) => {
        panel.hidden = panel.id !== tabId;
      });
    }

    function initializeCollapsibleSections() {
      document.querySelectorAll("details[data-collapse-key]").forEach((details) => {
        details.open = false;
      });
    }

    function showStatusMessage(message, kind) {
      const error = document.getElementById("error");
      error.textContent = message;
      error.className = kind === "info" ? "notice" : "error";
      error.style.display = "block";
    }

    document.addEventListener("click", (event) => {
      const analyze = event.target.closest(".conversation-analyze");
      if (analyze) {
        selectedConversationKey = analyze.dataset.conversationKey || null;
        selectedConversationPage = 1;
        renderConversationSection();
        setConversationTab("conversationAnalysis");
        return;
      }

      const pageButton = event.target.closest(".conversation-page");
      if (pageButton && !pageButton.disabled) {
        selectedConversationPage += pageButton.dataset.page === "next" ? 1 : -1;
        renderConversationSection();
        return;
      }

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
        const data = normalizeUsageData(await res.json());
        document.getElementById("monitorState").textContent = "Running";
        error.style.display = "none";
        document.getElementById("updated").textContent = `Updated: ${data.UpdatedAtLocal}`;
        document.getElementById("plan").textContent = `Plan: ${data.PlanType || "unknown"}`;
        currentCostBasisMode = data.CostBasisMode || "ApiUsdEstimate";
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
          { key: "Input", label: "Total input", number: true },
          { key: "CachedInput", label: "Cached input", number: true },
          { key: "NonCachedInput", label: "Non-cached input", number: true },
          { key: "Output", label: "Output", number: true },
          { key: "Reasoning", label: "Reasoning", number: true },
          { key: "Events", label: "Events", number: true }
        ]);
        document.getElementById("rateLimitHistory").innerHTML = renderRateLimitHistory(data.RateLimitHistoryRows, data.RateLimitHistorySummaryRows, data.RateLimitHistoryDays);
        document.getElementById("modelCosts").innerHTML = renderCosts(data.ModelTokenRows, data.ModelCostTotals, data.UsdToSgdRate, data.ModelTokenPeriodRows, data.ModelPeriodCostTotals);
        document.getElementById("noCompactionCosts").innerHTML = renderNoCompactionCosts(data.NoCompactionModelTokenRows, data.NoCompactionModelCostTotals, data.UsdToSgdRate, data.NoCompactionModelTokenPeriodRows, data.NoCompactionModelPeriodCostTotals);
        document.getElementById("sourceCosts").innerHTML = renderSourceCosts(data.SourceCostRows, data.UsdToSgdRate);
        conversationRows = data.ConversationOverviewRows;
        if (selectedConversationKey && !findSelectedConversation()) {
          selectedConversationKey = null;
          activeTabs.conversation = "conversationOverview";
        }
        renderConversationSection();
      } catch (err) {
        error.textContent = `Unable to refresh usage data: ${err.message}`;
        error.style.display = "block";
      }
    }

    initializeCollapsibleSections();
    load();
    refreshTimer = setInterval(load, refreshMs);
