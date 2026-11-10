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

# Run the real Release pacing advisor and formatters with synthetic inputs and isolated fixture paths.
# No test project, package, account query, existing settings, authentication, or raw response is used.
$probeSource = @'
using System;
using System.Collections;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Loader;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Drawing;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

internal static class PacingProbe
{
    private static Assembly _app = null!;
    private static string _root = "";
    private static int _passed;
    private static string _document = "";
    private static string _dailyDocument = "";
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-09T18:12:00+09:00");
    private static readonly DateTimeOffset DailyStart = DateTimeOffset.Parse("2026-11-09T00:00:00+09:00");
    private static readonly DateTimeOffset Reset = DateTimeOffset.Parse("2026-11-14T01:10:00+09:00");

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
            CheckExamples();
            CheckInvalid();
            CheckTime();
            CheckStateless();
            CheckDailyAllowance();
            CheckDailyFormula();
            CheckPresentation();
            CheckRendering();
            Console.WriteLine($"PASS: {_passed} synthetic usage-pacing checks; no accounts or user settings accessed.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("FAIL: " + (exception is CheckException ? exception.Message : exception.GetType().Name));
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
    private static object Window(double remaining = 76, int? duration = 10080, DateTimeOffset? reset = null) =>
        New("Models.UsageWindow", 100 - remaining, duration, reset);
    private static object Week(double remaining = 76) => Window(remaining, 10080, Reset);
    private static object Bucket(string id, object? first, object? second = null, string? name = null) =>
        New("Models.UsageBucket", id, name ?? id, first, second, null);
    private static object Snapshot(DateTimeOffset at, params object[] buckets) => New("Models.UsageSnapshot",
        "synthetic", ArrayOf("Models.UsageBucket", buckets), at);
    private static object Sample(double remaining = 76) => Snapshot(Start, Bucket("weekly", Week(remaining)));
    private static object Evaluate(object? snapshot, DateTimeOffset? now = null, string? error = null,
                                   bool stale = false) =>
        Static("Services.UsagePacingAdvisor", "Evaluate", snapshot, error, stale, now ?? Start);
    private static object[] Items(object advice, string property = "Weekly") =>
        ((IEnumerable?)Get(advice, property))?.Cast<object>().ToArray() ?? [];
    private static decimal? Average(object advice) => (decimal?)Get(Items(advice).Single(), "Average24Hours");
    private static string Level(object advice) => Get(advice, "Level")!.ToString()!;
    private static string Message(object advice) => (string)Static("UI.UsageDisplayHelper", "GetPacingMessage", advice);
    private static string Details(object advice) => (string)Static("UI.UsageDisplayHelper", "FormatPacingDetails", advice);
    private static void Check(bool condition, string label)
    {
        if (condition == false)
        {
            throw new CheckException(label);
        }
        _passed++;
    }
    private static void Hold(object advice, string label)
    {
        Check(Level(advice) == "Unavailable" && Get(advice, "Limiting") == null &&
              string.IsNullOrEmpty((string?)Get(advice, "Reason")) == false, label);
        Check(Items(advice).All(item => Get(item, "Average24Hours") == null), label + " no fabricated average");
        Check(Message(advice).Contains("여유") == false, label + " no success");
    }

    private static void CheckExamples()
    {
        object codex = Evaluate(Sample());
        Check(Math.Abs(Average(codex)!.Value - 17.714m) < 0.001m, "approved average 76 / 102h58m");
        Check(Details(codex).Contains("76% 남음"), "remaining units");
        Check(Message(codex) == "추천 페이스: 24시간에 약17.71%", "concise weekly average");
        Check(Math.Abs(Average(Evaluate(Sample(60)))!.Value / Average(codex)!.Value - 60m / 76m) < 0.00001m,
              "remaining changes proportional average");
        Check(Average(Evaluate(Sample(), Start.AddMinutes(5))) > Average(codex), "time changes recalculate");
        foreach ((double remaining, string text) in new[] { (68d, "19.43%"), (67d, "19.14%") })
        {
            object advice = Evaluate(Snapshot(Start, Bucket("a", Window(remaining, 10080, Start.AddHours(84)))));
            Check(Message(advice) == "추천 페이스: 24시간에 약" + text, "visible change for user example " + remaining);
        }
        foreach (bool reverse in new[] { false, true })
        {
            object week = Window(94, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"));
            object shortTerm = Window(100, 300);
            object snapshot = Snapshot(Start, Bucket("claude", reverse ? week : shortTerm, reverse ? shortTerm : week));
            object advice = Evaluate(snapshot);
            Check(Level(advice) == "Recommended" && Message(advice) == "추천 페이스: 24시간에 약16.37%",
                  "weekly valid without short reset / order");
            Check(Details(advice).Contains("100% 남음") && Details(advice).Contains("94% 남음") &&
                  Details(advice).Contains("시각 미제공"), "separate limits");
            Check(Items(advice, "ShortTerm").All(item => Get(item, "Average24Hours") == null), "no short average");
        }
        foreach (double remaining in new[] { 0d, 5, 10, 10.1 })
        {
            object advice = Evaluate(Snapshot(Start, Bucket("claude", Window(remaining, 300), Week(94))));
            string warning = (string)Static("UI.UsageDisplayHelper", "FormatShortTermWarning", Items(advice, "ShortTerm")[0]);
            Check(Level(advice) == "Recommended", "short warning independent of weekly");
            Check((warning.Length > 0) == (remaining <= 10), "short 10 percent threshold");
            Check(warning.Contains("소진") == (remaining == 0), "short exhaustion");
            Check(warning.Contains("매우") == (remaining > 0 && remaining <= 5), "short critical threshold");
        }
        foreach (bool reverse in new[] { false, true })
        {
            object a = Bucket("a", Week(76), name: "Model A");
            object b = Bucket("b", Window(70, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00")), name: "Model B");
            object multiple = Evaluate(Snapshot(Start, reverse ? b : a, reverse ? a : b));
            Check(Items(multiple).Length == 2 && Items(multiple).All(item => Get(item, "Average24Hours") != null), "per-model averages");
            Check((string?)Get(Get(multiple, "Limiting")!, "BucketName") == "Model B" && Message(multiple).Contains("Model B"), "smallest average summary named / order");
            Check(Details(multiple).Contains("Model A") && Details(multiple).Contains("Model B") &&
                  Details(multiple).Contains("약17.71%") && Details(multiple).Contains("약12.19%"), "model averages never pooled");
        }
        object partial = Evaluate(Snapshot(Start, Bucket("a", Week()), Bucket("b", Window(80))));
        Check(Get(Items(partial)[0], "Average24Hours") != null && Get(Items(partial)[1], "Average24Hours") == null,
              "invalid model does not block valid model");
        Check(Level(partial) == "Unavailable" && Message(partial).Contains("보류"), "partial invalid summary avoids overall success");
    }

    private static void CheckInvalid()
    {
        Hold(Evaluate(null), "missing snapshot");
        Hold(Evaluate(Sample(), error: "synthetic failure"), "query error");
        Hold(Evaluate(Sample(), stale: true), "stale");
        Hold(Evaluate(Sample(), Start.AddMinutes(15).AddTicks(1)), "older than 15 minutes");
        Check(Average(Evaluate(Sample(), Start.AddMinutes(15))) != null, "15-minute boundary inclusive");
        Hold(Evaluate(Snapshot(Start.AddTicks(1), Bucket("a", Week()))), "any future reception");
        Hold(Evaluate(Snapshot(Start, Bucket("a", Window(50, 300)))), "weekly not supplied");
        Hold(Evaluate(Snapshot(Start, Bucket("a", Window(50, null, Reset)))), "weekly length missing");
        Hold(Evaluate(Snapshot(Start)), "no windows");
        foreach (int length in new[] { 10079, 10081, 0, -1 })
        {
            Hold(Evaluate(Snapshot(Start, Bucket("a", Window(70, length, Reset)))), "only exact weekly length " + length);
        }
        foreach (DateTimeOffset? reset in new DateTimeOffset?[] { null, Start, Start.AddTicks(-1), Start.AddMinutes(10080).AddTicks(1) })
        {
            Hold(Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, reset)))), "invalid weekly reset");
        }
        Check(Average(Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, Start.AddMinutes(10080)))))) != null,
              "exact weekly length accepted");
        foreach (double remaining in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity, -1, 101 })
        {
            Hold(Evaluate(Sample(remaining)), "invalid remaining");
            Check(Average(Evaluate(Snapshot(Start, Bucket("a", Window(remaining, 300), Week())))) != null,
                  "invalid short percent does not block weekly");
        }
        Hold(Evaluate(Snapshot(Start, Bucket("a", Week(), Week()))), "ambiguous weekly pair");
        Hold(Evaluate(Snapshot(Start, Bucket("a", Week()), Bucket("a", Week()))), "duplicate bucket ids");
        Hold(Evaluate(Snapshot(Start, Bucket("", Week()))), "missing bucket identity");
        object expiredShort = Evaluate(Snapshot(Start, Bucket("a", Window(0, 300, Start), Week())));
        Check(Average(expiredShort) != null, "expired short does not block weekly");
        Check((string)Static("UI.UsageDisplayHelper", "FormatShortTermWarning", Items(expiredShort, "ShortTerm")[0]) == "",
              "expired short does not claim present exhaustion");
    }

    private static void CheckTime()
    {
        foreach (TimeSpan duration in new[] { TimeSpan.FromTicks(1), TimeSpan.FromMinutes(1),
                                             TimeSpan.FromHours(24).Subtract(TimeSpan.FromTicks(1)), TimeSpan.FromHours(24) })
        {
            object advice = Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, Start + duration))));
            Check(Level(advice) == "UntilReset" && Message(advice) == "초기화까지 남은 76%를 나눠 쓰세요",
                  "up to 24h including tiny interval");
        }
        object over = Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, Start.AddHours(24).AddTicks(1)))));
        Check(Level(over) == "Recommended" && Message(over).Contains("약76.00%"), "one tick beyond 24h");
        foreach (int hours in new[] { 1, 24, 48, 168 })
        {
            object zero = Evaluate(Snapshot(Start, Bucket("a", Window(0, 10080, Start.AddHours(hours)))));
            Check(Level(zero) == "Exhausted" && Average(zero) == 0 && Message(zero).Contains("소진"), "actual zero exhausted");
        }
        foreach ((double remaining, string text) in new[] {
            (0.01, "0.01% 미만"), (0.0199, "0.01% 미만"), (0.02, "0.01%"), (0.03, "0.02%"),
            (0.1, "0.05%"), (0.199, "0.10%"), (0.2, "0.10%"), (0.3, "0.15%"),
            (1.89, "0.95%"), (1.9, "0.95%"), (1.999, "1.00%"), (2d, "1.00%"),
            (2.998, "1.50%"), (3d, "1.50%"), (3.002, "1.50%") })
        {
            object advice = Evaluate(Snapshot(Start, Bucket("a", Window(remaining, 10080, Start.AddHours(48)))));
            Check(Message(advice) == "추천 페이스: 24시간에 약" + text, "percent precision / rounding " + remaining);
            Check(Level(advice) == "Recommended", "positive tiny remaining never exhausted");
        }
        object smallest = New("Models.UsageWindow", double.BitDecrement(100d), (int?)10080, (DateTimeOffset?)Reset);
        object smallestAdvice = Evaluate(Snapshot(Start, Bucket("tiny", smallest)));
        Check(Level(smallestAdvice) == "Recommended" && Average(smallestAdvice) > 0 &&
              Message(smallestAdvice).Contains("0.01% 미만"), "smallest representable remainder preserved");
        object tiny = Evaluate(Snapshot(Start, Bucket("a", Window(0.01, 10080, Start.AddHours(1)))));
        Check(Message(tiny).Contains("0.1% 미만") && Message(tiny).Contains("소진") == false, "tiny reset remainder not zero");
        DateTimeOffset midnight = DateTimeOffset.Parse("2026-11-10T00:00:00+09:00");
        object before = Snapshot(midnight.AddMinutes(-1), Bucket("a", Week()));
        decimal previous = Average(Evaluate(before, midnight.AddTicks(-1)))!.Value;
        decimal next = Average(Evaluate(before, midnight))!.Value;
        Check(Math.Abs(previous - next) < 0.000001m, "midnight continuous without new fetch");
        Check(Average(Evaluate(Sample(), Start.ToOffset(TimeSpan.FromHours(-5)))) == Average(Evaluate(Sample())),
              "same instant different timezone same average");
        Hold(Evaluate(Snapshot(Reset, Bucket("a", Week())), Reset), "weekly reset waits for new interval");
        object newWeek = Snapshot(Reset, Bucket("a", Window(100, 10080, Reset.AddDays(7))));
        Check(Average(Evaluate(newWeek, Reset)) != null, "new weekly reset accepted");
        foreach ((string begin, string end, int hours) in new[] {
            ("2026-03-08T00:00:00-05:00", "2026-03-09T00:00:00-04:00", 23),
            ("2026-11-01T00:00:00-04:00", "2026-11-02T00:00:00-05:00", 25) })
        {
            DateTimeOffset now = DateTimeOffset.Parse(begin);
            DateTimeOffset reset = DateTimeOffset.Parse(end);
            object advice = Evaluate(Snapshot(now, Bucket("a", Window(50, 10080, reset))), now);
            Check((reset - now).TotalHours == hours, "DST fixture actual duration");
            Check(Math.Abs(Average(advice)!.Value - 50m * 24 / hours) < 0.000001m, "DST uses elapsed hours");
            Check(Level(advice) == (hours == 23 ? "UntilReset" : "Recommended"), "DST 24h boundary real duration");
        }
    }

    private static void CheckStateless()
    {
        string expected = Details(Evaluate(Sample()));
        for (int index = 0; index < 3; index++)
        {
            Check(Details(Evaluate(Sample())) == expected, "repeat evaluation identical");
        }
        string path = Path.Combine(_root, "daily-budget.json");
        foreach (string content in new[] { "{broken", "{\"Version\":1,\"Entries\":[]}" })
        {
            File.WriteAllText(path, content);
            Check(Details(Evaluate(Sample())) == expected && File.ReadAllText(path) == content, "old fixture file independent and untouched");
            var context = new AssemblyLoadContext("restart-fixture", true);
            try
            {
                Assembly fresh = context.LoadFromAssemblyPath(_app.Location);
                Check(fresh.GetType("UsageViewer.Services.UsageDailyBudgetStore") == null &&
                      fresh.GetType("UsageViewer.Services.UsageDailyBudgetAdvisor") == null, "restart has no legacy storage code");
                Type windowType = fresh.GetType("UsageViewer.Models.UsageWindow", true)!;
                object window = Activator.CreateInstance(windowType, 24d, (int?)10080, (DateTimeOffset?)Reset)!;
                Type bucketType = fresh.GetType("UsageViewer.Models.UsageBucket", true)!;
                object bucket = Activator.CreateInstance(bucketType, "weekly", "weekly", window, null, null)!;
                Array buckets = Array.CreateInstance(bucketType, 1);
                buckets.SetValue(bucket, 0);
                object snapshot = Activator.CreateInstance(fresh.GetType("UsageViewer.Models.UsageSnapshot", true)!, "synthetic", buckets, Start)!;
                object advice = fresh.GetType("UsageViewer.Services.UsagePacingAdvisor", true)!.GetMethod("Evaluate")!
                    .Invoke(null, [snapshot, null, false, Start])!;
                string result = (string)fresh.GetType("UsageViewer.UI.UsageDisplayHelper", true)!.GetMethod("FormatPacingDetails")!
                    .Invoke(null, [advice])!;
                Check(result == expected, "fresh assembly restart same pure calculation");
            }
            finally
            {
                context.Unload();
            }
        }
    }

    private static object DailySnapshot(DateTimeOffset at, double remaining, DateTimeOffset? reset = null) =>
        Snapshot(at, Bucket("daily-fixture", Window(remaining, 10080, reset ?? DailyStart.AddHours(96))));
    private static object ApplyDaily(object tracker, object snapshot, DateTimeOffset now, string provider = "codex",
                                     TimeZoneInfo? zone = null, string? error = null, bool stale = false) =>
        Invoke(tracker, "Apply", provider, snapshot, Evaluate(snapshot, now, error, stale), now,
               zone ?? TimeZoneInfo.CreateCustomTimeZone("Fixture+9", TimeSpan.FromHours(9), "fixture", "fixture"));
    private static object Daily(object advice) => Get(Items(advice).Single(), "Daily")!;
    private static decimal DailyValue(object advice, string property) => (decimal)Get(Daily(advice), property)!;
    private static void SaveDaily(object tracker) => ((Task)Invoke(tracker, "SaveAsync")).GetAwaiter().GetResult();

    private static void CheckDailyAllowance()
    {
        string path = Path.Combine(_root, "allowance-fixture.json");
        object tracker = New("Services.DailyUsageAllowanceTracker", path);
        object first = ApplyDaily(tracker, DailySnapshot(DailyStart, 76), DailyStart);
        Check(DailyValue(first, "TargetPercent") == 19 && DailyValue(first, "RemainingPercent") == 19,
              "first daily target frozen at 19");
        Check(Message(first) == "오늘 남은 권장량: 19.00%", "daily label is not a rolling average");
        object early = ApplyDaily(tracker, DailySnapshot(DailyStart.AddMinutes(30), 74), DailyStart.AddMinutes(30));
        Check(DailyValue(early, "RemainingPercent") == 19 && DailyValue(early, "UsedPercent") == 0,
              "do not debit before hourly checkpoint");
        object hour = ApplyDaily(tracker, DailySnapshot(DailyStart.AddHours(1), 74), DailyStart.AddHours(1));
        Check(DailyValue(hour, "TargetPercent") == 19 && DailyValue(hour, "UsedPercent") == 2 &&
              DailyValue(hour, "RemainingPercent") == 17, "19 minus observed 2 equals 17");
        Check(Message(hour) == "오늘 남은 권장량: 17.00%", "hourly debit visible with two decimals");
        Check((DateTimeOffset)Get(Daily(hour), "CheckedAt")! == DailyStart.AddHours(1), "internal checkpoint timestamp preserved");
        object beforeSecond = ApplyDaily(tracker, DailySnapshot(DailyStart.AddMinutes(90), 70), DailyStart.AddMinutes(90));
        Check(DailyValue(beforeSecond, "RemainingPercent") == 17, "same hour does not repeatedly debit");
        object second = ApplyDaily(tracker, DailySnapshot(DailyStart.AddHours(2), 70), DailyStart.AddHours(2));
        Check(DailyValue(second, "UsedPercent") == 6 && DailyValue(second, "RemainingPercent") == 13,
              "second hour cumulative debit");
        SaveDaily(tracker);
        object restarted = New("Services.DailyUsageAllowanceTracker", path);
        object restored = ApplyDaily(restarted, DailySnapshot(DailyStart.AddMinutes(130), 69), DailyStart.AddMinutes(130));
        Check(DailyValue(restored, "TargetPercent") == 19 && DailyValue(restored, "RemainingPercent") == 13,
              "restart restores baseline and checkpoint");
        object recovery = ApplyDaily(restarted, DailySnapshot(DailyStart.AddHours(3), 72), DailyStart.AddHours(3));
        Check(DailyValue(recovery, "RemainingPercent") == 13, "increase does not issue another daily budget");
        object stale = ApplyDaily(restarted, DailySnapshot(DailyStart.AddHours(4), 65), DailyStart.AddHours(4), stale: true);
        Check(Level(stale) == "Unavailable" && Get(Items(stale).Single(), "Daily") == null, "stale checkpoint held");
        object error = ApplyDaily(restarted, DailySnapshot(DailyStart.AddHours(4), 65), DailyStart.AddHours(4), error: "failed");
        Check(Level(error) == "Unavailable", "failed checkpoint held");
        object recovered = ApplyDaily(restarted, DailySnapshot(DailyStart.AddHours(4), 65), DailyStart.AddHours(4));
        Check(DailyValue(recovered, "RemainingPercent") == 8, "error did not reset daily target");
        object independent = ApplyDaily(restarted, DailySnapshot(DailyStart.AddHours(4), 65), DailyStart.AddHours(4), "claude");
        Check(DailyValue(independent, "UsedPercent") == 0, "providers do not share budgets");
        object oldReceipt = DailySnapshot(DailyStart.AddHours(4).AddMinutes(-1), 64);
        Check(Level(ApplyDaily(restarted, oldReceipt, DailyStart.AddHours(4))) == "Unavailable", "receipt regression held");
        object over = ApplyDaily(restarted, DailySnapshot(DailyStart.AddHours(5), 50), DailyStart.AddHours(5));
        Check(DailyValue(over, "RemainingPercent") == 0 && DailyValue(over, "UsedPercent") == 26 &&
              Message(over).Contains("초과 사용"), "over-budget is distinct from actual quota exhaustion");
        Check(Items(over).Single() is object && Get(Items(over).Single(), "Window") is object, "actual quota retained");
        SaveDaily(restarted);
        string stored = File.ReadAllText(path);
        Check(stored.Contains("daily-fixture") == false && stored.Contains("claude") == false &&
              stored.Contains("synthetic") == false && stored.Contains("access_token") == false, "store has hashes not identifiers or raw responses");
        using (JsonDocument journal = JsonDocument.Parse(stored))
        {
            Check(journal.RootElement.EnumerateObject().All(pair => pair.Name.Length == 64), "hashed interval keys only");
        }
        DateTimeOffset midnight = DateTimeOffset.Parse("2026-11-10T00:00:00+09:00");
        object oldDay = DailySnapshot(midnight.AddMinutes(-1), 50);
        Check(Level(ApplyDaily(restarted, oldDay, midnight)) == "Unavailable", "yesterday cache does not seed today");
        object nextDay = ApplyDaily(restarted, DailySnapshot(midnight, 50), midnight);
        Check(DailyValue(nextDay, "UsedPercent") == 0 && DailyValue(nextDay, "TargetPercent") > 0,
              "next day starts from actual remaining quota");
        object lessUsedTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "less-used.json"));
        object lessUsed = ApplyDaily(lessUsedTracker, DailySnapshot(midnight, 60), midnight);
        Check(DailyValue(lessUsed, "TargetPercent") > DailyValue(nextDay, "TargetPercent"), "unused quota increases following day allocation");
        object resetTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "new-reset.json"));
        ApplyDaily(resetTracker, DailySnapshot(DailyStart, 76), DailyStart);
        object newReset = ApplyDaily(resetTracker, DailySnapshot(DailyStart.AddHours(1), 95, DailyStart.AddDays(7)), DailyStart.AddHours(1));
        Check(DailyValue(newReset, "UsedPercent") == 0 && DailyValue(newReset, "TargetPercent") < 95,
              "new reset gets independent baseline");
        object lastTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "last-day.json"));
        object last = ApplyDaily(lastTracker, DailySnapshot(DailyStart, 10, DailyStart.AddHours(10)), DailyStart);
        Check(DailyValue(last, "TargetPercent") == 10, "last day allocation does not exceed real remaining");
        object lastHour = ApplyDaily(lastTracker, DailySnapshot(DailyStart.AddHours(1), 8, DailyStart.AddHours(10)), DailyStart.AddHours(1));
        Check(DailyValue(lastHour, "RemainingPercent") == 8, "last day hourly debit");
        object zero = ApplyDaily(lastTracker, DailySnapshot(DailyStart.AddHours(2), 0, DailyStart.AddHours(10)), DailyStart.AddHours(2));
        Check(Message(zero).Contains("주간 한도 소진"), "real quota zero still distinct");
        object multiTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "multiple-allowances.json"));
        object multiFirst = Snapshot(DailyStart, Bucket("a", Window(76, 10080, DailyStart.AddHours(96))), Bucket("b", Window(40, 10080, DailyStart.AddHours(96))));
        ApplyDaily(multiTracker, multiFirst, DailyStart);
        object multiHour = Snapshot(DailyStart.AddHours(1), Bucket("a", Window(74, 10080, DailyStart.AddHours(96))), Bucket("b", Window(39, 10080, DailyStart.AddHours(96))));
        object multiDaily = ApplyDaily(multiTracker, multiHour, DailyStart.AddHours(1));
        object[] multiItems = Items(multiDaily);
        Check((decimal)Get(Get(multiItems[0], "Daily")!, "RemainingPercent")! == 17 &&
              (decimal)Get(Get(multiItems[1], "Daily")!, "RemainingPercent")! == 9, "model budgets independently deducted");
        Check((string)Get(Get(multiDaily, "Limiting")!, "BucketId")! == "b", "summary selects least daily allowance");
        object shortOnly = Snapshot(DailyStart, Bucket("short", Window(80, 300)));
        Check(Get(ApplyDaily(multiTracker, shortOnly, DailyStart), "Limiting") == null, "five hour interval does not fabricate weekly budget");
        object changedZone = ApplyDaily(restarted, DailySnapshot(DailyStart.AddHours(5), 50), DailyStart.AddHours(5),
            zone: TimeZoneInfo.CreateCustomTimeZone("Fixture+8", TimeSpan.FromHours(8), "fixture", "fixture"));
        Check(DailyValue(changedZone, "UsedPercent") == 0, "timezone has independent dated baseline");
        string invalidPath = Path.Combine(_root, "invalid-checkpoint.json");
        File.WriteAllText(invalidPath, stored.Replace("\"Target\":19", "\"Target\":101"));
        object invalidTracker = New("Services.DailyUsageAllowanceTracker", invalidPath);
        Check(Level(ApplyDaily(invalidTracker, DailySnapshot(DailyStart, 76), DailyStart)) == "Unavailable", "invalid stored target rejected");
        string corruptPath = Path.Combine(_root, "corrupt-allowance.json");
        File.WriteAllText(corruptPath, "broken");
        object corrupt = New("Services.DailyUsageAllowanceTracker", corruptPath);
        Check(Level(ApplyDaily(corrupt, DailySnapshot(DailyStart, 76), DailyStart)) == "Unavailable", "corrupt journal does not fabricate budget");
        SaveDaily(corrupt);
        Check(File.ReadAllText(corruptPath) == "broken", "corrupt input preserved");
        string blockedPath = Path.Combine(_root, "blocked-target");
        Directory.CreateDirectory(blockedPath);
        object blocked = New("Services.DailyUsageAllowanceTracker", blockedPath);
        ApplyDaily(blocked, DailySnapshot(DailyStart, 76), DailyStart);
        SaveDaily(blocked);
        Check(Level(ApplyDaily(blocked, DailySnapshot(DailyStart.AddMinutes(1), 76), DailyStart.AddMinutes(1))) == "Unavailable",
              "write failure shown rather than promising restart persistence");
    }

    private static decimal DayTarget(decimal remaining, DateTimeOffset at, DateTimeOffset reset, TimeZoneInfo zone) =>
        (decimal)Static("Services.DailyAllowanceHelper", "CalculateTarget", remaining, at, reset, zone);

    private static void CheckDailyFormula()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("Fixture+9", TimeSpan.FromHours(9), "fixture", "fixture");
        DateTimeOffset at = DateTimeOffset.Parse("2026-11-10T14:13:00+09:00");
        DateTimeOffset reset = DateTimeOffset.Parse("2026-11-14T01:10:00+09:00");
        decimal today = DayTarget(66, at, reset, zone);
        Check(Math.Abs(today - 7.784207m) < 0.000001m, "screenshot today fraction 66 over 82h57m");
        Check(today < 66m * 24 / (decimal)(reset - at).TotalHours, "partial day never gets a full 24-hour budget");
        decimal remaining = 66 - today;
        decimal total = today;
        DateTimeOffset day = DateTimeOffset.Parse("2026-11-11T00:00:00+09:00");
        for (int i = 0; i < 3; i++)
        {
            decimal target = DayTarget(remaining, day, reset, zone);
            Check(Math.Abs(target - 19.09584m) < 0.00001m, "Wednesday/Thursday/Friday allocation " + i);
            total += target;
            remaining -= target;
            day = day.AddDays(1);
        }
        decimal final = DayTarget(remaining, day, reset, zone);
        Check(Math.Abs(final - 0.92827m) < 0.00001m && Math.Abs(total + final - 66) < 0.000001m,
              "partial reset day and daily partitions conserve total remaining quota");
        object tracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "screenshot-day.json"));
        object first = ApplyDaily(tracker, DailySnapshot(at, 66, reset), at);
        Check(Message(first) == "오늘 남은 권장량: 7.78%", "screenshot popup correction");
        object used = ApplyDaily(tracker, DailySnapshot(at.AddHours(1), 64, reset), at.AddHours(1));
        Check(Message(used) == "오늘 남은 권장량: 5.78%" && DailyValue(used, "TargetPercent") == today,
              "fixed partial-day goal with hourly 2 percent debit");
        DateTimeOffset late = DateTimeOffset.Parse("2026-11-10T23:00:00+09:00");
        DateTimeOffset earlyReset = DateTimeOffset.Parse("2026-11-11T02:00:00+09:00");
        Check(DayTarget(24, late, earlyReset, zone) == 8, "reset within 24 hours but tomorrow keeps tomorrow share");
        Check(DayTarget(24, late, late.AddMinutes(30), zone) == 24, "reset today allocates all remaining quota");
        Check(DayTarget(0, at, reset, zone) == 0, "zero quota stays zero");
        Check(DayTarget(50, late.AddMinutes(59).AddSeconds(59), reset, zone) is > 0 and < 0.01m,
              "last second of day preserves a tiny positive allocation");
        var eastern = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");
        foreach ((string start, string end, int hours) in new[] {
            ("2026-03-08T00:00:00-05:00", "2026-03-15T00:00:00-04:00", 23),
            ("2026-11-01T00:00:00-04:00", "2026-11-08T00:00:00-05:00", 25) })
        {
            DateTimeOffset begin = DateTimeOffset.Parse(start);
            DateTimeOffset finish = DateTimeOffset.Parse(end);
            decimal target = DayTarget(70, begin, finish, eastern);
            decimal expected = 70m * TimeSpan.FromHours(hours).Ticks / (finish - begin).Ticks;
            Check(Math.Abs(target - expected) < 0.000001m, "DST daily allocation actual " + hours + " hours");
        }
        DateTimeOffset delayed = at.AddMinutes(5);
        object delayedTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "received-time-goal.json"));
        object delayedAdvice = ApplyDaily(delayedTracker, DailySnapshot(at, 66, reset), delayed);
        Check(DailyValue(delayedAdvice, "TargetPercent") == today, "first target anchored to receipt instead of UI reevaluation time");
        string migrationPath = Path.Combine(_root, "target-migration.json");
        object migrationSeed = New("Services.DailyUsageAllowanceTracker", migrationPath);
        ApplyDaily(migrationSeed, DailySnapshot(at, 66, reset), at);
        SaveDaily(migrationSeed);
        string key;
        using (JsonDocument journal = JsonDocument.Parse(File.ReadAllText(migrationPath)))
        {
            key = journal.RootElement.EnumerateObject().Single().Name;
        }
        var oldEntries = new System.Collections.Generic.Dictionary<string, object>
        {
            [key] = New("Services.AllowanceCheckpoint", 66m, 19.10m, 64m, at, at.AddHours(1), at.AddHours(1), reset)
        };
        File.WriteAllText(migrationPath, JsonSerializer.Serialize(oldEntries));
        object migratedTracker = New("Services.DailyUsageAllowanceTracker", migrationPath);
        object migrated = ApplyDaily(migratedTracker, DailySnapshot(at.AddMinutes(65), 64, reset), at.AddMinutes(65));
        Check(DailyValue(migrated, "TargetPercent") == today && DailyValue(migrated, "UsedPercent") == 2 &&
              Message(migrated) == "오늘 남은 권장량: 5.78%", "migrate old 24-hour target without forgetting prior use");
        Check((DateTimeOffset)Get(Daily(migrated), "StartedAt")! == at &&
              (DateTimeOffset)Get(Daily(migrated), "CheckedAt")! == at.AddHours(1), "migration preserves both original timestamps");
        SaveDaily(migratedTracker);
        object reloaded = New("Services.DailyUsageAllowanceTracker", migrationPath);
        object restored = ApplyDaily(reloaded, DailySnapshot(at.AddMinutes(70), 64, reset), at.AddMinutes(70));
        Check(DailyValue(restored, "RemainingPercent") == today - 2, "migrated target persists across restart");
    }

    private static void CheckPresentation()
    {
        object snapshot = Sample();
        object advice = Evaluate(snapshot);
        object unavailable = Evaluate(null);
        object preferences = New("Services.PopupPreferencesStore", Path.Combine(_root, "view.json"));
        object popup = New("UI.UsagePopup", preferences, Path.Combine(_root, "browser-profile"));
        object bar = New("UI.TopUsageBar");
        try
        {
            Invoke(popup, "SetState", snapshot, false, null, null, null, false, advice, unavailable);
            using JsonDocument payload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
            JsonElement provider = payload.RootElement.GetProperty("providers")[0];
            JsonElement pacing = provider.GetProperty("pacing");
            JsonElement window = provider.GetProperty("windows")[0];
            Check(window.GetProperty("remaining").GetDouble() == 76 && Math.Abs(window.GetProperty("average24Hours").GetDecimal() - 17.714m) < 0.001m,
                  "popup real DLL remaining/average payload");
            Check(pacing.GetProperty("message").GetString() == Message(advice) && pacing.GetProperty("detail").GetString() == Details(advice),
                  "popup shared values");
            string basis = pacing.GetProperty("basis").GetString()!;
            Check(basis.Contains("한 시간마다 확인한 사용량") && basis.Contains("%p") == false && basis.Contains("10%를") == false,
                  "new basis no budget or reserve");
            foreach (double remaining in new[] { double.NaN, double.PositiveInfinity, -1, 101 })
            {
                object invalid = Sample(remaining);
                Invoke(popup, "SetState", invalid, false, null, null, null, false, Evaluate(invalid), unavailable);
                using JsonDocument invalidPayload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
                JsonElement invalidWindow = invalidPayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0];
                Check(invalidWindow.GetProperty("remaining").ValueKind == JsonValueKind.Null && invalidWindow.GetProperty("invalid").GetBoolean() &&
                      invalidWindow.GetProperty("average24Hours").ValueKind == JsonValueKind.Null, "invalid values serialize unknown");
                DateTimeOffset realNow = DateTimeOffset.UtcNow;
                object freshInvalid = Snapshot(realNow, Bucket("a", Window(remaining, 10080, realNow.AddDays(2))));
                Check((string)Get(Invoke(bar, "CreateMetric", "Codex", freshInvalid, null, false), "Value")! == "확인 필요", "invalid top metric unknown");
            }
            foreach ((double remaining, double hours, string expected) in new[] {
                (76d, 24d, "초기화까지 남은 76%를 나눠 쓰세요"),
                (0d, 48d, "주간 한도 소진"), (0.01, 48d, "추천 페이스: 24시간에 약0.01% 미만") })
            {
                object fixture = Snapshot(Start, Bucket("a", Window(remaining, 10080, Start.AddHours(hours))));
                object fixtureAdvice = Evaluate(fixture);
                Invoke(popup, "SetState", fixture, false, null, null, null, false, fixtureAdvice, unavailable);
                using JsonDocument fixturePayload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
                string row = fixturePayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0]
                    .GetProperty("pacingMessage").GetString()!;
                Check(row.Contains(expected), "popup reset/exhausted/tiny advice");
            }
            object claude = Snapshot(Start, Bucket("claude", Window(100, 300),
                Window(94, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"))));
            Invoke(popup, "SetState", snapshot, false, null, claude, null, false, advice, Evaluate(claude));
            using JsonDocument both = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
            _document = both.RootElement.GetRawText();
            JsonElement[] windows = both.RootElement.GetProperty("providers")[1].GetProperty("windows").EnumerateArray().ToArray();
            Check(windows[0].GetProperty("remaining").GetDouble() == 100 && windows[0].GetProperty("average24Hours").ValueKind == JsonValueKind.Null,
                  "short limit retains own remaining, no average");
            Check(windows[1].GetProperty("remaining").GetDouble() == 94 && Math.Abs(windows[1].GetProperty("average24Hours").GetDecimal() - 16.372m) < 0.001m,
                  "Claude average actual popup payload");
            object dailyTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "daily-render.json"));
            ApplyDaily(dailyTracker, DailySnapshot(DailyStart, 76), DailyStart);
            object dailySnapshot = DailySnapshot(DailyStart.AddHours(1), 74);
            object dailyAdvice = ApplyDaily(dailyTracker, dailySnapshot, DailyStart.AddHours(1));
            object firstClaude = Snapshot(DailyStart, Bucket("claude", Window(100, 300),
                Window(94, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"))));
            ApplyDaily(dailyTracker, firstClaude, DailyStart, "claude");
            object dailyClaude = Snapshot(DailyStart.AddHours(1), Bucket("claude", Window(100, 300),
                Window(92, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"))));
            object claudeDailyAdvice = ApplyDaily(dailyTracker, dailyClaude, DailyStart.AddHours(1), "claude");
            Invoke(popup, "SetState", dailySnapshot, false, null, dailyClaude, null, false, dailyAdvice, claudeDailyAdvice);
            _dailyDocument = JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState"));
            using (JsonDocument dailyPayload = JsonDocument.Parse(_dailyDocument))
            {
                JsonElement row = dailyPayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0];
                Check(row.GetProperty("pacingMessage").GetString() == "오늘 남은 권장량: 17.00%" &&
                      row.TryGetProperty("dailyDetails", out _) == false, "actual daily popup payload uses shared checkpoint");
                Check(row.GetProperty("remaining").GetDouble() == 74, "real quota stays separate from daily allowance");
            }
            Invoke(bar, "LayoutDock");
            object size = Get(bar, "ClientSize")!;
            int dpi = (int)Get(bar, "DeviceDpi")!;
            Check((int)Get(size, "Width")! == (int)(264 * dpi / 96f) && (int)Get(size, "Height")! == (int)(32 * dpi / 96f), "264x32 DIP retained");
        }
        finally
        {
            ((IDisposable)popup).Dispose();
            ((IDisposable)bar).Dispose();
        }
        using Stream stream = _app.GetManifestResourceStream("UsageViewer.UI.Popup.html")!;
        using StreamReader reader = new StreamReader(stream);
        string html = reader.ReadToEnd();
        Check(html.Contains("usage(p,false)") && html.Contains("usage(p,true)"), "both HTML views share limit renderer");
        Check(html.Contains("uv-baseline-track") == false && html.Contains("percent(w.remaining)") &&
              html.Contains("esc(w.pacingMessage"), "single average row and real remaining meter");
        Check(html.Contains("<details class=\"uv-help\"") && html.Contains("helpOpen=new Set()") && html.Contains("<summary>오늘 권장량은 뭔가요?</summary>"), "help initially collapsed and keyboard accessible");
        Check(html.Contains("esc(w.name)") && html.Contains("esc(w.pacingMessage") && html.Contains("esc(a.basis)"), "external text escaped");
        Check(html.Contains("data-action=\"hide\"") && html.Contains("e.key==='Escape'") && html.Contains("id=\"show-both\"") && html.Contains("크레딧"), "existing controls retained");
    }

    private static void CheckRendering()
    {
        NativeLibrary.SetDllImportResolver(typeof(CoreWebView2Environment).Assembly, (name, assembly, search) =>
            name == "WebView2Loader.dll" ? NativeLibrary.Load(Path.Combine(Path.GetDirectoryName(_app.Location)!,
                "runtimes", "win-" + RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
                "native", name)) : IntPtr.Zero);
        // Invisible, isolated fixture host. Never initialize the user's app or its WebView profile.
        using Form host = new Form
        {
            ShowInTaskbar = false,
            StartPosition = FormStartPosition.Manual,
            Location = new Point(-20000, -20000),
            ClientSize = new Size(320, 900),
            Opacity = 0
        };
        using WebView2 browser = new WebView2 { Dock = DockStyle.Fill };
        host.Controls.Add(browser);
        Exception? failure = null;
        host.Shown += async (_, _) =>
        {
            TaskCompletionSource<bool>? browserExited = null;
            try
            {
                var options = new CoreWebView2EnvironmentOptions("--disable-background-networking --no-first-run");
                var environment = await CoreWebView2Environment.CreateAsync(null,
                    Path.Combine(_root, "render-profile"), options).WaitAsync(TimeSpan.FromSeconds(30));
                browserExited = new TaskCompletionSource<bool>();
                environment.BrowserProcessExited += (_, _) => browserExited.TrySetResult(true);
                await browser.EnsureCoreWebView2Async(environment).WaitAsync(TimeSpan.FromSeconds(30));
                var navigation = new TaskCompletionSource<bool>();
                browser.CoreWebView2.NavigationCompleted += (_, args) => navigation.TrySetResult(args.IsSuccess);
                using Stream stream = _app.GetManifestResourceStream("UsageViewer.UI.Popup.html")!;
                using StreamReader reader = new StreamReader(stream);
                browser.NavigateToString(reader.ReadToEnd());
                Check(await navigation.Task.WaitAsync(TimeSpan.FromSeconds(20)), "actual embedded HTML navigation");
                // Historical approved fixtures are rendered as received then; no real account data is used.
                await browser.ExecuteScriptAsync("window.fixture=" + _document + ";fixture.providers.forEach(p=>{p.stale=false;p.windows.forEach(w=>w.expired=false)});");
                foreach ((int width, bool both, bool docked) in new[] { (280, false, false), (320, true, false), (264, false, true) })
                {
                    host.ClientSize = new Size(width, 900);
                    await browser.ExecuteScriptAsync($"fixture.showBoth={both.ToString().ToLowerInvariant()};fixture.docked={docked.ToString().ToLowerInvariant()};fixture.activeProvider='codex';usageViewer.update(fixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('76%') && document.body.innerText.includes('추천 페이스: 24시간에 약17.71%')"), "rendered Codex average " + width);
                    Check(await ScriptBool(browser, "document.querySelectorAll('.uv-baseline-track').length===0 && !document.body.innerText.includes('오늘의 기준선')"), "no obsolete baseline " + width);
                    Check(await ScriptBool(browser, "document.querySelector('.uv-limit .uv-track>span').style.width==='76%'"), "actual meter uses remaining direction " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('details')].every(d=>!d.open)"), "help default collapsed " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('.uv-weekly-status')].every(e=>e.clientHeight<=parseFloat(getComputedStyle(e).lineHeight)+1)"), "concise average fits one line " + width);
                    Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && [...document.querySelectorAll('.uv-limit,.uv-line')].every(e=>e.scrollWidth<=e.clientWidth+1)"), "no horizontal overflow " + width);
                    await browser.ExecuteScriptAsync("fixture.showBoth=false;fixture.activeProvider='claude';usageViewer.update(fixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('100%') && document.body.innerText.includes('94%') && document.body.innerText.includes('추천 페이스: 24시간에 약16.37%') && document.querySelectorAll('.uv-weekly-status').length===1"), "Claude independent short/weekly rendered " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('.uv-limit,.uv-line')].every(e=>e.scrollWidth<=e.clientWidth+1)"), "Claude rows fit " + width);
                }
                await browser.ExecuteScriptAsync("document.querySelector('summary').click();");
                await Task.Delay(50);
                Check(await ScriptBool(browser, "document.querySelector('details').open && document.body.innerText.includes('5시간 한도는 따로')"), "help expands with separate limit explanation");
                await browser.ExecuteScriptAsync("usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.querySelector('details').open"), "help expansion retained on refresh");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[0].shortTermWarning='5시간 한도 소진 · 초기화를 기다려 주세요';fixture.providers[1].windows[0].remaining=0;usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.body.innerText.includes('5시간 한도 소진') && document.body.innerText.includes('추천 페이스: 24시간에 약16.37%')"), "rendered short exhaustion with valid weekly average");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[1].name='VeryLongModelName'.repeat(10)+'<script>';usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && document.querySelectorAll('script').length===1"), "long external model wraps and remains escaped");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[1].remaining=0.01;fixture.providers[1].windows[1].pacingMessage='추천 페이스: 24시간에 약0.01% 미만';usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.body.innerText.includes('0.1% 미만 남음') && !document.querySelector('.uv-limit:last-of-type strong').innerText.startsWith('0%')"), "tiny actual remainder not rendered as zero");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[1].pacingMessage='추천 페이스 보류 · 잔여량 확인 필요';fixture.providers[1].windows[1].pacingReason='잔여량 확인 필요';fixture.providers[1].windows[1].invalid=true;usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.body.innerText.includes('추천 페이스 보류 · 잔여량 확인 필요') && !document.body.innerText.includes('약0%')"), "rendered invalid advice held with reason");
                await browser.ExecuteScriptAsync("window.dailyFixture=" + _dailyDocument + ";dailyFixture.providers.forEach(p=>{p.stale=false;p.windows.forEach(w=>w.expired=false)});");
                foreach ((int width, bool both, bool docked) in new[] { (264, false, true), (280, false, false), (320, true, false) })
                {
                    host.ClientSize = new Size(width, 1000);
                    await browser.ExecuteScriptAsync($"dailyFixture.showBoth={both.ToString().ToLowerInvariant()};dailyFixture.docked={docked.ToString().ToLowerInvariant()};dailyFixture.activeProvider='codex';usageViewer.update(dailyFixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('오늘 남은 권장량: 17.00%') && !document.body.innerText.includes('오늘 권장 19.00%') && !document.body.innerText.includes('확인 사용') && !document.body.innerText.includes('다음 확인')"), "hourly daily allowance rendered " + width);
                    Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && [...document.querySelectorAll('.uv-limit')].every(e=>e.scrollWidth<=e.clientWidth+1)"), "daily allowance rows fit " + width);
                    if(both) Check(await ScriptBool(browser, "document.body.innerText.includes('오늘 남은 권장량: 12.46%') && document.body.innerText.includes('100%')"), "independent Claude daily allowance and five hour quota rendered");
                }
                await browser.ExecuteScriptAsync("fixture.showBoth=false;fixture.activeProvider='claude';usageViewer.update(fixture);");
                var messages = new System.Collections.Generic.List<string>();
                browser.CoreWebView2.WebMessageReceived += (_, args) => messages.Add(args.WebMessageAsJson);
                await browser.ExecuteScriptAsync("document.querySelector('[data-action=refresh]').click();document.querySelector('[data-action=hide]').click();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}));document.getElementById('show-both').click();document.getElementById('show-both').click();document.querySelector('[data-provider=codex]').click();");
                // Let posted WebView messages reach the native handler without interacting with the user app.
                await Task.Delay(100);
                string[] types = messages.Select(message => JsonDocument.Parse(message).RootElement.GetProperty("type").GetString()!).ToArray();
                Check(types.Contains("refresh") && types.Count(type => type == "hide") == 2 &&
                      types.Count(type => type == "mode") == 2 && types.Contains("provider"), "refresh/close/Escape/view/tab native message connections");
                Check(await ScriptBool(browser, "document.querySelector('[data-provider=codex]').getAttribute('aria-pressed')==='true' && !document.getElementById('show-both').checked"), "tab and view controls update rendered state");
                Console.WriteLine("PASS: actual WebView2 rendering at 264/280/320 DIP; invisible isolated fixture, no user interaction.");
            }
            catch (Exception exception)
            {
                failure = exception;
            }
            finally
            {
                browser.Dispose();
                if (browserExited != null)
                {
                    await Task.WhenAny(browserExited.Task, Task.Delay(10000));
                }
                host.Close();
            }
        };
        Application.Run(host);
        if (failure != null)
        {
            throw failure;
        }
    }

    private static async Task<bool> ScriptBool(WebView2 browser, string expression)
    {
        string result = await browser.ExecuteScriptAsync(expression).WaitAsync(TimeSpan.FromSeconds(10));
        return result == "true";
    }
}

internal sealed class CheckException(string message) : Exception(message)
{
}
'@
$artifactRoot = Join-Path $repoRoot '.artifacts'
$tempRoot = Join-Path $artifactRoot ('UsagePacing-' + [guid]::NewGuid().ToString('N'))
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
    # WebView2's existing netcore WinForms assembly references the compatible older framework identities.
    $compileArguments = @('-nologo', '-target:exe', '-nullable:enable', '-warnaserror+', '-nowarn:1701', '-langversion:latest',
                          ('-out:"' + $probePath + '"'))
    $compileArguments += Get-ChildItem -LiteralPath (Join-Path $referencePack.FullName 'ref/net10.0') -Filter '*.dll' |
        ForEach-Object { '-r:"' + $_.FullName + '"' }
    $desktopPack = Get-ChildItem -LiteralPath (Join-Path $dotNetRoot 'packs/Microsoft.WindowsDesktop.App.Ref') -Directory |
        Where-Object { $_.Name -like '10.*' } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    $compileArguments += Get-ChildItem -LiteralPath (Join-Path $desktopPack.FullName 'ref/net10.0') -Filter '*.dll' |
        ForEach-Object { '-r:"' + $_.FullName + '"' }
    $compileArguments += @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll') |
        ForEach-Object { '-r:"' + (Join-Path $buildPath $_) + '"' }
    $compileArguments += '"' + $sourcePath + '"'
    Set-Content -LiteralPath $responsePath -Value $compileArguments -Encoding utf8
    $compilerOutput = & $DotNetPath exec (Join-Path $sdkPath 'Roslyn/bincore/csc.dll') ('@' + $responsePath) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $compilerOutput | ForEach-Object { $_.ToString().Replace($tempRoot, '<fixture>') }
        throw 'Could not compile the synthetic driver.'
    }
    & $DotNetPath exec --runtimeconfig (Join-Path $buildPath 'UsageViewer.runtimeconfig.json') $probePath $assemblyPath $tempRoot
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic usage-pacing checks failed.' }
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedArtifacts = [System.IO.Path]::GetFullPath($artifactRoot) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedTemp.StartsWith($resolvedArtifacts, [System.StringComparison]::OrdinalIgnoreCase) -eq $false -or
        (Split-Path $resolvedTemp -Leaf) -notlike 'UsagePacing-*') {
        throw 'Fixture cleanup path is outside the expected workspace artifact directory.'
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
