param(
    [string]$DotNetPath = (Join-Path $env:USERPROFILE '.dotnet/dotnet.exe'),
    [switch]$SourceOnly,
    [switch]$ClaudeRefreshOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if ($SourceOnly) {
    # This mode never compiles or loads a DLL and does not start WebView2.
    $model = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src/UsageViewer/Models/UsagePacing.cs')
    $tracker = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src/UsageViewer/Services/DailyUsageAllowanceTracker.cs')
    foreach ($record in @(@('DailyUsageAllowance', $model), @('AllowanceCheckpoint', $tracker))) {
        $parameters = [regex]::Match($record[1], ('record ' + $record[0] + '\(([^;]+)\);')).Groups[1].Value
        if (-not $parameters -or $parameters -match 'Tomorrow') {
            throw ('Tomorrow guidance must stay outside the saved allowance contract: ' + $record[0])
        }
    }
    $node = (Get-Command node -ErrorAction Stop).Source
    $htmlProbe = @'
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const html = fs.readFileSync(process.argv[2], 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1);
let passed = 2;
const events = {}, docEvents = {}, messages = [];
const app = {innerHTML:'', classList:{toggle(){}}, getBoundingClientRect:()=>({height:500}),
    addEventListener:(name, handler)=>events[name]=handler};
const window = {chrome:{webview:{postMessage:m=>messages.push(m)}}, addEventListener(){}};
const document = {getElementById:id=>{assert.equal(id,'app');return app;},
    addEventListener:(name, handler)=>docEvents[name]=handler};
vm.runInNewContext(scripts[0][1], {window, document, requestAnimationFrame:f=>f(), console});
function check(condition, label){assert.ok(condition,label);passed++;}
const tomorrow = '내일 예상 권장량: 약 19.00% (참고)';
const weekly = (message='오늘 0.50% 남음 · 초과 시 내일 몫 사용', estimate=tomorrow)=>({
    name:'긴 모델 <A&B> '.repeat(5)+'주간 한도', shortName:'주간', remaining:57.5, weekly:true,
    resetText:'초기화 11/13 00:00', pacingMessage:message, tomorrowMessage:estimate});
const provider = (id, windows)=>({id,name:id,plan:'fixture',supported:true,windows,
    pacing:{level:'recommended',basis:'주간 전체 한도의 참고값'},updated:'01:00'});
const codex = provider('codex',[{name:'5시간 한도',remaining:0,weekly:false,
    shortTermWarning:'5시간 한도 소진',resetText:'초기화 02:00',tomorrowMessage:'SHORT MUST NOT FORECAST'},
    weekly(),weekly('오늘 남은 권장량: 1.00%','')]);
const claude = provider('claude',[weekly('내일 몫을 당겨 쓰는 중','내일 예상 권장량: 약 8.25% (참고)')]);
function render(providers=[codex,claude],showBoth=true,activeProvider='codex',docked=false){
    window.usageViewer.update({providers,showBoth,activeProvider,docked});return app.innerHTML;
}
for(const both of [true,false]) for(const id of ['codex','claude']) for(const docked of [true,false]){
    const rendered = render(undefined,both,id,docked);
    check(rendered.includes('내일 예상 권장량:'),'guidance in combined/tabbed/docked markup');
    check(!rendered.includes('SHORT MUST NOT FORECAST'),'short limit independent');
    check(rendered.includes('&lt;A&amp;B&gt;')&&!rendered.includes('<A&B>'),'model names escaped');
    check(!rendered.includes('dailyDetails')&&!rendered.includes('다음 확인'),'no expanded detail');
    if(both||id==='codex'){
        check(rendered.includes('오늘 남은 권장량: 1.00%')&&rendered.includes('5시간 한도 소진'),'ordinary row and short limit retained');
        check(rendered.includes('<br><span class="uv-muted">'+tomorrow+'</span>'),'guidance uses two text lines');
    }
    if(both)check(rendered.includes('약 19.00%')&&rendered.includes('약 8.25%'),'providers retain separate estimates');
}
for(const message of ['오늘 몫 소진 · 이후 사용은 내일 몫에서 써요','내일 몫을 당겨 쓰는 중']){
    check(render([provider('codex',[weekly(message)])]).includes(message),'exact/over budget wording retained');
}
for(const flag of ['invalid','expired','pacingReason']){
    const row = {...weekly(),[flag]:true};
    check(!render([provider('codex',[row])]).includes(tomorrow),'held row hides forecast '+flag);
}
for(const flag of ['stale','error']){
    check(!render([{...codex,[flag]:true}]).includes(tomorrow),'failed provider hides forecast '+flag);
}
check(!render([provider('codex',[weekly('오늘 남은 권장량: 1.00%','')])]).includes('<br>'),'ordinary row stays one line');
check(!render([provider('codex',[weekly('오늘 남은 권장량: 0.00%','')])]).includes('내일 예상'),'missing estimate is not zero');
check(render([provider('codex',[weekly('오늘 몫 소진','내일 예상 권장량: 약 0.00% (참고)')])]).includes('약 0.00%'),'valid recommendation zero is displayable');
check(render([provider('codex',[weekly('fixture','<img src=x onerror=bad()>')])]).includes('&lt;img'),'estimate text escaped');
check(/\.uv-limit\{[^}]*overflow-wrap:anywhere/.test(html)&&/\.uv-weekly-status\{[^}]*overflow-wrap:anywhere/.test(html),'narrow row wrapping rules present (no layout measurement)');
render(undefined,false,'codex');
events.click({target:{closest:()=>({dataset:{provider:'claude'}})}});
check(messages.some(m=>m.type==='provider'&&m.id==='claude')&&app.innerHTML.includes('약 8.25%'),'provider tab handler');
events.change({target:{id:'show-both',checked:true}});
check(messages.some(m=>m.type==='mode'&&m.showBoth)&&app.innerHTML.includes('약 19.00%'),'combined view handler');
docEvents.keydown({key:'Escape'});
check(messages.some(m=>m.type==='hide'),'Escape handler');
console.log(`PASS: ${passed} source/HTML contract checks; no compilation, DLL, WebView2, or layout measurement.`);
'@
    $htmlProbe | & $node - (Join-Path $repoRoot 'src/UsageViewer/UI/Popup.html')
    if ($LASTEXITCODE -ne 0) { throw 'Source/HTML contract checks failed.' }
    return
}

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
using System.Threading;
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
    private static string _tomorrowDocument = "";
    private static string _claudeStatusDocument = "";
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
            if (args.Length == 2)
            {
                CheckExamples();
                CheckInvalid();
                CheckTime();
                CheckStateless();
                CheckDailyAllowance();
                CheckDailyFormula();
                CheckTomorrowGuidance();
            }
            CheckClaudeRefresh();
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

    private static object ClaudeEnum(string type, string value) => Enum.Parse(TypeOf("Models.ClaudeRefresh" + type), value);

    private static void CheckClaudeRefresh()
    {
        const string policy = "Services.ClaudeRefreshPolicy";
        var clock = new ClaudeFixtureClock();
        object refresh = New("Services.ClaudeRefreshCoordinator", clock, null);
        object State() => Get(refresh, "State")!;
        string Result() => Get(State(), "Result")!.ToString()!;
        DateTimeOffset? Next() => (DateTimeOffset?)Get(State(), "NextAttempt");
        object? Begin(string trigger = "Automatic", bool ready = true, bool visible = false) =>
            Invoke(refresh, "TryBegin", ClaudeEnum("Trigger", trigger), ready, visible);
        void Fail(object attempt, string result, int? status = null, DateTimeOffset? retry = null) =>
            Invoke(refresh, "Fail", attempt, ClaudeEnum("Result", result), status, retry);
        object Describe(DateTimeOffset at) => Static("UI.UsageDisplayHelper", "DescribeClaude", State(), at);

        Check(Begin(visible: true) == null, "visible login/interaction never triggers background navigation");
        object init = Begin(ready: false)!;
        Check(Begin("Manual") == null && Begin("Connection") == null, "all triggers share the active initialization");
        clock.Advance(59);
        Check((bool)Invoke(refresh, "Accepts", init), "initialization still active at 59 seconds");
        clock.Advance(1);
        Check(!(bool)Invoke(refresh, "Initialized", init) && Result() == "InitializationTimeout", "60-second initialization deadline");
        Check(Next() == clock.GetUtcNow().AddSeconds(30), "initial retry in 30 seconds");
        Check(Begin() == null, "normal timer observes earlier retry gate");
        object initialized = Begin("Manual", ready: false)!;
        clock.Advance(59);
        Check((bool)Invoke(refresh, "Initialized", initialized), "initialization and response deadlines are distinct");
        clock.Advance(29);
        Check((bool)Invoke(refresh, "Accepts", initialized) && Begin("Manual") == null, "attempt still active and deduplicated at 29 seconds");
        clock.Advance(1);
        Invoke(refresh, "Expire");
        Check(Result() == "ResponseTimeout" && Next() == clock.GetUtcNow().AddMinutes(2), "response timeout and two-minute retry");
        Fail(Begin("Manual")!, "NavigationFailed");
        Check(Next() == clock.GetUtcNow().AddMinutes(5), "navigation retry reaches five-minute cap");
        Fail(Begin("Manual")!, "NetworkFailed");
        Check(Next() == clock.GetUtcNow().AddMinutes(5), "network retry stays capped");

        foreach ((int status, string result) in new[] { (200, "Success"), (401, "LoginRequired"), (403, "AccessRequired"),
                 (429, "RateLimited"), (503, "ServerError"), (418, "HttpError") })
        {
            Check(Static(policy, "ClassifyHttp", status).ToString() == result, "distinct HTTP classification " + status);
        }
        var at = clock.GetUtcNow();
        Check((DateTimeOffset?)Static(policy, "ParseRetryAfter", "180", at) == at.AddSeconds(180), "delay-seconds parsed");
        Check((DateTimeOffset?)Static(policy, "ParseRetryAfter", at.AddMinutes(7).ToString("r"), at) == at.AddMinutes(7), "HTTP-date parsed");
        Check(Static(policy, "ParseRetryAfter", "-9", at) == null, "invalid delay does not suppress retry");
        Fail(Begin("Manual")!, "RateLimited", 429, at.AddSeconds(180));
        Check(Next() == at.AddSeconds(180) && Begin("Manual") == null && Begin("Connection") == null,
            "server not-before overrides automatic and manual triggers");
        Check((string?)Get(Describe(at), "ShortStatus") == "잠시 대기", "rate limit has short status");
        clock.Advance(180);
        object cancelled = Begin()!;
        Invoke(refresh, "Cancel", cancelled);
        Check(((CancellationToken)Get(cancelled, "Token")!).IsCancellationRequested && Result() == "RateLimited",
            "cancel leaves the last result without counting a new failure");
        object current = Begin("Manual")!;
        Fail(cancelled, "AccessRequired", 403);
        Check((bool)Invoke(refresh, "Accepts", current) && Result() == "RateLimited", "late HTTP error rejected");
        Fail(current, "LoginRequired", 401);
        Check(Next() == null && Begin("Manual") == null && Begin() == null, "login suspends background and tray navigation");
        Fail(Begin("Page", visible: true)!, "AccessRequired", 403);
        Check(Next() == null && (string?)Get(Describe(at), "ShortStatus") == "접근 확인", "access has its own blocked state");
        Fail(Begin("Connection", visible: true)!, "ResponseFormat", 200);
        Check(Next() == clock.GetUtcNow().AddMinutes(2) && Begin() == null, "format allows one delayed retry");
        clock.Advance(120);
        Fail(Begin()!, "ResponseRange", 200);
        Check(Next() == null && Begin() == null && Begin("Manual") == null, "range belongs to the same retry budget");

        object parser = New("Services.ClaudeWebUsageParser");
        object Parse(string input)
        {
            using var document = JsonDocument.Parse(input);
            return Invoke(parser, "Parse", document.RootElement, clock.GetUtcNow());
        }
        foreach ((string payload, string expected) in new[] {
            ("{}", "ResponseFormat"), ("{\"five_hour\":{\"utilization\":101}}", "ResponseRange"),
            ("{\"five_hour\":{\"utilization\":0,\"resets_at\":\"bad\"}}", "ResponseFormat") })
        {
            try { Parse(payload); Check(false, "invalid usage accepted"); }
            catch (TargetInvocationException exception)
            {
                Check(Get(exception.InnerException!, "Result")!.ToString() == expected, "parser rejection " + expected);
            }
        }
        object cache = Parse("{\"five_hour\":{\"utilization\":100},\"seven_day\":null,\"fixture_private\":\"omit\"}");
        object snapshot = Invoke(cache, "ToSnapshot", "Claude Web");
        Check((double)Get(Get(cache, "FiveHour")!, "RemainingPercent")! == 0d && Get(cache, "SevenDay") == null,
            "actual remaining zero distinct from unprovided weekly window");
        Invoke(refresh, "RestoreCache", snapshot, false);
        Check(Result() == "ResponseRange" && !(bool)Get(Describe(clock.GetUtcNow()), "IsCurrent")!, "reread cannot clear failure");
        object readFailure = New("Services.ClaudeRefreshCoordinator", clock, null);
        string brokenPath = Path.Combine(_root, "claude-broken-cache.json");
        File.WriteAllText(brokenPath, "{bad");
        object badStore = New("Services.ClaudeUsageStore", brokenPath);
        try
        {
            ((Task)Invoke(badStore, "ReadWebAsync", CancellationToken.None)).GetAwaiter().GetResult();
            Check(false, "malformed local cache accepted");
        }
        catch (JsonException)
        {
            Invoke(readFailure, "RestoreCache", null, true);
        }
        Check(Get(Get(readFailure, "State")!, "Result")!.ToString() == "StorageRead", "local read failure classified separately");

        object page = Begin("Page", visible: true)!;
        object binding = New("UI.ClaudePageAttempt", page);
        IList requests = (IList)Get(binding, "Requests")!;
        foreach ((string id, string loader, string frame) in new[] {
            ("old", "previous", "main"), ("foreign", "active", "child"), ("first", "active", "main"), ("later", "active", "main") })
        {
            requests.Add(New("UI.ClaudePageRequest", id, loader, frame, "fixture"));
        }
        Check(Invoke(binding, "SelectRequest") == null, "cannot accept response before navigation identity is known");
        binding.GetType().GetProperty("Loader")!.SetValue(binding, "active");
        binding.GetType().GetProperty("Frame")!.SetValue(binding, "main");
        Check((string?)Get(Invoke(binding, "SelectRequest"), "Id") == "first", "only first matching main document request wins, not old or faster responses");

        string path = Path.Combine(_root, "claude-synthetic.json");
        object store = New("Services.ClaudeUsageStore", path);
        object earlierCache = Parse("{\"five_hour\":{\"utilization\":40}}");
        ((Task)Invoke(store, "SaveAsync", earlierCache, (Action<Action>)(replace => replace()), CancellationToken.None))
            .GetAwaiter().GetResult();
        string normalFile = File.ReadAllText(path);
        Task Save(object attempt) => (Task)Invoke(store, "SaveAsync", cache,
            (Action<Action>)(replace => Invoke(refresh, "Commit", attempt, cache, replace)), CancellationToken.None);
        Save(cancelled).GetAwaiter().GetResult();
        Check(File.ReadAllText(path) == normalFile, "late success cannot replace existing file");
        using (var locked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            try { Save(page).GetAwaiter().GetResult(); Check(false, "locked destination was replaced"); }
            catch (TargetInvocationException exception) when (exception.InnerException is IOException or UnauthorizedAccessException)
            { Fail(page, "StorageWrite", 200); }
        }
        Check(Result() == "StorageWrite" && File.ReadAllText(path) == normalFile, "write failure preserves the file and doesn't record success");
        object recovered = Begin("Manual")!;
        Save(recovered).GetAwaiter().GetResult();
        Check(Result() == "Success" && (int)Get(State(), "Failures")! == 0 && Next() == clock.GetUtcNow().AddSeconds(60), "stored response alone restores normal 60-second interval");
        Check(!File.ReadAllText(path).Contains("fixture_private"), "only normalized fields persisted");
        Check((bool)Get(Describe(clock.GetUtcNow().AddMinutes(15)), "IsCurrent")! &&
              (string?)Get(Describe(clock.GetUtcNow().AddMinutes(15).AddTicks(1)), "ShortStatus") == "갱신 지연", "15-minute freshness boundary");
        object laterAttempt = Begin("Manual")!;
        Check((string?)Get(Describe(clock.GetUtcNow()), "PreviousMark") == "↻", "active values visibly marked previous");
        Fail(laterAttempt, "ServerError", 503);
        Check((string?)Get(Describe(clock.GetUtcNow()), "PreviousMark") == "!", "fresh previous value on transient failure");
        laterAttempt = Begin("Manual")!;
        Invoke(refresh, "Stop");
        Fail(laterAttempt, "NetworkFailed");
        Save(laterAttempt).GetAwaiter().GetResult();
        Check(Result() == "ServerError" && Get(State(), "Phase")!.ToString() == "Stopped" && Begin("Connection") == null,
            "shutdown rejects late success, error and restart");

        string diagnosticPath = Path.Combine(_root, "claude-diagnostic.json");
        object diagnostics = New("Services.ClaudeRefreshDiagnostics", diagnosticPath, clock);
        for (int index = 0; index < 105; index++)
        {
            Invoke(diagnostics, "Record", New("Services.ClaudeRefreshDiagnostic", clock.GetUtcNow(),
                ClaudeEnum("Phase", "Idle"), ClaudeEnum("Result", "NetworkFailed"), null, 22L, index));
        }
        ((Task)Invoke(diagnostics, "FlushAsync")).GetAwaiter().GetResult();
        using (var journal = JsonDocument.Parse(File.ReadAllBytes(diagnosticPath)))
        {
            Check(new FileInfo(diagnosticPath).Length <= 65536 && journal.RootElement.GetArrayLength() == 100 &&
                 journal.RootElement[0].EnumerateObject().Count() == 6, "diagnostic caps and allowlisted fields");
        }
        clock.Advance(86400);
        Invoke(diagnostics, "Maintain");
        ((Task)Invoke(diagnostics, "FlushAsync")).GetAwaiter().GetResult();
        Check(File.ReadAllText(diagnosticPath) == "[]", "diagnostics pruned at 24 hours");
        object blockedDiagnostics = New("Services.ClaudeRefreshDiagnostics", Path.Combine(path, "not-a-directory.json"), clock);
        Invoke(blockedDiagnostics, "Record", New("Services.ClaudeRefreshDiagnostic", clock.GetUtcNow(),
            ClaudeEnum("Phase", "Idle"), ClaudeEnum("Result", "Stopped"), null, 0L, 0));
        ((Task)Invoke(blockedDiagnostics, "FlushAsync")).GetAwaiter().GetResult();
        Check(!File.Exists(Path.Combine(path, "not-a-directory.json")), "diagnostic storage errors remain best-effort");
    }
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
              Message(over).Contains("내일 몫을 당겨 쓰는 중"), "over-budget is distinct from actual quota exhaustion");
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

    private static decimal? Tomorrow(object advice) =>
        (decimal?)Get(Items(advice).Single(), "TomorrowEstimatePercent");
    private static string TomorrowMessage(object advice) =>
        (string)Static("UI.UsageDisplayHelper", "GetTomorrowMessage", Items(advice).Single());
    private static decimal? DayEstimate(decimal remaining, decimal today, DateTimeOffset at,
                                        DateTimeOffset reset, TimeZoneInfo zone) =>
        (decimal?)Static("Services.DailyAllowanceHelper", "CalculateTomorrowEstimate", remaining, today, at, reset, zone);
    private static (object Tracker, object Advice, object Snapshot) GuidanceCase(double remaining, string name)
    {
        object tracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, name + ".json"));
        ApplyDaily(tracker, DailySnapshot(DailyStart, 76), DailyStart);
        object snapshot = DailySnapshot(DailyStart.AddHours(1), remaining);
        return (tracker, ApplyDaily(tracker, snapshot, DailyStart.AddHours(1)), snapshot);
    }
    private static void CheckNoTomorrow(object advice, string label)
    {
        Check(Items(advice).All(item => Get(item, "TomorrowEstimatePercent") == null &&
              (string)Static("UI.UsageDisplayHelper", "GetTomorrowMessage", item) == ""), label);
    }

    private static void CheckTomorrowGuidance()
    {
        foreach ((double remaining, bool show) in new[] { (58.0001, false), (58d, false), (57.9999, true), (57.5, true) })
        {
            var sample = GuidanceCase(remaining, "threshold-" + remaining.ToString(System.Globalization.CultureInfo.InvariantCulture));
            Check((TomorrowMessage(sample.Advice).Length > 0) == show, "unrounded 1 percent threshold " + remaining);
            Check(Tomorrow(sample.Advice) == 19m, "reserve today's unused share before tomorrow allocation");
            Check(Message(sample.Advice).Contains("당겨 쓰는 중") == false &&
                  Message(sample.Advice).Contains("소진") == false, "before over-budget never claims borrowing");
            if (show == false)
            {
                Check(Message(sample.Advice) == "오늘 남은 권장량: 1.00%", "at or above 1 keeps original compact label");
            }
        }
        var low = GuidanceCase(57.5, "tomorrow-low");
        Check(Message(low.Advice) == "오늘 0.50% 남음 · 초과 시 내일 몫 사용" &&
              TomorrowMessage(low.Advice) == "내일 예상 권장량: 약 19.00% (참고)", "two concise near-exhaustion lines");
        Check(Details(low.Advice).Contains(TomorrowMessage(low.Advice)), "shared detail formatter includes reference estimate");
        var tiny = GuidanceCase(57.0001, "tomorrow-tiny");
        Check(Message(tiny.Advice).Contains("0.01% 미만") && Message(tiny.Advice).Contains("소진") == false,
              "positive tiny daily remainder is not exhausted");
        var exact = GuidanceCase(57, "tomorrow-exact");
        Check(DailyValue(exact.Advice, "RemainingPercent") == 0 &&
              Message(exact.Advice) == "오늘 몫 소진 · 이후 사용은 내일 몫에서 써요" && Tomorrow(exact.Advice) == 19,
              "exact zero daily remainder with weekly quota is not actual exhaustion or existing borrowing");
        var over = GuidanceCase(56.5, "tomorrow-over");
        Check(Message(over.Advice) == "내일 몫을 당겨 쓰는 중" &&
              TomorrowMessage(over.Advice) == "내일 예상 권장량: 약 18.83% (참고)", "confirmed overspend and two-decimal reference");
        object latest = ApplyDaily(low.Tracker, DailySnapshot(DailyStart.AddMinutes(65), 56.5), DailyStart.AddMinutes(65));
        Check(DailyValue(latest, "UsedPercent") == 18.5m && DailyValue(latest, "RemainingPercent") == 0.5m &&
              Math.Abs(Tomorrow(latest)!.Value - 56m / 3) < 0.000001m &&
              Message(latest).Contains("당겨 쓰는 중") == false, "latest real quota updates estimate without inventing hourly confirmation");

        var zone = TimeZoneInfo.CreateCustomTimeZone("Tomorrow+9", TimeSpan.FromHours(9), "fixture", "fixture");
        DateTimeOffset late = DateTimeOffset.Parse("2026-11-10T23:00:00+09:00");
        DateTimeOffset dawn = DateTimeOffset.Parse("2026-11-11T02:00:00+09:00");
        Check(DayEstimate(10, 0.5m, late, dawn, zone) == 9.5m, "tomorrow dawn reset allocates only the two available hours");
        Check(DayEstimate(10, 0.5m, late, late.AddMinutes(30), zone) == null &&
              DayEstimate(10, 0.5m, late, dawn.AddHours(-2), zone) == null, "today or exactly midnight reset creates no tomorrow share");
        Check(DayEstimate(10, 0, late, dawn.AddHours(-2).AddTicks(1), zone) == 10,
              "one tick after midnight has an actual tomorrow interval");
        Check(DayEstimate(0, 0, late, dawn, zone) == null && DayEstimate(10, 0, dawn, dawn, zone) == null,
              "actual zero or expired interval is not a successful zero estimate");
        Check(DayEstimate(0.5m, 0.5m, late, dawn, zone) == 0, "valid zero forecast differs from absent forecast");
        object reservedTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "tomorrow-reserved.json"));
        ApplyDaily(reservedTracker, DailySnapshot(DailyStart, 0.8), DailyStart);
        object reserved = ApplyDaily(reservedTracker, DailySnapshot(DailyStart.AddMinutes(30), 0.1), DailyStart.AddMinutes(30));
        Check(Tomorrow(reserved) == 0 && TomorrowMessage(reserved).Contains("약 0.00%") &&
              Message(reserved).Contains("소진") == false, "all current quota reserved for today is a real zero recommendation");
        object resetTodayTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "tomorrow-today-reset.json"));
        object resetToday = ApplyDaily(resetTodayTracker, DailySnapshot(DailyStart, 0.5, DailyStart.AddHours(10)), DailyStart);
        CheckNoTomorrow(resetToday, "current date reset suppresses guidance even below 1 percent");
        Check(Message(resetToday) == "오늘 남은 권장량: 0.50%", "no borrowing claim when current interval ends today");
        object dawnTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "tomorrow-dawn-reset.json"));
        object dawnAdvice = ApplyDaily(dawnTracker, DailySnapshot(late, 0.9, dawn), late);
        Check(DailyValue(dawnAdvice, "TargetPercent") == 0.3m && Tomorrow(dawnAdvice) == 0.6m &&
              TomorrowMessage(dawnAdvice).Contains("0.60%"), "tracker retains partial tomorrow even inside 24 hours");
        object roundingTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "tomorrow-tiny-estimate.json"));
        object tinyEstimate = ApplyDaily(roundingTracker, DailySnapshot(late, 0.0003, dawn), late);
        Check(TomorrowMessage(tinyEstimate).Contains("0.01% 미만") &&
              TomorrowMessage(tinyEstimate).Contains("0.00%") == false, "tiny positive forecast is never formatted as zero");
        var exhausted = GuidanceCase(0, "tomorrow-weekly-zero");
        CheckNoTomorrow(exhausted.Advice, "actual weekly exhaustion never forecasts tomorrow");
        Check(Message(exhausted.Advice).Contains("주간 한도 소진"), "actual zero uses weekly exhaustion wording");

        var eastern = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");
        foreach ((string start, string midnight, string finish, int hours) in new[] {
            ("2026-03-07T12:00:00-05:00", "2026-03-08T00:00:00-05:00", "2026-03-11T00:00:00-04:00", 23),
            ("2026-10-31T12:00:00-04:00", "2026-11-01T00:00:00-04:00", "2026-11-04T00:00:00-05:00", 25) })
        {
            DateTimeOffset at = DateTimeOffset.Parse(start), tomorrow = DateTimeOffset.Parse(midnight);
            DateTimeOffset reset = DateTimeOffset.Parse(finish);
            decimal expected = 57m * TimeSpan.FromHours(hours).Ticks / (reset - tomorrow).Ticks;
            Check(Math.Abs(DayEstimate(60, 3, at, reset, eastern)!.Value - expected) < 0.000001m,
                  "tomorrow DST interval has actual " + hours + " hours");
            Check(DayEstimate(60, 3, at.ToOffset(TimeSpan.FromHours(9)), reset, eastern) ==
                  DayEstimate(60, 3, at, reset, eastern), "forecast uses selected local date rather than input offset");
        }
        foreach ((string start, string end) in new[] {
            ("2026-03-08T00:00:00-05:00", "2026-03-11T00:00:00-04:00"),
            ("2026-11-01T00:00:00-04:00", "2026-11-04T00:00:00-05:00") })
        {
            Check(DayEstimate(60, 3, DateTimeOffset.Parse(start), DateTimeOffset.Parse(end), eastern) == 28.5m,
                  "today DST does not shift tomorrow midnight by a fixed 24 hours");
        }
        var midnightRule = TimeZoneInfo.AdjustmentRule.CreateAdjustmentRule(new DateTime(2026, 1, 1),
            new DateTime(2026, 12, 31), TimeSpan.FromHours(1),
            TimeZoneInfo.TransitionTime.CreateFixedDateRule(new DateTime(1, 1, 1, 0, 0, 0), 3, 8),
            TimeZoneInfo.TransitionTime.CreateFixedDateRule(new DateTime(1, 1, 1, 1, 0, 0), 11, 1));
        var midnightZone = TimeZoneInfo.CreateCustomTimeZone("MidnightDST", TimeSpan.FromHours(-5),
            "fixture", "standard", "daylight", [midnightRule]);
        Check(Math.Abs(DayEstimate(9, 0, DateTimeOffset.Parse("2026-03-07T12:00:00-05:00"),
              DateTimeOffset.Parse("2026-03-10T00:00:00-04:00"), midnightZone)!.Value - 9m * 23 / 47) < 0.000001m,
              "invalid local midnight advances to the first valid minute");
        Check(Math.Abs(DayEstimate(9, 0, DateTimeOffset.Parse("2026-10-31T12:00:00-04:00"),
              DateTimeOffset.Parse("2026-11-03T00:00:00-05:00"), midnightZone)!.Value - 9m * 25 / 49) < 0.000001m,
              "ambiguous local midnight uses the earlier instant consistently");

        foreach (object invalid in new[] {
            ApplyDaily(low.Tracker, low.Snapshot, DailyStart.AddHours(1), error: "fixture"),
            ApplyDaily(low.Tracker, low.Snapshot, DailyStart.AddHours(1), stale: true),
            ApplyDaily(low.Tracker, low.Snapshot, DailyStart.AddMinutes(76)),
            ApplyDaily(low.Tracker, low.Snapshot, DailyStart.AddMinutes(59)),
            ApplyDaily(low.Tracker, DailySnapshot(DailyStart.AddMinutes(59), 57), DailyStart.AddMinutes(66)) })
        {
            CheckNoTomorrow(invalid, "failure, stale, old, clock or receipt regression does not forecast");
        }
        object missing = ApplyDaily(low.Tracker, Snapshot(DailyStart, Bucket("short", Window(5, 300))), DailyStart);
        CheckNoTomorrow(missing, "weekly missing does not fabricate tomorrow");
        object noSnapshot = Invoke(low.Tracker, "Apply", "codex", null, Evaluate(null, DailyStart), DailyStart, zone);
        CheckNoTomorrow(noSnapshot, "no received snapshot does not fabricate tomorrow");
        string badPath = Path.Combine(_root, "tomorrow-corrupt.json");
        File.WriteAllText(badPath, "broken");
        object bad = New("Services.DailyUsageAllowanceTracker", badPath);
        CheckNoTomorrow(ApplyDaily(bad, low.Snapshot, DailyStart.AddHours(1)), "corrupt storage does not forecast");
        string blockedPath = Path.Combine(_root, "tomorrow-blocked");
        Directory.CreateDirectory(blockedPath);
        object blocked = New("Services.DailyUsageAllowanceTracker", blockedPath);
        ApplyDaily(blocked, DailySnapshot(DailyStart, 0.5), DailyStart);
        SaveDaily(blocked);
        CheckNoTomorrow(ApplyDaily(blocked, DailySnapshot(DailyStart.AddMinutes(1), 0.5), DailyStart.AddMinutes(1)),
                        "save failure does not forecast");

        object multiTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "tomorrow-multi.json"));
        object multi = Snapshot(DailyStart, Bucket("a", Window(0.8, 10080, DailyStart.AddDays(4))),
            Bucket("b", Window(0, 300), Window(0.9, 10080, DailyStart.AddDays(3))));
        object codex = ApplyDaily(multiTracker, multi, DailyStart);
        object claude = ApplyDaily(multiTracker, DailySnapshot(DailyStart, 0.4), DailyStart, "claude");
        Check((decimal)Get(Items(codex)[0], "TomorrowEstimatePercent")! == 0.2m &&
              (decimal)Get(Items(codex)[1], "TomorrowEstimatePercent")! == 0.3m && Tomorrow(claude) == 0.1m,
              "providers and multiple weekly models retain independent estimates");
        Check((string)Static("UI.UsageDisplayHelper", "FormatShortTermWarning", Items(codex, "ShortTerm").Single()) ==
              "5시간 한도 소진 · 초기화를 기다려 주세요", "five-hour exhaustion remains independent");
        Check(Get(Items(codex, "ShortTerm").Single(), "TomorrowEstimatePercent") == null, "short limits never get tomorrow data");
        SaveDaily(low.Tracker);
        using JsonDocument journal = JsonDocument.Parse(File.ReadAllText(Path.Combine(_root, "tomorrow-low.json")));
        string[] fields = { "BaselineRemaining", "Target", "CheckedRemaining", "StartedAt", "CheckedAt", "LastReceipt", "ResetsAt" };
        Check(journal.RootElement.EnumerateObject().All(pair => pair.Value.EnumerateObject().Select(p => p.Name).Order()
              .SequenceEqual(fields.Order())), "derived forecast never changes journal fields");
        Check(TypeOf("Models.DailyUsageAllowance").GetProperties().All(p => p.Name.Contains("Tomorrow") == false),
              "derived guidance remains outside daily allowance model");
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
            Invoke(popup, "SetState", snapshot, false, null, null, null, false, advice, unavailable, null);
            using JsonDocument payload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
            JsonElement provider = payload.RootElement.GetProperty("providers")[0];
            JsonElement pacing = provider.GetProperty("pacing");
            JsonElement window = provider.GetProperty("windows")[0];
            Check(window.GetProperty("remaining").GetDouble() == 76 && Math.Abs(window.GetProperty("average24Hours").GetDecimal() - 17.714m) < 0.001m,
                  "popup real DLL remaining/average payload");
            Check(window.GetProperty("dailyBoundaryRemaining").ValueKind == JsonValueKind.Null,
                  "average without daily allowance has no marker");
            Check(pacing.GetProperty("message").GetString() == Message(advice) && pacing.GetProperty("detail").GetString() == Details(advice),
                  "popup shared values");
            string basis = pacing.GetProperty("basis").GetString()!;
            Check(basis.Contains("한 시간마다 확인한 사용량") && basis.Contains("%p") == false && basis.Contains("10%를") == false,
                  "new basis no budget or reserve");
            foreach (double remaining in new[] { double.NaN, double.PositiveInfinity, -1, 101 })
            {
                object invalid = Sample(remaining);
                Invoke(popup, "SetState", invalid, false, null, null, null, false, Evaluate(invalid), unavailable, null);
                using JsonDocument invalidPayload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
                JsonElement invalidWindow = invalidPayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0];
                Check(invalidWindow.GetProperty("remaining").ValueKind == JsonValueKind.Null && invalidWindow.GetProperty("invalid").GetBoolean() &&
                      invalidWindow.GetProperty("average24Hours").ValueKind == JsonValueKind.Null, "invalid values serialize unknown");
                DateTimeOffset realNow = DateTimeOffset.UtcNow;
                object freshInvalid = Snapshot(realNow, Bucket("a", Window(remaining, 10080, realNow.AddDays(2))));
                Check((string)Get(Invoke(bar, "CreateMetric", "Codex", freshInvalid, null, false, null), "Value")! == "확인 필요", "invalid top metric unknown");
            }
            foreach ((double remaining, double hours, string expected) in new[] {
                (76d, 24d, "초기화까지 남은 76%를 나눠 쓰세요"),
                (0d, 48d, "주간 한도 소진"), (0.01, 48d, "추천 페이스: 24시간에 약0.01% 미만") })
            {
                object fixture = Snapshot(Start, Bucket("a", Window(remaining, 10080, Start.AddHours(hours))));
                object fixtureAdvice = Evaluate(fixture);
                Invoke(popup, "SetState", fixture, false, null, null, null, false, fixtureAdvice, unavailable, null);
                using JsonDocument fixturePayload = JsonDocument.Parse(JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState")));
                string row = fixturePayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0]
                    .GetProperty("pacingMessage").GetString()!;
                Check(row.Contains(expected), "popup reset/exhausted/tiny advice");
            }
            object claude = Snapshot(Start, Bucket("claude", Window(100, 300),
                Window(94, 10080, DateTimeOffset.Parse("2026-11-15T12:00:00+09:00"))));
            Invoke(popup, "SetState", snapshot, false, null, claude, null, false, advice, Evaluate(claude), null);
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
            Invoke(popup, "SetState", dailySnapshot, false, null, dailyClaude, null, false, dailyAdvice, claudeDailyAdvice, null);
            _dailyDocument = JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState"));
            using (JsonDocument dailyPayload = JsonDocument.Parse(_dailyDocument))
            {
                JsonElement row = dailyPayload.RootElement.GetProperty("providers")[0].GetProperty("windows")[0];
                Check(row.GetProperty("pacingMessage").GetString() == "오늘 남은 권장량: 17.00%" &&
                      row.TryGetProperty("dailyDetails", out _) == false, "actual daily popup payload uses shared checkpoint");
                Check(row.GetProperty("remaining").GetDouble() == 74, "real quota stays separate from daily allowance");
                Check(row.GetProperty("tomorrowMessage").GetString() == "", "no extra line for daily remainder above 1");
                Check(Math.Abs(row.GetProperty("dailyBoundaryRemaining").GetDouble() -
                      (74 - (double)DailyValue(dailyAdvice, "RemainingPercent"))) < 0.000001,
                      "daily marker subtracts allowance from actual quota");
            }
            object tomorrowTracker = New("Services.DailyUsageAllowanceTracker", Path.Combine(_root, "tomorrow-render.json"));
            object tomorrowFirst = Snapshot(DailyStart,
                Bucket("near", Window(0, 300), Window(76, 10080, DailyStart.AddDays(4)), "LongModelName <A&B> " + new string('x', 80)),
                Bucket("exact", Window(76, 10080, DailyStart.AddDays(4))),
                Bucket("over", Window(76, 10080, DailyStart.AddDays(4))));
            ApplyDaily(tomorrowTracker, tomorrowFirst, DailyStart);
            object tomorrowSnapshot = Snapshot(DailyStart.AddHours(1),
                Bucket("near", Window(0, 300), Window(57.5, 10080, DailyStart.AddDays(4)), "LongModelName <A&B> " + new string('x', 80)),
                Bucket("exact", Window(57, 10080, DailyStart.AddDays(4))),
                Bucket("over", Window(56.5, 10080, DailyStart.AddDays(4))));
            object tomorrowAdvice = ApplyDaily(tomorrowTracker, tomorrowSnapshot, DailyStart.AddHours(1));
            ApplyDaily(tomorrowTracker, DailySnapshot(DailyStart, 40), DailyStart, "claude");
            object tomorrowClaude = DailySnapshot(DailyStart.AddHours(1), 30.5);
            object tomorrowClaudeAdvice = ApplyDaily(tomorrowTracker, tomorrowClaude, DailyStart.AddHours(1), "claude");
            Invoke(popup, "SetState", tomorrowSnapshot, false, null, tomorrowClaude, null, false, tomorrowAdvice, tomorrowClaudeAdvice, null);
            _tomorrowDocument = JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState"));
            DateTimeOffset received = DateTimeOffset.UtcNow.AddSeconds(-1);
            object exhausted = Snapshot(received, Bucket("claude", Window(0, 300, received.AddHours(1)),
                Window(93, 10080, received)));
            object claudeState = New("Models.ClaudeRefreshState", ClaudeEnum("Phase", "Idle"),
                ClaudeEnum("Result", "NetworkFailed"), exhausted, received.AddSeconds(30), null, 1);
            object previous = Static("UI.UsageDisplayHelper", "DescribeClaude", claudeState, received);
            using (var claudeBar = (Form)New("UI.TopUsageBar"))
            {
                object metric = Invoke(claudeBar, "CreateMetric", "Claude", exhausted, null, true, previous);
                Check((string?)Get(metric, "Value") == "0% !", "summary marks the valid exhausted previous value");
                object expired = Snapshot(received, Bucket("claude", Window(0, 300, received)));
                metric = Invoke(claudeBar, "CreateMetric", "Claude", expired, null, true, previous);
                Check((string?)Get(metric, "Value") == "갱신 중", "summary doesn't display reset value as zero");
            }
            Invoke(popup, "SetState", tomorrowSnapshot, false, null, exhausted, null, true, tomorrowAdvice,
                Evaluate(exhausted, received, stale: true), previous);
            _claudeStatusDocument = JsonSerializer.Serialize(Invoke(popup, "BuildDocumentState"));
            using (JsonDocument statusPayload = JsonDocument.Parse(_claudeStatusDocument))
            {
                JsonElement claudeProvider = statusPayload.RootElement.GetProperty("providers")[1];
                Check(claudeProvider.GetProperty("previous").GetBoolean() && !claudeProvider.GetProperty("canConnect").GetBoolean() &&
                      claudeProvider.GetProperty("windows")[0].GetProperty("alert").GetString() == "none", "previous value has no reconnect or new exhaustion alert");
            }
            using (JsonDocument tomorrowPayload = JsonDocument.Parse(_tomorrowDocument))
            {
                JsonElement[] rows = tomorrowPayload.RootElement.GetProperty("providers")[0].GetProperty("windows")
                    .EnumerateArray().Where(row => row.GetProperty("weekly").GetBoolean()).ToArray();
                Check(rows.Length == 3 && rows[0].GetProperty("tomorrowMessage").GetString() == "내일 예상 권장량: 약 19.00% (참고)" &&
                      rows[1].GetProperty("pacingMessage").GetString()!.Contains("이후 사용은") &&
                      rows[2].GetProperty("pacingMessage").GetString() == "내일 몫을 당겨 쓰는 중",
                      "actual popup JSON carries independent before, exact, and over-budget guidance");
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

    private static async Task CheckClaudeNavigationAsync()
    {
        const string origin = "https://claude.ai";
        const string usage = "/settings/usage";
        const string endpoint = "/api/organizations/fixture/usage";
        TimeSpan limit = TimeSpan.FromSeconds(10);
        var clock = new ClaudeFixtureClock();
        string cachePath = Path.Combine(_root, "navigation-cache.json");
        object store = New("Services.ClaudeUsageStore", cachePath);
        object refresh = New("Services.ClaudeRefreshCoordinator", clock, null);
        using Form window = (Form)New("UI.ClaudeConnectionWindow", store, refresh);
        var browser = (WebView2)window.GetType().GetField("_browser", BindingFlags.Instance | BindingFlags.NonPublic)!
            .GetValue(window)!;
        var options = new CoreWebView2EnvironmentOptions("--disable-background-networking --no-first-run " +
            "--no-proxy-server --host-resolver-rules=\"MAP * ~NOTFOUND\"");
        string profile = Path.Combine(_root, "navigation-profile");
        var environment = await CoreWebView2Environment.CreateAsync(null, profile, options)
            .WaitAsync(TimeSpan.FromSeconds(30));
        Check(string.Equals(environment.UserDataFolder, profile, StringComparison.OrdinalIgnoreCase),
            "navigation fixture uses only its temporary profile");
        var exited = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        environment.BrowserProcessExited += (_, _) => exited.TrySetResult(true);
        _ = window.Handle;
        _ = browser.Handle;
        await browser.EnsureCoreWebView2Async(environment).WaitAsync(TimeSpan.FromSeconds(30));
        CoreWebView2 core = browser.CoreWebView2;
        string? redirect = null;
        int documentStatus = 200;
        int endpointStatus = 200;
        int used = 0;
        int replies = 0;
        bool holdReply = false;
        var requestPaused = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseReply = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All,
                CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested += async (_, args) =>
            {
                int status = 404;
                string headers = "Cache-Control: no-store\r\nContent-Type: text/html";
                string body = "";
                if (args.Request.Uri == origin + usage && redirect != null)
                {
                    status = 302;
                    headers += "\r\nLocation: " + redirect;
                }
                else if (args.Request.Uri == origin + endpoint)
                {
                    status = endpointStatus;
                    headers = "Cache-Control: no-store\r\nContent-Type: application/json";
                    body = $$"""{"five_hour":{"utilization":{{used}}},"fixture_private":true}""";
                    headers += status switch
                    {
                        302 => "\r\nLocation: /fixture-missing",
                        429 or 503 => "\r\nRetry-After: 90",
                        _ => ""
                    };
                    replies++;
                }
                else if (args.ResourceContext is CoreWebView2WebResourceContext.Document &&
                         (args.Request.Uri.StartsWith(origin + "/", StringComparison.Ordinal) ||
                          args.Request.Uri == "https://outside.invalid/settings/usage"))
                {
                    status = args.Request.Uri == origin + "/settings" ? documentStatus : 200;
                    body = "<!doctype html><title>Synthetic navigation</title>";
                }

                CoreWebView2Deferral? deferral = null;
                try
                {
                    if (holdReply && args.Request.Uri == origin + endpoint)
                    {
                        deferral = args.GetDeferral();
                        requestPaused.TrySetResult(true);
                        await releaseReply.Task;
                    }

                    args.Response = environment.CreateWebResourceResponse(new MemoryStream(System.Text.Encoding.UTF8.GetBytes(body)),
                        status, "Synthetic", headers);
                }
                finally
                {
                    deferral?.Complete();
                }
            };
            await ((Task)Invoke(window, "ObserveNavigationAsync")).WaitAsync(limit);

            object State() => Get(refresh, "State")!;
            string Result() => Get(State(), "Result")!.ToString()!;
            bool Active() => Get(refresh, "Active") != null;

            async Task Navigate(Func<Task> start, Uri expected, bool successful = true)
            {
                var navigated = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                EventHandler<CoreWebView2NavigationCompletedEventArgs> completed = (_, args) => navigated.TrySetResult(args.IsSuccess);
                core.NavigationCompleted += completed;
                try
                {
                    await start().WaitAsync(limit);
                    Check(await navigated.Task.WaitAsync(limit) == successful && new Uri(core.Source) == expected,
                        "WebView2 reaches expected synthetic document");
                }
                finally
                {
                    core.NavigationCompleted -= completed;
                }
            }

            async Task<string> Evaluate(string script)
            {
                string result = await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
                    JsonSerializer.Serialize(new { expression = script, awaitPromise = true, returnByValue = true })).WaitAsync(limit);
                using JsonDocument json = JsonDocument.Parse(result);
                return json.RootElement.GetProperty("result").TryGetProperty("value", out JsonElement value) ? value.ToString() : "";
            }

            async Task AwaitAttemptEnd()
            {
                if (!Active())
                {
                    return;
                }

                var finished = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                EventHandler changed = (_, _) => { if (!Active()) { finished.TrySetResult(true); } };
                EventInfo changedEvent = refresh.GetType().GetEvent("Changed")!;
                changedEvent.AddEventHandler(refresh, changed);
                try
                {
                    await finished.Task.WaitAsync(limit);
                }
                finally
                {
                    changedEvent.RemoveEventHandler(refresh, changed);
                }
            }

            string request = $"const response=await fetch('{endpoint}');await response.text();return response.status;";
            async Task Receive(bool changeRoute = false, string expectedStatus = "200", bool child = false)
            {
                int previousReplies = replies;
                string route = changeRoute ? "history.replaceState(null,'','/settings/usage');" : "";
                string fetch = "(async()=>{" + route + request + "})()";
                string script = child ? "frames[0].eval(" + JsonSerializer.Serialize(fetch) + ")" : fetch;
                string response = await Evaluate(script);
                Check(response == expectedStatus && replies == previousReplies + 1, "synthetic page receives the expected response");
                if (changeRoute)
                {
                    Check(new Uri(core.Source) == new Uri(origin + usage), "usage route reached in the same document");
                }
            }

            Task StartRefresh(string trigger) => (Task)Invoke(window, "RefreshAsync", ClaudeEnum("Trigger", trigger));
            Task Refresh() => StartRefresh(window.Visible ? "Connection" : "Manual");
            Task NavigateTo(string target) => Navigate(() => { core.Navigate(target); return Task.CompletedTask; }, new Uri(target));
            Task NavigateSettings() => Navigate(Refresh, new Uri(redirect = origin + "/settings"));

            void CheckCacheUnchanged(string previous, string expectedResult)
            {
                Check(!Active() && Result() == expectedResult && File.ReadAllText(cachePath) == previous,
                    "previous cache preserved with result " + expectedResult + " (actual: " + Result() + ")");
            }

            async Task<string> VerifyRefresh(int utilization, bool bootstrap, string trigger = "Manual")
            {
                string? previousCache = File.Exists(cachePath) ? File.ReadAllText(cachePath) : null;
                clock.Advance(1);
                used = utilization;
                redirect = bootstrap ? origin + "/settings" : null;
                await Navigate(() => StartRefresh(trigger), new Uri(redirect ?? origin + usage));
                await Receive(changeRoute: bootstrap);
                await AwaitAttemptEnd();
                string saved = File.Exists(cachePath) ? File.ReadAllText(cachePath) : "";
                Check(Result() == "Success" && saved != previousCache && saved.Contains($"\"UsedPercent\":{used}") &&
                    !saved.Contains("fixture_private"), "new normalized cache and Success after " +
                    (bootstrap ? "settings redirect (result: " + Result() + ")" : "ordinary navigation"));
                return saved;
            }

            await VerifyRefresh(11, bootstrap: false);
            await VerifyRefresh(22, bootstrap: false);
            await Evaluate("location.hash='fixture'");
            await VerifyRefresh(33, bootstrap: false);
            string previousCache = await VerifyRefresh(44, bootstrap: true);

            await NavigateSettings();
            used = 99;
            await Receive();
            Check(Active() && File.ReadAllText(cachePath) == previousCache, "bootstrap is not itself a usage document");
            await Evaluate("new Promise(resolve=>{const frame=document.createElement('iframe');" +
                "frame.onload=resolve;frame.src='/settings/usage?child';document.body.append(frame);})");
            await Receive(child: true);
            Check(Active() && File.ReadAllText(cachePath) == previousCache, "child-frame 200 cannot complete bootstrap");
            used = 55;
            await Receive(changeRoute: true);
            await AwaitAttemptEnd();
            previousCache = File.ReadAllText(cachePath);
            Check(Result() == "Success" && previousCache.Contains("\"UsedPercent\":55"),
                "only the top-frame response is saved after the child-frame response");

            await NavigateSettings();
            clock.Advance(29);
            Invoke(refresh, "Expire");
            await Refresh();
            Check(Active() && File.ReadAllText(cachePath) == previousCache, "bootstrap still pending at 29 seconds; duplicate refresh ignored");
            clock.Advance(1);
            Invoke(refresh, "Expire");
            await Receive(changeRoute: true);
            CheckCacheUnchanged(previousCache, "ResponseTimeout");
            Check((DateTimeOffset?)Get(State(), "NextAttempt") == clock.GetUtcNow().AddSeconds(30), "timeout keeps normal backoff");

            await NavigateSettings();
            clock.Advance(29);
            holdReply = true;
            Task late = Receive(changeRoute: true);
            await requestPaused.Task.WaitAsync(limit);
            Check(Active(), "request started before the response deadline");
            clock.Advance(1);
            Invoke(refresh, "Expire");
            releaseReply.SetResult(true);
            await late;
            holdReply = false;
            CheckCacheUnchanged(previousCache, "ResponseTimeout");

            await NavigateSettings();
            await NavigateTo(origin + usage + "?different-loader");
            await Receive();
            await AwaitAttemptEnd();
            CheckCacheUnchanged(previousCache, "NavigationFailed");

            foreach (string other in new[] { origin + "/settings/organization", origin + "/settings?check=fixture",
                         origin + "/cdn-cgi/challenge-platform/fixture", "https://outside.invalid/settings/usage" })
            {
                redirect = other;
                await Navigate(Refresh, new Uri(other));
                await AwaitAttemptEnd();
                CheckCacheUnchanged(previousCache, "NavigationFailed");
            }

            previousCache = await VerifyRefresh(66, bootstrap: true);
            window.Opacity = 0;
            window.ShowInTaskbar = false;
            window.Show();
            await NavigateSettings();
            await Evaluate("history.replaceState(null,'','/settings/usage');history.replaceState(null,'','/settings');");
            await AwaitAttemptEnd();
            CheckCacheUnchanged(previousCache, "Success");
            await Receive(changeRoute: true);
            CheckCacheUnchanged(previousCache, "Success");
            await NavigateSettings();
            await NavigateTo(origin + usage + "?user-navigation");
            await AwaitAttemptEnd();
            CheckCacheUnchanged(previousCache, "Success");
            window.Hide();

            endpointStatus = 302;
            await NavigateSettings();
            await Receive(changeRoute: true, expectedStatus: "404");
            await AwaitAttemptEnd();
            CheckCacheUnchanged(previousCache, "NetworkFailed");
            Check((DateTimeOffset?)Get(State(), "NextAttempt") == clock.GetUtcNow().AddSeconds(30), "network failure keeps retry backoff");
            endpointStatus = 200;
            clock.Advance(29);
            await StartRefresh("Automatic");
            CheckCacheUnchanged(previousCache, "NetworkFailed");
            previousCache = await VerifyRefresh(77, bootstrap: true, trigger: "Automatic");

            foreach ((int status, string result) in new[] { (503, "ServerError"), (429, "RateLimited"), (403, "AccessRequired") })
            {
                endpointStatus = status;
                await NavigateSettings();
                await Receive(changeRoute: true, expectedStatus: status.ToString());
                await AwaitAttemptEnd();
                CheckCacheUnchanged(previousCache, result);
                if (status is 429 or 503)
                {
                    Check((DateTimeOffset?)Get(State(), "ServerNotBefore") == clock.GetUtcNow().AddSeconds(90), "server wait retained");
                    await Refresh();
                    Check(!Active(), "server wait blocks manual navigation");
                    clock.Advance(90);
                }
            }

            window.Show();
            documentStatus = 403;
            await Navigate(Refresh, new Uri(redirect = origin + "/settings"), successful: false);
            await AwaitAttemptEnd();
            CheckCacheUnchanged(previousCache, "AccessRequired");
            documentStatus = 200;
            redirect = origin + "/login";
            await Navigate(Refresh, new Uri(redirect));
            await AwaitAttemptEnd();
            CheckCacheUnchanged(previousCache, "LoginRequired");
            await NavigateTo(origin + "/fixture-idle");

            endpointStatus = 200;
            await NavigateSettings();
            Check(Active(), "shutdown occurs during a pending bootstrap");
            Invoke(refresh, "Stop");
            await Receive(changeRoute: true);
            CheckCacheUnchanged(previousCache, "LoginRequired");
            Check(Get(State(), "Phase")!.ToString() == "Stopped", "shutdown ignores the late response");
            Console.WriteLine("PASS: actual WebView2 Claude navigation fixture; intercepted requests, isolated profile.");
        }
        finally
        {
            releaseReply.TrySetResult(true);
            Invoke(refresh, "Stop");
            window.Dispose();
            await exited.Task.WaitAsync(limit);
        }
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
                await CheckClaudeNavigationAsync();
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
                await browser.ExecuteScriptAsync("window.claudeFixture=" + _claudeStatusDocument + ";");
                foreach ((int width, bool both, bool docked) in new[] { (264, false, true), (280, false, false), (320, true, false) })
                {
                    host.ClientSize = new Size(width, 1000);
                    await browser.ExecuteScriptAsync($"claudeFixture.showBoth={both.ToString().ToLowerInvariant()};claudeFixture.docked={docked.ToString().ToLowerInvariant()};claudeFixture.activeProvider='claude';usageViewer.update(claudeFixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('이전 값 · 일시 오류') && document.body.innerText.includes('0%') && document.body.innerText.includes('초기화 후 새 값 확인 중') && document.documentElement.scrollWidth<=innerWidth && document.querySelector('.uv-provider-status').scrollWidth<=document.querySelector('.uv-provider-status').clientWidth+1"), "Claude status, previous zero and expired row fit " + width);
                }
                await browser.ExecuteScriptAsync("usageViewer.update(fixture);document.querySelector('summary').click();");
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
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('.uv-daily-marker')].length===" + (both ? "2" : "1") + " && [...document.querySelectorAll('.uv-daily-marker')].every(m=>{const t=m.parentElement.getBoundingClientRect(),r=m.getBoundingClientRect();return Math.abs((r.left+r.width/2-t.left)/t.width*100-parseFloat(m.style.left))<0.1 && r.height===10})"), "daily marker position and height " + width);
                    if(both) Check(await ScriptBool(browser, "document.body.innerText.includes('오늘 남은 권장량: 12.46%') && document.body.innerText.includes('100%')"), "independent Claude daily allowance and five hour quota rendered");
                }
                await browser.ExecuteScriptAsync("window.tomorrowFixture=" + _tomorrowDocument + ";tomorrowFixture.providers.forEach(p=>{p.stale=false;p.windows.forEach(w=>w.expired=false)});");
                foreach ((int width, bool both, bool docked) in new[] { (264, false, true), (264, true, true), (280, false, false), (320, true, false) })
                {
                    host.ClientSize = new Size(width, 1800);
                    await browser.ExecuteScriptAsync($"tomorrowFixture.showBoth={both.ToString().ToLowerInvariant()};tomorrowFixture.docked={docked.ToString().ToLowerInvariant()};tomorrowFixture.activeProvider='codex';usageViewer.update(tomorrowFixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('오늘 0.50% 남음 · 초과 시 내일 몫 사용') && document.body.innerText.includes('이후 사용은 내일 몫에서 써요') && document.body.innerText.includes('내일 몫을 당겨 쓰는 중') && document.body.innerText.includes('약 18.83% (참고)')"), "three distinct tomorrow states " + width);
                    Check(await ScriptBool(browser, "[...document.querySelectorAll('.uv-weekly-status')].every(e=>e.querySelectorAll('br').length===1 && e.clientHeight<=2*parseFloat(getComputedStyle(e).lineHeight)+1)"), "near-exhaustion guidance fits two lines " + width);
                    Check(await ScriptBool(browser, "document.documentElement.scrollWidth<=innerWidth && [...document.querySelectorAll('.uv-limit')].every(e=>e.scrollWidth<=e.clientWidth+1) && document.querySelectorAll('script').length===1"), "tomorrow long models fit and escape " + width);
                    Check(await ScriptBool(browser, "document.body.innerText.includes('5시간 한도 소진') && !document.body.innerText.includes('다음 확인') && !document.body.innerText.includes('확인 사용')"), "short quota remains separate without expanded details " + width);
                    await browser.ExecuteScriptAsync("tomorrowFixture.showBoth=false;tomorrowFixture.activeProvider='claude';usageViewer.update(tomorrowFixture);");
                    Check(await ScriptBool(browser, "document.body.innerText.includes('약 10.00% (참고)') && !document.body.innerText.includes('약 19.00%') && document.documentElement.scrollWidth<=innerWidth"), "Claude tab has independent estimate " + width);
                }
                await browser.ExecuteScriptAsync("dailyFixture.showBoth=false;dailyFixture.activeProvider='codex';const w=dailyFixture.providers[0].windows[0];w.remaining=65;w.dailyBoundaryRemaining=57.23;usageViewer.update(dailyFixture);");
                Check(await ScriptBool(browser, "document.querySelector('.uv-daily-marker').style.left==='57.23%' && document.querySelector('.uv-track>span').style.width==='65%'"), "screenshot allowance boundary preserves actual fill");
                await browser.ExecuteScriptAsync("dailyFixture.providers[0].stale=true;usageViewer.update(dailyFixture);");
                Check(await ScriptBool(browser, "!document.querySelector('.uv-daily-marker')"), "stale daily allowance hides marker");
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

internal sealed class ClaudeFixtureClock : TimeProvider
{
    private readonly DateTimeOffset _start = new DateTimeOffset(2026, 11, 19, 0, 0, 0, TimeSpan.Zero);
    private long _ticks;
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp() => _ticks;
    public override DateTimeOffset GetUtcNow() => _start.AddTicks(_ticks);
    public void Advance(int seconds) => _ticks += seconds * TimeSpan.TicksPerSecond;
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
    $probeArguments = @($assemblyPath, $tempRoot)
    if ($ClaudeRefreshOnly) { $probeArguments += 'claude-refresh' }
    & $DotNetPath exec --runtimeconfig (Join-Path $buildPath 'UsageViewer.runtimeconfig.json') $probePath @probeArguments
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
