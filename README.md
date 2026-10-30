# UsageViewer

C# / .NET 10 Windows Forms로 만든 Codex 사용량 트레이 앱.
트레이 아이콘을 왼쪽 클릭하면 사용 한도 팝업이 열린다.

- 서버에서 반환한 구간별 남은 비율·사용률·초기화 시각
- 크레딧 잔액·무제한 상태 (서버에서 반환하지 않으면 미제공으로 표시)
- 클릭한 트레이가 있는 모니터 작업 영역의 오른쪽 아래 구석에 고정, 갱신 후에도 위치 유지
- 60초 자동 갱신과 수동 새로고침
- 사용량에 따른 트레이 색상, 마우스를 올리면 남은 비율 표시
- 조회 실패 시 이전 값 표시, 초기화 시각이 지나면 갱신 필요 표시
- 오른쪽 클릭 메뉴의 사용량 보기·새로고침·종료
- 바깥 클릭 / Escape / ×로 팝업 숨기기, 다시 실행하면 기존 팝업 열기

## 실행

Windows 10/11, .NET 10 Desktop Runtime, ChatGPT 계정에 로그인된 Codex CLI가 필요하다.
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

`.cmd` / `.ps1` 실행기는 사용하지 않는다. 로그인 안내가 나오면 터미널에서 `codex login`을 실행한다.
이 앱에는 로그인·로그아웃 기능이 없으며 Codex의 기존 로그인만 활용한다.
`CODEX_HOME`이 설정되어 있으면 Codex CLI가 해당 환경을 그대로 사용한다.

## 조회 방식과 범위

[OpenAI 공식 App Server 문서](https://learn.chatgpt.com/docs/app-server)에 따라
`codex app-server --listen stdio://`를 실행하고 `initialize` / `initialized` 이후
`account/read`, `account/rateLimits/read`만 호출한다.
조회마다 자식 프로세스를 시작하고 결과를 받거나 30초 제한에 도달하면 정리한다.

앱은 인증 파일·토큰을 직접 읽거나 저장하지 않는다. 인증 갱신 등 내부 처리는 Codex CLI가 담당한다.
대화 생성, 모델 실행, 초기화 크레딧 사용, 계정 설정 변경은 하지 않는다.
사용량은 ChatGPT 계정의 할당량 비율이다. API 과금 내역이나 토큰 합계는 표시하지 않는다.
구간 길이는 계정 응답 기준이므로 주간 구간만 나오는 계정도 있다.
표시 시각은 Windows 시스템의 로컬 시간이다. 초기화 시각 경과만으로 남은 비율을 추정하지 않는다.
App Server 및 계정 응답은 Codex 버전에 따라 달라질 수 있다.

계정 식별 정보와 원본 응답은 로그로 남기지 않는다. 마지막 조회 값은 메모리에만 보관한다.
외부로 공개하는 서비스나 배포 패키지는 만들지 않는다. 자동 시작 등록도 하지 않는다.

읽기 전용 연동 진단은 팝업 없이 실행할 수 있다. 보고서에는 성공 여부·구간 수·길이·초기화 시각과
크레딧 정보/잔액 필드의 제공 여부를 남긴다. 잔액 값은 기록하지 않는다.

```powershell
Start-Process .\src\UsageViewer\bin\Release\net10.0-windows\UsageViewer.exe `
    -ArgumentList '--diagnose', '.artifacts\diagnostics.json' -Wait -WindowStyle Hidden
Get-Content .artifacts\diagnostics.json
```

## 저장소

기본 브랜치는 `main`이며, GitHub 저장소 [doubleh86/UsageViewer](https://github.com/doubleh86/UsageViewer)를 사용한다.
작업 지침과 C# 규약은 [AGENTS.md](AGENTS.md),
구현 범위와 검증 결과는 [계획 문서](Docs/Plan/TrayApp.md)에 기록한다.
