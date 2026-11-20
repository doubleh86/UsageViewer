# Claude 사용량 쿼리 및 시작 복구

작성일: 2026-11-20

상태: 구현 및 격리 검증 완료 · 제품 재시작 `user_check` 대기

## 목표와 범위

- 확인된 사용량 문서에서 현재 시도의 최상위 프레임·로더에 등록된 공식 GET은 쿼리가 있어도 같은 문서 내 전환 뒤 완료할 수 있게 한다.
- 목적 페이지 판정, 원래 요청 주소 전체와 응답 주소 비교, HTTP·본문·캐시 저장 검증과 시간 제한은 유지한다. 새 네트워크 요청이나 인증 변경은 추가하지 않는다.
- 2026-11-20 제품 재시작 후 첫 응답 시간 초과의 원인은 확인되지 않았다. 다음 탐색 실패는 전환 시 등록된 후보가 제거된 뒤 정상 응답이 도착한 사례로, 첫 시간 초과와 구분한다.

## 작업 및 검증

- `src/UsageViewer/UI/ClaudeConnectionWindow.cs`: 이미 등록된 GET을 전환 시 선별하는 조건만 수정한다.
- `Tools/Test-ClaudeRefreshReliability.ps1`, `Tools/Test-UsagePacing.ps1`: 소스/HTML 검사와 Release DLL 격리 WebView2 검사에서 수정 전후, 캐시 복원 후 자동 갱신 및 재시도를 확인한다.
- `README.md`: 검증 방법을 안내한다. 제품 재시작 실계정 확인은 `user_check`로 별도 기록한다.

## 검증 결과

- Release 이전 DLL: 외부 연결을 차단한 임시 프로필의 WebView2에서 사용량 문서의 쿼리 있는 GET을 등록하고 동일 문서 내 프래그먼트가 붙은 목적 페이지로 전환했다. 원래 요청의 지연 200이 도착했지만 `NavigationFailed`였고 이전 정규화 캐시는 바뀌지 않았다.
- Release 빌드: `dotnet build src/UsageViewer/UsageViewer.csproj -c Release --no-restore` 성공(경고 0, 오류 0).
- PowerShell 소스/HTML: `pwsh -NoProfile -File Tools/Test-ClaudeRefreshReliability.ps1 -SourceOnly` 37건, `pwsh -NoProfile -File Tools/Test-UsagePacing.ps1 -SourceOnly` 65건 통과.
- 실제 Release DLL: `pwsh -NoProfile -File Tools/Test-UsagePacing.ps1 -ClaudeRefreshOnly` 470건 통과. 느린 200은 쿼리 유무와 관계없이 정규화 캐시를 한 번 교체하고 `Success`가 됐다. 전환 후 요청과 허용되지 않는 목적 페이지·호스트·경로·프레임·새 문서는 성공에 쓰이지 않았다. 변조한 합성 응답 메타데이터로 다른 요청 ID·응답 주소·로더·프레임과 캐시 응답도 확인했다. 로그인·접근 차단, 429/503, 잘못된 본문 및 저장 실패에서는 이전 파일을 유지했다.
- 시작 검사는 임시 WebView2로 초기화 접점만 대체한 새 창과 코디네이터에서 실제 정규화 캐시 읽기를 사용했다. 추가 클릭 없이 첫 자동 응답과 이후 60초 주기 두 번이 수신 시각·수치를 갱신했다. 합성 시계에서 30초 무응답 뒤 이전 캐시 유지, 30초 뒤 재시도 성공, 시간 초과·종료 후 늦은 200 무시를 확인했다. 소스에서 Codex의 독립 예약을, 실제 팝업 DLL에서 Claude 대기·실패 중 합성 Codex 수치가 갱신됨을 확인했다.

## user_check

- 기존에 연결된 제품을 수정본으로 재시작한 뒤, 추가 클릭 없이 첫 Claude 갱신과 이후 자동 갱신에서 수신 시각이 전진하는지 확인한다. Codex 갱신은 별도로 확인한다.
- 이번 작업에서 실계정·기존 프로필·제품 실행본에는 접근하지 않았다. 제품 재시작에서 보고된 첫 시간 초과와 fixture의 시간 초과는 같은 원인으로 판단하지 않는다.
