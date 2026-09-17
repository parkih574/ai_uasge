---
name: AI 사용량 — 네이티브 설정
description: 한 화면에서 표시 항목과 실행 옵션을 조정하는 Windows 설정 창
colors:
  surface: "#ffffff"
  text: "#000000"
  primary: "#2563eb"
  primary-hover: "#1e56d2"
  section-text: "#000000"
  muted-text: "#000000"
  disabled-text: "#000000"
  toggle-off: "#b7c2d0"
  toggle-disabled: "#edf0f4"
  badge-surface: "#ffffff"
  neutral-hover: "#f6f8fb"
  divider: "#e9edf2"
  button-border: "#dce1e9"
typography:
  title:
    fontFamily: "Pretendard, Malgun Gothic"
    fontSize: "13pt"
    fontWeight: 700
  body:
    fontFamily: "Pretendard Medium, Malgun Gothic"
    fontSize: "12pt"
    fontWeight: 400
  label:
    fontFamily: "Pretendard Medium, Malgun Gothic"
    fontSize: "9.5pt"
    fontWeight: 400
rounded:
  button: "7px"
  switch: "11.5px"
spacing:
  inset: "24px"
  indent: "12px"
  divider-gap: "6px"
  action-gap: "8px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.surface}"
    typography: "{typography.body}"
    rounded: "{rounded.button}"
    padding: "4px 10px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.button}"
    padding: "4px 10px"
  switch-on:
    backgroundColor: "{colors.primary}"
    rounded: "{rounded.switch}"
    width: "40px"
    height: "23px"
  switch-off:
    backgroundColor: "{colors.toggle-off}"
    rounded: "{rounded.switch}"
    width: "40px"
    height: "23px"
  badge:
    backgroundColor: "{colors.badge-surface}"
    textColor: "{colors.muted-text}"
    typography: "{typography.label}"
    padding: "1px 4px"
---

# Design System: AI 사용량 — 네이티브 설정

## Overview

**Creative North Star: "한 화면에 모은 설정"**

이 문서는 `ai-usage-tray.ps1`의 네이티브 설정 창에만 적용한다. 승인된 설정 시안의 흰 바탕, 단일 열, 오른쪽 토글을 실제 WinForms 구현에서 추출한 기록이다. 사용량 팝업의 어두운 화면과 기존 트레이 아이콘 테마는 별도 체계다.

**Key Characteristics:**

- 넉넉한 작업 영역에서는 설정 전체를 한 화면에 표시한다.
- 제공자와 기간을 같은 행에서 읽고 토글을 바로 조작한다.
- 작은 화면에서는 본문만 스크롤하고 완료·취소 영역은 고정한다.

## Colors

### Primary

`primary`는 켜진 스위치와 완료 버튼에 사용한다. 완료 버튼의 포인터 상태에는 `primary-hover`를 사용한다.

### Neutral

설정 배경과 Pro 설명 바탕은 흰색으로 통일한다. 본문·제목·안내·Pro 설명·비활성 기간의 글자는 모두 검정색이며, 크기·굵기와 스위치 상태로 위계를 구별한다. 꺼진 스위치는 `toggle-off`, 비활성 스위치는 `toggle-disabled`로 구별한다. `divider`는 섹션 구분선, `button-border`는 취소와 CLI 연동·도움말 버튼 윤곽이다.

## Typography

본문은 번들 `Pretendard Medium` 패밀리의 Regular 스타일을 사용한다. 제목은 `Pretendard`의 Bold 스타일이며, 글꼴을 불러오지 못하면 `Malgun Gothic`을 사용한다. 작은 안내와 배지는 label 역할이다. 위 토큰의 weight는 API 스타일을 뜻하며 Medium 파일의 실제 획 두께를 대체하지 않는다.

설정 전용 텍스트는 GDI+ 회색조 안티앨리어싱을 사용한다. 제목·본문·안내의 위계는 크기와 굵기로 표현한다.

## Layout

Claude, Codex, Antigravity, 알림 및 시작, CLI 연동을 단일 열로 쌓는다. 제공자 제목에는 전체 표시 토글이 있고, 사용량 행은 항목 이름과 `5h`·`weekly` 열로 나뉜다. 기본 구성은 사용량 10개, 제공자 3개, 일반 설정 2개의 토글이며 추가 모델이 있으면 행이 늘어난다.

단위는 96 DPI 기준 논리 픽셀이다. 기본 클라이언트 너비는 560이고 높이는 실제 콘텐츠에 맞춘다. 모니터 작업 영역의 가장자리 여백은 16이다. 최소 창 크기는 460 × 400이지만 더 작은 작업 영역에서는 그 안에 맞춘다. 사용량·일반 옵션 행과 제목 높이는 36, CLI 제공자 행 높이는 40, 기간 열 너비는 각각 104와 124이다.

본문 좌우 여백은 inset, 하위 항목 들여쓰기는 indent 토큰을 따른다. 하단 영역은 기본 높이 56으로 고정되며, 오류 안내가 길면 높이를 늘린다. 행을 압축하지 않고 창을 세로로 늘린다. 본문이 실제 작업 영역보다 클 때만 세로 스크롤한다. 설정 HWND의 실제 DPI를 기준으로 한 번 확대하며, 같은 좌표계를 크기 변경에도 유지한다.

## Elevation & Depth

설정 본문에는 그림자나 카드 층을 추가하지 않는다. 흰 바탕 위의 얇은 구분선과 간격으로 그룹을 나눈다. 창 테두리와 제목 표시줄은 Windows가 그린다.

## Shapes

스위치는 둥근 트랙과 원형 손잡이로 구성한다. 손잡이는 15 논리 픽셀이며 트랙 위아래로 4만큼 여백을 둔다. 버튼은 button 반경을 사용한다. Pro 배지는 모서리를 둥글리지 않는 작은 바탕 영역이다.

## Components

- **스위치:** GDI+ 벡터로 그리되 네이티브 CheckBox 동작과 키보드 초점을 유지한다. 불투명 컨트롤은 매번 자기 배경을 흰색으로 채운 뒤 그린다. 포인터를 올리면 활성 트랙을 약간 어둡게 하고, 키보드 초점은 점선으로 표시한다. 상태를 색뿐 아니라 손잡이 위치로도 구별한다.
- **Pro 배지:** `Pro · 5h 숨김`으로 비활성 이유를 표시한다. Pro 계정의 기본 5h는 저장된 선택을 보존하면서 조작만 막고 비활성 모양으로 그린다.
- **완료 및 재시작:** 파란색 기본 버튼이다. 저장과 재시작이 성공하면 창을 닫고, 실패하면 하단 안내를 표시하고 다시 시도할 수 있게 한다.
- **취소:** 윤곽선 버튼이다. 저장하지 않고 창을 닫는다. Escape와 창 닫기도 취소 동작을 유지한다.
- **CLI 연동:** 제목 옆에 32 × 32 도움말 `?` 버튼을 둔다. Claude와 Antigravity 행은 왼쪽 제공자 이름과 오른쪽의 `연동설정`·`연동해제` 버튼으로 구성한다. 각 작업 버튼은 96 × 36이며 간격은 action-gap을 따른다. 도움말과 작업 버튼 모두 기존 `button-secondary` 모양과 키보드 초점 표시를 사용한다. 즉시 저장되며 취소해도 유지된다는 안내를 행 바로 위에 둔다.
- **CLI 도움말 및 동작:** `?`는 Windows 기본 MessageBox로 선택 기능의 목적과 제공자별 차이를 설명한다. `연동설정`은 기존 상태줄 경로를 현재 앱 경로로 교체하고, `연동해제`는 이 앱이 등록한 `statusLine` 항목만 삭제한다. 변경은 즉시 저장되지만 실행 중인 CLI는 다시 시작해야 반영된다. 해제 후에도 계정별 마지막 사용량 기록은 유지한다.
- **창 아이콘:** 설정 창의 작업표시줄 U는 흰색, 제목 표시줄 U는 본문색이다. 알림 영역의 기존 트레이 아이콘은 Windows 테마에 따른 색상을 유지한다.

구현 근거: `ai-usage-tray.ps1`의 `TraySettings`, 설정 전용 폰트, `New-SettingsUsageRow`, `Set-SettingsWindowBounds`, `New-SettingsDialog`, `Show-UsageStatusLineHelp`, `Write-UsageStatusLineSettings`. 기존 설정 시각 확인: `work/settings-preview-7.png`, `work/settings-compact-7.png`, `work/settings-narrow-7.png`. CLI 변경 시각 확인: `.impeccable/review/cli-preview.png`, `.impeccable/review/cli-compact.png`, `.impeccable/review/cli-narrow.png`. CLI 검증은 합성 상태 렌더링과 소스·테스트 근거에 한정되며, 실제 MessageBox 표시와 사용자 CLI 설정 변경은 확인하지 않았다. Sidecar의 HTML/CSS는 이 네이티브 컨트롤의 시각 참조용이며 앱의 이벤트 구현을 대체하지 않는다.

## Do's and Don'ts

### Do:

- **Do** 넉넉한 화면에서 모든 설정을 함께 보여 주고 작은 화면에서는 본문만 스크롤한다.
- **Do** 토글의 키보드 조작, 초점 표시, 접근 가능한 이름과 비활성 설명을 유지한다.
- **Do** 일반 설정의 저장 후 앱 재시작과 CLI 연동의 즉시 저장·CLI 재시작을 구별해 안내한다.

### Don't:

- **Don't** 이 설정 전용 기록을 사용량 팝업이나 트레이 테마의 재설계 근거로 확대한다.
- **Don't** 고DPI에서 레이아웃을 두 번 확대하거나 글꼴을 비트맵으로 늘린다.
- **Don't** Pro 기본 5h를 비활성화하면서 저장된 선택값까지 바꾼다.
