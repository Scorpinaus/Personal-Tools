    const refreshMs = 30000;
    document.getElementById("refresh").textContent = `Refresh: ${refreshMs / 1000}s`;

    const number = new Intl.NumberFormat();
    const dateLabel = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" });
    const monthLabel = new Intl.DateTimeFormat(undefined, { month: "short" });
    const stopMonitorButton = document.getElementById("stopMonitor");
    const rangeLabels = { 90: "last 90 days", 180: "last 180 days", 365: "last year" };
    const dayMs = 24 * 60 * 60 * 1000;
    let selectedDays = 90;
    let stopped = false;
    let refreshTimer = null;
    let loading = false;
    let dailyRows = [];

    function esc(value) {
      return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      }[ch]));
    }

    function fmt(value) {
      return value === null || value === undefined || value === "" ? "" : number.format(Math.round(Number(value) || 0));
    }

    function asArray(value) {
      if (!value) return [];
      return Array.isArray(value) ? value : [value];
    }

    function parseLocalDate(value) {
      const [year, month, day] = String(value || "").split("-").map((part) => Number(part));
      if (!year || !month || !day) return null;
      return new Date(year, month - 1, day);
    }

    function dateKey(date) {
      const pad = (part) => String(part).padStart(2, "0");
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
    }

    function addDays(date, days) {
      const copy = new Date(date);
      copy.setDate(copy.getDate() + days);
      return copy;
    }

    function normalizedDailyRows(rows, days) {
      const today = new Date();
      today.setHours(0, 0, 0, 0);
      const start = addDays(today, -days + 1);
      const byDate = new Map(asArray(rows).map((row) => [row.Date, row]));
      const normalized = [];

      for (let index = 0; index < days; index += 1) {
        const date = addDays(start, index);
        const key = dateKey(date);
        const row = byDate.get(key) || {};
        normalized.push({
          Date: key,
          Total: Number(row.Total || 0),
          Input: Number(row.Input || 0),
          CachedInput: Number(row.CachedInput || 0),
          NonCachedInput: Number(row.NonCachedInput || Math.max(0, Number(row.Input || 0) - Number(row.CachedInput || 0))),
          Output: Number(row.Output || 0),
          Reasoning: Number(row.Reasoning || 0),
          Events: Number(row.Events || 0)
        });
      }

      return normalized;
    }

    function quantile(values, q) {
      if (values.length === 0) return 0;
      return values[Math.floor((values.length - 1) * q)];
    }

    function heatThresholds(rows) {
      const values = rows.map((row) => Number(row.Total || 0)).filter((value) => value > 0).sort((left, right) => left - right);
      if (values.length === 0) return [1, 2, 3, 4];
      const unique = [...new Set(values)];
      if (unique.length === 1) {
        const max = unique[0];
        return [max * 0.25, max * 0.5, max * 0.75, max];
      }
      return [quantile(values, 0.25), quantile(values, 0.5), quantile(values, 0.75), quantile(values, 0.9)];
    }

    function heatLevel(value, thresholds) {
      const tokens = Number(value || 0);
      if (tokens <= 0) return 0;
      if (tokens <= thresholds[0]) return 1;
      if (tokens <= thresholds[1]) return 2;
      if (tokens <= thresholds[2]) return 3;
      return 4;
    }

    function summarize(rows) {
      const total = rows.reduce((sum, row) => sum + Number(row.Total || 0), 0);
      const activeDays = rows.filter((row) => Number(row.Total || 0) > 0).length;
      const average = rows.length ? total / rows.length : 0;
      const busiest = rows.reduce((best, row) => Number(row.Total || 0) > Number(best.Total || 0) ? row : best, rows[0] || { Total: 0 });
      return { total, activeDays, average, busiest };
    }

    function renderSummary(rows) {
      const stats = summarize(rows);
      const busiestDate = parseLocalDate(stats.busiest?.Date);
      const busiestLabel = busiestDate ? dateLabel.format(busiestDate) : "";

      return `
        <div class="metric">
          <span>Total tokens</span>
          <strong>${fmt(stats.total)}</strong>
        </div>
        <div class="metric">
          <span>Daily average</span>
          <strong>${fmt(stats.average)}</strong>
        </div>
        <div class="metric">
          <span>Active days</span>
          <strong>${fmt(stats.activeDays)} / ${fmt(rows.length)}</strong>
        </div>
        <div class="metric">
          <span>Busiest day</span>
          <strong>${fmt(stats.busiest?.Total || 0)}</strong>
          <small>${esc(busiestLabel)}</small>
        </div>
      `;
    }

    function renderHeatmap(rows) {
      if (rows.length === 0) {
        return `<p class="muted">No daily token data yet.</p>`;
      }

      const firstDate = parseLocalDate(rows[0].Date);
      const lastDate = parseLocalDate(rows[rows.length - 1].Date);
      if (!firstDate || !lastDate) {
        return `<p class="muted">Daily token data could not be read.</p>`;
      }

      const displayStart = addDays(firstDate, -firstDate.getDay());
      const displayEnd = addDays(lastDate, 6 - lastDate.getDay());
      const weekCount = Math.ceil((Math.round((displayEnd - displayStart) / dayMs) + 1) / 7);
      const byDate = new Map(rows.map((row) => [row.Date, row]));
      const thresholds = heatThresholds(rows);
      const monthLabels = new Map();
      monthLabels.set(0, monthLabel.format(firstDate));

      for (let cursor = new Date(displayStart); cursor <= displayEnd; cursor = addDays(cursor, 1)) {
        if (cursor < firstDate || cursor > lastDate || cursor.getDate() !== 1) continue;
        const week = Math.floor(Math.round((cursor - displayStart) / dayMs) / 7);
        monthLabels.set(week, monthLabel.format(cursor));
      }

      const monthHtml = [...monthLabels.entries()].map(([week, label]) =>
        `<span style="grid-column: ${week + 1} / span 3;">${esc(label)}</span>`
      ).join("");

      const cells = [];
      for (let cursor = new Date(displayStart); cursor <= displayEnd; cursor = addDays(cursor, 1)) {
        const inRange = cursor >= firstDate && cursor <= lastDate;
        const key = dateKey(cursor);
        const row = byDate.get(key);
        const tokens = row ? Number(row.Total || 0) : 0;
        const level = inRange ? heatLevel(tokens, thresholds) : "outside";
        const label = inRange
          ? `${fmt(tokens)} tokens on ${dateLabel.format(cursor)}`
          : "";
        cells.push(`<span class="heatmap-cell level-${level}" title="${esc(label)}" aria-label="${esc(label)}"></span>`);
      }

      const stats = summarize(rows);
      return `
        <div class="heatmap-scroll">
          <div class="heatmap-months" style="grid-template-columns: repeat(${weekCount}, var(--heat-cell));">${monthHtml}</div>
          <div class="heatmap-body">
            <div class="heatmap-weekdays" aria-hidden="true">
              <span></span><span>Mon</span><span></span><span>Wed</span><span></span><span>Fri</span><span></span>
            </div>
            <div class="heatmap-grid" style="grid-template-columns: repeat(${weekCount}, var(--heat-cell));">${cells.join("")}</div>
          </div>
        </div>
        <div class="heatmap-footer">
          <span>${fmt(stats.total)} tokens in the ${esc(rangeLabels[selectedDays])}</span>
          <div class="heatmap-legend" aria-label="Token usage intensity legend">
            <span>Less</span>
            <span class="heatmap-cell level-0"></span>
            <span class="heatmap-cell level-1"></span>
            <span class="heatmap-cell level-2"></span>
            <span class="heatmap-cell level-3"></span>
            <span class="heatmap-cell level-4"></span>
            <span>More</span>
          </div>
        </div>
      `;
    }

    function table(rows) {
      if (rows.length === 0) return `<p class="muted">No data yet.</p>`;
      const columns = [
        ["Date", "Date"],
        ["Total", "Total"],
        ["Input", "Total input"],
        ["CachedInput", "Cached input"],
        ["NonCachedInput", "Non-cached input"],
        ["Output", "Output"],
        ["Reasoning", "Reasoning"],
        ["Events", "Events"]
      ];
      const head = `<tr>${columns.map(([, label]) => `<th>${esc(label)}</th>`).join("")}</tr>`;
      const body = rows.map((row) => `<tr>${columns.map(([key]) => {
        const value = key === "Date" ? row[key] : fmt(row[key]);
        return `<td>${esc(value)}</td>`;
      }).join("")}</tr>`).join("");
      return `<div class="table-scroll"><table><thead>${head}</thead><tbody>${body}</tbody></table></div>`;
    }

    function renderDailyUsage() {
      const rows = normalizedDailyRows(dailyRows, selectedDays);
      const firstDate = parseLocalDate(rows[0]?.Date);
      const lastDate = parseLocalDate(rows[rows.length - 1]?.Date);
      document.getElementById("dailyRange").textContent = firstDate && lastDate
        ? `Showing ${dateLabel.format(firstDate)} through ${dateLabel.format(lastDate)}. Brighter days used more tokens.`
        : "Showing daily token activity.";
      document.getElementById("dailySummary").innerHTML = renderSummary(rows);
      document.getElementById("dailyHeatmap").innerHTML = renderHeatmap(rows);
      document.getElementById("dailyTable").innerHTML = table([...rows].reverse().slice(0, 30));
    }

    function showStatusMessage(message, kind) {
      const error = document.getElementById("error");
      error.textContent = message;
      error.className = kind === "info" ? "notice" : "error";
      error.style.display = "block";
    }

    document.addEventListener("click", (event) => {
      const segment = event.target.closest(".segment");
      if (!segment) return;
      selectedDays = Number(segment.dataset.days || 90);
      document.querySelectorAll(".segment").forEach((item) => {
        item.classList.toggle("active", Number(item.dataset.days || 0) === selectedDays);
      });
      renderDailyUsage();
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
      if (stopped || loading) return;
      loading = true;
      const error = document.getElementById("error");
      try {
        const res = await fetch("/api/usage", { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        document.getElementById("monitorState").textContent = "Running";
        error.style.display = "none";
        document.getElementById("updated").textContent = `Updated: ${data.UpdatedAtLocal}`;
        document.getElementById("plan").textContent = `Plan: ${data.PlanType || "unknown"}`;
        dailyRows = asArray(data.DailyTokenUsageRows);
        renderDailyUsage();
      } catch (err) {
        error.textContent = `Unable to refresh usage data: ${err.message}`;
        error.style.display = "block";
      } finally {
        loading = false;
      }
    }

    load();
    refreshTimer = setInterval(load, refreshMs);
