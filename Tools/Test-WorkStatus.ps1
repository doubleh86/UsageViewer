param(
    [switch]$SourceOnly,
    [string]$DotNetPath = (Join-Path $env:USERPROFILE '.dotnet/dotnet.exe')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $SourceOnly) {
    & (Join-Path $PSScriptRoot 'Test-UsagePacing.ps1') -WorkStatusOnly -DotNetPath $DotNetPath
    return
}

$node = (Get-Command node -ErrorAction Stop).Source
$probe = @'
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const appRoot=process.argv[2];
const src=name=>fs.readFileSync(path.join(appRoot,name),'utf8');
const html=src('UI/Popup.html');
const events={},messages=[];
const app={innerHTML:'',classList:{toggle(){}},addEventListener(name,callback){events[name]=callback},getBoundingClientRect:()=>({height:250})};
const window={chrome:{webview:{postMessage:message=>messages.push(message)}},addEventListener(){}};
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{window,document:{getElementById:()=>app,addEventListener(){}},requestAnimationFrame:fn=>fn()});
const row=(running,waiting,status='최근 훅 관측',partial=false)=>({running,waiting,status,partial});
const provider=(id,name,work)=>({id,name,work,supported:true,plan:'Fixture',windows:[{remaining:76,name:'5시간'}]});
const data={showBoth:false,docked:true,activeProvider:'codex',workTab:true,totalWorkMode:false,
    work:{running:3,waiting:1,partial:false,status:'최근 훅 관측',codex:row(2,1),claude:row(1,null)},
    providers:[provider('codex','Codex',row(2,1)),provider('claude','Claude',row(1,null))]};
const click=dataset=>events.click({target:{closest:()=>({dataset})}});
window.usageViewer.update(data);
assert.match(app.innerHTML,/전체 진행[\s\S]*3건[\s\S]*확인된 대기 1건[\s\S]*Codex[\s\S]*진행 2건 · 대기 1건[\s\S]*Claude[\s\S]*진행 1건/);
click({workTotal:'true'});
assert(messages.some(message=>message.type==='work-mode'&&message.total));
assert.match(app.innerHTML,/data-tab="work" aria-pressed="true"/);
click({provider:'claude'});
assert.match(app.innerHTML,/data-provider="claude" aria-pressed="true"/);
assert.match(app.innerHTML,/작업 · 진행 1건[\s\S]*76%/);
click({workTotal:'false'});
assert.match(app.innerHTML,/data-provider="claude" aria-pressed="true"/);
click({provider:'codex'});
assert.match(app.innerHTML,/작업 · 진행 2건 · 대기 1건/);
click({tab:'work'});
assert(messages.some(message=>message.type==='detail-tab'&&message.id==='work'));
const partial={...data.work,running:1203,partial:true,codex:row(1203,1),claude:row(null,null,'미연동')};
window.usageViewer.update({...data,work:partial});
assert.match(app.innerHTML,/연동된 작업 중[\s\S]*1203건[\s\S]*미연동/);
for(const status of ['미연동','수신 대기','신호 오래됨','연결 끊김']){
    window.usageViewer.update({...data,work:{running:null,partial:true,status,codex:row(null,null,status),claude:row(null,null,status)}});
    assert(app.innerHTML.includes(status)&&!app.innerHTML.includes('0건'));
}
window.usageViewer.update({...data,work:{running:0,partial:false,codex:row(0,null),claude:row(0,null)}});
assert.match(app.innerHTML,/전체 진행[\s\S]*0건/);
assert.match(src('UI/TopUsageBar.cs'),/264 \* scale[^\n]*32 \* scale/);
assert.match(src('Services/PopupPreferencesStore.cs'),/ShowTotalWorkCount = false/);
assert.match(src('Services/WorkStatusCollector.cs'),/PipeOptions\.CurrentUserOnly/);
assert.doesNotMatch(src('Services/WorkStatusCollector.cs'),/thread\/|account\/|Process\.Start/);
assert(src('Program.cs').indexOf('--work-status-hook')<src('Program.cs').indexOf('ApplicationConfiguration.Initialize'));
console.log('PASS: work status source/HTML contract; no build, profile, Git mutation, or layout measurement.');
'@
$probe | & $node - (Join-Path $repoRoot 'src/UsageViewer')
if ($LASTEXITCODE -ne 0) { throw 'Work status source checks failed.' }
