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
            CheckExamples();
            CheckInvalid();
            CheckTime();
            CheckStateless();
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
                                   bool stale = false, TimeZoneInfo? zone = null) =>
        Static("Services.UsagePacingAdvisor", "Evaluate", snapshot, error, stale, now ?? Start, zone ?? Korea);
    private static object[] Items(object advice, string property = "Weekly") =>
        ((IEnumerable?)Get(advice, property))?.Cast<object>().ToArray() ?? [];
    private static int? Baseline(object advice) => (int?)Get(Items(advice).Single(), "Baseline");
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
        Check(Items(advice).All(item => Get(item, "Baseline") == null), label + " no fabricated baseline");
        Check(Message(advice).Contains("여유") == false, label + " no success");
    }

    private static void CheckExamples()
    {
        object codex = Evaluate(Sample());
        Check(Baseline(codex) == 58 && Level(codex) == "Comfortable", "approved Codex 76 / 58");
        Check(Details(codex).Contains("76% 남음") && Details(codex).Contains("58% 남음"), "remaining units");
        Check(Message(codex) == "주간 한도는 여유 있어요", "concise weekly status");
        foreach (bool reverse in new[] { false, true })
        {
            object week = Window(94, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"));
            object shortTerm = Window(100, 300);
            object snapshot = Snapshot(Start, Bucket("claude", reverse ? week : shortTerm, reverse ? shortTerm : week));
            object advice = Evaluate(snapshot);
            Check(Baseline(advice) == 79 && Level(advice) == "Comfortable", "Claude weekly valid without short reset / order");
            Check(Details(advice).Contains("100% 남음") && Details(advice).Contains("94% 남음") &&
                  Details(advice).Contains("79% 남음") && Details(advice).Contains("시각 미제공"), "Claude separate limits");
            Check(Items(advice, "ShortTerm").All(item => Get(item, "Baseline") == null), "no daily baseline on short limit");
        }
        foreach (double remaining in new[] { 58d, 57.9, 58.1 })
        {
            string expected = remaining == 58 ? "Balanced" : remaining < 58 ? "Caution" : "Comfortable";
            Check(Level(Evaluate(Sample(remaining))) == expected, "compare displayed baseline " + remaining);
        }
        Check(Level(Evaluate(Sample(57.99))) == "Balanced", "display rounding agrees with status");
        foreach (double remaining in new[] { 0d, 5, 10, 10.1 })
        {
            object advice = Evaluate(Snapshot(Start, Bucket("claude", Window(remaining, 300), Week(94))));
            string warning = (string)Static("UI.UsageDisplayHelper", "FormatShortTermWarning", Items(advice, "ShortTerm")[0]);
            Check(Baseline(advice) == 58 && Level(advice) == "Comfortable", "short warning independent of weekly");
            Check((warning.Length > 0) == (remaining <= 10), "short 10 percent threshold");
            Check(warning.Contains("소진") == (remaining == 0), "short exhaustion");
            Check(warning.Contains("매우") == (remaining > 0 && remaining <= 5), "short critical threshold");
        }
        object multi = Snapshot(Start, Bucket("a", Week(76), name: "Model A"),
            Bucket("b", Window(70, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00")), name: "Model B"));
        object multiple = Evaluate(multi);
        Check(Items(multiple).Select(item => (int?)Get(item, "Baseline")).SequenceEqual(new int?[] { 58, 79 }), "per-model baselines");
        Check((string?)Get(Get(multiple, "Limiting")!, "BucketName") == "Model B" && Message(multiple).Contains("Model B"), "least difference summary named");
        object partial = Evaluate(Snapshot(Start, Bucket("a", Week()), Bucket("b", Window(80))));
        Check(Get(Items(partial)[0], "Baseline") is 58 && Get(Items(partial)[1], "Baseline") == null, "invalid model does not block valid model");
        Check(Level(partial) == "Unavailable", "partial invalid summary avoids overall success");
    }

    private static void CheckInvalid()
    {
        Hold(Evaluate(null), "missing snapshot");
        Hold(Evaluate(Sample(), error: "synthetic failure"), "query error");
        Hold(Evaluate(Sample(), stale: true), "stale");
        Hold(Evaluate(Sample(), Start.AddMinutes(15).AddTicks(1)), "older than 15 minutes");
        Check(Baseline(Evaluate(Sample(), Start.AddMinutes(15))) == 58, "15-minute boundary inclusive");
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
        Check(Baseline(Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, Start.AddMinutes(10080)))))) != null,
              "exact weekly length accepted");
        foreach (double remaining in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity, -1, 101 })
        {
            Hold(Evaluate(Sample(remaining)), "invalid remaining");
            Check(Baseline(Evaluate(Snapshot(Start, Bucket("a", Window(remaining, 300), Week())))) == 58,
                  "invalid short percent does not block weekly");
        }
        Hold(Evaluate(Snapshot(Start, Bucket("a", Week(), Week()))), "ambiguous weekly pair");
        Hold(Evaluate(Snapshot(Start, Bucket("a", Week()), Bucket("a", Week()))), "duplicate bucket ids");
        Hold(Evaluate(Snapshot(Start, Bucket("", Week()))), "missing bucket identity");
        object expiredShort = Evaluate(Snapshot(Start, Bucket("a", Window(0, 300, Start), Week())));
        Check(Baseline(expiredShort) == 58, "expired short does not block weekly");
        Check((string)Static("UI.UsageDisplayHelper", "FormatShortTermWarning", Items(expiredShort, "ShortTerm")[0]) == "",
              "expired short does not claim present exhaustion");
    }

    private static void CheckTime()
    {
        DateTimeOffset midnight = DateTimeOffset.Parse("2026-11-10T00:00:00+09:00");
        foreach (DateTimeOffset reset in new[] { Start.AddHours(1), midnight })
        {
            object advice = Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, reset))));
            Check(Baseline(advice) == 0 && (bool)Get(Items(advice)[0], "EndsAtReset")!, "reset before or at midnight zero");
            Check(Details(advice).Contains("초기화 전 기준"), "zero baseline scope");
        }
        DateTimeOffset exact = midnight.AddTicks(TimeSpan.FromMinutes(10080).Ticks / 2);
        Check(Baseline(Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, exact))))) == 50, "exact integer no epsilon");
        Check(Baseline(Evaluate(Snapshot(Start, Bucket("a", Window(76, 10080, exact.AddTicks(1)))))) == 51, "one tick rounds up");
        object before = Snapshot(midnight.AddMinutes(-1), Bucket("a", Week()));
        Check(Baseline(Evaluate(before, midnight.AddTicks(-1))) == 58, "before midnight");
        Check(Baseline(Evaluate(before, midnight)) == 44, "midnight advances without saved state or new fetch");
        Hold(Evaluate(Snapshot(Reset, Bucket("a", Week())), Reset), "weekly reset waits for new interval");
        object newWeek = Snapshot(Reset, Bucket("a", Window(100, 10080, Reset.AddDays(7))));
        Check(Baseline(Evaluate(newWeek, Reset)) != null, "new weekly reset accepted");
        Check(Baseline(Evaluate(Sample(), zone: TimeZoneInfo.Utc)) == 53, "timezone changes pure result");
        TimeZoneInfo eastern = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");
        foreach ((string begin, string end, int hours) in new[] {
            ("2026-03-08T00:00:00-05:00", "2026-03-09T00:00:00-04:00", 23),
            ("2026-11-01T00:00:00-04:00", "2026-11-02T00:00:00-05:00", 25) })
        {
            DateTimeOffset now = DateTimeOffset.Parse(begin);
            DateTimeOffset next = DateTimeOffset.Parse(end);
            object advice = Evaluate(Snapshot(now, Bucket("a", Window(100, 10080, now.AddDays(7)))), now, zone: eastern);
            Check((next - now).TotalHours == hours, "DST fixture duration");
            Check(Baseline(advice) == (hours == 23 ? 87 : 86), "DST real elapsed baseline");
        }
        foreach (bool gap in new[] { true, false })
        {
            var start = TimeZoneInfo.TransitionTime.CreateFixedDateRule(new DateTime(1, 1, 1, 0, 0, 0), 3, 1);
            var end = TimeZoneInfo.TransitionTime.CreateFixedDateRule(new DateTime(1, 1, 1, 1, 0, 0), 11, 1);
            var rule = TimeZoneInfo.AdjustmentRule.CreateAdjustmentRule(new DateTime(2026, 1, 1),
                new DateTime(2026, 12, 31), TimeSpan.FromHours(1), start, end);
            var zone = TimeZoneInfo.CreateCustomTimeZone("fixture", TimeSpan.Zero, "fixture", "standard", "daylight", [rule]);
            DateTimeOffset now = DateTimeOffset.Parse(gap ? "2026-02-28T12:00:00Z" : "2026-10-31T12:00:00Z");
            DateTimeOffset actual = (DateTimeOffset)Static("Services.UsagePacingAdvisor", "NextMidnight", now, zone);
            DateTimeOffset expected = DateTimeOffset.Parse(gap ? "2026-03-01T00:00:00Z" : "2026-10-31T23:00:00Z");
            Check(actual == expected, "midnight gap/overlap first real instant");
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
                    .Invoke(null, [snapshot, null, false, Start, Korea])!;
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
            Check(window.GetProperty("remaining").GetDouble() == 76 && window.GetProperty("baseline").GetInt32() == 58,
                  "popup real DLL remaining/baseline payload");
            Check(pacing.GetProperty("message").GetString() == Message(advice) && pacing.GetProperty("detail").GetString() == Details(advice),
                  "popup shared values");
            Invoke(bar, "SetUsageTip", "codex", "Codex", snapshot, advice);
            var tips = (IDictionary)bar.GetType().GetField("_usageTips", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(bar)!;
            string tip = (string)tips["codex"]!;
            Check(tip.Contains("76% 남음") && tip.Contains("58% 남음") && tip.Contains(Message(advice)), "tooltip same values/units/status");
            Check(tip.Contains("한 주의 한도를 고르게") && tip.Contains("%p") == false && tip.Contains("10%를") == false,
                  "new basis no budget or reserve");
            foreach (double remaining in new[] { double.NaN, double.PositiveInfinity, -1, 101 })
            {
                object invalid = Sample(remaining);
                Invoke(popup, "SetState", invalid, false, null, null, null, false, Evaluate(invalid), unavailable);
                using JsonDocument invalidPayload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
                JsonElement invalidWindow = invalidPayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0];
                Check(invalidWindow.GetProperty("remaining").ValueKind == JsonValueKind.Null && invalidWindow.GetProperty("invalid").GetBoolean() &&
                      invalidWindow.GetProperty("baseline").ValueKind == JsonValueKind.Null, "invalid values serialize unknown");
                DateTimeOffset realNow = DateTimeOffset.UtcNow;
                object freshInvalid = Snapshot(realNow, Bucket("a", Window(remaining, 10080, realNow.AddDays(2))));
                Check((string)Get(Invoke(bar, "CreateMetric", "Codex", freshInvalid, null, false), "Value")! == "확인 필요", "invalid top metric unknown");
            }
            object claude = Snapshot(Start, Bucket("claude", Window(100, 300),
                Window(94, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"))));
            Invoke(popup, "SetState", snapshot, false, null, claude, null, false, advice, Evaluate(claude));
            using JsonDocument both = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
            _document = both.RootElement.GetRawText();
            JsonElement[] windows = both.RootElement.GetProperty("providers")[1].GetProperty("windows").EnumerateArray().ToArray();
            Check(windows[0].GetProperty("remaining").GetDouble() == 100 && windows[0].GetProperty("baseline").ValueKind == JsonValueKind.Null,
                  "short limit retains own remaining, no baseline");
            Check(windows[1].GetProperty("remaining").GetDouble() == 94 && windows[1].GetProperty("baseline").GetInt32() == 79,
                  "Claude comparison actual popup payload");
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
        Check(html.Contains("uv-baseline-track") && html.Contains("percent(w.baseline)") &&
              html.Contains("percent(w.remaining)") && html.Contains("오늘의 기준선"), "two remaining rows with gray baseline meter");
        Check(html.Contains("<details class=\"uv-help\"") && html.Contains("helpOpen=new Set()") && html.Contains("<summary>기준선은 뭔가요?</summary>"), "help initially collapsed and keyboard accessible");
        Check(html.Contains("esc(w.name)") && html.Contains("esc(w.pacingReason") && html.Contains("esc(a.basis)"), "external text escaped");
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
                    Check(await ScriptBool(browser, "document.body.innerText.includes('76%') && document.body.innerText.includes('58%')"), "rendered Codex comparison " + width);
                    Check(await ScriptBool(browser, "document.querySelector('.uv-baseline-track>span').style.width==='58%'"), "rendered baseline width " + width);
                    Check(await ScriptBool(browser, "document.querySelector('.uv-limit .uv-track>span').style.width==='76%'"), "actual meter uses remaining direction " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('details')].every(d=>!d.open)"), "help default collapsed " + width);
                    Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && [...document.querySelectorAll('.uv-limit,.uv-line')].every(e=>e.scrollWidth<=e.clientWidth+1)"), "no horizontal overflow " + width);
                    Check(await ScriptBool(browser, "getComputedStyle(document.querySelector('.uv-baseline-track>span')).backgroundColor==='rgb(120, 130, 143)'"), "baseline gray " + width);
                    await browser.ExecuteScriptAsync("fixture.showBoth=false;fixture.activeProvider='claude';usageViewer.update(fixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('100%') && document.body.innerText.includes('94%') && document.body.innerText.includes('79%') && document.querySelectorAll('.uv-baseline-track').length===1"), "Claude independent short/weekly rendered " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('.uv-limit,.uv-line')].every(e=>e.scrollWidth<=e.clientWidth+1)"), "Claude rows fit " + width);
                }
                await browser.ExecuteScriptAsync("document.querySelector('summary').click();");
                await Task.Delay(50);
                Check(await ScriptBool(browser, "document.querySelector('details').open && document.body.innerText.includes('5시간 한도는 따로')"), "help expands with separate limit explanation");
                await browser.ExecuteScriptAsync("usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.querySelector('details').open"), "help expansion retained on refresh");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[0].shortTermWarning='5시간 한도 소진 · 초기화를 기다려 주세요';fixture.providers[1].windows[0].remaining=0;usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.body.innerText.includes('5시간 한도 소진') && document.body.innerText.includes('79%')"), "rendered short exhaustion with valid weekly baseline");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[1].name='VeryLongModelName'.repeat(10)+'<script>';usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && document.querySelectorAll('script').length===1"), "long external model wraps and remains escaped");
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
