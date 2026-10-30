# UsageViewer

C# / .NET 10 Windows Forms로 만든 Codex·Claude 사용량 트레이 앱.
트레이 아이콘을 왼쪽 클릭하면 사용 한도 팝업이 열린다.

- 구간별 남은 비율·초기화 시각
- Codex·Claude·Gemini·Cursor·Copilot 설치 자동 감지 (실행 파일/PATH/설치 등록 정보)
- 사용량 연동은 Codex·Claude 지원. 나머지는 감지 여부와 미지원 상태만 표시
- ‘두 서비스 함께 보기’ 체크: 320 DIP 두 서비스 보기, 해제: 280 DIP 서비스 탭 보기
- 보기 방식과 마지막 선택 탭을 다음 실행에도 유지
- 서비스 탭·함께 보기 전환 중에는 상세창을 열린 채 유지
- 크레딧 잔액·무제한 상태 (서버에서 반환하지 않으면 미제공으로 표시)
- 클릭한 트레이가 있는 모니터 작업 영역의 오른쪽 아래 구석에 고정, 갱신 후에도 위치 유지
- Codex와 연결된 Claude 웹 페이지는 60초 갱신, Claude 수신 파일은 5초마다 확인. 상단 ↻로 수동 새로고침
- 사용량에 따른 트레이 색상, 마우스를 올리면 남은 비율 표시
- 조회 실패 시 이전 값 표시, 초기화 시각이 지나면 갱신 필요 표시
- 상단 264×32 DIP 요약 바 상시 표시, 클릭하면 바로 아래 상세 팝업
- 탭/바를 드래그해 위쪽 위치와 모니터를 변경. 놓은 모니터 작업 영역 상단에 붙고 위치를 기억
- 오른쪽 클릭 메뉴의 ‘모니터 상단에 표시’·‘항상 가장 앞에 표시’ 체크 옵션
- 오른쪽 클릭 메뉴의 사용량 보기·새로고침·종료
- 바깥 클릭 / Escape / ×로 팝업 숨기기, 다시 실행하면 기존 팝업 열기

## 실행

Windows 10/11, .NET 10 Desktop Runtime, ChatGPT 계정에 로그인된 Codex CLI가 필요하다.
Claude 웹 연결에는 Microsoft Edge WebView2 Runtime이 필요하다.
개발 빌드에는 .NET 10 SDK가 필요하다.

```powershell
dotnet build .\src\UsageViewer\UsageViewer.csproj -c Release
.\src\UsageViewer\bin\Release\net10.0-windows\UsageViewer.exe
```

작업 표시줄의 숨겨진 아이콘 영역에 표시될 수 있다. 트레이의 아이콘을 눌러 팝업을 연다.
실행 직후 팝업을 열려면 `UsageViewer.exe --show`를 사용한다.
사용자 폴더에 SDK를 설치했다면 `& "$env:USERPROFILE\.dotnet\dotnet.exe"`로 실행할 수 있다.

Codex는 Desktop 번들 → PATH의 `codex.exe` → 기본 npm 설치 경로 순서로 찾는다.
직접 지정하려면 앱 실행 전에 환경 변수에 네이티브 실행 파일의 절대 경로를 넣는다.

```powershell
$env:USAGEVIEWER_CODEX_PATH = 'C:\path\to\codex.exe'
.\src\UsageViewer\bin\Release\net10.0-windows\UsageViewer.exe
```

`.cmd` / `.ps1` 실행기는 사용하지 않는다. 기존 CLI가 ChatGPT로 연결되어 있으면 그 로그인을 사용한다.
CLI가 API 키로 연결되어 있거나 다른 앱과 인증이 섞이면 팝업의 **ChatGPT 연결하기** 또는
트레이의 **Codex 구독 연결**을 누른다. 브라우저에서 Codex 앱과 같은 구독 계정으로 직접 로그인한다.
전용 연결 후에는 표시기 프로필의 로그인을 우선 사용한다. 다른 앱을 위해 전역 `codex login`을 바꿀 필요가 없다.

전용 연결은 `%LOCALAPPDATA%/UsageViewer/CodexProfile`에서 Codex 자체가 관리하며 인증 파일을 직접 읽거나 복사하지 않는다.
이 자식 프로세스만 전용 `CODEX_HOME`과 파일 자격 증명 저장소를 사용하고 API 키·워크로드 인증 환경 변수를 제외한다.
다른 프로세스의 환경, 기존 Codex 홈·계정·대화·설정은 변경하지 않는다.
전용 연결 전의 기존 CLI 조회는 사용자 지정 `CODEX_HOME`을 그대로 따른다.

## 조회 방식과 범위

[OpenAI 공식 App Server 문서](https://learn.chatgpt.com/docs/app-server)에 따라
`codex app-server --listen stdio://`를 실행하고 `initialize` / `initialized` 이후
평소에는 `account/read`, `account/rateLimits/read`만 호출한다.
사용자가 표시기 전용 연결을 선택한 경우에만 전용 프로필에서 `account/login/start`를 추가로 호출한다.
조회마다 자식 프로세스를 시작하고 결과를 받거나 30초 제한에 도달하면 정리한다.

앱은 인증 파일·토큰을 직접 읽거나 저장하지 않는다. 전용 연결의 저장과 인증 갱신 등 내부 처리는 Codex CLI가 담당한다.
대화 생성, 모델 실행, 초기화 크레딧 사용, 계정 설정 변경은 하지 않는다.
사용량은 ChatGPT 계정의 할당량 비율이다. API 과금 내역이나 토큰 합계는 표시하지 않는다.
구간 길이는 계정 응답 기준이므로 주간 구간만 나오는 계정도 있다.
표시 시각은 Windows 시스템의 로컬 시간이다. 초기화 시각 경과만으로 남은 비율을 추정하지 않는다.
App Server 및 계정 응답은 Codex 버전에 따라 달라질 수 있다.

계정 식별 정보와 원본 응답은 로그로 남기지 않는다. Codex 조회 값은 메모리에만 보관한다.
외부로 공개하는 서비스나 배포 패키지는 만들지 않는다. 자동 시작 등록도 하지 않는다.

읽기 전용 연동 진단은 팝업 없이 실행할 수 있다. 보고서에는 성공 여부·구간 수·길이·초기화 시각과
크레딧 정보/잔액 필드의 제공 여부를 남긴다. 잔액 값은 기록하지 않는다.

```powershell
Start-Process .\src\UsageViewer\bin\Release\net10.0-windows\UsageViewer.exe `
    -ArgumentList '--diagnose', '.artifacts\diagnostics.json' -Wait -WindowStyle Hidden
Get-Content .artifacts\diagnostics.json
```

## Claude 앱 사용량 연결

1. 자동 감지된 Claude 영역의 **연결하기**를 누른다. 또는 트레이 오른쪽 메뉴의 **Claude 연결 / 계정 확인**을 사용한다.
2. 열린 Claude 공식 페이지에서 데스크톱 앱과 같은 계정으로 직접 로그인한다.
3. 사용량 페이지에 한도가 표시되고 창 위쪽에 **사용량 수신 완료**가 나타나는지 확인한다.
4. 창을 닫으면 트레이에서 주기적으로 페이지를 다시 열어 갱신한다.

기존 Claude 앱의 인증 파일이나 브라우저 쿠키는 읽지 않는다. 연결 창은 별도 WebView2 프로필을 사용하므로
여기서 한 번 로그인해야 한다. 프로필은 `%LOCALAPPDATA%/UsageViewer/ClaudeWebProfile`에 WebView2가 관리한다.
로그인 입력과 인증 데이터는 앱의 사용량 캐시나 로그로 기록하지 않는다.

사용량 페이지가 실제로 받은 응답에서 5시간·주간 한도만 읽고
`%LOCALAPPDATA%/UsageViewer/claude-web-usage.json`에 정규화해 저장한다.
이 웹 응답은 공개 API 계약이 아니므로 페이지 형식이 바뀌거나 한도를 반환하지 않으면 오류를 표시한다.
실제 로그인·최초 웹 사용량 수신은 아직 검증하지 않았다. 빌드 및 예시 응답 파싱 검증과 구분한다.

## 팝업 디자인

실제 팝업은 앞서 선택한 시안과 같은 HTML/CSS 구조를 내장 WebView2로 표시한다.
함께 보기 너비는 320 DIP, 탭 보기 너비는 280 DIP이며 내용에 맞춰 높이를 조절한다.
체크박스 선택을 기억하고 트레이에서 열 때 작업 영역 오른쪽 아래 고정을 유지한다. 설치 감지는 인증 파일에 접근하지 않는다.
상단 바에서 열면 264 DIP 너비로 바 바로 아래에 연결되며, 접합부 모서리를 펴서 하나의 화면처럼 표시한다.

상단 표시를 켜면 264×32 DIP 요약 바가 계속 표시된다. 마우스가 떠나도 접히지 않는다.
바의 여백이나 본문을 누른 채 드래그해 좌우 위치를 바꿀 수 있다.
다른 모니터로 끌어 놓으면 그 모니터 작업 영역의 위쪽에 붙는다. 클릭은 상세 팝업을 열고 닫는다.
상세 팝업을 닫아도 요약 바는 그대로 남는다.

트레이 또는 상단 바의 오른쪽 메뉴에서 ‘모니터 상단에 표시’와 ‘항상 가장 앞에 표시’를 각각 바꾼다.
항상 앞 옵션은 상단 바와 상세 팝업 모두에 적용된다. 옵션을 끄면 보통 창 순서로 표시된다.
선택 모니터의 테두리 없는 전체화면 창이 전경이면 상단 바를 자동으로 숨기고, 돌아오면 다시 표시한다.
드래그하는 동안 작업 창의 포커스를 유지하며, 상세 보기를 클릭할 때만 활성화한다.
보기 방식·선택 탭·상단 표시·항상 앞 옵션·모니터·가로 위치는 같은 `view.json`에 저장한다.

## Claude Code 보조 연동

Claude Code의 [공식 statusLine](https://code.claude.com/docs/en/statusline) 입력을 받는
`UsageViewer.exe --claude-statusline` 수집 모드를 제공한다. 입력 중 5시간·주간 비율과 초기화 시각만
`%LOCALAPPDATA%/UsageViewer/claude-usage.json`에 저장한다. 원본 입력이나 인증 파일은 저장·조회하지 않는다.
사용량은 Claude 응답 이후에 제공되므로 Claude를 사용하지 않는 동안에는 마지막 수신 값이다.
15분 이상 지난 수신은 오래된 값으로 구분한다. 크레딧 잔액은 이 입력에서 제공되지 않는다.

빌드 후 아래 명령으로 Claude의 `statusLine`을 연결한다. PowerShell 7이 필요하다.
기존 statusLine이 있으면 덮어쓰지 않으며 다른 설정을 보존한다.

```powershell
pwsh -NoProfile -File .\Tools\Connect-ClaudeStatusLine.ps1
```

터미널 보조 연동은 Claude Code 터미널 세션의 다음 응답부터 사용량이 수신된다.
웹 연결에서 받은 캐시가 있으면 웹 데이터를 우선 사용한다.
연결 도구를 다시 실행하면 이 도구가 만든 기존 명령의 PowerShell 호환 문제도 교정한다.
데이터가 없거나 해당 계정이 사용량을 제공하지 않으면 대기 안내를 표시한다.
Claude의 상태 표시줄 설정이 수집 스크립트를 참조하므로 이 프로젝트를 옮기면 연결 명령을 다시 실행해야 한다.
해제하려면 Claude의 `settings.json`에서 이 프로젝트를 참조하는 `statusLine` 항목만 제거한다.
보기 설정은 `%LOCALAPPDATA%/UsageViewer/view.json`에 보관한다.

## 저장소

기본 브랜치는 `main`이며, GitHub 저장소 [doubleh86/UsageViewer](https://github.com/doubleh86/UsageViewer)를 사용한다.
작업 지침과 C# 규약은 [AGENTS.md](AGENTS.md),
구현 범위와 검증 결과는 [계획 문서](Docs/Plan/TrayApp.md)에 기록한다.
