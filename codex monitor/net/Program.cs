using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

var options = MonitorOptions.Parse(args);
var monitor = new UsageMonitor(options);

if (options.BackfillRateLimitHistory)
{
    var result = monitor.ImportRateLimitHistoryFromSessions();
    Console.WriteLine($"Rate-limit history backfill imported {result.Imported} observed rows and saved {result.Saved} compressed samples.");
    Console.WriteLine($"History file: {result.Path}");
    if (options.Once)
    {
        return;
    }
}

if (!options.LibraryOnly && !options.ConsoleMode && !options.Once)
{
    var server = new DashboardServer(options, monitor);
    server.Run();
    return;
}

if (!options.LibraryOnly)
{
    do
    {
        var snapshot = monitor.GetLatestSnapshot(forceCostRefresh: options.Once);
        ConsoleRenderer.Show(options, snapshot);
        if (options.Once)
        {
            break;
        }

        Thread.Sleep(TimeSpan.FromSeconds(Math.Max(1, options.RefreshSeconds)));
    } while (true);
}

sealed class MonitorOptions
{
    public string CodexHome { get; set; } =
        Environment.GetEnvironmentVariable("CODEX_HOME")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");

    public int RefreshSeconds { get; set; } = 3;
    public int MaxFiles { get; set; } = 5;
    public int TailLines { get; set; } = 500;
    public int ConversationLookbackHours { get; set; } = 24;
    public int ConversationFallbackLookbackDays { get; set; } = 7;
    public int ConversationFallbackMaxFiles { get; set; } = 5;
    public int ConversationFallbackTailLines { get; set; } = 500;
    public int RollingMaxFiles { get; set; }
    public int RollingTailLines { get; set; }
    public int CostMaxFiles { get; set; }
    public int CostTailLines { get; set; }
    public int CostFiveHourRefreshSeconds { get; set; } = 30;
    public int CostWeekRefreshSeconds { get; set; } = 30;
    public int CostMonthRefreshSeconds { get; set; } = 86400;
    public int RateLimitHistoryDays { get; set; } = 8;
    public int RateLimitHistorySampleSeconds { get; set; } = 30;
    public double UsdToSgdRate { get; set; } = 1.274;
    public string CostBasisMode { get; set; } = "ApiUsdEstimate";
    public string PricingMode { get; set; } = "Standard";
    public bool Once { get; set; }
    public bool IncludeArchived { get; set; }
    public bool LibraryOnly { get; set; }
    public bool ConsoleMode { get; set; }
    public bool NoOpen { get; set; }
    public bool DisableRateLimitHistory { get; set; }
    public bool BackfillRateLimitHistory { get; set; }
    public bool DisableSqliteCache { get; set; }
    public bool RebuildCache { get; set; }
    public int DashboardPort { get; set; } = 8787;
    public string DashboardRoot { get; set; } = Path.Combine(AppContext.BaseDirectory, "dashboard");
    public string CacheDbPath { get; set; } = Path.Combine(GetMonitorDirectory(), "codex_usage_monitor.sqlite");

    public static MonitorOptions Parse(string[] args)
    {
        var options = new MonitorOptions();
        for (var index = 0; index < args.Length; index++)
        {
            var raw = args[index];
            if (!raw.StartsWith("-", StringComparison.Ordinal))
            {
                continue;
            }

            var key = raw.TrimStart('-', '/');
            string? value = null;
            var colon = key.IndexOf(':');
            if (colon >= 0)
            {
                value = key[(colon + 1)..];
                key = key[..colon];
            }
            else if (index + 1 < args.Length && !args[index + 1].StartsWith("-", StringComparison.Ordinal))
            {
                value = args[++index];
            }

            var truthy = value is null || bool.TryParse(value, out var b) && b;
            switch (key.ToLowerInvariant())
            {
                case "codexhome": options.CodexHome = value ?? options.CodexHome; break;
                case "dashboardroot": options.DashboardRoot = value ?? options.DashboardRoot; break;
                case "refreshseconds": options.RefreshSeconds = ToInt(value, options.RefreshSeconds); break;
                case "maxfiles": options.MaxFiles = ToInt(value, options.MaxFiles); break;
                case "taillines": options.TailLines = ToInt(value, options.TailLines); break;
                case "conversationlookbackhours": options.ConversationLookbackHours = ToInt(value, options.ConversationLookbackHours); break;
                case "conversationfallbacklookbackdays": options.ConversationFallbackLookbackDays = ToInt(value, options.ConversationFallbackLookbackDays); break;
                case "conversationfallbackmaxfiles": options.ConversationFallbackMaxFiles = ToInt(value, options.ConversationFallbackMaxFiles); break;
                case "conversationfallbacktaillines": options.ConversationFallbackTailLines = ToInt(value, options.ConversationFallbackTailLines); break;
                case "rollingmaxfiles": options.RollingMaxFiles = ToInt(value, options.RollingMaxFiles); break;
                case "rollingtaillines": options.RollingTailLines = ToInt(value, options.RollingTailLines); break;
                case "costmaxfiles": options.CostMaxFiles = ToInt(value, options.CostMaxFiles); break;
                case "costtaillines": options.CostTailLines = ToInt(value, options.CostTailLines); break;
                case "costfivehourrefreshseconds": options.CostFiveHourRefreshSeconds = ToInt(value, options.CostFiveHourRefreshSeconds); break;
                case "costweekrefreshseconds": options.CostWeekRefreshSeconds = ToInt(value, options.CostWeekRefreshSeconds); break;
                case "costmonthrefreshseconds": options.CostMonthRefreshSeconds = ToInt(value, options.CostMonthRefreshSeconds); break;
                case "ratelimithistorydays": options.RateLimitHistoryDays = ToInt(value, options.RateLimitHistoryDays); break;
                case "ratelimithistorysampleseconds": options.RateLimitHistorySampleSeconds = ToInt(value, options.RateLimitHistorySampleSeconds); break;
                case "usdtosgdrate": options.UsdToSgdRate = ToDouble(value, options.UsdToSgdRate); break;
                case "costbasismode": options.CostBasisMode = Valid(value, "ApiUsdEstimate", "CodexCredits") ? value! : options.CostBasisMode; break;
                case "pricingmode": options.PricingMode = Valid(value, "Standard", "Batch", "Flex", "Priority") ? value! : options.PricingMode; break;
                case "once": options.Once = truthy; break;
                case "includearchived": options.IncludeArchived = truthy; break;
                case "libraryonly": options.LibraryOnly = truthy; break;
                case "console": options.ConsoleMode = truthy; break;
                case "noopen": options.NoOpen = truthy; break;
                case "disableratelimithistory": options.DisableRateLimitHistory = truthy; break;
                case "backfillratelimithistory": options.BackfillRateLimitHistory = truthy; break;
                case "disablesqlitecache": options.DisableSqliteCache = truthy; break;
                case "rebuildcache": options.RebuildCache = truthy; break;
                case "cachedbpath": options.CacheDbPath = value ?? options.CacheDbPath; break;
                case "dashboardport":
                case "port": options.DashboardPort = ToInt(value, options.DashboardPort); break;
            }
        }

        return options;
    }

    static int ToInt(string? value, int fallback) => int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var result) ? result : fallback;
    static double ToDouble(string? value, double fallback) => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var result) ? result : fallback;
    static bool Valid(string? value, params string[] values) => value is not null && values.Any(v => string.Equals(v, value, StringComparison.OrdinalIgnoreCase));

    static string GetMonitorDirectory()
    {
        var baseDirectory = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        for (var directory = new DirectoryInfo(baseDirectory); directory is not null; directory = directory.Parent)
        {
            if (File.Exists(Path.Combine(directory.FullName, "codex_usage_monitor.ps1")) ||
                File.Exists(Path.Combine(directory.FullName, "start_codex_monitor.cmd")))
            {
                return directory.FullName;
            }
        }

        return baseDirectory;
    }
}

sealed class UsageMonitor
{
    public const long LongContextThresholdTokens = 270_000;
    const string NoCompactionCostBasisMode = "ApiNoCompactionUsdEstimate";

    readonly MonitorOptions _options;
    readonly Dictionary<string, CacheEntry<TokenBucket>> _windowCostCache = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, CacheEntry<TokenBucket>> _noCompactionWindowCostCache = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, CacheEntry<TokenBucket>> _periodCostCache = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, CacheEntry<TokenBucket>> _noCompactionPeriodCostCache = new(StringComparer.OrdinalIgnoreCase);
    readonly SqliteUsageCache? _usageCache;

    public UsageMonitor(MonitorOptions options)
    {
        _options = options;
        if (_options.DisableSqliteCache)
        {
            return;
        }

        try
        {
            _usageCache = new SqliteUsageCache(_options.CacheDbPath);
            _usageCache.Initialize(_options.RebuildCache);
        }
        catch (Exception ex)
        {
            if (_options.Once || _options.ConsoleMode)
            {
                Console.Error.WriteLine($"SQLite cache disabled; falling back to JSONL scanning. {ex.Message}");
            }

            _usageCache = null;
        }
    }

    public Snapshot? GetLatestSnapshot(bool forceCostRefresh = false)
    {
        var nowUtc = DateTime.UtcNow;
        SyncUsageCache();
        var searches = new List<SearchPlan>();
        var overviewFiles = new List<FileInfo>();

        if (_options.ConversationLookbackHours > 0)
        {
            var since = nowUtc.AddHours(-_options.ConversationLookbackHours);
            overviewFiles = GetSessionFilesSince(since).ToList();
            searches.Add(new SearchPlan(overviewFiles, 0, since));
        }

        if (_options.ConversationFallbackLookbackDays > 0)
        {
            var since = nowUtc.AddDays(-_options.ConversationFallbackLookbackDays);
            searches.Add(new SearchPlan(GetSessionFilesSince(since).ToList(), 0, since));
        }

        var legacyLimit = _options.ConversationFallbackMaxFiles > 0 ? _options.ConversationFallbackMaxFiles : _options.MaxFiles;
        var legacyTail = _options.ConversationFallbackTailLines > 0 ? _options.ConversationFallbackTailLines : _options.TailLines;
        searches.Add(new SearchPlan(GetSessionFiles(legacyLimit).ToList(), legacyTail, DateTime.MinValue));

        foreach (var search in searches)
        {
            if (search.Files.Count == 0)
            {
                continue;
            }

            var matches = GetLatestConversationUsageMatches(search.Files, search.Tail, search.SinceUtc);
            var usageMatch = matches.Usage;
            var rateLimitMatch = matches.RateLimit;
            var sourceMatch = usageMatch ?? rateLimitMatch;
            if (sourceMatch is null)
            {
                continue;
            }

            var rateLimits = rateLimitMatch?.RateLimits ?? usageMatch?.RateLimits;
            var modelRows = GetCachedTokenUsageByModel(forceCostRefresh);
            var noCompactionModelRows = GetCachedNoCompactionTokenUsageByModel(forceCostRefresh);
            var periodWindows = GetModelPeriodWindowDefinitions();
            var modelPeriodRows = GetCachedTokenUsageByModelPeriods(forceCostRefresh);
            var noCompactionModelPeriodRows = GetCachedNoCompactionTokenUsageByModelPeriods(forceCostRefresh);

            var snapshot = new Snapshot
            {
                Timestamp = sourceMatch.EventTimestampText,
                SourceFile = sourceMatch.SourceFile,
                Session = sourceMatch.Session,
                PlanType = JsonTools.GetString(rateLimits, "plan_type", "planType") ?? GetLatestPlanType(legacyLimit, legacyTail),
                RateLimitRows = ConvertRateLimits(rateLimits),
                RollingTokenRows = GetRollingTokenUsage(_options.RollingMaxFiles, _options.RollingTailLines),
                ModelTokenRows = modelRows,
                NoCompactionModelTokenRows = noCompactionModelRows,
                ModelTokenPeriodRows = modelPeriodRows,
                NoCompactionModelTokenPeriodRows = noCompactionModelPeriodRows,
                ModelTokenPeriodWindows = periodWindows,
                SourceCostRows = GetTokenSourceCostEstimates(_options.CostMaxFiles, _options.CostTailLines, modelRows),
                CostBasis = _options.CostBasisMode == "CodexCredits"
                    ? "Codex credit equivalent for paid/extra usage"
                    : "API-equivalent USD estimate for ChatGPT/Codex subscription usage",
                CostBasisMode = _options.CostBasisMode,
                PricingMode = _options.PricingMode,
                PricingSource = _options.CostBasisMode == "CodexCredits"
                    ? "https://help.openai.com/en/articles/20001106-codex-rate-card"
                    : "https://openai.com/api/pricing/",
                RegionalUpliftApplied = false,
                TokenRows = usageMatch is null ? [] : ConvertConversationUsageRows(usageMatch),
                ContextWindow = usageMatch?.ContextWindow,
                ConversationOverviewRows = GetConversationOverviewRows(overviewFiles)
            };

            WriteRateLimitHistorySamples(snapshot);
            snapshot.RateLimitHistoryRows = GetRateLimitHistoryRows(_options.RateLimitHistoryDays);
            snapshot.RateLimitHistorySummaryRows = GetRateLimitHistorySummary(snapshot.RateLimitHistoryRows);
            snapshot.RateLimitHistoryDays = _options.RateLimitHistoryDays;
            snapshot.RateLimitHistorySampleSeconds = _options.RateLimitHistorySampleSeconds;
            return snapshot;
        }

        return null;
    }

    public BackfillResult ImportRateLimitHistoryFromSessions()
    {
        var path = GetRateLimitHistoryPath();
        if (_options.DisableRateLimitHistory)
        {
            return new BackfillResult(0, 0, path, true);
        }

        SyncUsageCache();
        var existing = GetRateLimitHistoryRows(_options.RateLimitHistoryDays);
        var backfill = GetRateLimitHistoryRowsFromSessions(_options.RateLimitHistoryDays);
        var merged = CompressRateLimitHistoryRows(existing.Concat(backfill), _options.RateLimitHistorySampleSeconds).ToList();
        SaveRateLimitHistoryRows(merged);
        return new BackfillResult(backfill.Count, merged.Count, path, false);
    }

    void SyncUsageCache()
    {
        if (_usageCache is null || !_usageCache.IsAvailable)
        {
            return;
        }

        try
        {
            _usageCache.SyncFiles(GetSessionFiles(0), IsArchivedSessionPath, ReadSessionUsageDeltasFromJsonl);
        }
        catch
        {
            _usageCache.Disable();
        }
    }

    bool IsArchivedSessionPath(string path)
    {
        var archivedRoot = Path.Combine(_options.CodexHome, "archived_sessions");
        return path.StartsWith(archivedRoot, StringComparison.OrdinalIgnoreCase);
    }

    List<TokenBucket> GetCachedTokenUsageByModel(bool force)
    {
        var now = DateTime.Now;
        var windows = GetCostWindowDefinitions().ToList();
        var dueNames = new List<string>();
        foreach (var window in windows)
        {
            var due = force || !_windowCostCache.TryGetValue(window.Name, out var cache) || (now - cache.UpdatedAt).TotalSeconds >= window.RefreshSeconds;
            if (due)
            {
                dueNames.Add(window.Name);
            }
        }

        if (dueNames.Count > 0)
        {
            var fresh = GetTokenUsageByModel(_options.CostMaxFiles, _options.CostTailLines, dueNames.ToArray());
            foreach (var name in dueNames)
            {
                _windowCostCache[name] = new CacheEntry<TokenBucket>(now, fresh.Where(r => r.Window == name).ToList());
            }
        }

        return windows.Where(w => _windowCostCache.ContainsKey(w.Name)).SelectMany(w => _windowCostCache[w.Name].Rows).ToList();
    }

    List<TokenBucket> GetCachedNoCompactionTokenUsageByModel(bool force)
    {
        var now = DateTime.Now;
        var windows = GetCostWindowDefinitions().ToList();
        var dueNames = new List<string>();
        foreach (var window in windows)
        {
            var due = force || !_noCompactionWindowCostCache.TryGetValue(window.Name, out var cache) || (now - cache.UpdatedAt).TotalSeconds >= window.RefreshSeconds;
            if (due)
            {
                dueNames.Add(window.Name);
            }
        }

        if (dueNames.Count > 0)
        {
            var fresh = GetNoCompactionTokenUsageByModel(_options.CostMaxFiles, dueNames.ToArray());
            foreach (var name in dueNames)
            {
                _noCompactionWindowCostCache[name] = new CacheEntry<TokenBucket>(now, fresh.Where(r => r.Window == name).ToList());
            }
        }

        return windows.Where(w => _noCompactionWindowCostCache.ContainsKey(w.Name)).SelectMany(w => _noCompactionWindowCostCache[w.Name].Rows).ToList();
    }

    List<TokenBucket> GetCachedTokenUsageByModelPeriods(bool force)
    {
        var now = DateTime.Now;
        var windows = GetModelPeriodWindowDefinitions().ToList();
        var groups = windows.Select(w => w.Group).Distinct().ToList();
        var dueGroups = new List<string>();
        foreach (var group in groups)
        {
            var refresh = windows.First(w => w.Group == group).RefreshSeconds;
            var due = force || !_periodCostCache.TryGetValue(group, out var cache) || (now - cache.UpdatedAt).TotalSeconds >= refresh;
            if (due)
            {
                dueGroups.Add(group);
            }
        }

        if (dueGroups.Count > 0)
        {
            var dueWindows = windows.Where(w => dueGroups.Contains(w.Group)).ToList();
            var fresh = GetTokenUsageByModelPeriod(_options.CostMaxFiles, _options.CostTailLines, dueWindows);
            foreach (var group in dueGroups)
            {
                _periodCostCache[group] = new CacheEntry<TokenBucket>(now, fresh.Where(r => r.PeriodGroup == group).ToList());
            }
        }

        return groups.Where(g => _periodCostCache.ContainsKey(g)).SelectMany(g => _periodCostCache[g].Rows).ToList();
    }

    List<TokenBucket> GetCachedNoCompactionTokenUsageByModelPeriods(bool force)
    {
        var now = DateTime.Now;
        var windows = GetModelPeriodWindowDefinitions().ToList();
        var groups = windows.Select(w => w.Group).Distinct().ToList();
        var dueGroups = new List<string>();
        foreach (var group in groups)
        {
            var refresh = windows.First(w => w.Group == group).RefreshSeconds;
            var due = force || !_noCompactionPeriodCostCache.TryGetValue(group, out var cache) || (now - cache.UpdatedAt).TotalSeconds >= refresh;
            if (due)
            {
                dueGroups.Add(group);
            }
        }

        if (dueGroups.Count > 0)
        {
            var dueWindows = windows.Where(w => dueGroups.Contains(w.Group)).ToList();
            var fresh = GetNoCompactionTokenUsageByModelPeriod(_options.CostMaxFiles, dueWindows);
            foreach (var group in dueGroups)
            {
                _noCompactionPeriodCostCache[group] = new CacheEntry<TokenBucket>(now, fresh.Where(r => r.PeriodGroup == group).ToList());
            }
        }

        return groups.Where(g => _noCompactionPeriodCostCache.ContainsKey(g)).SelectMany(g => _noCompactionPeriodCostCache[g].Rows).ToList();
    }

    List<RateLimitRow> ConvertRateLimits(JsonElement? rateLimits)
    {
        if (rateLimits is null)
        {
            return [];
        }

        var source = JsonTools.GetElement(rateLimits, "rate_limit", "rateLimit") ?? rateLimits;
        var rows = new List<RateLimitRow>();
        var primary = ConvertWindow("5 hour", JsonTools.GetElement(source, "primary", "primary_window", "primaryWindow"));
        if (primary is not null) rows.Add(primary);
        var secondary = ConvertWindow("1 week", JsonTools.GetElement(source, "secondary", "secondary_window", "secondaryWindow"));
        if (secondary is not null) rows.Add(secondary);
        return rows;
    }

    static RateLimitRow? ConvertWindow(string name, JsonElement? window)
    {
        if (window is null)
        {
            return null;
        }

        var usedPercent = JsonTools.GetDouble(window, "used_percent", "usedPercent");
        var minutes = JsonTools.GetDouble(window, "window_minutes", "windowDurationMins", "windowMinutes");
        var seconds = JsonTools.GetDouble(window, "limit_window_seconds", "window_seconds", "windowSeconds");
        var resetEpoch = JsonTools.GetLong(window, "resets_at", "reset_at", "resetsAt", "resetAt");
        if (minutes is null && seconds is not null)
        {
            minutes = seconds / 60.0;
        }

        if (usedPercent is null && minutes is null && resetEpoch is null)
        {
            return null;
        }

        var used = usedPercent ?? 0.0;
        return new RateLimitRow
        {
            Window = name,
            UsedPercent = Math.Round(used, 2),
            RemainingPercent = Math.Round(Math.Max(0.0, Math.Min(100.0, 100.0 - used)), 2),
            WindowMinutes = minutes,
            ResetsAt = resetEpoch is null ? null : DateTimeOffset.FromUnixTimeSeconds(resetEpoch.Value).LocalDateTime
        };
    }

    List<TokenUsageRow> ConvertConversationUsageRows(ConversationUsageMatch match)
    {
        var rows = new List<TokenUsageRow>();
        var total = ConvertTokenUsage("Conversation total", match.TotalUsage);
        if (total is not null) rows.Add(total);
        var last = ConvertTokenUsage("Last update", match.LastUsage);
        if (last is not null) rows.Add(last);
        return rows;
    }

    static TokenUsageRow? ConvertTokenUsage(string label, JsonElement? usage)
    {
        if (usage is null)
        {
            return null;
        }

        return new TokenUsageRow
        {
            Scope = label,
            Total = JsonTools.GetNullableLong(usage, "total_tokens", "totalTokens"),
            Input = JsonTools.GetNullableLong(usage, "input_tokens", "inputTokens"),
            CachedInput = JsonTools.GetNullableLong(usage, "cached_input_tokens", "cachedInputTokens"),
            Output = JsonTools.GetNullableLong(usage, "output_tokens", "outputTokens"),
            Reasoning = JsonTools.GetNullableLong(usage, "reasoning_output_tokens", "reasoningOutputTokens")
        };
    }

    List<ConversationOverviewRow> GetConversationOverviewRows(IEnumerable<FileInfo> files)
    {
        var rows = new List<ConversationOverviewRow>();
        foreach (var file in files)
        {
            var matches = GetLatestConversationUsageMatches([file], 0, DateTime.MinValue);
            var turnRows = GetConversationTurnTokenRows(file.FullName);
            var noCompactionTurnRows = GetNoCompactionTurnTokenRows(turnRows);
            rows.Add(new ConversationOverviewRow
            {
                Session = Path.GetFileNameWithoutExtension(file.Name),
                LastModified = file.LastWriteTime,
                SourceFile = file.FullName,
                TokenRows = matches.Usage is null ? [] : ConvertConversationUsageRows(matches.Usage),
                TurnTokenRows = turnRows,
                CostTotals = new ConversationCostTotals(GetTotalEstimatedCostUsd(turnRows), GetTotalEstimatedCostCredits(turnRows)),
                NoCompactionTurnRows = noCompactionTurnRows,
                NoCompactionCostTotals = new ConversationCostTotals(GetTotalEstimatedCostUsd(noCompactionTurnRows), 0),
                ContextWindow = matches.Usage?.ContextWindow,
                LatestUsageTimestamp = matches.Usage?.Timestamp
            });
        }

        return rows;
    }

    List<NoCompactionTurnTokenRow> GetNoCompactionTurnTokenRows(IEnumerable<TurnTokenRow> turnRows)
    {
        var rows = new List<NoCompactionTurnTokenRow>();
        long cumulativeInput = 0;
        foreach (var turn in turnRows.OrderBy(row => row.Turn))
        {
            var before = cumulativeInput;
            cumulativeInput += turn.Input;
            var band = GetNoCompactionPricingBand(turn.Model, cumulativeInput);
            var pricing = GetApiModelPricing(turn.Model, band);
            double? cost = null;
            if (pricing is not null)
            {
                cost = Math.Round(
                    turn.NonCachedInput * pricing.InputPerMillion / 1_000_000.0 +
                    turn.CachedInput * pricing.CachedInputPerMillion / 1_000_000.0 +
                    turn.Output * pricing.OutputPerMillion / 1_000_000.0,
                    4);
            }

            rows.Add(new NoCompactionTurnTokenRow
            {
                Turn = turn.Turn,
                Timestamp = turn.Timestamp,
                Model = turn.Model,
                PricingBand = band,
                PricingMode = _options.PricingMode,
                CostUnit = pricing?.Unit,
                BillingConfidence = pricing is null ? "Low" : "Scenario",
                Total = turn.Total,
                Input = turn.Input,
                CachedInput = turn.CachedInput,
                NonCachedInput = turn.NonCachedInput,
                Output = turn.Output,
                Reasoning = turn.Reasoning,
                CumulativeInputBeforeTurn = before,
                CumulativeInput = cumulativeInput,
                ThresholdTokens = LongContextThresholdTokens,
                EstimatedCost = cost,
                EstimatedCostUsd = cost,
                EstimatedCostCredits = null
            });
        }

        return rows;
    }

    List<TurnTokenRow> GetConversationTurnTokenRows(string path)
    {
        var rows = new List<TurnTokenRow>();
        var turn = 0;
        foreach (var usageEvent in GetSessionUsageDeltas(path))
        {
            turn++;
            var metrics = usageEvent.Metrics;
            var model = string.IsNullOrWhiteSpace(usageEvent.Model) ? "unknown" : usageEvent.Model;
            var pricingBand = GetPricingBand(model, metrics.Input);
            var bucket = NewTokenBucket("Conversation", model, pricingBand);
            AddTokenMetrics(bucket, metrics);
            SetEstimatedCost(bucket);
            rows.Add(new TurnTokenRow
            {
                Turn = turn,
                Timestamp = usageEvent.Timestamp,
                Model = model,
                PricingBand = bucket.PricingBand,
                PricingMode = bucket.PricingMode,
                CostUnit = bucket.CostUnit,
                BillingConfidence = bucket.BillingConfidence,
                Total = metrics.Total,
                Input = metrics.Input,
                CachedInput = metrics.CachedInput,
                NonCachedInput = Math.Max(0, metrics.Input - metrics.CachedInput),
                Output = metrics.Output,
                Reasoning = metrics.Reasoning,
                EstimatedCost = bucket.EstimatedCost,
                EstimatedCostUsd = bucket.EstimatedCostUsd,
                EstimatedCostCredits = bucket.EstimatedCostCredits
            });
        }

        return rows;
    }

    ConversationMatches GetLatestConversationUsageMatches(IReadOnlyList<FileInfo> files, int tail, DateTime sinceUtc)
    {
        ConversationUsageMatch? latestUsage = null;
        ConversationUsageMatch? latestRateLimit = null;
        foreach (var file in files)
        {
            var lines = ReadSessionLines(file.FullName, tail);
            for (var index = lines.Count - 1; index >= 0; index--)
            {
                using var doc = ParseJsonLine(lines[index]);
                if (doc is null)
                {
                    continue;
                }

                var entry = doc.RootElement;
                var eventTime = GetEventTime(entry);
                if (sinceUtc != DateTime.MinValue && eventTime is not null && eventTime.Value < sinceUtc)
                {
                    continue;
                }

                var payload = JsonTools.GetElement(entry, "payload");
                if (payload is null)
                {
                    continue;
                }

                var rateLimits = JsonTools.GetElement(payload, "rate_limits", "rateLimitStatus", "rate_limit_status");
                var info = JsonTools.GetElement(payload, "info");
                var totalUsage = JsonTools.GetElement(info, "total_token_usage", "totalTokenUsage");
                var lastUsage = JsonTools.GetElement(info, "last_token_usage", "lastTokenUsage");
                if (rateLimits is null && totalUsage is null && lastUsage is null)
                {
                    continue;
                }

                var match = new ConversationUsageMatch
                {
                    Timestamp = eventTime,
                    EventTimestampText = JsonTools.GetString(entry, "timestamp"),
                    SourceFile = file.FullName,
                    Session = Path.GetFileNameWithoutExtension(file.Name),
                    RateLimits = JsonTools.Clone(rateLimits),
                    TotalUsage = JsonTools.Clone(totalUsage),
                    LastUsage = JsonTools.Clone(lastUsage),
                    ContextWindow = JsonTools.GetRawValue(JsonTools.GetElement(info, "model_context_window", "modelContextWindow"))
                };

                if ((totalUsage is not null || lastUsage is not null) && (latestUsage is null || CompareNullableTime(match.Timestamp, latestUsage.Timestamp) >= 0))
                {
                    latestUsage = match;
                }

                if (rateLimits is not null && (latestRateLimit is null || CompareNullableTime(match.Timestamp, latestRateLimit.Timestamp) >= 0))
                {
                    latestRateLimit = match;
                }
            }
        }

        return new ConversationMatches(latestUsage, latestRateLimit);
    }

    static int CompareNullableTime(DateTime? left, DateTime? right) => (left ?? DateTime.MinValue).CompareTo(right ?? DateTime.MinValue);

    List<UsageDeltaEvent> GetSessionUsageDeltas(string path)
    {
        if (_usageCache is not null && _usageCache.TryGetUsageDeltas(path, out var rows))
        {
            return rows;
        }

        return ReadSessionUsageDeltasFromJsonl(path).Events;
    }

    UsageParseResult ReadSessionUsageDeltasFromJsonl(string path)
    {
        var currentModel = GetSessionInitialModel(path);
        UsageMetrics? previousTotal = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var rows = new List<UsageDeltaEvent>();
        var rateLimitRows = new List<RateLimitEvent>();
        var sourceEstimateRows = new List<SourceEstimateEvent>();
        var eventIndex = 0;
        var rateLimitEventIndex = 0;
        var sourceEventIndex = 0;
        long cumulativeInput = 0;
        DateTime? lastEventUtc = null;
        var lines = ReadSessionLines(path, 0);

        foreach (var line in lines)
        {
            if (line.Contains("\"turn_context\"", StringComparison.Ordinal))
            {
                var model = ExtractJsonString(line, "model");
                if (!string.IsNullOrWhiteSpace(model))
                {
                    currentModel = model;
                }
            }

            var mayHaveTokenUsage = line.Contains("\"total_token_usage\"", StringComparison.Ordinal) || line.Contains("\"last_token_usage\"", StringComparison.Ordinal);
            var mayHaveRateLimits =
                line.Contains("\"rate_limits\"", StringComparison.Ordinal) ||
                line.Contains("\"rateLimitStatus\"", StringComparison.Ordinal) ||
                line.Contains("\"rate_limit_status\"", StringComparison.Ordinal);
            var mayHaveSourceEstimate = LineMayHaveSourceEstimate(line);
            if (!mayHaveTokenUsage && !mayHaveRateLimits && !mayHaveSourceEstimate)
            {
                continue;
            }

            using var doc = ParseJsonLine(line);
            if (doc is null)
            {
                continue;
            }

            var entry = doc.RootElement;
            var eventTime = GetEventTime(entry);
            if (eventTime is null)
            {
                continue;
            }

            if (lastEventUtc is null || eventTime.Value > lastEventUtc.Value)
            {
                lastEventUtc = eventTime.Value;
            }

            if (mayHaveRateLimits)
            {
                var payload = JsonTools.GetElement(entry, "payload");
                var rateLimits = JsonTools.GetElement(payload, "rate_limits", "rateLimitStatus", "rate_limit_status");
                if (rateLimits is not null)
                {
                    var planType = JsonTools.GetString(rateLimits, "plan_type", "planType");
                    foreach (var rateRow in ConvertRateLimits(rateLimits))
                    {
                        rateLimitEventIndex++;
                        rateLimitRows.Add(new RateLimitEvent(
                            eventTime.Value,
                            JsonTools.GetString(entry, "timestamp"),
                            planType,
                            rateRow.Window,
                            rateRow.UsedPercent,
                            rateRow.RemainingPercent,
                            rateRow.WindowMinutes,
                            FormatDisplayDateTime(rateRow.ResetsAt),
                            rateLimitEventIndex));
                    }
                }
            }

            if (mayHaveSourceEstimate)
            {
                var estimate = GetSourceEstimateFromEntry(entry);
                if (estimate is not null)
                {
                    sourceEventIndex++;
                    sourceEstimateRows.Add(new SourceEstimateEvent(
                        eventTime.Value,
                        currentModel,
                        estimate.Source,
                        estimate.Side,
                        estimate.Tokens,
                        estimate.Chars,
                        estimate.Attribution,
                        sourceEventIndex));
                }
            }

            if (!mayHaveTokenUsage || !IsTokenCountEvent(entry))
            {
                continue;
            }

            var currentTotal = GetUsageMetricsFromEntry(entry, "total_token_usage", "totalTokenUsage");
            if (currentTotal is not null)
            {
                var lastUsage = GetUsageMetricsFromEntry(entry, "last_token_usage", "lastTokenUsage");
                var key = $"{eventTime.Value:o}|{MetricsKey(currentTotal)}|{MetricsKey(lastUsage)}";
                if (!seen.Add(key) || SameMetrics(previousTotal, currentTotal))
                {
                    continue;
                }

                var delta = GetUsageDeltaMetrics(previousTotal, currentTotal, lastUsage);
                previousTotal = currentTotal;
                if (delta is null)
                {
                    continue;
                }

                eventIndex++;
                cumulativeInput += delta.Input;
                rows.Add(new UsageDeltaEvent(eventTime.Value, currentModel, delta, eventIndex, cumulativeInput));
            }
        }

        return new UsageParseResult(rows, rateLimitRows, sourceEstimateRows, lines.Count, lastEventUtc);
    }

    List<TokenBucket> GetRollingTokenUsage(int limit, int tail)
    {
        var now = DateTime.UtcNow;
        var fiveHourCutoff = now.AddHours(-5);
        var weekCutoff = GetLocalWindowStartUtc("This week");
        var monthCutoff = GetLocalWindowStartUtc("This month");
        var fiveHour = NewTokenBucket("Last 5 hours");
        var week = NewTokenBucket("This week");
        var month = NewTokenBucket("This month");

        foreach (var file in GetSessionFiles(limit))
        {
            if (file.LastWriteTimeUtc < monthCutoff)
            {
                continue;
            }

            foreach (var usageEvent in GetSessionUsageDeltas(file.FullName))
            {
                if (usageEvent.Timestamp >= weekCutoff) AddTokenMetrics(week, usageEvent.Metrics);
                if (usageEvent.Timestamp >= monthCutoff) AddTokenMetrics(month, usageEvent.Metrics);
                if (usageEvent.Timestamp >= fiveHourCutoff) AddTokenMetrics(fiveHour, usageEvent.Metrics);
            }
        }

        return [fiveHour, week, month];
    }

    List<TokenBucket> GetTokenUsageByModel(int limit, int tail, string[] windowNames)
    {
        var windows = GetCostWindowDefinitions(windowNames).ToList();
        if (windows.Count == 0)
        {
            return [];
        }

        var oldestStart = windows.Min(w => w.StartUtc);
        var buckets = new Dictionary<string, TokenBucket>(StringComparer.Ordinal);
        foreach (var file in GetSessionFiles(limit))
        {
            if (file.LastWriteTimeUtc < oldestStart)
            {
                continue;
            }

            foreach (var usageEvent in GetSessionUsageDeltas(file.FullName))
            {
                if (usageEvent.Timestamp < oldestStart)
                {
                    continue;
                }

                foreach (var window in windows)
                {
                    if (usageEvent.Timestamp < window.StartUtc)
                    {
                        continue;
                    }

                    var band = GetPricingBand(usageEvent.Model, usageEvent.Metrics.Input);
                    var key = $"{window.Name}|{usageEvent.Model}|{band}";
                    if (!buckets.TryGetValue(key, out var bucket))
                    {
                        bucket = NewTokenBucket(window.Name, usageEvent.Model, band);
                        buckets[key] = bucket;
                    }

                    AddTokenMetrics(bucket, usageEvent.Metrics);
                }
            }
        }

        foreach (var bucket in buckets.Values)
        {
            SetEstimatedCost(bucket);
        }

        return buckets.Values.OrderBy(b => b.Window).ThenBy(b => b.Model).ToList();
    }

    List<TokenBucket> GetNoCompactionTokenUsageByModel(int limit, string[] windowNames)
    {
        var windows = GetCostWindowDefinitions(windowNames).ToList();
        if (windows.Count == 0)
        {
            return [];
        }

        var oldestStart = windows.Min(w => w.StartUtc);
        var buckets = new Dictionary<string, TokenBucket>(StringComparer.Ordinal);
        foreach (var file in GetSessionFiles(limit))
        {
            if (file.LastWriteTimeUtc < oldestStart)
            {
                continue;
            }

            long cumulativeInput = 0;
            foreach (var usageEvent in GetSessionUsageDeltas(file.FullName))
            {
                cumulativeInput += usageEvent.Metrics.Input;
                if (usageEvent.Timestamp < oldestStart)
                {
                    continue;
                }

                var band = GetNoCompactionPricingBand(usageEvent.Model, cumulativeInput);
                foreach (var window in windows)
                {
                    if (usageEvent.Timestamp < window.StartUtc)
                    {
                        continue;
                    }

                    var key = $"{window.Name}|{usageEvent.Model}|{band}";
                    if (!buckets.TryGetValue(key, out var bucket))
                    {
                        bucket = NewTokenBucket(window.Name, usageEvent.Model, band);
                        bucket.CostBasisMode = NoCompactionCostBasisMode;
                        buckets[key] = bucket;
                    }

                    AddTokenMetrics(bucket, usageEvent.Metrics);
                }
            }
        }

        foreach (var bucket in buckets.Values)
        {
            SetNoCompactionEstimatedCost(bucket);
        }

        return buckets.Values.OrderBy(b => b.Window).ThenBy(b => b.Model).ThenBy(b => b.PricingBand).ToList();
    }

    List<TokenBucket> GetTokenUsageByModelPeriod(int limit, int tail, IReadOnlyList<PeriodWindow> windows)
    {
        if (windows.Count == 0)
        {
            return [];
        }

        var oldestStart = windows.Min(w => w.StartUtc);
        var newestEnd = windows.Max(w => w.EndUtc);
        var buckets = new Dictionary<string, TokenBucket>(StringComparer.Ordinal);

        foreach (var file in GetSessionFiles(limit))
        {
            if (file.LastWriteTimeUtc < oldestStart)
            {
                continue;
            }

            foreach (var usageEvent in GetSessionUsageDeltas(file.FullName))
            {
                if (usageEvent.Timestamp < oldestStart || usageEvent.Timestamp >= newestEnd)
                {
                    continue;
                }

                foreach (var window in windows)
                {
                    if (usageEvent.Timestamp < window.StartUtc || usageEvent.Timestamp >= window.EndUtc)
                    {
                        continue;
                    }

                    var band = GetPricingBand(usageEvent.Model, usageEvent.Metrics.Input);
                    var key = $"{window.Name}|{usageEvent.Model}|{band}";
                    if (!buckets.TryGetValue(key, out var bucket))
                    {
                        bucket = NewTokenBucket(window.Group, usageEvent.Model, band);
                        bucket.PeriodGroup = window.Group;
                        bucket.PeriodName = window.Name;
                        bucket.PeriodLabel = window.Label;
                        bucket.PeriodStartUtc = window.StartUtc;
                        bucket.PeriodEndUtc = window.EndUtc;
                        bucket.PeriodSortOrder = window.SortOrder;
                        buckets[key] = bucket;
                    }

                    AddTokenMetrics(bucket, usageEvent.Metrics);
                }
            }
        }

        foreach (var bucket in buckets.Values)
        {
            SetEstimatedCost(bucket);
        }

        return buckets.Values.OrderBy(b => b.PeriodGroup).ThenBy(b => b.PeriodSortOrder).ThenBy(b => b.Model).ToList();
    }

    List<TokenBucket> GetNoCompactionTokenUsageByModelPeriod(int limit, IReadOnlyList<PeriodWindow> windows)
    {
        if (windows.Count == 0)
        {
            return [];
        }

        var oldestStart = windows.Min(w => w.StartUtc);
        var newestEnd = windows.Max(w => w.EndUtc);
        var buckets = new Dictionary<string, TokenBucket>(StringComparer.Ordinal);

        foreach (var file in GetSessionFiles(limit))
        {
            if (file.LastWriteTimeUtc < oldestStart)
            {
                continue;
            }

            long cumulativeInput = 0;
            foreach (var usageEvent in GetSessionUsageDeltas(file.FullName))
            {
                cumulativeInput += usageEvent.Metrics.Input;
                if (usageEvent.Timestamp < oldestStart || usageEvent.Timestamp >= newestEnd)
                {
                    continue;
                }

                var band = GetNoCompactionPricingBand(usageEvent.Model, cumulativeInput);
                foreach (var window in windows)
                {
                    if (usageEvent.Timestamp < window.StartUtc || usageEvent.Timestamp >= window.EndUtc)
                    {
                        continue;
                    }

                    var key = $"{window.Name}|{usageEvent.Model}|{band}";
                    if (!buckets.TryGetValue(key, out var bucket))
                    {
                        bucket = NewTokenBucket(window.Group, usageEvent.Model, band);
                        bucket.CostBasisMode = NoCompactionCostBasisMode;
                        bucket.PeriodGroup = window.Group;
                        bucket.PeriodName = window.Name;
                        bucket.PeriodLabel = window.Label;
                        bucket.PeriodStartUtc = window.StartUtc;
                        bucket.PeriodEndUtc = window.EndUtc;
                        bucket.PeriodSortOrder = window.SortOrder;
                        buckets[key] = bucket;
                    }

                    AddTokenMetrics(bucket, usageEvent.Metrics);
                }
            }
        }

        foreach (var bucket in buckets.Values)
        {
            SetNoCompactionEstimatedCost(bucket);
        }

        return buckets.Values.OrderBy(b => b.PeriodGroup).ThenBy(b => b.PeriodSortOrder).ThenBy(b => b.Model).ThenBy(b => b.PricingBand).ToList();
    }

    List<SourceCostRow> GetTokenSourceCostEstimates(int limit, int tail, IReadOnlyList<TokenBucket> modelRows)
    {
        var windows = GetCostWindowDefinitions().ToList();
        if (windows.Count == 0 || modelRows.Count == 0)
        {
            return [];
        }

        var oldestStart = windows.Min(w => w.StartUtc);
        var files = GetSessionFiles(limit).Where(file => file.LastWriteTimeUtc >= oldestStart).ToList();
        if (tail <= 0 && _usageCache is not null && _usageCache.TryGetSourceEstimateBuckets(files, windows, oldestStart, out var cachedBuckets))
        {
            return GetSourceCostRows(cachedBuckets, modelRows);
        }

        var buckets = new Dictionary<string, SourceEstimateBucket>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            var currentModel = GetSessionInitialModel(file.FullName);
            foreach (var line in ReadSessionLines(file.FullName, tail))
            {
                var eventTime = GetJsonLineEventTime(line);
                if (eventTime is null || eventTime.Value < oldestStart)
                {
                    continue;
                }

                if (line.Contains("\"turn_context\"", StringComparison.Ordinal))
                {
                    var model = ExtractJsonString(line, "model");
                    if (!string.IsNullOrWhiteSpace(model))
                    {
                        currentModel = model;
                    }
                }

                if (!LineMayHaveSourceEstimate(line))
                {
                    continue;
                }

                using var doc = ParseJsonLine(line);
                if (doc is null)
                {
                    continue;
                }

                var estimate = GetSourceEstimateFromEntry(doc.RootElement);
                if (estimate is null)
                {
                    continue;
                }

                foreach (var window in windows.Where(w => eventTime.Value >= w.StartUtc))
                {
                    AddSourceEstimate(buckets, window.Name, currentModel, estimate);
                }
            }
        }

        return GetSourceCostRows(buckets.Values.ToList(), modelRows);
    }

    static bool LineMayHaveSourceEstimate(string line) =>
        line.Contains("\"user_message\"", StringComparison.Ordinal) ||
        line.Contains("\"function_call\"", StringComparison.Ordinal) ||
        line.Contains("\"custom_tool_call\"", StringComparison.Ordinal) ||
        line.Contains("\"reasoning\"", StringComparison.Ordinal) ||
        line.Contains("\"summary\"", StringComparison.Ordinal) ||
        line.Contains("\"context_compacted\"", StringComparison.Ordinal) ||
        line.Contains("\"message\"", StringComparison.Ordinal);

    static SourceEstimate? GetSourceEstimateFromEntry(JsonElement entry)
    {
        var payload = JsonTools.GetElement(entry, "payload");
        if (payload is null)
        {
            return null;
        }

        var entryType = JsonTools.GetString(entry, "type");
        var payloadType = JsonTools.GetString(payload, "type");
        string? source = null;
        string? side = null;
        long chars = 0;
        var attribution = "Field text estimate";

        if (entryType == "event_msg" && payloadType == "user_message")
        {
            source = "User input";
            side = "Input";
            chars = TextFieldChars(JsonTools.GetElement(payload, "message")) + TextFieldChars(JsonTools.GetElement(payload, "text_elements", "textElements"));
        }
        else if (entryType == "response_item" && payloadType == "message")
        {
            var role = JsonTools.GetString(payload, "role");
            if (role == "assistant")
            {
                source = "Assistant output";
                side = "Output";
                chars = TextFieldChars(JsonTools.GetElement(payload, "content"));
            }
            else if (role == "user")
            {
                source = "User context";
                side = "Input";
                chars = TextFieldChars(JsonTools.GetElement(payload, "content"));
            }
            else if (role is "developer" or "system")
            {
                source = "System/developer context";
                side = "Input";
                chars = TextFieldChars(JsonTools.GetElement(payload, "content"));
            }
        }
        else if (entryType == "response_item" && payloadType is "function_call" or "custom_tool_call")
        {
            source = "Tool call arguments";
            side = "Output";
            chars = TextFieldChars(JsonTools.GetElement(payload, "arguments", "input"));
        }
        else if (entryType == "response_item" && payloadType is "function_call_output" or "custom_tool_call_output")
        {
            source = "Tool outputs";
            side = "Input";
            chars = TextFieldChars(JsonTools.GetElement(payload, "output"));
        }
        else if (entryType == "response_item" && payloadType == "reasoning")
        {
            source = "Reasoning";
            side = "Output";
            chars = TextFieldChars(JsonTools.GetElement(payload, "summary")) + TextFieldChars(JsonTools.GetElement(payload, "content"));
            attribution = "Visible reasoning text estimate";
        }
        else if ((entryType == "response_item" && payloadType == "summary") || (entryType == "event_msg" && payloadType == "context_compacted") || entryType == "compacted")
        {
            source = "Context summaries";
            side = "Input";
            chars = TextFieldChars(JsonTools.GetElement(payload, "summary")) + TextFieldChars(JsonTools.GetElement(payload, "content")) + TextFieldChars(JsonTools.GetElement(payload, "message", "text"));
        }

        if (string.IsNullOrWhiteSpace(source))
        {
            return null;
        }

        var tokens = chars <= 0 ? 0 : (long)Math.Ceiling(chars / 4.0);
        return tokens <= 0 ? null : new SourceEstimate(source, side ?? "Input", tokens, chars, attribution);
    }

    static long TextFieldChars(JsonElement? value)
    {
        if (value is null)
        {
            return 0;
        }

        var element = value.Value;
        return element.ValueKind switch
        {
            JsonValueKind.String => element.GetString()?.Length ?? 0,
            JsonValueKind.Array => element.EnumerateArray().Sum(item => TextFieldChars(item)),
            JsonValueKind.Object => TextFieldChars(JsonTools.GetElement(element, "text")) + TextFieldChars(JsonTools.GetElement(element, "content")),
            _ => 0
        };
    }

    static void AddSourceEstimate(Dictionary<string, SourceEstimateBucket> buckets, string window, string model, SourceEstimate estimate)
    {
        var key = $"{window}|{model}|{estimate.Source}";
        if (!buckets.TryGetValue(key, out var bucket))
        {
            bucket = new SourceEstimateBucket { Window = window, Model = model, Source = estimate.Source };
            buckets[key] = bucket;
        }

        if (estimate.Side == "Input") bucket.EstimatedInputTokens += estimate.Tokens;
        else bucket.EstimatedOutputTokens += estimate.Tokens;
        bucket.EstimatedChars += estimate.Chars;
        bucket.Attribution = bucket.Attribution != estimate.Attribution ? "Mixed text estimate" : estimate.Attribution;
        bucket.Events++;
    }

    List<SourceCostRow> GetSourceCostRows(IReadOnlyList<SourceEstimateBucket> estimates, IReadOnlyList<TokenBucket> modelRows)
    {
        var rows = new List<SourceCostRow>();
        foreach (var modelRow in modelRows)
        {
            var pricing = GetModelPricing(modelRow.Model, modelRow.Input, modelRow.PricingBand);
            var sourceRows = estimates.Where(r => r.Window == modelRow.Window && r.Model == modelRow.Model).Select(r => r.Clone()).ToList();
            var inputEstimateTotal = sourceRows.Sum(r => r.EstimatedInputTokens);
            var outputEstimateTotal = sourceRows.Sum(r => r.EstimatedOutputTokens);

            if (modelRow.Input > inputEstimateTotal)
            {
                sourceRows.Add(new SourceEstimateBucket { Window = modelRow.Window, Model = modelRow.Model, Source = "Unattributed input/context", EstimatedInputTokens = modelRow.Input - inputEstimateTotal, Attribution = "Allocated remainder" });
                inputEstimateTotal = modelRow.Input;
            }

            if (modelRow.Output > outputEstimateTotal)
            {
                sourceRows.Add(new SourceEstimateBucket { Window = modelRow.Window, Model = modelRow.Model, Source = "Unattributed output", EstimatedOutputTokens = modelRow.Output - outputEstimateTotal, Attribution = "Allocated remainder" });
                outputEstimateTotal = modelRow.Output;
            }

            foreach (var sourceRow in sourceRows)
            {
                var rawInput = sourceRow.EstimatedInputTokens;
                var rawOutput = sourceRow.EstimatedOutputTokens;
                var allocatedInput = inputEstimateTotal > 0 && rawInput > 0 ? (long)Math.Round((double)modelRow.Input * rawInput / inputEstimateTotal) : 0;
                var allocatedOutput = outputEstimateTotal > 0 && rawOutput > 0 ? (long)Math.Round((double)modelRow.Output * rawOutput / outputEstimateTotal) : 0;
                var allocatedCached = modelRow.Input > 0 && allocatedInput > 0 ? (long)Math.Round((double)modelRow.CachedInput * allocatedInput / modelRow.Input) : 0;
                double? cost = null;
                double? costUsd = null;
                double? costCredits = null;
                if (pricing is not null)
                {
                    var uncachedInput = Math.Max(0, allocatedInput - allocatedCached);
                    cost = Math.Round(
                        uncachedInput * pricing.InputPerMillion / 1_000_000.0 +
                        allocatedCached * pricing.CachedInputPerMillion / 1_000_000.0 +
                        allocatedOutput * pricing.OutputPerMillion / 1_000_000.0,
                        4);
                    if (pricing.Unit == "USD") costUsd = cost;
                    if (pricing.Unit == "credits") costCredits = cost;
                }

                rows.Add(new SourceCostRow
                {
                    Window = sourceRow.Window,
                    Model = sourceRow.Model,
                    Source = sourceRow.Source,
                    PricingMode = _options.PricingMode,
                    CostBasisMode = _options.CostBasisMode,
                    CostUnit = pricing?.Unit,
                    PricingBand = modelRow.PricingBand,
                    BillingConfidence = pricing is null ? "Low" : sourceRow.Attribution == "Allocated remainder" ? "Medium" : modelRow.BillingConfidence,
                    EstimatedChars = sourceRow.EstimatedChars,
                    EstimatedInputTokens = rawInput,
                    EstimatedOutputTokens = rawOutput,
                    EstimatedTokens = rawInput + rawOutput,
                    AllocatedInput = allocatedInput,
                    AllocatedCachedInput = allocatedCached,
                    AllocatedNonCachedInput = Math.Max(0, allocatedInput - allocatedCached),
                    AllocatedOutput = allocatedOutput,
                    AllocatedTokens = allocatedInput + allocatedOutput,
                    ReconciliationDelta = allocatedInput + allocatedOutput - (rawInput + rawOutput),
                    Events = sourceRow.Events,
                    EstimatedCost = cost,
                    EstimatedCostUsd = costUsd,
                    EstimatedCostCredits = costCredits,
                    Attribution = sourceRow.Attribution
                });
            }
        }

        return rows.OrderBy(r => r.Window).ThenBy(r => r.Model).ThenBy(r => r.Source).ToList();
    }

    List<PeriodWindow> GetCostWindowDefinitions(params string[] names)
    {
        names = names.Length == 0 ? ["Last 5 hours", "This week", "This month"] : names;
        var windows = new List<PeriodWindow>
        {
            new("Last 5 hours", "Last 5 hours", "Last 5 hours", DateTime.UtcNow.AddHours(-5), DateTime.MaxValue, 0, _options.CostFiveHourRefreshSeconds),
            new("This week", "This week", "This week", GetLocalWindowStartUtc("This week"), DateTime.MaxValue, 1, _options.CostWeekRefreshSeconds),
            new("This month", "This month", "This month", GetLocalWindowStartUtc("This month"), DateTime.MaxValue, 2, _options.CostMonthRefreshSeconds)
        };
        return windows.Where(w => names.Contains(w.Name)).ToList();
    }

    List<PeriodWindow> GetModelPeriodWindowDefinitions()
    {
        var nowLocal = DateTime.Now;
        var windows = new List<PeriodWindow>();
        for (var index = 0; index < 5; index++)
        {
            var end = nowLocal.AddHours(-5 * index);
            var start = end.AddHours(-5);
            var label = index == 0 ? "Last 5h" : $"{5 * index}-{5 * (index + 1)}h ago";
            windows.Add(new PeriodWindow("Last 5 hours", $"5h-{index}", label, start.ToUniversalTime(), end.ToUniversalTime(), index, _options.CostFiveHourRefreshSeconds));
        }

        var today = nowLocal.Date;
        for (var index = 0; index < 7; index++)
        {
            var start = today.AddDays(-index);
            var end = start.AddDays(1);
            var label = index == 0 ? "Today" : index == 1 ? "Yesterday" : start.ToString("MMM d", CultureInfo.InvariantCulture);
            windows.Add(new PeriodWindow("This week", $"day-{index}", label, start.ToUniversalTime(), end.ToUniversalTime(), index, _options.CostWeekRefreshSeconds));
        }

        for (var index = 0; index < 4; index++)
        {
            var end = nowLocal.Date.AddDays(1).AddDays(-7 * index);
            var start = end.AddDays(-7);
            windows.Add(new PeriodWindow("This month", $"week-{index}", FormatPeriodRangeLabel(start, end), start.ToUniversalTime(), end.ToUniversalTime(), index, _options.CostMonthRefreshSeconds));
        }

        return windows;
    }

    static string FormatPeriodRangeLabel(DateTime startLocal, DateTime endLocal)
    {
        var inclusiveEnd = endLocal.AddSeconds(-1);
        return startLocal.Date == inclusiveEnd.Date
            ? startLocal.ToString("MMM d", CultureInfo.InvariantCulture)
            : $"{startLocal.ToString("MMM d", CultureInfo.InvariantCulture)}-{inclusiveEnd.ToString("MMM d", CultureInfo.InvariantCulture)}";
    }

    DateTime GetLocalWindowStartUtc(string window)
    {
        var now = DateTime.Now;
        return window switch
        {
            "Last 5 hours" => DateTime.UtcNow.AddHours(-5),
            "This week" => now.Date.AddDays(-(((int)now.Date.DayOfWeek + 6) % 7)).ToUniversalTime(),
            "This month" => new DateTime(now.Year, now.Month, 1).ToUniversalTime(),
            _ => DateTime.MinValue
        };
    }

    TokenBucket NewTokenBucket(string window, string? model = null, string pricingBand = "Short") => new()
    {
        Window = window,
        Model = model,
        PricingBand = pricingBand,
        PricingMode = _options.PricingMode,
        BillingConfidence = "Low",
        CostBasisMode = _options.CostBasisMode
    };

    void AddTokenMetrics(TokenBucket bucket, UsageMetrics metrics)
    {
        bucket.Total += metrics.Total;
        bucket.Input += metrics.Input;
        bucket.CachedInput += metrics.CachedInput;
        bucket.Output += metrics.Output;
        bucket.Reasoning += metrics.Reasoning;
        bucket.Events++;
    }

    void SetEstimatedCost(TokenBucket bucket)
    {
        if (string.IsNullOrWhiteSpace(bucket.Model))
        {
            return;
        }

        bucket.PricingBand = string.IsNullOrWhiteSpace(bucket.PricingBand) ? GetPricingBand(bucket.Model, bucket.Input) : bucket.PricingBand;
        bucket.PricingMode = _options.PricingMode;
        bucket.CostBasisMode = _options.CostBasisMode;
        var pricing = GetModelPricing(bucket.Model, bucket.Input, bucket.PricingBand);
        if (pricing is null)
        {
            bucket.BillingConfidence = "Low";
            return;
        }

        var uncachedInput = Math.Max(0, bucket.Input - bucket.CachedInput);
        var cost = Math.Round(
            uncachedInput * pricing.InputPerMillion / 1_000_000.0 +
            bucket.CachedInput * pricing.CachedInputPerMillion / 1_000_000.0 +
            bucket.Output * pricing.OutputPerMillion / 1_000_000.0,
            4);
        bucket.CostUnit = pricing.Unit;
        bucket.EstimatedCost = cost;
        bucket.EstimatedCostUsd = pricing.Unit == "USD" ? cost : null;
        bucket.EstimatedCostCredits = pricing.Unit == "credits" ? cost : null;
        bucket.BillingConfidence = "Medium";
    }

    void SetNoCompactionEstimatedCost(TokenBucket bucket)
    {
        if (string.IsNullOrWhiteSpace(bucket.Model))
        {
            return;
        }

        bucket.PricingMode = _options.PricingMode;
        bucket.CostBasisMode = NoCompactionCostBasisMode;
        var pricing = GetApiModelPricing(bucket.Model, bucket.PricingBand);
        if (pricing is null)
        {
            bucket.BillingConfidence = "Low";
            return;
        }

        var uncachedInput = Math.Max(0, bucket.Input - bucket.CachedInput);
        var cost = Math.Round(
            uncachedInput * pricing.InputPerMillion / 1_000_000.0 +
            bucket.CachedInput * pricing.CachedInputPerMillion / 1_000_000.0 +
            bucket.Output * pricing.OutputPerMillion / 1_000_000.0,
            4);
        bucket.CostUnit = pricing.Unit;
        bucket.EstimatedCost = cost;
        bucket.EstimatedCostUsd = cost;
        bucket.EstimatedCostCredits = null;
        bucket.BillingConfidence = "Scenario";
    }

    PricingRecord? GetModelPricing(string? model, long inputTokens = 0, string? pricingBand = null)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            return null;
        }

        pricingBand ??= GetPricingBand(model, inputTokens);
        var rows = PricingTable();
        var pricing = rows.FirstOrDefault(p => p.Basis == _options.CostBasisMode && p.Mode == _options.PricingMode && p.Model == model && p.ContextBand == pricingBand);
        if (pricing is null && pricingBand == "Long")
        {
            pricing = rows.FirstOrDefault(p => p.Basis == _options.CostBasisMode && p.Mode == _options.PricingMode && p.Model == model && p.ContextBand == "Short");
        }

        if (pricing is null && _options.CostBasisMode == "CodexCredits" && _options.PricingMode != "Standard")
        {
            pricing = rows.FirstOrDefault(p => p.Basis == _options.CostBasisMode && p.Mode == "Standard" && p.Model == model && p.ContextBand == pricingBand);
        }

        if (pricing is null && _options.CostBasisMode == "CodexCredits" && pricingBand == "Long")
        {
            pricing = rows.FirstOrDefault(p => p.Basis == _options.CostBasisMode && p.Mode == "Standard" && p.Model == model && p.ContextBand == "Short");
        }

        return pricing;
    }

    PricingRecord? GetApiModelPricing(string? model, string? pricingBand)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            return null;
        }

        var band = string.IsNullOrWhiteSpace(pricingBand) ? "Short" : pricingBand;
        var rows = PricingTable();
        var pricing = rows.FirstOrDefault(p => p.Basis == "ApiUsdEstimate" && p.Mode == _options.PricingMode && p.Model == model && p.ContextBand == band);
        if (pricing is null && band == "Long")
        {
            pricing = rows.FirstOrDefault(p => p.Basis == "ApiUsdEstimate" && p.Mode == _options.PricingMode && p.Model == model && p.ContextBand == "Short");
        }

        return pricing;
    }

    static string GetPricingBand(string? model, long inputTokens) => model is "gpt-5.5" or "gpt-5.4" && inputTokens >= LongContextThresholdTokens ? "Long" : "Short";

    string GetNoCompactionPricingBand(string? model, long cumulativeInputTokens)
    {
        if (cumulativeInputTokens < LongContextThresholdTokens)
        {
            return "Short";
        }

        return PricingTable().Any(p => p.Basis == "ApiUsdEstimate" && p.Mode == _options.PricingMode && p.Model == model && p.ContextBand == "Long")
            ? "Long"
            : "Short";
    }

    static IReadOnlyList<PricingRecord> PricingTable() =>
    [
        new("ApiUsdEstimate", "USD", "Standard", "gpt-5.5", "Short", 5.00, 0.50, 30.00),
        new("ApiUsdEstimate", "USD", "Standard", "gpt-5.5", "Long", 10.00, 1.00, 45.00),
        new("ApiUsdEstimate", "USD", "Standard", "gpt-5.4", "Short", 2.50, 0.25, 15.00),
        new("ApiUsdEstimate", "USD", "Standard", "gpt-5.4", "Long", 5.00, 0.50, 22.50),
        new("ApiUsdEstimate", "USD", "Standard", "gpt-5.4-mini", "Short", 0.75, 0.075, 4.50),
        new("ApiUsdEstimate", "USD", "Standard", "gpt-5.4-nano", "Short", 0.20, 0.02, 1.25),
        new("ApiUsdEstimate", "USD", "Standard", "gpt-5.3-codex", "Short", 1.75, 0.175, 14.00),
        new("ApiUsdEstimate", "USD", "Batch", "gpt-5.5", "Short", 2.50, 0.25, 15.00),
        new("ApiUsdEstimate", "USD", "Batch", "gpt-5.5", "Long", 5.00, 0.50, 22.50),
        new("ApiUsdEstimate", "USD", "Batch", "gpt-5.4", "Short", 1.25, 0.125, 7.50),
        new("ApiUsdEstimate", "USD", "Batch", "gpt-5.4", "Long", 2.50, 0.25, 11.25),
        new("ApiUsdEstimate", "USD", "Batch", "gpt-5.4-mini", "Short", 0.375, 0.0375, 2.25),
        new("ApiUsdEstimate", "USD", "Batch", "gpt-5.4-nano", "Short", 0.10, 0.01, 0.625),
        new("ApiUsdEstimate", "USD", "Flex", "gpt-5.5", "Short", 2.50, 0.25, 15.00),
        new("ApiUsdEstimate", "USD", "Flex", "gpt-5.5", "Long", 5.00, 0.50, 22.50),
        new("ApiUsdEstimate", "USD", "Flex", "gpt-5.4", "Short", 1.25, 0.125, 7.50),
        new("ApiUsdEstimate", "USD", "Flex", "gpt-5.4", "Long", 2.50, 0.25, 11.25),
        new("ApiUsdEstimate", "USD", "Flex", "gpt-5.4-mini", "Short", 0.375, 0.0375, 2.25),
        new("ApiUsdEstimate", "USD", "Flex", "gpt-5.4-nano", "Short", 0.10, 0.01, 0.625),
        new("ApiUsdEstimate", "USD", "Priority", "gpt-5.5", "Short", 12.50, 1.25, 75.00),
        new("ApiUsdEstimate", "USD", "Priority", "gpt-5.4", "Short", 5.00, 0.50, 30.00),
        new("ApiUsdEstimate", "USD", "Priority", "gpt-5.4-mini", "Short", 1.50, 0.15, 9.00),
        new("ApiUsdEstimate", "USD", "Priority", "gpt-5.3-codex", "Short", 3.50, 0.35, 28.00),
        new("CodexCredits", "credits", "Standard", "gpt-5.5", "Short", 125.00, 12.50, 750.00),
        new("CodexCredits", "credits", "Standard", "gpt-5.4", "Short", 62.50, 6.25, 375.00),
        new("CodexCredits", "credits", "Standard", "gpt-5.4-mini", "Short", 18.75, 1.875, 113.00),
        new("CodexCredits", "credits", "Standard", "gpt-5.3-codex", "Short", 43.75, 4.375, 350.00),
        new("CodexCredits", "credits", "Standard", "gpt-5.2", "Short", 43.75, 4.375, 350.00)
    ];

    string GetSessionInitialModel(string path)
    {
        foreach (var line in ReadHeadLines(path, 200))
        {
            if (!line.Contains("\"turn_context\"", StringComparison.Ordinal))
            {
                continue;
            }

            var model = ExtractJsonString(line, "model");
            if (!string.IsNullOrWhiteSpace(model))
            {
                return model;
            }
        }

        return "unknown";
    }

    string? GetLatestPlanType(int limit, int tail)
    {
        foreach (var file in GetSessionFiles(limit))
        {
            var lines = ReadSessionLines(file.FullName, tail);
            for (var index = lines.Count - 1; index >= 0; index--)
            {
                var line = lines[index];
                if (!line.Contains("\"plan_type\"", StringComparison.Ordinal) && !line.Contains("\"planType\"", StringComparison.Ordinal))
                {
                    continue;
                }

                using var doc = ParseJsonLine(line);
                if (doc is null) continue;
                var payload = JsonTools.GetElement(doc.RootElement, "payload");
                var rateLimits = JsonTools.GetElement(payload, "rate_limits", "rateLimitStatus", "rate_limit_status");
                var planType = JsonTools.GetString(rateLimits, "plan_type", "planType");
                if (!string.IsNullOrWhiteSpace(planType))
                {
                    return planType;
                }
            }
        }

        return null;
    }

    List<FileInfo> GetSessionFiles(int limit)
    {
        var roots = new List<string> { Path.Combine(_options.CodexHome, "sessions") };
        if (_options.IncludeArchived)
        {
            roots.Add(Path.Combine(_options.CodexHome, "archived_sessions"));
        }

        var files = roots
            .Where(Directory.Exists)
            .SelectMany(root => Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories))
            .Select(path => new FileInfo(path))
            .OrderByDescending(file => file.LastWriteTimeUtc);
        return limit <= 0 ? files.ToList() : files.Take(limit).ToList();
    }

    List<FileInfo> GetSessionFilesSince(DateTime sinceUtc) =>
        GetSessionFiles(0).Where(file => file.LastWriteTimeUtc >= sinceUtc).OrderByDescending(file => file.LastWriteTimeUtc).ToList();

    static List<string> ReadSessionLines(string path, int tail)
    {
        try
        {
            var lines = ReadSharedLines(path);
            if (tail <= 0)
            {
                return lines;
            }

            var queue = new Queue<string>();
            foreach (var line in lines)
            {
                queue.Enqueue(line);
                while (queue.Count > tail)
                {
                    queue.Dequeue();
                }
            }

            return queue.ToList();
        }
        catch
        {
            return [];
        }
    }

    static IEnumerable<string> ReadHeadLines(string path, int count)
    {
        try
        {
            return ReadSharedLines(path).Take(count).ToList();
        }
        catch
        {
            return [];
        }
    }

    static List<string> ReadSharedLines(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line)
        {
            lines.Add(line);
        }

        return lines;
    }

    static JsonDocument? ParseJsonLine(string line)
    {
        try
        {
            return JsonDocument.Parse(line);
        }
        catch
        {
            return null;
        }
    }

    static DateTime? GetEventTime(JsonElement entry)
    {
        var timestamp = JsonTools.GetString(entry, "timestamp");
        return DateTimeOffset.TryParse(timestamp, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dto) ? dto.UtcDateTime : null;
    }

    static DateTime? GetJsonLineEventTime(string line)
    {
        var timestamp = ExtractJsonString(line, "timestamp");
        return DateTimeOffset.TryParse(timestamp, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dto) ? dto.UtcDateTime : null;
    }

    static string? ExtractJsonString(string line, string name)
    {
        var match = Regex.Match(line, "\"" + Regex.Escape(name) + "\"\\s*:\\s*\"(?<value>[^\"]+)\"");
        return match.Success ? match.Groups["value"].Value : null;
    }

    static bool IsTokenCountEvent(JsonElement entry)
    {
        if (JsonTools.GetString(entry, "type") != "event_msg")
        {
            return false;
        }

        var payload = JsonTools.GetElement(entry, "payload");
        return JsonTools.GetString(payload, "type") == "token_count";
    }

    static UsageMetrics? GetUsageMetricsFromEntry(JsonElement entry, params string[] names)
    {
        var payload = JsonTools.GetElement(entry, "payload");
        var info = JsonTools.GetElement(payload, "info");
        var usage = JsonTools.GetElement(info, names);
        return usage is null ? null : ConvertUsageToMetrics(usage.Value);
    }

    static UsageMetrics ConvertUsageToMetrics(JsonElement usage) => new(
        JsonTools.GetLong(usage, "total_tokens", "totalTokens") ?? 0,
        JsonTools.GetLong(usage, "input_tokens", "inputTokens") ?? 0,
        JsonTools.GetLong(usage, "cached_input_tokens", "cachedInputTokens") ?? 0,
        JsonTools.GetLong(usage, "output_tokens", "outputTokens") ?? 0,
        JsonTools.GetLong(usage, "reasoning_output_tokens", "reasoningOutputTokens") ?? 0);

    static UsageMetrics? GetUsageDeltaMetrics(UsageMetrics? previous, UsageMetrics current, UsageMetrics? last)
    {
        if (last is not null && AnyMetrics(last))
        {
            return last;
        }

        if (previous is null)
        {
            return null;
        }

        var delta = new UsageMetrics(
            current.Total - previous.Total,
            current.Input - previous.Input,
            current.CachedInput - previous.CachedInput,
            current.Output - previous.Output,
            current.Reasoning - previous.Reasoning);
        return delta.Total < 0 || delta.Input < 0 || delta.CachedInput < 0 || delta.Output < 0 || delta.Reasoning < 0 || !AnyMetrics(delta) ? null : delta;
    }

    static bool AnyMetrics(UsageMetrics? m) => m is not null && (m.Total != 0 || m.Input != 0 || m.CachedInput != 0 || m.Output != 0 || m.Reasoning != 0);
    static bool SameMetrics(UsageMetrics? left, UsageMetrics? right) => left is not null && right is not null && left.Equals(right);
    static string MetricsKey(UsageMetrics? m) => m is null ? "null" : $"{m.Total}/{m.Input}/{m.CachedInput}/{m.Output}/{m.Reasoning}";

    string GetRateLimitHistoryPath() => Path.Combine(_options.CodexHome, "usage-history", "rate_limit_samples.jsonl");

    List<RateLimitHistoryRow> GetRateLimitHistoryRows(int days)
    {
        var path = GetRateLimitHistoryPath();
        if (!File.Exists(path))
        {
            return [];
        }

        var cutoff = DateTime.UtcNow.AddDays(-Math.Max(1, days));
        var rows = new List<RateLimitHistoryRow>();
        foreach (var line in File.ReadLines(path))
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            using var doc = ParseJsonLine(line);
            if (doc is null)
            {
                continue;
            }

            var root = doc.RootElement;
            var sampledAt = ParseHistoryDate(JsonTools.GetString(root, "sampled_at", "SampledAt"));
            if (sampledAt is null || sampledAt.Value < cutoff)
            {
                continue;
            }

            rows.Add(new RateLimitHistoryRow
            {
                SampledAt = sampledAt.Value,
                EventTimestamp = JsonTools.GetString(root, "event_timestamp", "EventTimestamp"),
                PlanType = JsonTools.GetString(root, "plan_type", "PlanType"),
                Window = JsonTools.GetString(root, "window", "Window"),
                UsedPercent = JsonTools.GetDouble(root, "used_percent", "UsedPercent") ?? 0,
                RemainingPercent = JsonTools.GetDouble(root, "remaining_percent", "RemainingPercent") ?? 0,
                WindowMinutes = JsonTools.GetDouble(root, "window_minutes", "WindowMinutes"),
                ResetsAt = JsonTools.GetString(root, "resets_at", "ResetsAt"),
                Session = JsonTools.GetString(root, "session", "Session"),
                SourceFile = JsonTools.GetString(root, "source_file", "SourceFile")
            });
        }

        return rows.OrderBy(row => row.SampledAt).ToList();
    }

    void SaveRateLimitHistoryRows(IEnumerable<RateLimitHistoryRow> rows)
    {
        var path = GetRateLimitHistoryPath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var lines = rows.Select(row => JsonSerializer.Serialize(new
        {
            sampled_at = ToIsoUtcString(row.SampledAt),
            event_timestamp = row.EventTimestamp,
            plan_type = row.PlanType,
            window = row.Window,
            used_percent = row.UsedPercent,
            remaining_percent = row.RemainingPercent,
            window_minutes = row.WindowMinutes,
            resets_at = row.ResetsAt,
            session = row.Session,
            source_file = row.SourceFile
        }, JsonTools.JsonOptions));
        File.WriteAllLines(path, lines, Encoding.UTF8);
    }

    void WriteRateLimitHistorySamples(Snapshot snapshot)
    {
        if (_options.DisableRateLimitHistory || snapshot.RateLimitRows.Count == 0)
        {
            return;
        }

        var nowUtc = DateTime.UtcNow;
        var rows = GetRateLimitHistoryRows(_options.RateLimitHistoryDays);
        var changed = false;
        foreach (var rateRow in snapshot.RateLimitRows)
        {
            var reset = FormatDisplayDateTime(rateRow.ResetsAt);
            var last = rows.Where(r => r.Window == rateRow.Window).OrderByDescending(r => r.SampledAt).FirstOrDefault();
            var shouldAppend = true;
            if (last is not null)
            {
                var ageSeconds = (nowUtc - last.SampledAt).TotalSeconds;
                var sameUsed = Math.Abs(last.UsedPercent - rateRow.UsedPercent) < 0.01;
                var sameReset = string.Equals(last.ResetsAt, reset, StringComparison.Ordinal);
                shouldAppend = !(sameUsed && sameReset && ageSeconds < Math.Max(1, _options.RateLimitHistorySampleSeconds));
            }

            if (!shouldAppend)
            {
                continue;
            }

            rows.Add(new RateLimitHistoryRow
            {
                SampledAt = nowUtc,
                EventTimestamp = snapshot.Timestamp,
                PlanType = snapshot.PlanType,
                Window = rateRow.Window,
                UsedPercent = rateRow.UsedPercent,
                RemainingPercent = rateRow.RemainingPercent,
                WindowMinutes = rateRow.WindowMinutes,
                ResetsAt = reset,
                Session = snapshot.Session,
                SourceFile = snapshot.SourceFile
            });
            changed = true;
        }

        if (changed)
        {
            SaveRateLimitHistoryRows(CompressRateLimitHistoryRows(rows, _options.RateLimitHistorySampleSeconds));
        }
    }

    List<RateLimitHistorySummaryRow> GetRateLimitHistorySummary(IReadOnlyList<RateLimitHistoryRow> rows)
    {
        var summaries = new List<RateLimitHistorySummaryRow>();
        foreach (var window in new[] { "5 hour", "1 week" })
        {
            var windowRows = rows.Where(r => r.Window == window).OrderBy(r => r.SampledAt).ToList();
            if (windowRows.Count == 0)
            {
                continue;
            }

            var latest = windowRows[^1];
            summaries.Add(new RateLimitHistorySummaryRow
            {
                Window = window,
                LatestUsedPercent = Math.Round(latest.UsedPercent, 2),
                PeakUsedPercent = Math.Round(windowRows.Max(r => r.UsedPercent), 2),
                AverageUsedPercent = Math.Round(windowRows.Average(r => r.UsedPercent), 2),
                Samples = windowRows.Count,
                ResetCount = windowRows.Where(r => !string.IsNullOrWhiteSpace(r.ResetsAt)).Select(r => r.ResetsAt).Distinct().Count(),
                FirstSampledAt = windowRows[0].SampledAt,
                LastSampledAt = latest.SampledAt
            });
        }

        return summaries;
    }

    List<RateLimitHistoryRow> CompressRateLimitHistoryRows(IEnumerable<RateLimitHistoryRow> source, int sampleSeconds)
    {
        var kept = new List<RateLimitHistoryRow>();
        foreach (var row in source.OrderBy(r => r.SampledAt).ThenBy(r => r.Window))
        {
            var last = kept.Where(r => r.Window == row.Window).OrderByDescending(r => r.SampledAt).FirstOrDefault();
            if (last is not null)
            {
                var age = (row.SampledAt - last.SampledAt).TotalSeconds;
                var sameUsed = Math.Abs(last.UsedPercent - row.UsedPercent) < 0.01;
                var sameReset = string.Equals(last.ResetsAt, row.ResetsAt, StringComparison.Ordinal);
                if (sameUsed && sameReset && age >= 0 && age < Math.Max(1, sampleSeconds))
                {
                    continue;
                }
            }

            kept.Add(row);
        }

        return kept;
    }

    List<RateLimitHistoryRow> GetRateLimitHistoryRowsFromSessions(int days)
    {
        var cutoff = DateTime.UtcNow.AddDays(-Math.Max(1, days));
        var files = GetSessionFilesSince(cutoff);
        if (_usageCache is not null && _usageCache.TryGetRateLimitRows(files, cutoff, out var cachedRows))
        {
            return cachedRows;
        }

        var rows = new List<RateLimitHistoryRow>();
        foreach (var file in files)
        {
            var session = Path.GetFileNameWithoutExtension(file.Name);
            foreach (var line in ReadSessionLines(file.FullName, 0))
            {
                if (!line.Contains("\"rate_limits\"", StringComparison.Ordinal) &&
                    !line.Contains("\"rateLimitStatus\"", StringComparison.Ordinal) &&
                    !line.Contains("\"rate_limit_status\"", StringComparison.Ordinal))
                {
                    continue;
                }

                using var doc = ParseJsonLine(line);
                if (doc is null)
                {
                    continue;
                }

                var entry = doc.RootElement;
                var eventTime = GetEventTime(entry);
                if (eventTime is null || eventTime.Value < cutoff)
                {
                    continue;
                }

                var payload = JsonTools.GetElement(entry, "payload");
                var rateLimits = JsonTools.GetElement(payload, "rate_limits", "rateLimitStatus", "rate_limit_status");
                if (rateLimits is null)
                {
                    continue;
                }

                var planType = JsonTools.GetString(rateLimits, "plan_type", "planType");
                foreach (var rateRow in ConvertRateLimits(rateLimits))
                {
                    rows.Add(new RateLimitHistoryRow
                    {
                        SampledAt = eventTime.Value,
                        EventTimestamp = JsonTools.GetString(entry, "timestamp"),
                        PlanType = planType,
                        Window = rateRow.Window,
                        UsedPercent = rateRow.UsedPercent,
                        RemainingPercent = rateRow.RemainingPercent,
                        WindowMinutes = rateRow.WindowMinutes,
                        ResetsAt = FormatDisplayDateTime(rateRow.ResetsAt),
                        Session = session,
                        SourceFile = file.FullName
                    });
                }
            }
        }

        return rows;
    }

    static DateTime? ParseHistoryDate(string? value) => DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dto) ? dto.UtcDateTime : null;
    static string? ToIsoUtcString(DateTime? value) => value?.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
    public static string? FormatDisplayDateTime(DateTime? value) => value?.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
    public static string? FormatLocalDateTime(DateTime? value) => value?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
    static double GetTotalEstimatedCostUsd(IEnumerable<ICostRow> rows) => Math.Round(rows.Where(r => r.EstimatedCostUsd is not null).Sum(r => r.EstimatedCostUsd!.Value), 4);
    static double GetTotalEstimatedCostCredits(IEnumerable<ICostRow> rows) => Math.Round(rows.Where(r => r.EstimatedCostCredits is not null).Sum(r => r.EstimatedCostCredits!.Value), 4);

    record SearchPlan(IReadOnlyList<FileInfo> Files, int Tail, DateTime SinceUtc);
    record CacheEntry<T>(DateTime UpdatedAt, List<T> Rows);
}

sealed class SqliteUsageCache
{
    const int SchemaVersion = 2;

    readonly string _path;
    readonly object _gate = new();

    public bool IsAvailable { get; private set; } = true;

    public SqliteUsageCache(string path) => _path = Path.GetFullPath(path);

    public void Initialize(bool rebuild)
    {
        lock (_gate)
        {
            SQLitePCL.Batteries_V2.Init();

            var directory = Path.GetDirectoryName(_path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            using var connection = OpenConnection();
            ExecuteNonQuery(connection, null, "PRAGMA journal_mode=WAL;");
            ExecuteNonQuery(connection, null, "PRAGMA foreign_keys=ON;");
            EnsureSchema(connection);

            var version = GetSchemaVersion(connection);
            if (version is not null && version != SchemaVersion)
            {
                ClearData(connection);
            }

            SetSchemaVersion(connection);
            if (rebuild)
            {
                ClearData(connection);
            }
        }
    }

    public void Disable() => IsAvailable = false;

    public void SyncFiles(IEnumerable<FileInfo> files, Func<string, bool> isArchived, Func<string, UsageParseResult> parseFile)
    {
        if (!IsAvailable)
        {
            return;
        }

        lock (_gate)
        {
            using var connection = OpenConnection();
            ExecuteNonQuery(connection, null, "PRAGMA foreign_keys=ON;");
            using var transaction = connection.BeginTransaction();

            foreach (var file in files)
            {
                try
                {
                    file.Refresh();
                    if (!file.Exists)
                    {
                        continue;
                    }

                    var path = file.FullName;
                    var size = file.Length;
                    var lastWriteUtc = file.LastWriteTimeUtc.ToString("o", CultureInfo.InvariantCulture);
                    var state = GetFileState(connection, transaction, path);
                    if (state is not null &&
                        state.FileSizeBytes == size &&
                        string.Equals(state.LastWriteUtc, lastWriteUtc, StringComparison.Ordinal) &&
                        string.Equals(state.IndexStatus, "indexed", StringComparison.Ordinal))
                    {
                        continue;
                    }

                    var sessionId = Path.GetFileNameWithoutExtension(file.Name);
                    var sessionFileId = EnsureSessionFile(connection, transaction, path, sessionId, isArchived(path), size, lastWriteUtc);
                    SetFileStatus(connection, transaction, sessionFileId, "indexing", null);
                    DeleteIndexedEvents(connection, transaction, sessionFileId);

                    var parsed = parseFile(path);
                    InsertTokenEvents(connection, transaction, sessionFileId, sessionId, parsed.Events);
                    InsertRateLimitEvents(connection, transaction, sessionFileId, sessionId, parsed.RateLimitEvents);
                    InsertSourceEstimateEvents(connection, transaction, sessionFileId, sessionId, parsed.SourceEstimateEvents);
                    UpdateIndexedFile(connection, transaction, sessionFileId, size, lastWriteUtc, parsed.LineCount, parsed.LastEventUtc);
                }
                catch (Exception ex)
                {
                    MarkFileError(connection, transaction, file.FullName, ex.Message);
                }
            }

            transaction.Commit();
        }
    }

    public bool TryGetUsageDeltas(string path, out List<UsageDeltaEvent> rows)
    {
        rows = [];
        if (!IsAvailable)
        {
            return false;
        }

        try
        {
            lock (_gate)
            {
                using var connection = OpenConnection();
                using var stateCommand = CreateCommand(connection, null, """
                    SELECT id, index_status
                    FROM session_files
                    WHERE path = $path;
                    """);
                stateCommand.Parameters.AddWithValue("$path", path);
                using var stateReader = stateCommand.ExecuteReader();
                if (!stateReader.Read() || !string.Equals(stateReader.GetString(1), "indexed", StringComparison.Ordinal))
                {
                    return false;
                }

                var sessionFileId = stateReader.GetInt64(0);
                stateReader.Close();

                using var command = CreateCommand(connection, null, """
                    SELECT event_index, event_utc, model, total_tokens, input_tokens, cached_input_tokens,
                           output_tokens, reasoning_tokens, cumulative_input_tokens
                    FROM token_events
                    WHERE session_file_id = $session_file_id
                    ORDER BY event_index;
                    """);
                command.Parameters.AddWithValue("$session_file_id", sessionFileId);
                using var reader = command.ExecuteReader();
                while (reader.Read())
                {
                    var timestamp = ParseUtc(reader.GetString(1)) ?? DateTime.MinValue;
                    var metrics = new UsageMetrics(
                        reader.GetInt64(3),
                        reader.GetInt64(4),
                        reader.GetInt64(5),
                        reader.GetInt64(6),
                        reader.GetInt64(7));
                    rows.Add(new UsageDeltaEvent(timestamp, reader.GetString(2), metrics, reader.GetInt32(0), reader.GetInt64(8)));
                }

                return true;
            }
        }
        catch
        {
            Disable();
            rows = [];
            return false;
        }
    }

    public bool TryGetRateLimitRows(IReadOnlyList<FileInfo> files, DateTime cutoffUtc, out List<RateLimitHistoryRow> rows)
    {
        rows = [];
        if (!IsAvailable)
        {
            return false;
        }

        try
        {
            lock (_gate)
            {
                using var connection = OpenConnection();
                foreach (var file in files)
                {
                    var state = GetFileState(connection, null, file.FullName);
                    if (state is null || !string.Equals(state.IndexStatus, "indexed", StringComparison.Ordinal))
                    {
                        return false;
                    }

                    using var command = CreateCommand(connection, null, """
                        SELECT event_utc, source_timestamp, plan_type, window_name, used_percent,
                               remaining_percent, window_minutes, resets_at_local
                        FROM rate_limit_events
                        WHERE session_file_id = $session_file_id
                          AND event_utc >= $cutoff_utc
                        ORDER BY event_utc, window_name;
                        """);
                    command.Parameters.AddWithValue("$session_file_id", state.Id);
                    command.Parameters.AddWithValue("$cutoff_utc", cutoffUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture));
                    using var reader = command.ExecuteReader();
                    while (reader.Read())
                    {
                        var sampledAt = ParseUtc(reader.GetString(0));
                        if (sampledAt is null)
                        {
                            continue;
                        }

                        rows.Add(new RateLimitHistoryRow
                        {
                            SampledAt = sampledAt.Value,
                            EventTimestamp = GetNullableString(reader, 1),
                            PlanType = GetNullableString(reader, 2),
                            Window = reader.GetString(3),
                            UsedPercent = reader.GetDouble(4),
                            RemainingPercent = reader.GetDouble(5),
                            WindowMinutes = reader.IsDBNull(6) ? null : reader.GetDouble(6),
                            ResetsAt = GetNullableString(reader, 7),
                            Session = Path.GetFileNameWithoutExtension(file.Name),
                            SourceFile = file.FullName
                        });
                    }
                }

                rows = rows.OrderBy(row => row.SampledAt).ThenBy(row => row.Window).ToList();
                return true;
            }
        }
        catch
        {
            Disable();
            rows = [];
            return false;
        }
    }

    public bool TryGetSourceEstimateBuckets(IReadOnlyList<FileInfo> files, IReadOnlyList<PeriodWindow> windows, DateTime oldestStartUtc, out List<SourceEstimateBucket> rows)
    {
        rows = [];
        if (!IsAvailable)
        {
            return false;
        }

        try
        {
            lock (_gate)
            {
                using var connection = OpenConnection();
                var buckets = new Dictionary<string, SourceEstimateBucket>(StringComparer.Ordinal);
                foreach (var file in files)
                {
                    var state = GetFileState(connection, null, file.FullName);
                    if (state is null || !string.Equals(state.IndexStatus, "indexed", StringComparison.Ordinal))
                    {
                        return false;
                    }

                    using var command = CreateCommand(connection, null, """
                        SELECT event_utc, model, source, side, estimated_tokens, estimated_chars, attribution
                        FROM source_estimate_events
                        WHERE session_file_id = $session_file_id
                          AND event_utc >= $oldest_start_utc;
                        """);
                    command.Parameters.AddWithValue("$session_file_id", state.Id);
                    command.Parameters.AddWithValue("$oldest_start_utc", oldestStartUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture));
                    using var reader = command.ExecuteReader();
                    while (reader.Read())
                    {
                        var eventTime = ParseUtc(reader.GetString(0));
                        if (eventTime is null)
                        {
                            continue;
                        }

                        var model = reader.GetString(1);
                        var estimate = new SourceEstimate(
                            reader.GetString(2),
                            reader.GetString(3),
                            reader.GetInt64(4),
                            reader.GetInt64(5),
                            reader.GetString(6));

                        foreach (var window in windows.Where(w => eventTime.Value >= w.StartUtc))
                        {
                            AddSourceEstimateBucket(buckets, window.Name, model, estimate);
                        }
                    }
                }

                rows = buckets.Values.ToList();
                return true;
            }
        }
        catch
        {
            Disable();
            rows = [];
            return false;
        }
    }

    static void AddSourceEstimateBucket(Dictionary<string, SourceEstimateBucket> buckets, string window, string model, SourceEstimate estimate)
    {
        var key = $"{window}|{model}|{estimate.Source}";
        if (!buckets.TryGetValue(key, out var bucket))
        {
            bucket = new SourceEstimateBucket { Window = window, Model = model, Source = estimate.Source };
            buckets[key] = bucket;
        }

        if (estimate.Side == "Input") bucket.EstimatedInputTokens += estimate.Tokens;
        else bucket.EstimatedOutputTokens += estimate.Tokens;
        bucket.EstimatedChars += estimate.Chars;
        bucket.Attribution = bucket.Attribution != estimate.Attribution ? "Mixed text estimate" : estimate.Attribution;
        bucket.Events++;
    }

    SqliteConnection OpenConnection()
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = _path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared
        };
        var connection = new SqliteConnection(builder.ToString());
        connection.Open();
        return connection;
    }

    static void EnsureSchema(SqliteConnection connection)
    {
        ExecuteNonQuery(connection, null, """
            CREATE TABLE IF NOT EXISTS schema_meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """);

        ExecuteNonQuery(connection, null, """
            CREATE TABLE IF NOT EXISTS session_files (
              id INTEGER PRIMARY KEY,
              path TEXT NOT NULL UNIQUE,
              session_id TEXT NOT NULL,
              is_archived INTEGER NOT NULL DEFAULT 0,
              file_size_bytes INTEGER NOT NULL,
              last_write_utc TEXT NOT NULL,
              line_count INTEGER NOT NULL DEFAULT 0,
              last_indexed_utc TEXT,
              last_event_utc TEXT,
              index_status TEXT NOT NULL DEFAULT 'pending',
              error_message TEXT
            );
            """);

        ExecuteNonQuery(connection, null, """
            CREATE TABLE IF NOT EXISTS token_events (
              id INTEGER PRIMARY KEY,
              session_file_id INTEGER NOT NULL,
              session_id TEXT NOT NULL,
              event_index INTEGER NOT NULL,
              event_utc TEXT NOT NULL,
              model TEXT NOT NULL,
              total_tokens INTEGER NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_tokens INTEGER NOT NULL,
              cumulative_input_tokens INTEGER NOT NULL DEFAULT 0,
              FOREIGN KEY(session_file_id) REFERENCES session_files(id) ON DELETE CASCADE,
              UNIQUE(session_file_id, event_index)
            );
            """);

        ExecuteNonQuery(connection, null, """
            CREATE TABLE IF NOT EXISTS rate_limit_events (
              id INTEGER PRIMARY KEY,
              session_file_id INTEGER NOT NULL,
              session_id TEXT NOT NULL,
              event_index INTEGER NOT NULL,
              event_utc TEXT NOT NULL,
              source_timestamp TEXT,
              plan_type TEXT,
              window_name TEXT NOT NULL,
              used_percent REAL NOT NULL,
              remaining_percent REAL NOT NULL,
              window_minutes REAL,
              resets_at_local TEXT,
              FOREIGN KEY(session_file_id) REFERENCES session_files(id) ON DELETE CASCADE,
              UNIQUE(session_file_id, event_index, window_name)
            );
            """);

        ExecuteNonQuery(connection, null, """
            CREATE TABLE IF NOT EXISTS source_estimate_events (
              id INTEGER PRIMARY KEY,
              session_file_id INTEGER NOT NULL,
              session_id TEXT NOT NULL,
              event_index INTEGER NOT NULL,
              event_utc TEXT NOT NULL,
              model TEXT NOT NULL,
              source TEXT NOT NULL,
              side TEXT NOT NULL,
              estimated_tokens INTEGER NOT NULL,
              estimated_chars INTEGER NOT NULL,
              attribution TEXT NOT NULL,
              FOREIGN KEY(session_file_id) REFERENCES session_files(id) ON DELETE CASCADE,
              UNIQUE(session_file_id, event_index)
            );
            """);

        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_session_files_write ON session_files(last_write_utc);");
        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_events(event_utc);");
        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_token_events_model_time ON token_events(model, event_utc);");
        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_token_events_session ON token_events(session_id, event_index);");
        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_rate_limit_events_time ON rate_limit_events(event_utc);");
        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_rate_limit_events_session ON rate_limit_events(session_id, event_index);");
        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_source_estimate_events_time ON source_estimate_events(event_utc);");
        ExecuteNonQuery(connection, null, "CREATE INDEX IF NOT EXISTS idx_source_estimate_events_session ON source_estimate_events(session_id, event_index);");
    }

    static int? GetSchemaVersion(SqliteConnection connection)
    {
        using var command = CreateCommand(connection, null, "SELECT value FROM schema_meta WHERE key = 'schema_version';");
        var value = command.ExecuteScalar()?.ToString();
        return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var version) ? version : null;
    }

    static void SetSchemaVersion(SqliteConnection connection)
    {
        using var command = CreateCommand(connection, null, """
            INSERT INTO schema_meta(key, value)
            VALUES('schema_version', $version)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """);
        command.Parameters.AddWithValue("$version", SchemaVersion.ToString(CultureInfo.InvariantCulture));
        command.ExecuteNonQuery();
    }

    static void ClearData(SqliteConnection connection)
    {
        ExecuteNonQuery(connection, null, "DELETE FROM source_estimate_events;");
        ExecuteNonQuery(connection, null, "DELETE FROM rate_limit_events;");
        ExecuteNonQuery(connection, null, "DELETE FROM token_events;");
        ExecuteNonQuery(connection, null, "DELETE FROM session_files;");
    }

    static SessionFileState? GetFileState(SqliteConnection connection, SqliteTransaction? transaction, string path)
    {
        using var command = CreateCommand(connection, transaction, """
            SELECT id, file_size_bytes, last_write_utc, index_status
            FROM session_files
            WHERE path = $path;
            """);
        command.Parameters.AddWithValue("$path", path);
        using var reader = command.ExecuteReader();
        return reader.Read()
            ? new SessionFileState(reader.GetInt64(0), reader.GetInt64(1), reader.GetString(2), reader.GetString(3))
            : null;
    }

    static long EnsureSessionFile(SqliteConnection connection, SqliteTransaction transaction, string path, string sessionId, bool isArchived, long size, string lastWriteUtc)
    {
        using (var insert = CreateCommand(connection, transaction, """
            INSERT OR IGNORE INTO session_files(path, session_id, is_archived, file_size_bytes, last_write_utc, index_status)
            VALUES($path, $session_id, $is_archived, $file_size_bytes, $last_write_utc, 'pending');
            """))
        {
            insert.Parameters.AddWithValue("$path", path);
            insert.Parameters.AddWithValue("$session_id", sessionId);
            insert.Parameters.AddWithValue("$is_archived", isArchived ? 1 : 0);
            insert.Parameters.AddWithValue("$file_size_bytes", size);
            insert.Parameters.AddWithValue("$last_write_utc", lastWriteUtc);
            insert.ExecuteNonQuery();
        }

        using var update = CreateCommand(connection, transaction, """
            UPDATE session_files
            SET session_id = $session_id,
                is_archived = $is_archived,
                file_size_bytes = $file_size_bytes,
                last_write_utc = $last_write_utc
            WHERE path = $path;
            """);
        update.Parameters.AddWithValue("$path", path);
        update.Parameters.AddWithValue("$session_id", sessionId);
        update.Parameters.AddWithValue("$is_archived", isArchived ? 1 : 0);
        update.Parameters.AddWithValue("$file_size_bytes", size);
        update.Parameters.AddWithValue("$last_write_utc", lastWriteUtc);
        update.ExecuteNonQuery();

        using var select = CreateCommand(connection, transaction, "SELECT id FROM session_files WHERE path = $path;");
        select.Parameters.AddWithValue("$path", path);
        return Convert.ToInt64(select.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    static void DeleteIndexedEvents(SqliteConnection connection, SqliteTransaction transaction, long sessionFileId)
    {
        foreach (var table in new[] { "source_estimate_events", "rate_limit_events", "token_events" })
        {
            using var command = CreateCommand(connection, transaction, $"DELETE FROM {table} WHERE session_file_id = $session_file_id;");
            command.Parameters.AddWithValue("$session_file_id", sessionFileId);
            command.ExecuteNonQuery();
        }
    }

    static void InsertTokenEvents(SqliteConnection connection, SqliteTransaction transaction, long sessionFileId, string sessionId, IReadOnlyList<UsageDeltaEvent> events)
    {
        using var command = CreateCommand(connection, transaction, """
            INSERT INTO token_events(
              session_file_id, session_id, event_index, event_utc, model,
              total_tokens, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens,
              cumulative_input_tokens
            )
            VALUES(
              $session_file_id, $session_id, $event_index, $event_utc, $model,
              $total_tokens, $input_tokens, $cached_input_tokens, $output_tokens, $reasoning_tokens,
              $cumulative_input_tokens
            );
            """);

        var sessionFileParam = command.Parameters.Add("$session_file_id", SqliteType.Integer);
        var sessionParam = command.Parameters.Add("$session_id", SqliteType.Text);
        var indexParam = command.Parameters.Add("$event_index", SqliteType.Integer);
        var timestampParam = command.Parameters.Add("$event_utc", SqliteType.Text);
        var modelParam = command.Parameters.Add("$model", SqliteType.Text);
        var totalParam = command.Parameters.Add("$total_tokens", SqliteType.Integer);
        var inputParam = command.Parameters.Add("$input_tokens", SqliteType.Integer);
        var cachedInputParam = command.Parameters.Add("$cached_input_tokens", SqliteType.Integer);
        var outputParam = command.Parameters.Add("$output_tokens", SqliteType.Integer);
        var reasoningParam = command.Parameters.Add("$reasoning_tokens", SqliteType.Integer);
        var cumulativeInputParam = command.Parameters.Add("$cumulative_input_tokens", SqliteType.Integer);

        foreach (var usageEvent in events)
        {
            sessionFileParam.Value = sessionFileId;
            sessionParam.Value = sessionId;
            indexParam.Value = usageEvent.EventIndex;
            timestampParam.Value = usageEvent.Timestamp.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
            modelParam.Value = string.IsNullOrWhiteSpace(usageEvent.Model) ? "unknown" : usageEvent.Model;
            totalParam.Value = usageEvent.Metrics.Total;
            inputParam.Value = usageEvent.Metrics.Input;
            cachedInputParam.Value = usageEvent.Metrics.CachedInput;
            outputParam.Value = usageEvent.Metrics.Output;
            reasoningParam.Value = usageEvent.Metrics.Reasoning;
            cumulativeInputParam.Value = usageEvent.CumulativeInput;
            command.ExecuteNonQuery();
        }
    }

    static void InsertRateLimitEvents(SqliteConnection connection, SqliteTransaction transaction, long sessionFileId, string sessionId, IReadOnlyList<RateLimitEvent> events)
    {
        using var command = CreateCommand(connection, transaction, """
            INSERT INTO rate_limit_events(
              session_file_id, session_id, event_index, event_utc, source_timestamp, plan_type,
              window_name, used_percent, remaining_percent, window_minutes, resets_at_local
            )
            VALUES(
              $session_file_id, $session_id, $event_index, $event_utc, $source_timestamp, $plan_type,
              $window_name, $used_percent, $remaining_percent, $window_minutes, $resets_at_local
            );
            """);

        var sessionFileParam = command.Parameters.Add("$session_file_id", SqliteType.Integer);
        var sessionParam = command.Parameters.Add("$session_id", SqliteType.Text);
        var indexParam = command.Parameters.Add("$event_index", SqliteType.Integer);
        var timestampParam = command.Parameters.Add("$event_utc", SqliteType.Text);
        var sourceTimestampParam = command.Parameters.Add("$source_timestamp", SqliteType.Text);
        var planTypeParam = command.Parameters.Add("$plan_type", SqliteType.Text);
        var windowParam = command.Parameters.Add("$window_name", SqliteType.Text);
        var usedParam = command.Parameters.Add("$used_percent", SqliteType.Real);
        var remainingParam = command.Parameters.Add("$remaining_percent", SqliteType.Real);
        var windowMinutesParam = command.Parameters.Add("$window_minutes", SqliteType.Real);
        var resetsAtParam = command.Parameters.Add("$resets_at_local", SqliteType.Text);

        foreach (var rateEvent in events)
        {
            sessionFileParam.Value = sessionFileId;
            sessionParam.Value = sessionId;
            indexParam.Value = rateEvent.EventIndex;
            timestampParam.Value = rateEvent.Timestamp.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
            sourceTimestampParam.Value = rateEvent.EventTimestamp is null ? DBNull.Value : rateEvent.EventTimestamp;
            planTypeParam.Value = rateEvent.PlanType is null ? DBNull.Value : rateEvent.PlanType;
            windowParam.Value = string.IsNullOrWhiteSpace(rateEvent.Window) ? "unknown" : rateEvent.Window;
            usedParam.Value = rateEvent.UsedPercent;
            remainingParam.Value = rateEvent.RemainingPercent;
            windowMinutesParam.Value = rateEvent.WindowMinutes is null ? DBNull.Value : rateEvent.WindowMinutes.Value;
            resetsAtParam.Value = rateEvent.ResetsAt is null ? DBNull.Value : rateEvent.ResetsAt;
            command.ExecuteNonQuery();
        }
    }

    static void InsertSourceEstimateEvents(SqliteConnection connection, SqliteTransaction transaction, long sessionFileId, string sessionId, IReadOnlyList<SourceEstimateEvent> events)
    {
        using var command = CreateCommand(connection, transaction, """
            INSERT INTO source_estimate_events(
              session_file_id, session_id, event_index, event_utc, model, source, side,
              estimated_tokens, estimated_chars, attribution
            )
            VALUES(
              $session_file_id, $session_id, $event_index, $event_utc, $model, $source, $side,
              $estimated_tokens, $estimated_chars, $attribution
            );
            """);

        var sessionFileParam = command.Parameters.Add("$session_file_id", SqliteType.Integer);
        var sessionParam = command.Parameters.Add("$session_id", SqliteType.Text);
        var indexParam = command.Parameters.Add("$event_index", SqliteType.Integer);
        var timestampParam = command.Parameters.Add("$event_utc", SqliteType.Text);
        var modelParam = command.Parameters.Add("$model", SqliteType.Text);
        var sourceParam = command.Parameters.Add("$source", SqliteType.Text);
        var sideParam = command.Parameters.Add("$side", SqliteType.Text);
        var tokensParam = command.Parameters.Add("$estimated_tokens", SqliteType.Integer);
        var charsParam = command.Parameters.Add("$estimated_chars", SqliteType.Integer);
        var attributionParam = command.Parameters.Add("$attribution", SqliteType.Text);

        foreach (var sourceEvent in events)
        {
            sessionFileParam.Value = sessionFileId;
            sessionParam.Value = sessionId;
            indexParam.Value = sourceEvent.EventIndex;
            timestampParam.Value = sourceEvent.Timestamp.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
            modelParam.Value = string.IsNullOrWhiteSpace(sourceEvent.Model) ? "unknown" : sourceEvent.Model;
            sourceParam.Value = sourceEvent.Source;
            sideParam.Value = sourceEvent.Side;
            tokensParam.Value = sourceEvent.Tokens;
            charsParam.Value = sourceEvent.Chars;
            attributionParam.Value = sourceEvent.Attribution;
            command.ExecuteNonQuery();
        }
    }

    static void UpdateIndexedFile(SqliteConnection connection, SqliteTransaction transaction, long sessionFileId, long size, string lastWriteUtc, int lineCount, DateTime? lastEventUtc)
    {
        using var command = CreateCommand(connection, transaction, """
            UPDATE session_files
            SET file_size_bytes = $file_size_bytes,
                last_write_utc = $last_write_utc,
                line_count = $line_count,
                last_indexed_utc = $last_indexed_utc,
                last_event_utc = $last_event_utc,
                index_status = 'indexed',
                error_message = NULL
            WHERE id = $id;
            """);
        command.Parameters.AddWithValue("$id", sessionFileId);
        command.Parameters.AddWithValue("$file_size_bytes", size);
        command.Parameters.AddWithValue("$last_write_utc", lastWriteUtc);
        command.Parameters.AddWithValue("$line_count", lineCount);
        command.Parameters.AddWithValue("$last_indexed_utc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
        command.Parameters.AddWithValue("$last_event_utc", lastEventUtc is null ? DBNull.Value : lastEventUtc.Value.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture));
        command.ExecuteNonQuery();
    }

    static void SetFileStatus(SqliteConnection connection, SqliteTransaction transaction, long sessionFileId, string status, string? error)
    {
        using var command = CreateCommand(connection, transaction, """
            UPDATE session_files
            SET index_status = $status,
                error_message = $error
            WHERE id = $id;
            """);
        command.Parameters.AddWithValue("$id", sessionFileId);
        command.Parameters.AddWithValue("$status", status);
        command.Parameters.AddWithValue("$error", error is null ? DBNull.Value : error);
        command.ExecuteNonQuery();
    }

    static void MarkFileError(SqliteConnection connection, SqliteTransaction transaction, string path, string error)
    {
        using var command = CreateCommand(connection, transaction, """
            UPDATE session_files
            SET index_status = 'error',
                error_message = $error
            WHERE path = $path;
            """);
        command.Parameters.AddWithValue("$path", path);
        command.Parameters.AddWithValue("$error", error);
        command.ExecuteNonQuery();
    }

    static DateTime? ParseUtc(string? value) =>
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dto)
            ? dto.UtcDateTime
            : null;

    static string? GetNullableString(SqliteDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);

    static SqliteCommand CreateCommand(SqliteConnection connection, SqliteTransaction? transaction, string text)
    {
        var command = connection.CreateCommand();
        command.CommandText = text;
        if (transaction is not null)
        {
            command.Transaction = transaction;
        }

        return command;
    }

    static void ExecuteNonQuery(SqliteConnection connection, SqliteTransaction? transaction, string text)
    {
        using var command = CreateCommand(connection, transaction, text);
        command.ExecuteNonQuery();
    }

    record SessionFileState(long Id, long FileSizeBytes, string LastWriteUtc, string IndexStatus);
}

sealed class DashboardServer
{
    readonly MonitorOptions _options;
    readonly UsageMonitor _monitor;
    TcpListener? _listener;
    volatile bool _shutdownRequested;

    public DashboardServer(MonitorOptions options, UsageMonitor monitor)
    {
        _options = options;
        _monitor = monitor;
    }

    public void Run()
    {
        if (!Directory.Exists(_options.DashboardRoot))
        {
            throw new DirectoryNotFoundException($"Dashboard asset folder not found: {_options.DashboardRoot}");
        }

        var requestedPort = _options.DashboardPort;
        for (var port = requestedPort; port <= requestedPort + 20; port++)
        {
            try
            {
                _listener = new TcpListener(IPAddress.Loopback, port);
                _listener.Start();
                _options.DashboardPort = port;
                if (port != requestedPort)
                {
                    Console.WriteLine($"Port {requestedPort} is unavailable; using http://127.0.0.1:{port}/ instead.");
                }
                break;
            }
            catch (SocketException)
            {
                _listener?.Stop();
                _listener = null;
            }
        }

        if (_listener is null)
        {
            throw new InvalidOperationException($"Unable to listen on ports {requestedPort}-{requestedPort + 20}.");
        }

        var prefix = $"http://127.0.0.1:{_options.DashboardPort}/";
        if (!_options.NoOpen)
        {
            if (!TryOpenDashboardUrl(prefix))
            {
                Console.WriteLine($"Open this URL in your browser: {prefix}");
            }
        }

        Console.WriteLine($"Codex usage dashboard running at {prefix}");
        Console.WriteLine("Press Ctrl+C to stop.");
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            _shutdownRequested = true;
            _listener.Stop();
        };

        try
        {
            while (!_shutdownRequested)
            {
                var client = _listener.AcceptTcpClient();
                _ = Task.Run(() =>
                {
                    using (client)
                    {
                        HandleClient(client);
                    }
                });
            }
        }
        catch (SocketException) when (_shutdownRequested)
        {
        }
        finally
        {
            _listener.Stop();
        }
    }

    void HandleClient(TcpClient client)
    {
        client.ReceiveTimeout = 3000;
        client.SendTimeout = 10000;

        try
        {
            var request = ReadRequest(client);
            if (request is null)
            {
                return;
            }

            if (request.Path == "/api/usage")
            {
                var snapshot = _monitor.GetLatestSnapshot();
                if (snapshot is null)
                {
                    WriteResponse(client, 404, "application/json; charset=utf-8", JsonSerializer.Serialize(new { error = "No Codex usage snapshot found." }, JsonTools.JsonOptions));
                    return;
                }

                WriteResponse(client, 200, "application/json; charset=utf-8", JsonSerializer.Serialize(SnapshotJson.From(snapshot, _options), JsonTools.JsonOptions));
            }
            else if (request.Path == "/api/shutdown")
            {
                if (request.Method != "POST")
                {
                    WriteResponse(client, 405, "application/json; charset=utf-8", JsonSerializer.Serialize(new { error = "Use POST to stop the dashboard." }, JsonTools.JsonOptions));
                    return;
                }

                _shutdownRequested = true;
                WriteResponse(client, 200, "application/json; charset=utf-8", JsonSerializer.Serialize(new { status = "stopping" }, JsonTools.JsonOptions));
                Console.WriteLine("Shutdown requested from dashboard.");
                Task.Run(() =>
                {
                    Thread.Sleep(100);
                    _listener?.Stop();
                });
            }
            else
            {
                var asset = GetAsset(request.Path);
                if (asset is null)
                {
                    WriteResponse(client, 404, "text/plain; charset=utf-8", "Not found");
                    return;
                }

                WriteResponse(client, 200, asset.Value.ContentType, File.ReadAllText(asset.Value.Path));
            }
        }
        catch (IOException ex) when (IsSocketTimeout(ex))
        {
        }
        catch (Exception ex)
        {
            WriteResponse(client, 500, "application/json; charset=utf-8", JsonSerializer.Serialize(new { error = ex.Message }, JsonTools.JsonOptions));
        }
    }

    RequestInfo? ReadRequest(TcpClient client)
    {
        using var reader = new StreamReader(client.GetStream(), Encoding.ASCII, leaveOpen: true);
        var requestLine = reader.ReadLine();
        while (true)
        {
            var line = reader.ReadLine();
            if (line is null or "")
            {
                break;
            }
        }

        if (string.IsNullOrWhiteSpace(requestLine))
        {
            return null;
        }

        var parts = requestLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2)
        {
            return new RequestInfo("GET", "/");
        }

        var path = "/";
        try
        {
            path = new Uri("http://localhost" + parts[1]).AbsolutePath;
        }
        catch
        {
        }

        return new RequestInfo(parts[0].ToUpperInvariant(), path);
    }

    static bool IsSocketTimeout(Exception ex)
    {
        for (var current = ex; current is not null; current = current.InnerException)
        {
            if (current is SocketException socketException && socketException.SocketErrorCode == SocketError.TimedOut)
            {
                return true;
            }
        }

        return false;
    }

    (string Path, string ContentType)? GetAsset(string path)
    {
        var fileName = path switch
        {
            "/" or "/index.html" => "index.html",
            "/styles.css" => "styles.css",
            "/app.js" => "app.js",
            _ => null
        };
        if (fileName is null)
        {
            return null;
        }

        var fullPath = Path.Combine(_options.DashboardRoot, fileName);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException($"Dashboard asset not found: {fullPath}");
        }

        var contentType = fileName.EndsWith(".css", StringComparison.OrdinalIgnoreCase)
            ? "text/css; charset=utf-8"
            : fileName.EndsWith(".js", StringComparison.OrdinalIgnoreCase)
                ? "application/javascript; charset=utf-8"
                : "text/html; charset=utf-8";
        return (fullPath, contentType);
    }

    static void WriteResponse(TcpClient client, int statusCode, string contentType, string body)
    {
        var reason = statusCode switch
        {
            200 => "OK",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            _ => "OK"
        };
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var header = $"HTTP/1.1 {statusCode} {reason}\r\nContent-Type: {contentType}\r\nContent-Length: {bodyBytes.Length}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n";
        var headerBytes = Encoding.ASCII.GetBytes(header);
        var stream = client.GetStream();
        stream.Write(headerBytes);
        stream.Write(bodyBytes);
        stream.Flush();
    }

    record RequestInfo(string Method, string Path);

    static bool TryOpenDashboardUrl(string url)
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Mozilla Firefox", "firefox.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Mozilla Firefox", "firefox.exe")
        };

        foreach (var candidate in candidates.Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (File.Exists(candidate) && TryStartBrowser(candidate, url))
            {
                return true;
            }
        }

        foreach (var command in new[] { "msedge.exe", "chrome.exe", "firefox.exe" })
        {
            if (TryStartBrowser(command, url))
            {
                return true;
            }
        }

        return false;
    }

    static bool TryStartBrowser(string fileName, string url)
    {
        try
        {
            var start = new ProcessStartInfo(fileName)
            {
                UseShellExecute = false
            };
            start.ArgumentList.Add(url);
            Process.Start(start);
            return true;
        }
        catch
        {
            return false;
        }
    }
}

static class ConsoleRenderer
{
    public static void Show(MonitorOptions options, Snapshot? snapshot)
    {
        try
        {
            Console.Clear();
        }
        catch (IOException)
        {
        }

        Console.WriteLine("Codex usage monitor");
        Console.WriteLine($"Updated   : {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        if (snapshot is null)
        {
            Console.WriteLine();
            Console.WriteLine($"No Codex usage snapshot found under {options.CodexHome}");
            return;
        }

        Console.WriteLine($"Event     : {snapshot.Timestamp}");
        Console.WriteLine($"Plan      : {snapshot.PlanType ?? "unknown"}");
        Console.WriteLine($"Session   : {snapshot.Session}");
        Console.WriteLine($"Source    : {snapshot.SourceFile}");
        Console.WriteLine();
        PrintRows("Rate limits", snapshot.RateLimitRows.Select(r => $"{r.Window,-10} used {r.UsedPercent,6:N2}% remaining {r.RemainingPercent,6:N2}% resets {UsageMonitor.FormatDisplayDateTime(r.ResetsAt) ?? ""}"));
        PrintRows("Rolling token usage, local estimate", snapshot.RollingTokenRows.Select(r => $"{r.Window,-13} total {r.Total,12:N0} input {r.Input,12:N0} cached {r.CachedInput,12:N0} output {r.Output,12:N0} reasoning {r.Reasoning,12:N0} events {r.Events,5:N0}"));
        PrintRows("Estimated token cost by model, local estimate", snapshot.ModelTokenRows.Select(r => $"{r.Window,-13} {r.Model,-16} {r.PricingBand,-5} total {r.Total,12:N0} input {r.Input,12:N0} output {r.Output,12:N0} cost {r.EstimatedCost?.ToString("N4", CultureInfo.InvariantCulture) ?? ""} {r.CostUnit ?? ""}"));
        PrintRows("API no-compaction scenario by model", snapshot.NoCompactionModelTokenRows.Select(r => $"{r.Window,-13} {r.Model,-16} {r.PricingBand,-5} total {r.Total,12:N0} input {r.Input,12:N0} output {r.Output,12:N0} cost {r.EstimatedCost?.ToString("N4", CultureInfo.InvariantCulture) ?? ""} {r.CostUnit ?? ""}"));
        PrintRows("Conversation token usage", snapshot.TokenRows.Select(r => $"{r.Scope,-20} total {r.Total,12:N0} input {r.Input,12:N0} cached {r.CachedInput,12:N0} output {r.Output,12:N0} reasoning {r.Reasoning,12:N0}"));
        if (snapshot.ContextWindow is not null)
        {
            Console.WriteLine($"Model context window: {snapshot.ContextWindow} tokens");
        }

        if (!options.Once)
        {
            Console.WriteLine();
            Console.WriteLine($"Refreshing every {options.RefreshSeconds}s. Press Ctrl+C to stop.");
            Console.WriteLine($"Cost refresh cadence: 5h every {options.CostFiveHourRefreshSeconds}s, week every {options.CostWeekRefreshSeconds}s, month every {options.CostMonthRefreshSeconds}s.");
        }
    }

    static void PrintRows(string title, IEnumerable<string> rows)
    {
        var materialized = rows.ToList();
        if (materialized.Count == 0)
        {
            Console.WriteLine($"{title}: no data yet.");
            Console.WriteLine();
            return;
        }

        Console.WriteLine(title);
        foreach (var row in materialized)
        {
            Console.WriteLine(row);
        }
        Console.WriteLine();
    }
}

static class SnapshotJson
{
    public static object From(Snapshot snapshot, MonitorOptions options)
    {
        var modelCostTotals = new[] { "Last 5 hours", "This week", "This month" }.Select(window =>
        {
            var rows = snapshot.ModelTokenRows.Where(row => row.Window == window).ToList();
            var usd = TotalUsd(rows);
            return new { Window = window, TotalCostUsd = usd, TotalCostSgd = Math.Round(usd * options.UsdToSgdRate, 4), TotalCostCredits = TotalCredits(rows) };
        }).ToList();

        var noCompactionModelCostTotals = new[] { "Last 5 hours", "This week", "This month" }.Select(window =>
        {
            var rows = snapshot.NoCompactionModelTokenRows.Where(row => row.Window == window).ToList();
            var usd = TotalUsd(rows);
            return new { Window = window, TotalCostUsd = usd, TotalCostSgd = Math.Round(usd * options.UsdToSgdRate, 4), TotalCostCredits = 0.0 };
        }).ToList();

        var periodTotals = snapshot.ModelTokenPeriodWindows.Select(period =>
        {
            var rows = snapshot.ModelTokenPeriodRows.Where(row => row.PeriodGroup == period.Group && row.PeriodName == period.Name).ToList();
            var totalInput = rows.Sum(r => r.Input);
            var cached = rows.Sum(r => r.CachedInput);
            var usd = TotalUsd(rows);
            return new
            {
                PeriodGroup = period.Group,
                PeriodName = period.Name,
                PeriodLabel = period.Label,
                PeriodSortOrder = period.SortOrder,
                Total = rows.Sum(r => r.Total),
                Input = totalInput,
                CachedInput = cached,
                NonCachedInput = Math.Max(0, totalInput - cached),
                Output = rows.Sum(r => r.Output),
                Reasoning = rows.Sum(r => r.Reasoning),
                Events = rows.Sum(r => r.Events),
                TotalCostUsd = usd,
                TotalCostSgd = Math.Round(usd * options.UsdToSgdRate, 4),
                TotalCostCredits = TotalCredits(rows)
            };
        }).OrderBy(r => r.PeriodGroup).ThenBy(r => r.PeriodSortOrder).ToList();

        var noCompactionPeriodTotals = snapshot.ModelTokenPeriodWindows.Select(period =>
        {
            var rows = snapshot.NoCompactionModelTokenPeriodRows.Where(row => row.PeriodGroup == period.Group && row.PeriodName == period.Name).ToList();
            var totalInput = rows.Sum(r => r.Input);
            var cached = rows.Sum(r => r.CachedInput);
            var usd = TotalUsd(rows);
            return new
            {
                PeriodGroup = period.Group,
                PeriodName = period.Name,
                PeriodLabel = period.Label,
                PeriodSortOrder = period.SortOrder,
                Total = rows.Sum(r => r.Total),
                Input = totalInput,
                CachedInput = cached,
                NonCachedInput = Math.Max(0, totalInput - cached),
                Output = rows.Sum(r => r.Output),
                Reasoning = rows.Sum(r => r.Reasoning),
                Events = rows.Sum(r => r.Events),
                TotalCostUsd = usd,
                TotalCostSgd = Math.Round(usd * options.UsdToSgdRate, 4),
                TotalCostCredits = 0.0
            };
        }).OrderBy(r => r.PeriodGroup).ThenBy(r => r.PeriodSortOrder).ToList();

        return new
        {
            UpdatedAtLocal = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
            EventTimestamp = snapshot.Timestamp,
            snapshot.PlanType,
            snapshot.Session,
            snapshot.SourceFile,
            snapshot.CostBasis,
            snapshot.CostBasisMode,
            snapshot.PricingMode,
            snapshot.PricingSource,
            snapshot.RegionalUpliftApplied,
            RateLimitRows = snapshot.RateLimitRows.Select(r => new { r.Window, r.UsedPercent, r.RemainingPercent, r.WindowMinutes, ResetsAt = UsageMonitor.FormatDisplayDateTime(r.ResetsAt) }).ToList(),
            RateLimitHistoryRows = snapshot.RateLimitHistoryRows.Select(r => new { SampledAt = UsageMonitor.FormatLocalDateTime(r.SampledAt), r.EventTimestamp, r.PlanType, r.Window, r.UsedPercent, r.RemainingPercent, r.WindowMinutes, r.ResetsAt, r.Session, r.SourceFile }).DistinctBy(r => $"{r.SampledAt}|{r.Window}|{Math.Round(r.UsedPercent, 2)}|{Math.Round(r.RemainingPercent, 2)}|{r.ResetsAt}").ToList(),
            RateLimitHistorySummaryRows = snapshot.RateLimitHistorySummaryRows.Select(r => new { r.Window, r.LatestUsedPercent, r.PeakUsedPercent, r.AverageUsedPercent, r.Samples, r.ResetCount, FirstSampledAt = UsageMonitor.FormatLocalDateTime(r.FirstSampledAt), LastSampledAt = UsageMonitor.FormatLocalDateTime(r.LastSampledAt) }).ToList(),
            snapshot.RateLimitHistoryDays,
            snapshot.RateLimitHistorySampleSeconds,
            RollingTokenRows = snapshot.RollingTokenRows.Select(CopyTokenBucket).ToList(),
            ModelTokenRows = snapshot.ModelTokenRows.Select(CopyTokenBucket).ToList(),
            NoCompactionModelTokenRows = snapshot.NoCompactionModelTokenRows.Select(CopyTokenBucket).ToList(),
            ModelTokenPeriodRows = snapshot.ModelTokenPeriodRows.Select(CopyTokenBucket).ToList(),
            NoCompactionModelTokenPeriodRows = snapshot.NoCompactionModelTokenPeriodRows.Select(CopyTokenBucket).ToList(),
            snapshot.ModelTokenPeriodWindows,
            SourceCostRows = snapshot.SourceCostRows,
            ModelCostTotals = modelCostTotals,
            NoCompactionModelCostTotals = noCompactionModelCostTotals,
            ModelPeriodCostTotals = periodTotals,
            NoCompactionModelPeriodCostTotals = noCompactionPeriodTotals,
            TokenRows = snapshot.TokenRows.Select(CopyUsageRow).ToList(),
            ConversationOverviewRows = snapshot.ConversationOverviewRows.Select(row => new
            {
                row.Session,
                LastModified = UsageMonitor.FormatDisplayDateTime(row.LastModified),
                row.SourceFile,
                TokenRows = row.TokenRows.Select(CopyUsageRow).ToList(),
                TurnTokenRows = row.TurnTokenRows.Select(turn => new
                {
                    turn.Turn,
                    Timestamp = UsageMonitor.FormatLocalDateTime(turn.Timestamp),
                    turn.Model,
                    turn.PricingBand,
                    turn.PricingMode,
                    turn.CostUnit,
                    turn.BillingConfidence,
                    turn.Total,
                    turn.Input,
                    turn.CachedInput,
                    turn.NonCachedInput,
                    turn.Output,
                    turn.Reasoning,
                    turn.EstimatedCost,
                    turn.EstimatedCostUsd,
                    EstimatedCostSgd = turn.EstimatedCostUsd is null ? (double?)null : Math.Round(turn.EstimatedCostUsd.Value * options.UsdToSgdRate, 4),
                    turn.EstimatedCostCredits
                }).ToList(),
                CostTotals = new { row.CostTotals.TotalCostUsd, TotalCostSgd = Math.Round(row.CostTotals.TotalCostUsd * options.UsdToSgdRate, 4), row.CostTotals.TotalCostCredits },
                NoCompactionTurnRows = row.NoCompactionTurnRows.Select(turn => new
                {
                    turn.Turn,
                    Timestamp = UsageMonitor.FormatLocalDateTime(turn.Timestamp),
                    turn.Model,
                    turn.PricingBand,
                    turn.PricingMode,
                    turn.CostUnit,
                    turn.BillingConfidence,
                    turn.Total,
                    turn.Input,
                    turn.CachedInput,
                    turn.NonCachedInput,
                    turn.Output,
                    turn.Reasoning,
                    turn.CumulativeInputBeforeTurn,
                    turn.CumulativeInput,
                    turn.ThresholdTokens,
                    turn.EstimatedCost,
                    turn.EstimatedCostUsd,
                    EstimatedCostSgd = turn.EstimatedCostUsd is null ? (double?)null : Math.Round(turn.EstimatedCostUsd.Value * options.UsdToSgdRate, 4),
                    turn.EstimatedCostCredits
                }).ToList(),
                NoCompactionCostTotals = new { row.NoCompactionCostTotals.TotalCostUsd, TotalCostSgd = Math.Round(row.NoCompactionCostTotals.TotalCostUsd * options.UsdToSgdRate, 4), row.NoCompactionCostTotals.TotalCostCredits },
                row.ContextWindow,
                LatestUsageTimestamp = UsageMonitor.FormatLocalDateTime(row.LatestUsageTimestamp)
            }).ToList(),
            snapshot.ContextWindow,
            options.UsdToSgdRate
        };
    }

    static object CopyUsageRow(TokenUsageRow row) => new
    {
        row.Scope,
        row.Total,
        row.Input,
        row.CachedInput,
        NonCachedInput = Math.Max(0, (row.Input ?? 0) - (row.CachedInput ?? 0)),
        row.Output,
        row.Reasoning
    };

    static object CopyTokenBucket(TokenBucket row) => new
    {
        row.Window,
        row.Model,
        row.PricingBand,
        row.PricingMode,
        row.BillingConfidence,
        row.CostBasisMode,
        row.CostUnit,
        row.Total,
        row.Input,
        row.CachedInput,
        NonCachedInput = Math.Max(0, row.Input - row.CachedInput),
        row.Output,
        row.Reasoning,
        row.Events,
        row.EstimatedCost,
        row.EstimatedCostUsd,
        row.EstimatedCostCredits,
        row.PeriodGroup,
        row.PeriodName,
        row.PeriodLabel,
        row.PeriodStartUtc,
        row.PeriodEndUtc,
        row.PeriodSortOrder
    };

    static double TotalUsd(IEnumerable<ICostRow> rows) => Math.Round(rows.Where(row => row.EstimatedCostUsd is not null).Sum(row => row.EstimatedCostUsd!.Value), 4);
    static double TotalCredits(IEnumerable<ICostRow> rows) => Math.Round(rows.Where(row => row.EstimatedCostCredits is not null).Sum(row => row.EstimatedCostCredits!.Value), 4);
}

static class JsonTools
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = null,
        WriteIndented = false
    };

    public static JsonElement? GetElement(JsonElement? element, params string[] names) => element is null ? null : GetElement(element.Value, names);

    public static JsonElement? GetElement(JsonElement element, params string[] names)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var name in names)
        {
            if (element.TryGetProperty(name, out var value))
            {
                return value;
            }
        }

        return null;
    }

    public static string? GetString(JsonElement? element, params string[] names)
    {
        var value = GetElement(element, names);
        if (value is null)
        {
            return null;
        }

        return value.Value.ValueKind switch
        {
            JsonValueKind.String => value.Value.GetString(),
            JsonValueKind.Number => value.Value.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null
        };
    }

    public static long? GetLong(JsonElement? element, params string[] names)
    {
        var value = GetElement(element, names);
        if (value is null)
        {
            return null;
        }

        if (value.Value.ValueKind == JsonValueKind.Number && value.Value.TryGetInt64(out var number))
        {
            return number;
        }

        return long.TryParse(value.Value.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out number) ? number : null;
    }

    public static long? GetNullableLong(JsonElement? element, params string[] names) => GetLong(element, names);

    public static double? GetDouble(JsonElement? element, params string[] names)
    {
        var value = GetElement(element, names);
        if (value is null)
        {
            return null;
        }

        if (value.Value.ValueKind == JsonValueKind.Number && value.Value.TryGetDouble(out var number))
        {
            return number;
        }

        return double.TryParse(value.Value.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out number) ? number : null;
    }

    public static object? GetRawValue(JsonElement? element)
    {
        if (element is null)
        {
            return null;
        }

        return element.Value.ValueKind switch
        {
            JsonValueKind.String => element.Value.GetString(),
            JsonValueKind.Number when element.Value.TryGetInt64(out var l) => l,
            JsonValueKind.Number when element.Value.TryGetDouble(out var d) => d,
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => element.Value.GetRawText()
        };
    }

    public static JsonElement? Clone(JsonElement? element) => element is null ? null : element.Value.Clone();
}

interface ICostRow
{
    double? EstimatedCostUsd { get; }
    double? EstimatedCostCredits { get; }
}

sealed class Snapshot
{
    public string? Timestamp { get; set; }
    public string? SourceFile { get; set; }
    public string? Session { get; set; }
    public string? PlanType { get; set; }
    public List<RateLimitRow> RateLimitRows { get; set; } = [];
    public List<TokenBucket> RollingTokenRows { get; set; } = [];
    public List<TokenBucket> ModelTokenRows { get; set; } = [];
    public List<TokenBucket> NoCompactionModelTokenRows { get; set; } = [];
    public List<TokenBucket> ModelTokenPeriodRows { get; set; } = [];
    public List<TokenBucket> NoCompactionModelTokenPeriodRows { get; set; } = [];
    public List<PeriodWindow> ModelTokenPeriodWindows { get; set; } = [];
    public List<SourceCostRow> SourceCostRows { get; set; } = [];
    public string? CostBasis { get; set; }
    public string? CostBasisMode { get; set; }
    public string? PricingMode { get; set; }
    public string? PricingSource { get; set; }
    public bool RegionalUpliftApplied { get; set; }
    public List<TokenUsageRow> TokenRows { get; set; } = [];
    public object? ContextWindow { get; set; }
    public List<ConversationOverviewRow> ConversationOverviewRows { get; set; } = [];
    public List<RateLimitHistoryRow> RateLimitHistoryRows { get; set; } = [];
    public List<RateLimitHistorySummaryRow> RateLimitHistorySummaryRows { get; set; } = [];
    public int RateLimitHistoryDays { get; set; }
    public int RateLimitHistorySampleSeconds { get; set; }
}

sealed class RateLimitRow
{
    public string? Window { get; set; }
    public double UsedPercent { get; set; }
    public double RemainingPercent { get; set; }
    public double? WindowMinutes { get; set; }
    public DateTime? ResetsAt { get; set; }
}

sealed class TokenUsageRow
{
    public string? Scope { get; set; }
    public long? Total { get; set; }
    public long? Input { get; set; }
    public long? CachedInput { get; set; }
    public long? Output { get; set; }
    public long? Reasoning { get; set; }
}

sealed class TokenBucket : ICostRow
{
    public string? Window { get; set; }
    public string? Model { get; set; }
    public string PricingBand { get; set; } = "Short";
    public string? PricingMode { get; set; }
    public string? BillingConfidence { get; set; }
    public string? CostBasisMode { get; set; }
    public string? CostUnit { get; set; }
    public long Total { get; set; }
    public long Input { get; set; }
    public long CachedInput { get; set; }
    public long Output { get; set; }
    public long Reasoning { get; set; }
    public int Events { get; set; }
    public double? EstimatedCost { get; set; }
    public double? EstimatedCostUsd { get; set; }
    public double? EstimatedCostCredits { get; set; }
    public string? PeriodGroup { get; set; }
    public string? PeriodName { get; set; }
    public string? PeriodLabel { get; set; }
    public DateTime? PeriodStartUtc { get; set; }
    public DateTime? PeriodEndUtc { get; set; }
    public int? PeriodSortOrder { get; set; }
}

sealed class TurnTokenRow : ICostRow
{
    public int Turn { get; set; }
    public DateTime Timestamp { get; set; }
    public string? Model { get; set; }
    public string? PricingBand { get; set; }
    public string? PricingMode { get; set; }
    public string? CostUnit { get; set; }
    public string? BillingConfidence { get; set; }
    public long Total { get; set; }
    public long Input { get; set; }
    public long CachedInput { get; set; }
    public long NonCachedInput { get; set; }
    public long Output { get; set; }
    public long Reasoning { get; set; }
    public double? EstimatedCost { get; set; }
    public double? EstimatedCostUsd { get; set; }
    public double? EstimatedCostCredits { get; set; }
}

sealed class NoCompactionTurnTokenRow : ICostRow
{
    public int Turn { get; set; }
    public DateTime Timestamp { get; set; }
    public string? Model { get; set; }
    public string? PricingBand { get; set; }
    public string? PricingMode { get; set; }
    public string? CostUnit { get; set; }
    public string? BillingConfidence { get; set; }
    public long Total { get; set; }
    public long Input { get; set; }
    public long CachedInput { get; set; }
    public long NonCachedInput { get; set; }
    public long Output { get; set; }
    public long Reasoning { get; set; }
    public long CumulativeInputBeforeTurn { get; set; }
    public long CumulativeInput { get; set; }
    public long ThresholdTokens { get; set; }
    public double? EstimatedCost { get; set; }
    public double? EstimatedCostUsd { get; set; }
    public double? EstimatedCostCredits { get; set; }
}

sealed class ConversationOverviewRow
{
    public string? Session { get; set; }
    public DateTime LastModified { get; set; }
    public string? SourceFile { get; set; }
    public List<TokenUsageRow> TokenRows { get; set; } = [];
    public List<TurnTokenRow> TurnTokenRows { get; set; } = [];
    public ConversationCostTotals CostTotals { get; set; } = new(0, 0);
    public List<NoCompactionTurnTokenRow> NoCompactionTurnRows { get; set; } = [];
    public ConversationCostTotals NoCompactionCostTotals { get; set; } = new(0, 0);
    public object? ContextWindow { get; set; }
    public DateTime? LatestUsageTimestamp { get; set; }
}

sealed class RateLimitHistoryRow
{
    public DateTime SampledAt { get; set; }
    public string? EventTimestamp { get; set; }
    public string? PlanType { get; set; }
    public string? Window { get; set; }
    public double UsedPercent { get; set; }
    public double RemainingPercent { get; set; }
    public double? WindowMinutes { get; set; }
    public string? ResetsAt { get; set; }
    public string? Session { get; set; }
    public string? SourceFile { get; set; }
}

sealed class RateLimitHistorySummaryRow
{
    public string? Window { get; set; }
    public double LatestUsedPercent { get; set; }
    public double PeakUsedPercent { get; set; }
    public double AverageUsedPercent { get; set; }
    public int Samples { get; set; }
    public int ResetCount { get; set; }
    public DateTime FirstSampledAt { get; set; }
    public DateTime LastSampledAt { get; set; }
}

sealed class SourceEstimateBucket
{
    public string? Window { get; set; }
    public string? Model { get; set; }
    public string? Source { get; set; }
    public long EstimatedInputTokens { get; set; }
    public long EstimatedOutputTokens { get; set; }
    public long EstimatedChars { get; set; }
    public int Events { get; set; }
    public string Attribution { get; set; } = "Field text estimate";
    public SourceEstimateBucket Clone() => (SourceEstimateBucket)MemberwiseClone();
}

sealed class SourceCostRow : ICostRow
{
    public string? Window { get; set; }
    public string? Model { get; set; }
    public string? Source { get; set; }
    public string? PricingMode { get; set; }
    public string? CostBasisMode { get; set; }
    public string? CostUnit { get; set; }
    public string? PricingBand { get; set; }
    public string? BillingConfidence { get; set; }
    public long EstimatedChars { get; set; }
    public long EstimatedInputTokens { get; set; }
    public long EstimatedOutputTokens { get; set; }
    public long EstimatedTokens { get; set; }
    public long AllocatedInput { get; set; }
    public long AllocatedCachedInput { get; set; }
    public long AllocatedNonCachedInput { get; set; }
    public long AllocatedOutput { get; set; }
    public long AllocatedTokens { get; set; }
    public long ReconciliationDelta { get; set; }
    public int Events { get; set; }
    public double? EstimatedCost { get; set; }
    public double? EstimatedCostUsd { get; set; }
    public double? EstimatedCostCredits { get; set; }
    public string? Attribution { get; set; }
}

record UsageMetrics(long Total, long Input, long CachedInput, long Output, long Reasoning);
record UsageDeltaEvent(DateTime Timestamp, string Model, UsageMetrics Metrics, int EventIndex = 0, long CumulativeInput = 0);
record RateLimitEvent(DateTime Timestamp, string? EventTimestamp, string? PlanType, string? Window, double UsedPercent, double RemainingPercent, double? WindowMinutes, string? ResetsAt, int EventIndex = 0);
record SourceEstimateEvent(DateTime Timestamp, string Model, string Source, string Side, long Tokens, long Chars, string Attribution, int EventIndex = 0);
record UsageParseResult(List<UsageDeltaEvent> Events, List<RateLimitEvent> RateLimitEvents, List<SourceEstimateEvent> SourceEstimateEvents, int LineCount, DateTime? LastEventUtc);
record PricingRecord(string Basis, string Unit, string Mode, string Model, string ContextBand, double InputPerMillion, double CachedInputPerMillion, double OutputPerMillion);
record PeriodWindow(string Group, string Name, string Label, DateTime StartUtc, DateTime EndUtc, int SortOrder, int RefreshSeconds);
record SourceEstimate(string Source, string Side, long Tokens, long Chars, string Attribution);
record ConversationCostTotals(double TotalCostUsd, double TotalCostCredits);
record ConversationMatches(ConversationUsageMatch? Usage, ConversationUsageMatch? RateLimit);
record BackfillResult(int Imported, int Saved, string Path, bool Disabled);

sealed class ConversationUsageMatch
{
    public DateTime? Timestamp { get; set; }
    public string? EventTimestampText { get; set; }
    public string? SourceFile { get; set; }
    public string? Session { get; set; }
    public JsonElement? RateLimits { get; set; }
    public JsonElement? TotalUsage { get; set; }
    public JsonElement? LastUsage { get; set; }
    public object? ContextWindow { get; set; }
}
