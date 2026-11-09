param(
    [string]$DotNetPath = (Join-Path $env:USERPROFILE '.dotnet/dotnet.exe')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $repoRoot 'src/UsageViewer/bin/Release/net10.0-windows'
$assemblyPath = Join-Path $buildPath 'UsageViewer.dll'
if ((Test-Path -LiteralPath $assemblyPath) -eq $false) {
    throw 'Build UsageViewer.csproj in Release before running this check.'
}

# Run the real Release advisors/store/formatters with synthetic snapshots and an isolated state path.
# No test project, package, account query, existing settings, authentication, or raw response is used.
$probeSource = @'
using System;
using System.Collections;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json;

internal static class DailyBudgetProbe
{
    private static Assembly _app = null!;
    private static string _root = "";
    private static int _passed;
    private static int _sequence;
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-09T16:10:00+09:00");
    private static readonly DateTimeOffset Reset = DateTimeOffset.Parse("2026-11-14T01:10:00+09:00");
    private static readonly TimeZoneInfo Korea = TimeZoneInfo.FindSystemTimeZoneById("Korea Standard Time");

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            _root = args[1];
            AssemblyLoadContext.Default.Resolving += (_, name) =>
            {
                string path = Path.Combine(Path.GetDirectoryName(args[0])!, name.Name + ".dll");
                return File.Exists(path) ? AssemblyLoadContext.Default.LoadFromAssemblyPath(path) : null;
            };
            _app = Assembly.LoadFrom(args[0]);
            CheckBudgets();
            CheckBoundaries();
            CheckStorage();
            CheckPresentation();
            Console.WriteLine($"PASS: {_passed} synthetic daily-budget checks; no accounts or existing settings accessed.");
            return 0;
        }
        catch (CheckException exception)
        {
            Console.Error.WriteLine("FAIL: " + exception.Message);
            return 1;
        }
        catch (Exception)
        {
            Console.Error.WriteLine("FAIL: synthetic daily-budget probe did not complete.");
            return 1;
        }
    }

    private static Type TypeOf(string name) => _app.GetType("UsageViewer." + name, true)!;
    private static object New(string name, params object?[] args) => Activator.CreateInstance(TypeOf(name), args)!;
    private static object? Get(object value, string property) => value.GetType().GetProperty(property)!.GetValue(value);
    private static object Invoke(object target, string method, params object?[] args) => target.GetType()
        .GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
        .Single(item => item.Name == method && item.GetParameters().Length == args.Length).Invoke(target, args)!;
    private static object Static(string name, string method, params object?[] args) => TypeOf(name)
        .GetMethod(method, BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!.Invoke(null, args)!;
    private static Array ArrayOf(string type, params object[] values)
    {
        Array array = Array.CreateInstance(TypeOf(type), values.Length);
        for (int index = 0; index < values.Length; index++)
        {
            array.SetValue(values[index], index);
        }
        return array;
    }
    private static string PathFor() => Path.Combine(_root, "state-" + ++_sequence + ".json");
    private static object Advisor(string? path = null) => New("Services.UsageDailyBudgetAdvisor",
        New("Services.UsageDailyBudgetStore", path ?? PathFor()));
    private static object Window(double remaining = 78, int? duration = 10080, DateTimeOffset? reset = null) =>
        New("Models.UsageWindow", 100 - remaining, duration, reset ?? Reset);
    private static object Bucket(string id, object? first, object? second = null, string? name = null) =>
        New("Models.UsageBucket", id, name ?? id, first, second, null);
    private static object Snapshot(DateTimeOffset at, params object[] buckets) => New("Models.UsageSnapshot",
        "synthetic", ArrayOf("Models.UsageBucket", buckets), at);
    private static object Sample(double remaining = 78, DateTimeOffset? at = null) =>
        Snapshot(at ?? Start, Bucket("weekly", Window(remaining)));
    private static object Evaluate(object advisor, object? snapshot, DateTimeOffset? now = null,
                                   string? error = null, bool stale = false, TimeZoneInfo? zone = null,
                                   string provider = "codex") =>
        Invoke(advisor, "Evaluate", provider, snapshot, error, stale, now ?? Start, zone ?? Korea);
    private static string Status(object budget) => Get(budget, "Status")!.ToString()!;
    private static decimal Additional(object budget) => (decimal)Get(Get(budget, "Limiting")!, "AdditionalPercentPoints")!;
    private static decimal Target(object budget) => (decimal)Get(Get(budget, "Limiting")!, "TargetRemainingPercent")!;
    private static void Check(bool condition, string label)
    {
        if (condition == false)
        {
            throw new CheckException(label);
        }
        _passed++;
    }
    private static void Hold(object budget, string label)
    {
        Check(Status(budget) == "Unavailable" && Get(budget, "Limiting") == null &&
              string.IsNullOrEmpty((string?)Get(budget, "Reason")) == false, label);
    }
    private static object Advice(object snapshot, object budget, DateTimeOffset? now = null,
                                 string? error = null, bool stale = false) =>
        Static("Services.UsagePacingAdvisor", "Evaluate", snapshot, error, stale, now ?? Start, budget);
    private static string Message(object advice) => (string)Static("UI.UsageDisplayHelper", "GetPacingMessage", advice);
    private static string Details(object advice) => (string)Static("UI.UsageDisplayHelper", "FormatPacingDetails", advice);

    private static void CheckBudgets()
    {
        string path = PathFor();
        object advisor = Advisor(path);
        object initial = Evaluate(advisor, Sample());
        Check(Status(initial) == "Ready" && Additional(initial) == 5.07m, "initial 5.07pp");
        Check(Target(initial) == 72.93m && Additional(initial) + Target(initial) == 78m, "conservative target 72.93");
        Check((DateTimeOffset)Get(Get(initial, "Limiting")!, "EndsAt")! == DateTimeOffset.Parse("2026-11-10T00:00:00+09:00"),
              "system-zone midnight endpoint");
        Check(Additional(Evaluate(advisor, Sample(), Start.AddMinutes(5))) == 5.07m, "duplicate does not reallocate");
        object spent = Evaluate(advisor, Sample(76, Start.AddMinutes(6)), Start.AddMinutes(6));
        Check(Additional(spent) == 3.07m && Target(spent) == 72.93m, "same-day spending deducted");
        advisor = Advisor(path);
        Check(Additional(Evaluate(advisor, Sample(76, Start.AddMinutes(7)), Start.AddMinutes(7))) == 3.07m,
              "restart restores fixed target");
        Check(Additional(Evaluate(advisor, Sample(80, Start.AddMinutes(8)), Start.AddMinutes(8))) == 7.07m,
              "upward correction retains target");
        object exhausted = Evaluate(advisor, Sample(72.93, Start.AddMinutes(9)), Start.AddMinutes(9));
        Check(Status(exhausted) == "Exhausted" && Additional(exhausted) == 0m, "target reached is normal exhaustion");
        Check(Message(Advice(Sample(72.93, Start.AddMinutes(9)), exhausted, Start.AddMinutes(9))).Contains("목표 도달"),
              "exhaustion message differs from unavailable");
        Check(Additional(Evaluate(advisor, Sample(70, Start.AddMinutes(10)), Start.AddMinutes(10))) == 0m,
              "no negative additional budget");
        object belowReserve = Evaluate(Advisor(), Sample(8));
        Check(Status(belowReserve) == "Exhausted" && Target(belowReserve) == 8m, "below reserve normal exhaustion");
        Check(Target(Evaluate(Advisor(), Sample(10))) == 10m, "reserve exact boundary");
        Check(Additional(Evaluate(Advisor(), Sample(100))) > 0, "full weekly quota");
        Check(Status(Evaluate(Advisor(), Sample(0))) == "Exhausted", "zero received is valid exhaustion");
        object subCent = Evaluate(Advisor(), Sample(10.001));
        Check(Additional(subCent) == 0 && Target(subCent) >= 10.001m, "sub-cent budget never overstated");
        Hold(Evaluate(advisor, Sample(77, Start.AddMinutes(5)), Start.AddMinutes(11)), "out-of-order receipt");
        Hold(Evaluate(Advisor(path), Sample(78), Start.AddMinutes(1)), "receipt ordering survives restart");

        DateTimeOffset earlyReset = Start.AddHours(1);
        object beforeReset = Snapshot(Start, Bucket("weekly", Window(78, reset: earlyReset)));
        object early = Evaluate(Advisor(), beforeReset);
        Check(Additional(early) == 68m && Target(early) == 10m, "reset before midnight uses all spendable remainder");
        Check((bool)Get(Get(early, "Limiting")!, "EndsAtReset")! && Message(Advice(beforeReset, early)).StartsWith("초기화 전까지"),
              "early reset wording");

        object combined = Snapshot(Start, Bucket("weekly", Window(78), Window(5, 300, Start.AddHours(4))));
        object combinedBudget = Evaluate(Advisor(), combined);
        object low = Advice(combined, combinedBudget);
        Check(Additional(combinedBudget) == 5.07m, "five-hour window does not change weekly budget");
        Check(Get(low, "Level")!.ToString() == "Low" && Message(low).Contains("잔여량이 적어요"), "low priority retained");
        Check(Details(low).Contains("5시간 한도가 더 빠듯해요"), "five-hour warning retained");
        combined = Snapshot(Start, Bucket("weekly", Window(78), Window(50, 300, Start.AddHours(4))));
        Check(Details(Advice(combined, Evaluate(Advisor(), combined))).Contains("단기 사용을 아껴"), "short-term pacing warning");
        object reversed = Snapshot(Start, Bucket("weekly", Window(99, 300, Start.AddHours(1)), Window(78)));
        Check(Additional(Evaluate(Advisor(), reversed)) == 5.07m, "weekly secondary recognized by actual duration");
        object multi = Snapshot(Start, Bucket("a", Window(78), name: "Model A"), Bucket("b", Window(40), name: "Model B"));
        object multiBudget = Evaluate(Advisor(), multi);
        Check(((IEnumerable)Get(multiBudget, "Items")!).Cast<object>().Count() == 2 && Additional(multiBudget) == 2.23m,
              "independent multiple model budgets and tightest summary");
        Check((string)Get(Get(multiBudget, "Limiting")!, "LimitName")! == "Model B · 주간 한도", "summary names limiting model");
        Check(Details(Advice(multi, multiBudget)).Contains("각 모델은 자기 주간 한도 기준"), "model scope explanation");
        multi = Snapshot(Start, Bucket("a", Window(78)), Bucket("b", Window(10)));
        Check(Status(Evaluate(Advisor(), multi)) == "Exhausted", "exhausted model limits positive model summary");
        multi = Snapshot(Start, Bucket("a", Window(78)), Bucket("b", Window(double.NaN)));
        Hold(Evaluate(Advisor(), multi), "invalid model prevents positive aggregate budget");
        object noWeek = Snapshot(Start, Bucket("short", Window(50, 300, Start.AddHours(4))));
        object noWeekBudget = Evaluate(Advisor(), noWeek);
        Check(Status(noWeekBudget) == "NotProvided" && Get(noWeekBudget, "Limiting") == null, "weekly not provided");
        object almostWeek = Snapshot(Start, Bucket("weekly-name", Window(78, 10079)));
        Check(Status(Evaluate(Advisor(), almostWeek)) == "NotProvided", "weekly identification requires exactly 10080 minutes");
        Check(Details(Advice(noWeek, noWeekBudget)).Contains("일일 예산 계산 불가") &&
              Get(Advice(noWeek, noWeekBudget), "Level")!.ToString() == "Caution", "short-term guidance without weekly quota");
        Check(Additional(Evaluate(Advisor(), Sample(), provider: "claude")) == 5.07m, "Claude weekly-only");
        Check(Additional(Evaluate(Advisor(), reversed, provider: "claude")) == 5.07m, "Claude five-hour and weekly");
        advisor = Advisor();
        Evaluate(advisor, Sample());
        Check(Target(Evaluate(advisor, Sample(60), provider: "claude")) != 72.93m, "provider states isolated");

        advisor = Advisor();
        Evaluate(advisor, reversed);
        object positionSwap = Snapshot(Start.AddMinutes(1), Bucket("weekly", Window(76), Window(99, 300, Start.AddHours(1))));
        Check(Additional(Evaluate(advisor, positionSwap, Start.AddMinutes(1))) == 3.07m, "primary-secondary swap retains identity");
        path = PathFor();
        advisor = Advisor(path);
        Evaluate(advisor, beforeReset);
        object nextWeek = Snapshot(earlyReset, Bucket("weekly", Window(100, reset: earlyReset.AddDays(7))));
        object resetBudget = Evaluate(Advisor(path), nextWeek, earlyReset);
        Check(Status(resetBudget) == "Ready" && Target(resetBudget) > 10m, "weekly reset rollover allocates new fixed target");
        advisor = Advisor();
        Evaluate(advisor, Sample());
        object changed = Snapshot(Start.AddMinutes(1), Bucket("weekly", Window(76), Window(99, 300, Start.AddHours(1))));
        Check(Target(Evaluate(advisor, changed, Start.AddMinutes(1))) != 72.93m, "limit configuration transition");
        advisor = Advisor();
        Evaluate(advisor, Sample());
        changed = Snapshot(Start.AddMinutes(1), Bucket("weekly", Window(76, reset: Reset.AddDays(1))));
        Check(Target(Evaluate(advisor, changed, Start.AddMinutes(1))) != 72.93m, "reset transition");
    }

    private static void CheckBoundaries()
    {
        Hold(Evaluate(Advisor(), null), "missing snapshot");
        Hold(Evaluate(Advisor(), Sample(), error: "synthetic failure"), "query error");
        Hold(Evaluate(Advisor(), Sample(), stale: true), "explicit stale flag");
        Check(Status(Evaluate(Advisor(), Sample(), Start.AddMinutes(15))) == "Ready", "freshness exact 15 minutes");
        Hold(Evaluate(Advisor(), Sample(), Start.AddMinutes(15).AddTicks(1)), "freshness beyond 15 minutes");
        Hold(Evaluate(Advisor(), Sample(at: Start.AddSeconds(1))), "future receipt within old tolerance held");
        Hold(Evaluate(Advisor(), Sample(at: Start.AddMinutes(2))), "future receipt beyond old tolerance held");
        foreach (double remaining in new[] { double.NaN, double.PositiveInfinity, -1, 101 })
        {
            Hold(Evaluate(Advisor(), Sample(remaining)), "invalid percentage");
        }
        Hold(Evaluate(Advisor(), Snapshot(Start)), "empty windows");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window(duration: null)))), "missing duration");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window(duration: 0)))), "zero duration");
        object missingReset = New("Models.UsageWindow", 22d, 10080, null);
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", missingReset))), "missing reset");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window(reset: Start)))), "expired exact reset");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window(reset: Start.AddSeconds(-1))))), "expired before reset");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window(reset: Start.AddDays(7).AddTicks(1))))), "reset beyond duration");
        Check(Status(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window(reset: Start.AddDays(7)))))) == "Ready",
              "reset exactly full duration");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window(), Window()))), "ambiguous weekly windows");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("a", Window()), Bucket("a", Window()))), "duplicate bucket identity");
        Hold(Evaluate(Advisor(), Snapshot(Start, Bucket("", Window()))), "empty bucket identity");

        object advisor = Advisor();
        Evaluate(advisor, Sample(), Start.AddMinutes(2));
        Hold(Evaluate(advisor, Sample(), Start.AddMinutes(1)), "system clock rollback");
        Check(Status(Evaluate(advisor, Sample(), Start.AddMinutes(3))) == "Ready", "clock catches up without reallocating");
        DateTimeOffset beforeMidnight = DateTimeOffset.Parse("2026-11-09T23:55:00+09:00");
        DateTimeOffset midnight = DateTimeOffset.Parse("2026-11-10T00:00:00+09:00");
        string path = PathFor();
        advisor = Advisor(path);
        Evaluate(advisor, Sample(at: beforeMidnight), beforeMidnight);
        Hold(Evaluate(advisor, Sample(at: beforeMidnight), midnight), "fresh previous-day sample cannot rebase");
        object nextDay = Evaluate(Advisor(path), Sample(76, midnight), midnight);
        Check(Status(nextDay) == "Ready" && Additional(nextDay) > 10m, "midnight restart new-day allocation");
        object state = Invoke(New("Services.UsageDailyBudgetStore", path), "Load");
        Check(((IEnumerable)Get(Get(state, "State")!, "Entries")!).Cast<object>().Count() == 1, "old date discarded");

        TimeZoneInfo utc = TimeZoneInfo.Utc;
        path = PathFor();
        advisor = Advisor(path);
        Evaluate(advisor, Sample());
        Hold(Evaluate(advisor, Sample(), zone: utc), "timezone change waits for new receipt");
        object shifted = Evaluate(advisor, Sample(at: Start.AddMinutes(1)), Start.AddMinutes(1), zone: utc);
        Check(Status(shifted) == "Ready" && Target(shifted) != 72.93m, "timezone change uses new local boundary");
        Check(Target(Evaluate(Advisor(path), Sample(at: Start.AddMinutes(2)), Start.AddMinutes(2), zone: utc)) == Target(shifted),
              "timezone baseline survives restart");
        advisor = Advisor();
        Evaluate(advisor, Sample());
        Evaluate(advisor, Sample(), provider: "claude");
        Evaluate(advisor, Sample(at: Start.AddMinutes(1)), Start.AddMinutes(1), zone: utc);
        Hold(Evaluate(advisor, Sample(), Start.AddMinutes(1), zone: utc, provider: "claude"),
             "one provider timezone transition preserves other provider receipt guard");

        TimeZoneInfo pacific = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");
        foreach (var test in new[] { ("2026-03-08T00:00:00-08:00", 23), ("2026-11-01T00:00:00-07:00", 25) })
        {
            DateTimeOffset at = DateTimeOffset.Parse(test.Item1);
            object snapshot = Snapshot(at, Bucket("dst", Window(78, reset: at.AddDays(5))));
            object result = Evaluate(Advisor(), snapshot, at, zone: pacific);
            DateTimeOffset end = (DateTimeOffset)Get(Get(result, "Limiting")!, "EndsAt")!;
            Check((end - at).TotalHours == test.Item2, "DST actual elapsed hours " + test.Item2);
            decimal expectedTarget = decimal.Ceiling((78m - 68m * test.Item2 / 120m) * 100m) / 100m;
            Check(Target(result) == expectedTarget, "DST allocation uses actual duration " + test.Item2);
        }
        // Cuba has both invalid and ambiguous local midnights.
        TimeZoneInfo cuba = TimeZoneInfo.FindSystemTimeZoneById("Cuba Standard Time");
        foreach (string timestamp in new[] { "2026-03-07T23:00:00-05:00", "2026-10-31T23:00:00-04:00" })
        {
            DateTimeOffset at = DateTimeOffset.Parse(timestamp);
            object result = Evaluate(Advisor(), Snapshot(at, Bucket("dst", Window(78, reset: at.AddDays(5)))), at, zone: cuba);
            DateTimeOffset end = (DateTimeOffset)Get(Get(result, "Limiting")!, "EndsAt")!;
            Check(end > at && TimeZoneInfo.ConvertTime(end, cuba).Day != TimeZoneInfo.ConvertTime(at, cuba).Day,
                  "midnight transition chooses first real new date");
        }
    }

    private static void CheckStorage()
    {
        string path = PathFor();
        Evaluate(Advisor(path), Sample());
        string saved = File.ReadAllText(path);
        using JsonDocument json = JsonDocument.Parse(saved);
        string[] allowed = { "Provider", "LimitKey", "ConfigurationKey", "LocalDate", "TimeZoneKey", "BaselineAt",
                             "LastReceivedAt", "EndsAt", "ResetsAt", "TargetRemainingPercent" };
        Check(json.RootElement.GetProperty("Entries")[0].EnumerateObject().All(property => allowed.Contains(property.Name)),
              "minimal state field allowlist");
        Check(saved.Contains("synthetic") == false && saved.Contains("weekly") == false && saved.Contains("UsedPercent") == false,
              "no plan, raw identifier or usage history persisted");
        foreach (string corrupt in new[] { "{", "null", "{}", "{\"Version\":2,\"Entries\":[]}",
                                          saved.Replace("72.93", "101"), saved.Replace("72.93", "72.931"),
                                          saved.Replace("\"LimitKey\":\"", "\"LimitKey\":\"INVALID"),
                                          new string('x', 65537) })
        {
            string corruptPath = PathFor();
            File.WriteAllText(corruptPath, corrupt);
            Hold(Evaluate(Advisor(corruptPath), Sample()), "corrupt state is not silently rebased");
            Check(File.ReadAllText(corruptPath) == corrupt, "corrupt state preserved for recovery");
        }
        string restoredPath = PathFor();
        File.WriteAllText(restoredPath, "{");
        Hold(Evaluate(Advisor(restoredPath), Sample()), "damaged state before restoration");
        File.WriteAllText(restoredPath, saved);
        Check(Additional(Evaluate(Advisor(restoredPath), Sample(76, Start.AddMinutes(1)), Start.AddMinutes(1))) == 3.07m,
              "restored state recovers target without reallocation");
        string failedPath = PathFor();
        object failing = Advisor(failedPath);
        Directory.CreateDirectory(failedPath);
        Hold(Evaluate(failing, Sample()), "save failure held");
        Directory.Delete(failedPath);
        object recovered = Evaluate(failing, Sample(76, Start.AddMinutes(1)), Start.AddMinutes(1));
        Check(Target(recovered) == 72.93m && Additional(recovered) == 3.07m, "save retry retains in-memory target");
        Check(Target(Evaluate(Advisor(failedPath), Sample(76, Start.AddMinutes(2)), Start.AddMinutes(2))) == 72.93m,
              "recovered save survives restart");
        string unreadablePath = PathFor();
        Directory.CreateDirectory(unreadablePath);
        Hold(Evaluate(Advisor(unreadablePath), Sample()), "read failure held");
        using (FileStream locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Hold(Evaluate(Advisor(path), Sample()), "locked state read held");
        }
        path = PathFor();
        object advisor = Advisor(path);
        Evaluate(advisor, Sample());
        using (FileStream locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Hold(Evaluate(advisor, Sample(76, Start.AddMinutes(1)), Start.AddMinutes(1)), "locked state write held");
        }
        Check(Additional(Evaluate(advisor, Sample(76, Start.AddMinutes(2)), Start.AddMinutes(2))) == 3.07m,
              "write lock recovery retains target");
        Check(File.Exists(path + ".tmp") == false, "atomic temporary file cleaned");
    }

    private static void CheckPresentation()
    {
        object snapshot = Sample();
        object budget = Evaluate(Advisor(), snapshot);
        object advice = Advice(snapshot, budget);
        string message = Message(advice);
        string detail = Details(advice);
        string basis = (string)Static("UI.UsageDisplayHelper", "FormatPacingBasis", advice);
        Check(message.Contains("5.07%p") && message.Contains("오늘 자정까지"), "explicit additional percentage points");
        Check(detail.Contains("72.93% 이상 유지") && detail.Contains("주간 한도"), "explicit remaining weekly target and scope");
        Check(basis.Contains("10%") && basis.Contains("주간 전체 한도") && basis.Contains("참고 예산"), "reserve and units basis");
        object unavailable = Evaluate(Advisor(), null);
        object unavailableAdvice = Advice(snapshot, unavailable);
        Check(Message(unavailableAdvice).Contains("계산 보류") && Details(unavailableAdvice).Contains("미수신") &&
              Message(unavailableAdvice).Contains("0%") == false, "missing data never displayed as zero success");

        // Construct hidden controls with explicit temporary preferences/profile paths. Never show a window.
        object preferences = New("Services.PopupPreferencesStore", Path.Combine(_root, "view.json"));
        object popup = New("UI.UsagePopup", preferences, Path.Combine(_root, "browser-profile"));
        object bar = New("UI.TopUsageBar");
        try
        {
            Invoke(popup, "SetState", snapshot, false, null, null, null, false, advice, unavailableAdvice);
            object document = Invoke(popup, "BuildDocumentState");
            using JsonDocument payload = JsonDocument.Parse(JsonSerializer.Serialize(document));
            JsonElement pacing = payload.RootElement.GetProperty("providers")[0].GetProperty("pacing");
            Check(pacing.GetProperty("message").GetString() == message && pacing.GetProperty("detail").GetString() == detail &&
                  pacing.GetProperty("basis").GetString() == basis, "popup payload uses shared advice");
            Invoke(bar, "SetUsageTip", "codex", "Codex", snapshot, advice);
            var tips = (IDictionary)bar.GetType().GetField("_usageTips", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(bar)!;
            string tip = (string)tips["codex"]!;
            Check(tip.Contains(message) && tip.Contains(detail) && tip.Contains(basis), "top tooltip uses same budget and basis");
            foreach (double remaining in new[] { double.NaN, double.PositiveInfinity, -1, 101 })
            {
                object invalid = Sample(remaining);
                object invalidAdvice = Advice(invalid, Evaluate(Advisor(), invalid));
                Invoke(popup, "SetState", invalid, false, null, null, null, false, invalidAdvice, unavailableAdvice);
                using JsonDocument invalidPayload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
                JsonElement window = invalidPayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0];
                Check(window.GetProperty("remaining").ValueKind == JsonValueKind.Null && window.GetProperty("invalid").GetBoolean(),
                      "invalid percentages serialize as unknown");
                object metric = Invoke(bar, "CreateMetric", "Codex", invalid, null, false);
                Check((string)Get(metric, "Value")! == "확인 필요", "invalid top metric is not zero or success");
            }
            DateTimeOffset realNow = DateTimeOffset.UtcNow;
            object lowSnapshot = Snapshot(realNow, Bucket("low", Window(5, reset: realNow.AddDays(2)),
                                                          Window(80, 300, realNow.AddHours(2))));
            Invoke(bar, "SetAlertLevel", "Codex", lowSnapshot, null, false);
            object lowMetric = Invoke(bar, "CreateMetric", "Codex", lowSnapshot, null, false);
            Check((string)Get(lowMetric, "Period")! == "주간" && (string)Get(lowMetric, "Value")! == "5%",
                  "top metric retains lowest weekly remaining priority");
            Invoke(bar, "LayoutDock");
            object size = Get(bar, "ClientSize")!;
            int dpi = (int)Get(bar, "DeviceDpi")!;
            Check((int)Get(size, "Width")! == (int)(264 * dpi / 96f) &&
                  (int)Get(size, "Height")! == (int)(32 * dpi / 96f), "top bar remains 264 by 32 DIP");
        }
        finally
        {
            ((IDisposable)popup).Dispose();
            ((IDisposable)bar).Dispose();
        }
        using Stream stream = _app.GetManifestResourceStream("UsageViewer.UI.Popup.html")!;
        using StreamReader reader = new StreamReader(stream);
        string html = reader.ReadToEnd();
        Check(html.Contains("content+pacing(p)") && html.Contains("alertNotice(p)+pacing(p)"), "both HTML views use common pacing renderer");
        Check(html.Contains("esc(a.message)") && html.Contains("esc(a.detail)") && html.Contains("esc(a.basis)"), "all advice text escaped");
        Check(html.Contains("overflow-wrap:anywhere") && html.Contains("white-space:pre-line"), "long advice text can wrap");
    }
}

internal sealed class CheckException(string message) : Exception(message)
{
}
'@

$artifactRoot = Join-Path $repoRoot '.artifacts'
$tempRoot = Join-Path $artifactRoot ('DailyUsageBudget-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $sdkLines = & $DotNetPath --list-sdks
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate the configured .NET SDK.' }
    $sdkLine = $sdkLines | Where-Object { $_ -match '^10\.\S+ \[' } | Select-Object -Last 1
    if ($sdkLine -notmatch '^(\S+) \[(.+)\]$') { throw '.NET 10 SDK is required.' }
    $sdkPath = Join-Path $Matches[2] $Matches[1]
    $dotNetRoot = Split-Path (Split-Path $sdkPath -Parent) -Parent
    $referencePack = Get-ChildItem -LiteralPath (Join-Path $dotNetRoot 'packs/Microsoft.NETCore.App.Ref') -Directory |
        Where-Object { $_.Name -like '10.*' } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    $sourcePath = Join-Path $tempRoot 'Probe.cs'
    $responsePath = Join-Path $tempRoot 'compile.rsp'
    $probePath = Join-Path $tempRoot 'Probe.dll'
    Set-Content -LiteralPath $sourcePath -Value $probeSource -Encoding utf8
    $compileArguments = @('-nologo', '-target:exe', '-nullable:enable', '-warnaserror+', '-langversion:latest',
                          ('-out:"' + $probePath + '"'))
    $compileArguments += Get-ChildItem -LiteralPath (Join-Path $referencePack.FullName 'ref/net10.0') -Filter '*.dll' |
        ForEach-Object { '-r:"' + $_.FullName + '"' }
    $compileArguments += '"' + $sourcePath + '"'
    Set-Content -LiteralPath $responsePath -Value $compileArguments -Encoding utf8
    $compilerOutput = & $DotNetPath exec (Join-Path $sdkPath 'Roslyn/bincore/csc.dll') ('@' + $responsePath) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $compilerOutput | ForEach-Object { $_.ToString().Replace($tempRoot, '<fixture>') }
        throw 'Could not compile the synthetic driver.'
    }
    & $DotNetPath exec --runtimeconfig (Join-Path $buildPath 'UsageViewer.runtimeconfig.json') $probePath $assemblyPath $tempRoot
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic daily-budget checks failed.' }
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedArtifacts = [System.IO.Path]::GetFullPath($artifactRoot) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedTemp.StartsWith($resolvedArtifacts, [System.StringComparison]::OrdinalIgnoreCase) -eq $false -or
        (Split-Path $resolvedTemp -Leaf) -notlike 'DailyUsageBudget-*') {
        throw 'Fixture cleanup path is outside the expected workspace artifact directory.'
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
