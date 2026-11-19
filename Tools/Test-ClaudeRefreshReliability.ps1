param(
    [switch]$SourceOnly,
    [string]$DotNetPath = (Join-Path $env:USERPROFILE '.dotnet/dotnet.exe')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$node = (Get-Command node -ErrorAction Stop).Source
$probe = @'
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const root = process.argv[2], read = file => fs.readFileSync(path.join(root, file), 'utf8');
const src = file => read('src/UsageViewer/' + file);
const tray = src('TrayApplicationContext.cs'), coordinator = src('Services/ClaudeRefreshCoordinator.cs');
const policy = src('Services/ClaudeRefreshPolicy.cs'), connection = src('UI/ClaudeConnectionWindow.cs');
const store = src('Services/ClaudeUsageStore.cs'), top = src('UI/TopUsageBar.cs'), popup = src('UI/UsagePopup.cs');
const diagnostics = src('Services/ClaudeRefreshDiagnostics.cs');
let passed = 0;
function check(value, name) { assert.ok(value, name); passed++; }
function block(source, start, end) { return source.slice(source.indexOf(start), source.indexOf(end)); }
const request = block(tray, 'private Task RequestRefreshAsync', 'private Task RefreshCodexAsync');
const tick = block(tray, '_timer.Tick +=', '// Ensure an invokable UI handle');
const codex = block(tray, 'private async Task RefreshCoreAsync', 'private void ApplyWindowPreferences');
check((tray.match(/await RequestRefreshAsync\(\)/g) || []).length === 2 && request.includes('RefreshCodexAsync()') &&
    request.includes('RefreshAsync(ClaudeRefreshTrigger.Manual)'), 'tray and popup manual refresh use one guarded Claude flow');
check(tick.includes('RefreshCodexAsync()') && tick.includes('RefreshAsync(ClaudeRefreshTrigger.Automatic)') &&
    !/await.*Claude/.test(tick + request + codex) && codex.includes('_client.ReadAsync'), 'Codex refresh independent of Claude');
check(/_active != null.*ServerNotBefore > Now/.test(coordinator) && coordinator.includes('&& interactive == true'), 'duplicate, server and visible interaction gates');
check(/InitializationTimeout = TimeSpan.FromSeconds\(60\)/.test(policy) && /AttemptTimeout = TimeSpan.FromSeconds\(30\)/.test(policy) &&
    coordinator.includes('GetElapsedTime(_phaseStarted)'), 'separate elapsed deadlines');
check(connection.includes('"Page.navigate"') && connection.includes('"Network.requestWillBeSent"') && connection.includes('"Network.loadingFinished"') &&
    connection.includes('item.Loader == Loader && item.Frame == Frame') && connection.includes('request.Url') &&
    connection.includes('sentAt.TryGetDouble'), 'loader, frame, request, provider and passive request-start correlation');
check(connection.includes('uri.AbsolutePath is "/settings" or "/settings/"') && connection.includes('uri.Query.Length == 0') &&
    /bool matches = pageAttempt.Loader == _documentLoader && pageAttempt.Frame == _documentFrame/.test(connection) &&
    /matches == false \|\| _refreshRoute != ClaudeRefreshRoute.SettingsBootstrap \|\|\s*pageAttempt.Attempt.Trigger == ClaudeRefreshTrigger.Page/.test(connection),
    'only the bound explicit attempt waits on the exact settings bootstrap');
const dispatch = block(connection, 'private void Dispatch', 'private async Task ReadAndSaveAsync');
check(dispatch.includes('CanUseDocument(pageAttempt) == false') && dispatch.includes('_refresh.Accepts(pageAttempt.Attempt) == false') &&
    dispatch.includes('request.Status == 200 && request.Finished == true'), 'bootstrap waits without treating the document or an incomplete response as success');
check(/if \(_refresh.Accepts\(attempt\) == false\)[\s\S]*RetireLoader\(loader\)/.test(connection) &&
    tray.indexOf('_claudeRefresh.Stop();') < tray.indexOf('_shutdown.Cancel();'), 'late callbacks and shutdown guarded');
check(/replaceFile\(\);\s+Finish\(ClaudeRefreshResult.Success/.test(coordinator) &&
    /File.WriteAllTextAsync[\s\S]*commit\(\(\) => File.Move/.test(store) &&
    connection.includes('_refresh.Commit(attempt, cache, replace)'), 'normalized atomic write precedes success');
check(!block(coordinator, 'public void RestoreCache', 'public void Cancel').includes('ClaudeRefreshResult.Success') &&
    tray.includes('|| _claudeWebSelected == true)'), 'cache reread and stale web values cannot cause success or Code fallback');
check(tray.includes('if (claudeStale == false && claudeError == null)') &&
    tray.includes('UpdateUsageAlerts(claudeSnapshot, claudeError, claudeStale, now)'), 'allowance and alerts observe validity');
check(/264 *\* *scale/.test(top) && !/ToolTip/.test(top) && top.includes('DetailsRequested') && top.includes('PreviousMark') &&
    popup.includes('? 264 : _preferences.ShowBoth == true ? 320 : 280'), 'compact widths, click target and no top toolbar tooltip');
check(diagnostics.includes('MaxEntries = 100') && diagnostics.includes('MaxBytes = 64 * 1024') &&
    diagnostics.includes('AddHours(-24)') && diagnostics.includes('exception is IOException or UnauthorizedAccessException'), 'bounded best-effort diagnostics');
check(read('.gitignore').includes('claude-refresh-diagnostics.json.tmp') && read('README.md').includes('ZIP'), 'release exclusions documented');

const html = src('UI/Popup.html');
const app = {innerHTML:'', classList:{toggle(){}}, getBoundingClientRect:()=>({height:420}), addEventListener(){}};
const window = {addEventListener(){}};
const document = {getElementById:()=>app, addEventListener(){}};
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], {window, document, requestAnimationFrame:work=>work()});
const short = {name:'5시간 한도', remaining:0, resetText:'초기화 01:30'};
const expired = {name:'주간 한도', remaining:83, expired:true, weekly:true, resetText:'새 수신 필요'};
const codexProvider = {id:'codex', name:'Codex', supported:true, windows:[{name:'Codex 합성 한도', remaining:77}]};
const claudeProvider = {id:'claude', name:'Claude', supported:true, web:true, windows:[short, expired]};
function render(status, {both=false, docked=true, active='claude', ...provider}={}) {
    window.usageViewer.update({providers:[codexProvider,{...claudeProvider,status,...provider}],
        showBoth:both,docked,activeProvider:active,refreshing:true});
    return app.innerHTML;
}
for (const mode of [{docked:true}, {docked:false}, {both:true,docked:false}]) {
    const previous = render('일시 오류 · 자동 재시도', {...mode, previous:true, stale:true});
    check(previous.includes('이전 값 · 일시 오류') && previous.includes('0% <small>남음') && !previous.includes('83%'), 'previous zero not confused with expired weekly');
    check(previous.includes('초기화 후 새 값 확인 중') && !previous.includes('연결 창 열기'), 'transient status is not a login prompt');
    check(!previous.match(/data-action="refresh"[^>]+disabled/), 'manual button stays available during independent work');
    const login = render('로그인 상태를 확인해 주세요.', {...mode,previous:true,stale:true,canConnect:true});
    check(login.includes('연결 창 열기') && login.indexOf('이전 값 · 로그인') < login.indexOf('0%'), 'login prompt precedes previous figures');
    const waiting = render('사용량 확인 중…', {...mode,windows:[]});
    check(waiting.includes('사용량 확인 중…') && !waiting.includes('0%') && !waiting.includes('연결 창 열기'), 'missing not rendered as zero or recovery prompt');
    if (mode.both) check(previous.includes('77%') && login.includes('77%'), 'Claude state does not suppress Codex in combined view');
}
check(!render('잠시 대기', {active:'codex', windows:[]}).includes('잠시 대기'), 'status stays in Claude tab');
check(/\.uv-provider-status\{[^}]*overflow-wrap:anywhere/.test(html), 'short status wraps in narrow popup (not a layout measurement)');
console.log(`PASS: ${passed} Claude refresh source/HTML checks; no compilation, DLL, WebView2, or layout measurement.`);
'@
$probe | & $node - $repoRoot
if ($LASTEXITCODE -ne 0) { throw 'Claude refresh source/HTML checks failed.' }

if (-not $SourceOnly) {
    & (Join-Path $PSScriptRoot 'Test-UsagePacing.ps1') -DotNetPath $DotNetPath -ClaudeRefreshOnly
}
