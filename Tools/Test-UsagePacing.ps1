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
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-09T18:12:00+09:00");
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
        Check(Message(codex) == "추천 페이스: 24시간에 약18%", "concise weekly average");
        Check(Math.Abs(Average(Evaluate(Sample(60)))!.Value / Average(codex)!.Value - 60m / 76m) < 0.00001m,
              "remaining changes proportional average");
        Check(Average(Evaluate(Sample(), Start.AddMinutes(5))) > Average(codex), "time changes recalculate");
        foreach (bool reverse in new[] { false, true })
        {
            object week = Window(94, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"));
            object shortTerm = Window(100, 300);
            object snapshot = Snapshot(Start, Bucket("claude", reverse ? week : shortTerm, reverse ? shortTerm : week));
            object advice = Evaluate(snapshot);
            Check(Level(advice) == "Recommended" && Message(advice) == "추천 페이스: 24시간에 약16%",
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
                  Details(multiple).Contains("약18%") && Details(multiple).Contains("약12%"), "model averages never pooled");
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
        Check(Level(over) == "Recommended" && Message(over).Contains("약76%"), "one tick beyond 24h");
        foreach (int hours in new[] { 1, 24, 48, 168 })
        {
            object zero = Evaluate(Snapshot(Start, Bucket("a", Window(0, 10080, Start.AddHours(hours)))));
            Check(Level(zero) == "Exhausted" && Average(zero) == 0 && Message(zero).Contains("소진"), "actual zero exhausted");
        }
        foreach ((double remaining, string text) in new[] {
            (0.1, "0.1% 미만"), (0.199, "0.1% 미만"), (0.2, "0.1%"), (0.3, "0.2%"),
            (1.89, "0.9%"), (1.9, "1%"), (1.999, "1%"), (2d, "1%"), (2.998, "1%"), (3d, "2%"), (3.002, "2%") })
        {
            object advice = Evaluate(Snapshot(Start, Bucket("a", Window(remaining, 10080, Start.AddHours(48)))));
            Check(Message(advice) == "추천 페이스: 24시간에 약" + text, "percent precision / rounding " + remaining);
            Check(Level(advice) == "Recommended", "positive tiny remaining never exhausted");
        }
        object smallest = New("Models.UsageWindow", double.BitDecrement(100d), (int?)10080, (DateTimeOffset?)Reset);
        object smallestAdvice = Evaluate(Snapshot(Start, Bucket("tiny", smallest)));
        Check(Level(smallestAdvice) == "Recommended" && Average(smallestAdvice) > 0 &&
              Message(smallestAdvice).Contains("0.1% 미만"), "smallest representable remainder preserved");
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
            Check(basis.Contains("남은 주간 한도를 초기화까지") && basis.Contains("%p") == false && basis.Contains("10%를") == false,
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
                (0d, 48d, "주간 한도 소진"), (0.01, 48d, "추천 페이스: 24시간에 약0.1% 미만") })
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
        Check(html.Contains("<details class=\"uv-help\"") && html.Contains("helpOpen=new Set()") && html.Contains("<summary>추천 페이스는 뭔가요?</summary>"), "help initially collapsed and keyboard accessible");
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
                    Check(await ScriptBool(browser, "document.body.innerText.includes('76%') && document.body.innerText.includes('추천 페이스: 24시간에 약18%')"), "rendered Codex average " + width);
                    Check(await ScriptBool(browser, "document.querySelectorAll('.uv-baseline-track').length===0 && !document.body.innerText.includes('오늘의 기준선')"), "no obsolete baseline " + width);
                    Check(await ScriptBool(browser, "document.querySelector('.uv-limit .uv-track>span').style.width==='76%'"), "actual meter uses remaining direction " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('details')].every(d=>!d.open)"), "help default collapsed " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('.uv-weekly-status')].every(e=>e.clientHeight<=parseFloat(getComputedStyle(e).lineHeight)+1)"), "concise average fits one line " + width);
                    Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && [...document.querySelectorAll('.uv-limit,.uv-line')].every(e=>e.scrollWidth<=e.clientWidth+1)"), "no horizontal overflow " + width);
                    await browser.ExecuteScriptAsync("fixture.showBoth=false;fixture.activeProvider='claude';usageViewer.update(fixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('100%') && document.body.innerText.includes('94%') && document.body.innerText.includes('추천 페이스: 24시간에 약16%') && document.querySelectorAll('.uv-weekly-status').length===1"), "Claude independent short/weekly rendered " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('.uv-limit,.uv-line')].every(e=>e.scrollWidth<=e.clientWidth+1)"), "Claude rows fit " + width);
                }
                await browser.ExecuteScriptAsync("document.querySelector('summary').click();");
                await Task.Delay(50);
                Check(await ScriptBool(browser, "document.querySelector('details').open && document.body.innerText.includes('5시간 한도는 따로')"), "help expands with separate limit explanation");
                await browser.ExecuteScriptAsync("usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.querySelector('details').open"), "help expansion retained on refresh");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[0].shortTermWarning='5시간 한도 소진 · 초기화를 기다려 주세요';fixture.providers[1].windows[0].remaining=0;usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.body.innerText.includes('5시간 한도 소진') && document.body.innerText.includes('추천 페이스: 24시간에 약16%')"), "rendered short exhaustion with valid weekly average");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[1].name='VeryLongModelName'.repeat(10)+'<script>';usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && document.querySelectorAll('script').length===1"), "long external model wraps and remains escaped");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[1].remaining=0.01;fixture.providers[1].windows[1].pacingMessage='추천 페이스: 24시간에 약0.1% 미만';usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.body.innerText.includes('0.1% 미만 남음') && !document.querySelector('.uv-limit:last-of-type strong').innerText.startsWith('0%')"), "tiny actual remainder not rendered as zero");
                await browser.ExecuteScriptAsync("fixture.providers[1].windows[1].pacingMessage='추천 페이스 보류 · 잔여량 확인 필요';fixture.providers[1].windows[1].pacingReason='잔여량 확인 필요';fixture.providers[1].windows[1].invalid=true;usageViewer.update(fixture);");
                Check(await ScriptBool(browser, "document.body.innerText.includes('추천 페이스 보류 · 잔여량 확인 필요') && !document.body.innerText.includes('약0%')"), "rendered invalid advice held with reason");
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
