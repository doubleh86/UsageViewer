# 상단 작업 수 구현

목표: 264×32 DIP의 사용량·클릭을 보존하면서 앱별/전체 작업 수, 작업 탭, 서비스별 한 줄 상태를 추가한다. 기존 사용량·크레딧·알림과 관측을 분리한다.

## 공식 수집 경계 (2026-11-25)

- [Codex App Server](https://learn.chatgpt.com/docs/app-server#track-thread-status-changes)의 `thread/list`는 페이지 단위 스레드 및 해당 서버의 런타임 상태를 반환한다. `thread/status/changed`는 로드된 스레드의 상태 변경을 알린다. 전체 관측에는 실제 작업 소유 서버의 읽기 가능한 연결, 초기 전체 스냅샷, 후속 알림 범위와 재연결 동기화가 필요하다.
- 공식 문서에는 stdio·Unix 소켓과 실험적 TCP WebSocket이 있고, [Windows 백그라운드 서버 공유 릴리스 노트](https://learn.chatgpt.com/docs/changelog?type=chatgpt-desktop-app)도 있다. 그러나 `CodexUsageClient`는 데스크톱 번들 바이너리를 사용하더라도 별도 stdio 프로세스를 시작하며 계정/한도만 조회한다. 이 체크아웃에서 실제 작업 소유 서버에 대한 공식 읽기 전용 연결과 알림 범위는 입증되지 않았다. 새 stdio, 로그, 비공개 백엔드, 프로세스/소켓 탐색을 상태 수집에 사용하지 않는다.
- 사용자가 선택한 [Codex 공식 훅](https://learn.chatgpt.com/docs/hooks), [Claude Code 공식 훅](https://code.claude.com/docs/en/hooks), [Claude 데스크톱 Code 플러그인/로컬 환경](https://code.claude.com/docs/en/desktop#install-plugins)을 연결한다. Claude는 사용자가 Desktop의 로컬 환경에만 지정하는 표식을 요구하며, 일반 Chat·Cowork·CLI/IDE·SSH·클라우드는 연결하지 않는다.

## 구현 및 검증 범위

`Models/WorkStatus`, `Services/WorkStatus*`에 관측·집계·훅 진입점을 분리하고, `Program`, `TrayApplicationContext`, `PopupPreferencesStore`, `UI/TopUsageBar`, `UI/UsagePopup`, `UI/Popup.html`에 연결한다. README에 설정 방법과 이벤트 경계를 기록한다. 입력을 메모리에서 필요한 필드로 축소하고 현재 Windows 사용자 전용 로컬 파이프를 통해 전달한다.

`Tools/Test-WorkStatus.ps1` 및 기존 `Tools/Test-UsagePacing.ps1`의 합성 데이터와 별도 WebView 프로필로 검증한다. 최소 Release 빌드, `git diff --check`, PowerShell 7 `-SourceOnly`를 실행한다. 실제 앱/훅·병렬 작업 화면은 별도 사용자 확인으로 남긴다.

## 관측 정책

Codex의 `PermissionRequest`는 승인 요청 신호이고 `PreModelRequest`는 동일 턴의 실제 후속 요청 신호다. `Interrupt`는 활성 턴의 취소이며 `SessionEnd`는 메인 세션의 정상 종료 경로에서만 전달된다. `Stop`은 응답 종료이며 다른 Stop 훅의 계속 실행 결정과 세션 폐쇄를 알 수 없다. `PostModelRequest` 결과는 요청 시도 하나의 결과라 최종 오류 수신으로 간주하지 않는다. Claude는 `Notification: permission_prompt`로 따로 관측한 대기만 센다. `PostToolBatch`는 도구 배치 전체가 해소된 재개 신호다. `StopFailure`는 API 오류 턴, `SessionEnd`는 전달된 세션 종료다. 사용자 취소의 `Stop`은 없으므로 별도 취소 신호로 가정하지 않는다. `PostToolUse`는 이미 진행 중인 세션을 갱신하지만 대기나 종료를 덮지 않는다. 다른 훅이 모델 전송을 막거나 Stop 뒤로 작업을 연장하는 경우 및 이벤트가 빠지는 경우는 스냅샷으로 복구할 수 없다.

10분 뒤 진행/대기는 만료된다. 그러한 미해결 세션은 다른 세션에서 받은 종료 신호로 0이 되지 않는다. 집계는 메모리의 관측 세션만 포함하며 전체 앱 인벤토리를 보장하지 않는다. 파이프 자체가 열리지 않거나 사용자가 연결 해제를 알리면 단절로 처리한다. 세션 신호 없이 발생한 강제 종료·훅 중단은 만료로 표현한다. 재시작 후 새 신호가 필요하다. 합성 예시(진행 Codex 2, 대기 1, 진행 Claude 1)는 운영 기본 데이터가 아니다.

## 브랜치와 병합 참고

격리 작업 브랜치 `ai/mcp-plan-ea4c16a187c64c7090bf2b87f883f3c9`, 기준 `1051b4d3f930b800daf210dbdd428532919eb15d`. 과제에 제공된 main 진행 작업 경로와 이 브랜치의 변경이 겹치는 곳은 `README.md`, `Tools/Test-UsagePacing.ps1`, `src/UsageViewer/Program.cs`, `src/UsageViewer/TrayApplicationContext.cs`, `src/UsageViewer/UI/Popup.html`, `src/UsageViewer/UI/UsagePopup.cs`다. 특히 팝업 상태/HTML과 트레이 갱신 및 검증 스크립트의 독립 경로를 함께 유지해야 한다. main 체크아웃 검사는 하지 않았으며 작업 트리·설정·실계정은 변경하지 않았다.

`Services/WorkStatusAppServer.cs`는 추가하지 않았다. 검증된 Desktop 공유 연결이 없는 상태에서 미사용 어댑터나 별도 서버를 넣지 않고, 공식 훅 경로만 실행 가능하게 구현했다.

## 검증 결과

- `dotnet build src/UsageViewer/UsageViewer.csproj -c Release`: 성공, 경고·오류 0. Windows의 `net10.0-windows` Release를 빌드했다. 첫 복원은 샌드박스의 NuGet 접근 제한으로 실패해 승인된 실행에서 복원했다.
- PowerShell 7 `Tools/Test-WorkStatus.ps1 -SourceOnly`, `Tools/Test-UsagePacing.ps1 -SourceOnly`: 통과(기존 사용량/크레딧 등 74개). 소스 검증은 프로젝트 빌드·WebView·Git 상태 변경 없이 실행했다.
- `Tools/Test-WorkStatus.ps1`: 격리 실행 66개 통과. 실제 Release 어셈블리에 합성 훅·병렬 상태·중복·하위 에이전트·대기·재개·완료·취소·오류·세션 종료·단절·만료·부분 집계를 입력했다. 실제 임의 이름 파이프로 송수신했으며, 별도 일회용 보기 파일과 보이지 않는 WebView2로 264×32 DIP/좁은 폭의 상단 적중 범위, 다자릿수, 작업/서비스 상세의 열린 상태, 보기 저장/복원, 기존 사용량/잔량 경고를 확인했다. 기본 샌드박스에서 Windows 자원 접근이 거부되어 승인된 격리 검증으로 통과했다.
- 작업공간을 명령 단위로 신뢰한 `git diff --check` 통과. 커밋·병합·푸시·배포는 하지 않았다.
- **user_check (미실행):** 사용자 동의 후 실제 Codex Desktop / Claude Desktop Code Local에서 훅 설치·전달 여부와 두 세션 이상 병렬 작업, 승인 대기·재개·종료 및 264×32 DIP에서 실제 표시를 확인한다. 별도 Windows DPI 및 제공자 버전/조직 정책도 이때 확인한다. 이 작업에서 제공자 설정·실계정·실행 세션은 사용하지 않았다.
