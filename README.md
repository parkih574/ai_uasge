# AI Usage Tray

Claude · Codex · Antigravity의 **요금제, 계정, 사용량 한도, 리셋 시각**을 Windows 트레이에서 확인하는 모니터입니다. 서비스가 반환하는 사용량을 읽으며, 요금제 이름으로 사용 한도를 추정하지 않습니다. 수치가 없는 항목은 0%로 만들지 않습니다.

| 서비스 | 요금제·계정 | 사용량 소스 | 필요한 설치·로그인 |
| --- | --- | --- | --- |
| Claude | `claude auth status` 및 OAuth 요금제 정보 | OAuth 사용량 API, 실패 시 같은 계정의 상태줄/성공 캐시 | Claude Code의 구독 계정 로그인 |
| Codex | 앱 서버 `account/read` | `account/rateLimits/read`의 모든 한도 그룹; 장애 시 경고를 붙인 세션 로그 | Codex CLI 또는 데스크톱에 포함된 앱 서버와 ChatGPT 로그인 |
| Antigravity | 데스크톱/CLI 로컬 서버의 계정·요금제 및 상태줄의 `plan_tier`, `email` | 로컬 서버의 한도 그룹·모델별 한도 + CLI 상태줄, 계정별 통합 | 실행 중인 Antigravity 데스크톱 또는 CLI 상태줄 연동 |

**지원 범위:** Claude 데스크톱 단독 조회는 지원하지 않으며 Claude Code 연동이 필요합니다. Antigravity 데스크톱은 실행 중인 앱의 로컬 조회 서버를 자동 탐지합니다. 비공개 프로토콜을 사용하므로 앱 버전에 따라 조회가 제한될 수 있습니다. Codex도 발견된 앱 서버에서 로그인 상태를 확인할 수 있어야 하며, 데스크톱 설치만으로 성공을 보장하지 않습니다. API 키 사용량/요금 청구는 구독 한도와 별개이며 이 프로그램의 대상이 아닙니다.

트레이 아이콘 좌클릭으로 상세 팝업을 엽니다. 맨 위 AI 이름과 같은 줄 오른쪽의 **톱니바퀴**를 누르면 설정 창이 열립니다. 우클릭 메뉴에는 **설정·새로고침·종료**만 표시합니다.

**설정** 창에서 회사별 표시 항목·90% 알림·Windows 자동 시작을 선택하고, **완료 및 재시작**을 누르면 저장 후 자동으로 재시작해 적용합니다. 취소하거나 창을 닫으면 이 선택은 저장하지 않습니다. CLI 상태줄 연동 버튼은 즉시 적용되며 취소해도 유지됩니다.

설정 창은 흰 배경·검정 글자와 ON/OFF 토글을 사용하며, 모든 항목을 항상 한 열로 배치합니다. 글자와 토글 사이 간격을 확보하고 내용에 맞춰 창을 세로로 늘립니다. 실제 화면의 높이가 부족할 때만 본문을 스크롤하며 글자 크기와 하단 완료 버튼은 유지합니다. 설정 창의 작업표시줄 `U`는 흰색, 제목 표시줄 `U`는 어두운색입니다. 할당량 팝업의 톱니바퀴는 첫 AI 이름과 함께 스크롤되며 별도 공간을 차지하지 않습니다. 사용량 로딩으로 팝업 크기가 변하면 해당 화면의 작업 영역 안으로 위치를 다시 맞춥니다.

| 설정 분류 | 선택 항목 |
| --- | --- |
| Claude | `5h`, `weekly` (모델별 주간 한도 포함) |
| Codex | 기본 `5h`·`weekly`, `5.3spark`의 `5h`·`weekly`, Reserve `weekly` |
| Antigravity | Gemini `5h`·`weekly`, Claude (GPT와 공유하는 한도 그룹 전체) |

회사 이름 옆 토글은 해당 회사 전체 표시를 제어합니다. 기간별 선택은 저장·복원되며 팝업·툴팁·90% 알림에 함께 적용합니다. 이전 Spark·Antigravity 모델 선택도 새 설정으로 이전합니다. Antigravity가 다른 모델 그룹을 제공하면 그 그룹의 표시 선택도 추가됩니다.

Codex Pro 계정에서는 기본 `5h`를 선택해도 숨깁니다. 이 프로그램의 표시 규칙이며, Spark `5h`에는 적용하지 않습니다. 설정에서는 `Pro · 5h 숨김`으로 안내하고 기본 `5h` 토글을 비활성화하며, 이전 선택은 보존합니다.

5시간·주간 표시는 `5h`·`weekly`로 줄이고, 각 모델 안에서 `5h → weekly` 순서를 고정합니다. 서버가 제공하는 기간만 표시합니다. Codex의 `gpt-reserve`는 일반 한도 소진 후 Luna로 계속 사용할 수 있는 별도 예비 한도입니다 ([공식 안내](https://help.openai.com/en/articles/20001499-luna-reserve-in-codex-and-chatgpt-work)).

## 트레이 아이콘·알림

- **아이콘** — `U` 글자입니다. 작업표시줄 테마에 맞춰 흰색/검정이 자동 전환되고, 고DPI 에서는 시스템이 요구하는 크기로 그립니다. 수치는 아이콘에 마우스를 올리면 나오는 툴팁과 좌클릭 팝업이 담당합니다.
- **90% 알림** — 어느 항목이든 90% 를 넘기면 풍선 알림을 한 번 띄웁니다. 같은 창에서는 다시 알리지 않고, 창이 리셋되면 다음 주기에 한 번 더 알립니다. 설정 창의 **사용량 90% 알림**으로 끄고 켭니다 (기본 켜짐).
- **소진 예측** — Claude 5시간 창은 폴링마다 사용률을 모아 두고, 지금 속도면 리셋 전에 100% 에 닿겠다 싶을 때 `≈06:12 소진` 을 덧붙이고 그 줄을 빨갛게 칠합니다. 같은 창에서 모은 표본만 쓰고 2개·10분 이상이 필요해서, 켠 직후에는 뜨지 않는 게 정상입니다 (폴링이 5분 주기라 세 번째 갱신부터).
- **조회 시각** — 각 섹션 제목에 마지막 조회 시각을 `(09.17  14:30)` 형식으로 표시합니다.

## 요구 사항

- Windows 10 / 11
- PowerShell 7 권장 (없으면 Windows 기본 PowerShell 5.1 로 자동 폴백)
- 위 표에 맞는 CLI 또는 데스크톱 설치와 로그인이 필요합니다. 없는 항목은 안내 문구로 표시됩니다.

## 실행

`AiUsageTray.exe` 를 더블클릭하면 끝입니다. 콘솔 창 없이 트레이 아이콘만 뜹니다.

exe 를 직접 빌드하려면 (Windows 에 내장된 .NET Framework 컴파일러만 사용, 추가 설치 없음):

```powershell
pwsh -File build-exe.ps1
```

exe 없이 스크립트로 띄우려면 `start-hidden.vbs`를 실행해도 됩니다. 런처와 `.ps1` 파일들을 같은 폴더에 두세요. 실행 파일은 스크립트를 불러오는 런처이므로 스크립트 수정에 따른 재빌드가 필요하지 않습니다. 상태줄 연동 후 폴더를 옮겼다면 연동 설정을 다시 실행하세요.

**Windows 시작 시 자동 실행**은 설정 창에서 켜고 끕니다 (관리자 권한 불필요, `HKCU\...\Run` 에 등록).

## 데이터 소스 탐지

실행 파일과 데이터 경로를 매 수집마다 탐색합니다. `CLAUDE_CONFIG_DIR`·`CODEX_HOME`이 명시되어 있으면 그 경로만 사용하며, 누락되었다고 다른 기본 프로필로 넘어가지 않습니다. 실행 중인 앱이 상속받은 환경 변수를 바꾸려면 앱을 다시 실행하세요.

| 항목 | 탐지 순서 |
| --- | --- |
| Claude | CLI는 `PATH`, `~\.local\bin`. 인증 위치는 명시한 `CLAUDE_CONFIG_DIR` 또는 기본 Claude 경로. 상태줄 캐시는 현재 계정·프로필이 일치할 때만 사용 |
| Codex | `PATH`의 실행 파일 → `%LOCALAPPDATA%\OpenAI\Codex\bin`의 설치된 런타임 → Codex MSIX의 알려진 런타임 위치. 로그는 명시한 `CODEX_HOME\sessions` 또는 `~\.codex\sessions` |
| Antigravity | 현재 Windows 사용자로 실행 중인 Antigravity 언어 서버·`agy`/`antigravity-cli`의 수신 포트 → CLI 상태줄 캐시. 다른 사용자·다른 앱의 서버는 제외 |

지금 무엇을 잡았는지는 아래 명령으로 확인합니다 (UI 없이 수집 결과와 소스 경로만 출력):

```powershell
pwsh -File ai-usage-tray.ps1 -Test
```

### 상태줄 연동

- **CLI 연동 옆 `?`:** 연동이 필요한 경우, 서비스별 조회 방식, 설정·해제 동작을 도움말 팝업으로 표시합니다.
- **Claude → 연동설정:** Claude의 `settings.json`에 `claude-statusline.ps1`을 등록합니다. 공식 `rate_limits` 입력을 사용합니다. CLI 사용 후 캐시가 채워지며, OAuth 조회가 실패했을 때 같은 계정의 마지막 값으로 사용됩니다. `claude auth status`가 계정 정보를 반환해야 합니다.
- **Antigravity → 연동설정:** `~\.gemini\antigravity-cli\settings.json`에 `antigravity-statusline.ps1`을 등록합니다. `plan_tier`·`email`·전체 `quota`를 저장합니다. Gemini, Claude, GPT 이름을 하드코딩하여 제외하지 않습니다.
- **연동설정**은 기존 상태줄 등록을 현재 앱 경로로 교체합니다. **연동해제**는 이 앱이 등록한 `statusLine` 항목을 삭제합니다. 다른 도구의 상태줄과 계정별 마지막 사용량 기록은 해제로 삭제하지 않습니다.
- 설정·해제는 즉시 저장되며, 실행 중인 CLI를 다시 시작하면 반영됩니다. 원본 설정은 `settings.json.ai-usage-tray.<시각>.<고유값>.bak`에 보존하며 나머지 설정은 유지합니다. Antigravity는 기본 상태줄과 함께 표시합니다.
- 공백·작은따옴표가 포함된 경로는 PowerShell의 인코딩된 명령으로 전달합니다. 8.3 단축 경로에 의존하지 않습니다.

### Antigravity 데스크톱·CLI 통합

- 데스크톱에 로그인하고 실행해 두면 다음 갱신에서 자동 탐지합니다. 데스크톱 사용에는 CLI 상태줄 설정이 필요하지 않습니다. 실행 중인 CLI의 로컬 서버도 탐지하며, 상태줄 캐시는 앱을 닫은 뒤에도 마지막 값을 제공합니다.
- 데스크톱·CLI가 모두 꺼져 있으면 현재 사용량을 조회할 수 없습니다. 마지막 정상 조회의 요금제·계정·사용량·조회 시각은 저장해 표시하며, 트레이를 재시작해도 유지합니다. 마지막 사용량과 조회 시각이 있으면 팝업에서 서버를 찾지 못했다는 안내는 생략하며, 과거 값으로 알림을 띄우지 않습니다. 앱을 다시 실행하면 다음 갱신에서 최신 값으로 바뀝니다. 저장된 기록이 없다면 한 번 정상 조회해야 합니다.
- 로컬 서버에서 `GetUserStatus`로 계정·요금제를 읽고, `RetrieveUserQuotaSummary`가 제공하는 모든 한도 그룹과 기간을 표시합니다. 해당 메서드가 없는 구버전 IDE에서는 `GetUserStatus`/`GetCommandModelConfigs`의 모델별 한도를 읽습니다. 서버가 주간 한도를 제공하지 않으면 만들어 표시하지 않습니다.
- 같은 이메일의 데스크톱·CLI 값은 한 번만 표시합니다. 수치를 더하지 않으며, 한도가 있는 실시간 응답을 우선합니다. 여러 실시간 응답 중에서는 그룹별 한도 응답을 우선하고, 같은 종류에서는 최신 응답을 사용합니다. 출처는 함께 표시합니다.
- 이메일이 다르면 계정별 섹션으로 나눕니다. 이메일을 확인할 수 없는 출처는 합치지 않습니다. CLI 캐시만 남으면 마지막 활동 기준이라는 안내를 표시하고 자동 알림에서 제외합니다.
- 계정·요금제 필드 없이 저장하던 구형 CLI 캐시는 표시하지 않습니다. 현재 상태줄 연동이 생성하는 캐시는 계속 사용합니다.
- 앱을 자동 실행하거나 종료하지 않습니다. 인증 파일을 사용하지 않으며, 데스크톱 프로세스의 임시 CSRF 값은 그 프로세스의 로컬 포트에만 전달하고 저장·표시하지 않습니다. 프록시·리다이렉트는 사용하지 않습니다. 자체 서명 인증서 허용은 확인된 루프백 주소의 해당 요청에만 적용합니다.

## 저장되는 파일

캐시와 표시 설정은 프로그램 폴더가 아니라 `%LOCALAPPDATA%\ai-usage-tray\` 에 씁니다. 읽기 전용 위치에 설치해도 되고, 저장소가 더러워지지 않습니다.

### 계정별 마지막 사용량

- Claude·Codex·Antigravity는 계정별 마지막 요금제·사용량·조회 시각을 따로 보존합니다. A → B → A로 전환하거나 트레이를 재시작해도 A의 기록이 B의 값으로 덮어써지지 않습니다.
- Claude와 Codex는 로그인 계정과 설정 프로필 경로가 일치하는 기록만 복원합니다. Codex는 계정 확인 후 한도 조회가 실패했을 때 해당 계정의 기록을 사용합니다. 계정 자체를 확인하지 못한 경우에는 저장된 계정을 임의로 선택하지 않습니다.
- Antigravity는 현재 확인된 계정에 사용량이 없으면 그 계정의 마지막 기록을 보완합니다. 앱이 모두 꺼졌을 때는 기존처럼 마지막으로 표시했던 계정 목록을 복원합니다. 보존된 모든 과거 계정을 현재 로그인 목록으로 취급하지 않습니다.
- 기존 단일 계정 기록은 새 값으로 교체하기 전에 보존합니다. 계정별 파일명은 계정·프로필의 해시이며 원래 조회 시각을 유지합니다. 저장된 값만 복원한 경우 새 사용량 알림·소진 예측에 사용하지 않습니다.

| 파일 | 용도 |
| --- | --- |
| `state-cache.json` | Claude 마지막 성공 값 및 계정·프로필 |
| `claude-statusline-cache.json` | Claude 상태줄의 사용량 및 계정·프로필 |
| `codex-state-cache.json` | Codex 마지막 정상 조회의 계정·프로필·사용량 |
| `antigravity-cache.json` | Antigravity 상태줄의 요금제·계정·전체 할당량 |
| `antigravity-state-cache.json` | Antigravity 마지막 조회 상태·계정별 사용량·원래 조회 시각 |
| `display-state.json` | 표시 항목·90% 알림 체크 상태 |
| `*.json.accounts\<해시>.json` | 각 사용량 캐시의 계정별 마지막 기록 |

## 알아둘 점

- Claude 사용량 엔드포인트는 **계정 단위로 요청 제한이 민감합니다.** 폴링 주기는 5분이며, 429 를 받으면 15분부터 누진 백오프하고 마지막 성공 값을 계속 보여줍니다. 주기를 짧게 바꾸지 마세요.
- 각 섹션에 **요금제·계정·출처·기준 시각**을 표시합니다. 미제공 요금제·계정은 확인 불가로 표시합니다. 많은 한도는 스크롤로 확인하며 `Page Up`·`Page Down`·`Esc`를 지원합니다.
- Codex·Antigravity 앱 서버는 조회 시 서버 쪽 한도를 갱신할 수 있습니다. 로그·상태줄 캐시는 마지막 활동 기준이며, CLI 캐시만 사용할 때는 로그아웃·계정 전환을 새 상태줄 입력 전까지 감지할 수 없습니다.
- 리셋이 지난 스냅샷은 이전 수치와 `리셋 지남`을 함께 표시하고 알림에서 제외합니다. 근거 없이 0%로 바꾸지 않습니다.
- Codex 로그는 전체 `rollout-*.jsonl`에서 한도 그룹별 마지막 유효 기록을 찾습니다. 로그만으로 현재 계정을 확인할 수 없어 경고를 표시하고 알림에서 제외합니다. 로그가 많은 환경에서는 대체 조회가 느릴 수 있습니다.
- 프로그램은 Claude OAuth 인증에 저장된 토큰을 사용하며, 인증 헤더는 Anthropic 사용량 엔드포인트로만 전송합니다. 토큰을 캐시·화면·진단 출력에 저장하지 않습니다. Codex 인증 처리는 설치된 앱 서버가 담당합니다.
- 상태줄 캐시에 계정 이메일을 저장합니다. 대화 내용·작업 경로·전체 입력 페이로드는 저장하지 않습니다. 이 사용자 데이터 폴더를 배포 파일에 포함하지 마세요.

## 자체 점검

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/verify.ps1 # 5.1/7 오프라인 통합 검사
pwsh -File ai-usage-tray.ps1 -SelfTest                              # 합성 파서·로그·저장 검사
pwsh -File antigravity-statusline.ps1 -SelfTest                     # Antigravity 입력 검사
pwsh -File claude-statusline.ps1 -SelfTest                          # Claude 입력 검사
```

오프라인 검사는 가짜 CLI·임시 로컬 HTTP 서버·합성 계정만 사용합니다. Antigravity 프로세스/포트 필터, 로컬 요청, 구형 응답, 같은 계정 중복 제거, 여러 계정 분리, CLI 대체 경로도 검사합니다. 실제 설치된 Antigravity 앱의 인증 연결·HTTPS 응답은 별도 확인이 필요합니다. `-Test`와 `-Snapshot`은 실제 수집을 수행하므로 로그인된 사용자 환경에서 별도로 확인해야 합니다. 공개 검증에 실계정 값을 사용하지 마세요.

연동 규격: [Codex 앱 서버](https://learn.chatgpt.com/docs/app-server), [Claude CLI](https://code.claude.com/docs/en/cli-usage), [Claude 상태줄](https://code.claude.com/docs/en/statusline), [Antigravity 상태줄](https://antigravity.google/docs/cli/statusline).

Antigravity 데스크톱의 비공개 프로토콜 근거: [CodexBar 로컬 조회 구현](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift), [한도 그룹 응답 파서](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Antigravity/AntigravityQuotaSummaryParser.swift). Google이 보장하는 공개 사용량 API는 아닙니다.

## 라이선스

MIT — `LICENSE` 참고.

번들된 [Pretendard](https://github.com/orioncactus/pretendard) 글꼴은 SIL Open Font License 1.1 을 따릅니다. 원문은 [LICENSE-Pretendard](LICENSE-Pretendard)에 포함되어 있습니다. 글꼴 파일을 지워도 맑은 고딕으로 폴백하므로 동작에는 문제가 없습니다.
