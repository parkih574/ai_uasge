# ai-usage-tray.ps1 — Claude / GPT(Codex) 5시간·주간 할당량 트레이 모니터
#
# 데이터 소스
#   Claude : https://api.anthropic.com/api/oauth/usage  (~/.claude/.credentials.json 의 OAuth 토큰, 매 폴링마다 새로 읽음)
#            요금제 = credentials 의 rateLimitTier (예: default_claude_max_20x → "Max 20x")
#   GPT    : codex app-server account/rateLimits/read 우선, 세션 JSONL 은 구버전·장애 폴백
#   Antigravity : 실행 중인 데스크톱/CLI 로컬 서버 + CLI statusLine, 계정별 통합
#
# 실행: start-hidden.vbs (숨김) / 테스트: pwsh -File ai-usage-tray.ps1 -Test (UI 없이 수집 결과만 JSON 출력)
# 트레이 아이콘: 'U' 글자(테마 따라 흰/검) — 수치는 툴팁과 좌클릭 팝업이 담당.
# 좌클릭 = 상세 팝업, 우클릭 = 설정/새로고침/종료.
param(
    [switch]$Test,
    [switch]$Snapshot,
    [switch]$SelfTest,
    [switch]$SyntheticSelfTest,
    [switch]$Library,
    [switch]$Collect,
    [switch]$CollectClaude,
    [switch]$CollectGpt,
    [switch]$CollectAntigravity,
    [switch]$Force,
    [switch]$WaitForPreviousInstance,
    [string]$InitialBackoffUntil = '',
    [int]$Initial429Count = 0,
    [string]$InitialClaudeAccount = ''
)

$ErrorActionPreference = 'Stop'

# 5분 주기 + 팝업 열 때 60초 이상 지났으면 즉시 갱신. 60초 상시 폴링은 usage 엔드포인트 429 유발 확인됨.
$POLL_MS        = 300000

# 캐시·설정은 스크립트 폴더가 아니라 사용자 데이터 폴더에 둔다
# (Program Files 등 쓰기 불가 위치에 설치돼도 동작 + 저장소를 더럽히지 않음).
$DATA_DIR = Join-Path $env:LOCALAPPDATA 'ai-usage-tray'
$STATE_CACHE       = Join-Path $DATA_DIR 'state-cache.json'   # 마지막 성공 값 (재시작 직후 429 대비)
$ANTIGRAVITY_CACHE = Join-Path $DATA_DIR 'antigravity-cache.json'
$ANTIGRAVITY_STATE_CACHE = Join-Path $DATA_DIR 'antigravity-state-cache.json'
$CLAUDE_STATUS_CACHE = Join-Path $DATA_DIR 'claude-statusline-cache.json'
$DISPLAY_STATE     = Join-Path $DATA_DIR 'display-state.json'

function Initialize-DataDirectory([switch]$Migrate) {
    if (-not (Test-Path -LiteralPath $DATA_DIR)) { New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null }
    if ($Migrate) {
        foreach ($n in 'state-cache.json', 'antigravity-cache.json', 'display-state.json') {
            $old = Join-Path $PSScriptRoot $n
            $new = Join-Path $DATA_DIR $n
            if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new)) {
                try { Move-Item -LiteralPath $old -Destination $new -Force } catch { }
            }
        }
    }
}

# ---------- 데이터 소스 위치 탐지 ----------
# 설치 위치는 PC마다 다르다. 각 CLI 의 공식 환경변수를 먼저 보고, 없으면 기본 경로를 순서대로 확인한다.
# 매 폴링마다 다시 해석 — CLI 를 나중에 설치·로그인해도 재시작 없이 잡힌다.

function Get-FirstExisting([string[]]$paths) {
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-ClaudeCredPath {
    if ($env:CLAUDE_CONFIG_DIR) {
        return Get-FirstExisting @((Join-Path $env:CLAUDE_CONFIG_DIR '.credentials.json'))
    }
    return Get-FirstExisting @(
        (Join-Path $HOME '.claude\.credentials.json')
        $(if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'claude\.credentials.json' })
        (Join-Path $HOME '.config\claude\.credentials.json')
    )
}

function Get-CodexSessionsPath {
    if ($env:CODEX_HOME) { return Get-FirstExisting @((Join-Path $env:CODEX_HOME 'sessions')) }
    return Get-FirstExisting @(
        (Join-Path $HOME '.codex\sessions')
    )
}

$state = @{
    claude      = @{ plan = ''; account = ''; source = ''; rows = @(); err = $null; updated = $null; success = $false; clear = $false }
    gpt         = @{ plan = ''; account = ''; source = ''; rows = @(); err = $null; asOf = $null; success = $false; clear = $false }
    antigravity = @{ plan = ''; account = ''; source = ''; rows = @(); err = $null; asOf = $null; success = $false; clear = $false }
}
$script:claudeBackoffUntil = $null
$script:antigravityModelVisibility = @{}
$script:usageVisibility = @{}
$script:claude429Count = $Initial429Count
if ($InitialBackoffUntil) {
    try { $script:claudeBackoffUntil = [DateTimeOffset]::Parse($InitialBackoffUntil).LocalDateTime } catch { }
}

# ---------- 수집 ----------

# ConvertFrom-Json(pwsh)이 이미 DateTime으로 바꾼 값과 문자열 둘 다 처리.
# Codex 로그 타임스탬프는 UTC(무표기)라 -AssumeUtc 필요.
function ConvertTo-LocalTime($v, [switch]$AssumeUtc) {
    if ($null -eq $v) { return $null }
    # Windows PowerShell 5.1은 Get-Date를 {value: "/Date(...)/", ...}로 직렬화할 수 있다.
    if ($v -isnot [string] -and $v -isnot [ValueType]) {
        $wrapped = Get-Field $v @('value')
        if ($null -ne $wrapped) { return ConvertTo-LocalTime $wrapped -AssumeUtc:$AssumeUtc }
    }
    if ($v -is [string] -and $v -match '^/Date\((-?\d+)(?:[+-]\d{4})?\)/$') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Matches[1]).LocalDateTime
    }
    if ($v -is [DateTimeOffset]) { return $v.LocalDateTime }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [System.DateTimeKind]::Utc) { return $v.ToLocalTime() }
        if ($v.Kind -eq [System.DateTimeKind]::Unspecified -and $AssumeUtc) {
            return [datetime]::SpecifyKind($v, [System.DateTimeKind]::Utc).ToLocalTime()
        }
        return $v
    }
    $style = [System.Globalization.DateTimeStyles]::None
    if ($AssumeUtc) { $style = [System.Globalization.DateTimeStyles]::AssumeUniversal }
    return [DateTimeOffset]::Parse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture, $style).LocalDateTime
}

function Get-Field($item, [string[]]$names) {
    if ($null -eq $item) { return $null }
    foreach ($name in $names) {
        if ($item -is [System.Collections.IDictionary]) {
            if ($item.Contains($name)) { return $item[$name] }
        }
        else {
            $property = $item.PSObject.Properties[$name]
            if ($property) { return $property.Value }
        }
    }
    return $null
}

function Test-Field($item, [string]$name) {
    if ($null -eq $item) { return $false }
    if ($item -is [System.Collections.IDictionary]) { return $item.Contains($name) }
    return $null -ne $item.PSObject.Properties[$name]
}

function Get-Entries($item) {
    if ($null -eq $item) { return }
    if ($item -is [System.Collections.IDictionary]) {
        foreach ($key in $item.Keys) { [pscustomobject]@{ name = [string]$key; value = $item[$key] } }
    }
    else {
        foreach ($property in $item.PSObject.Properties) { [pscustomobject]@{ name = $property.Name; value = $property.Value } }
    }
}

function Format-Plan($value) {
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return '' }
    return ([string]$value).Trim() -replace '^default_claude_', '' -replace '_', ' '
}

function Convert-UsageReset($value) {
    if ($null -eq $value -or [string]$value -eq '') { return $null }
    if ($value -is [ValueType] -and $value -isnot [datetime] -and $value -isnot [DateTimeOffset]) {
        return [DateTimeOffset]::FromUnixTimeSeconds([long](ConvertTo-FiniteDouble $value 'reset')).LocalDateTime
    }
    return ConvertTo-LocalTime $value
}

function Format-Window([double]$minutes) {
    if ($minutes -le 0) { throw '사용량 창 길이는 양수여야 합니다' }
    if ($minutes -eq 10080) { return '주간' }
    if ($minutes % 1440 -eq 0) { return "$($minutes / 1440)일" }
    if ($minutes % 60 -eq 0) { return "$($minutes / 60)시간" }
    return "$minutes 분"
}

function Format-UsageLabel([string]$name) {
    $name = $name -replace '(?<!\d)5\s*시간', '5h' -replace '주간', 'weekly'
    $name = $name -replace '(?i)\b(?:five[ _-]+hours?|5\s*(?:hours?|h))(?:[ _-]+limit(?:[ _-]+remaining)?)?\b', '5h'
    return $name -replace '(?i)\bweekly(?:[ _-]+limit(?:[ _-]+remaining)?)?\b', 'weekly'
}

function Get-UsageModelKey([string]$name) {
    return ($name -replace '(?i)(?<![a-z0-9])(5h|weekly)(?![a-z0-9])', '').Trim([char[]]' ·/-_')
}

function Sort-UsageRows($rows) {
    # 모델 이름을 먼저 고정하고, 각 모델 안에서는 5h → weekly → 기타 순으로 정렬한다.
    return @($rows | Sort-Object -Property @{Expression={$_.modelKey}}, @{Expression={
        if ($_.name -match '(?i)(?<![a-z0-9])5h(?![a-z0-9])') { 0 }
        elseif ($_.name -match '(?i)(?<![a-z0-9])weekly(?![a-z0-9])') { 1 }
        else { 2 }
    }}, @{Expression={$_.name}})
}

function ConvertTo-FiniteDouble($value, [string]$field) {
    if ($null -eq $value -or $value -is [bool] -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "$field 값이 없습니다"
    }
    try { $number = [Convert]::ToDouble($value, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "$field 값이 숫자가 아닙니다" }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "$field 값이 유한하지 않습니다" }
    return $number
}

function ConvertTo-UsagePercent($value, [string]$field) {
    $number = ConvertTo-FiniteDouble $value $field
    if ($number -lt 0 -or $number -gt 100) { throw "$field 범위는 0..100 이어야 합니다" }
    return [int][Math]::Round($number)
}

function New-UsageRow([string]$name, $pct, $reset, [switch]$AllowOverLimit) {
    if ([string]::IsNullOrWhiteSpace($name)) { throw '사용량 항목 이름이 없습니다' }
    $name = Format-UsageLabel $name
    $percentage = if ($AllowOverLimit) {
        $number = ConvertTo-FiniteDouble $pct "$name percent"
        if ($number -lt 0 -or $number -gt [int]::MaxValue) { throw '사용률 범위를 벗어났습니다' }
        [int][Math]::Round($number)
    } else { ConvertTo-UsagePercent $pct "$name percent" }
    $resetTime = Convert-UsageReset $reset
    $stale = $false
    $note = $null
    if ($resetTime -and $resetTime -le (Get-Date)) {
        $stale = $true
        $resetTime = $null
        $note = '리셋 지남'
    }
    return @{ name = $name; modelKey = Get-UsageModelKey $name; pct = $percentage; reset = $resetTime; note = $note; stale = $stale; allowOverLimit = [bool]$AllowOverLimit }
}

function Convert-StoredUsageRow($row) {
    $restored = New-UsageRow ([string](Get-Field $row @('name'))) (Get-Field $row @('pct')) (Get-Field $row @('reset')) -AllowOverLimit:([bool](Get-Field $row @('allowOverLimit')))
    if ([bool](Get-Field $row @('stale'))) {
        $restored.stale = $true
        $restored.reset = $null
        $storedNote = [string](Get-Field $row @('note'))
        $restored.note = if ($storedNote) { $storedNote } else { '리셋 지남' }
    }
    elseif (Get-Field $row @('note')) { $restored.note = [string](Get-Field $row @('note')) }
    if ((Get-Field $row @('isCodexSpark')) -eq $true) { $restored.isCodexSpark = $true }
    if (Test-Field $row 'modelKey') { $restored.modelKey = [string](Get-Field $row @('modelKey')) }
    return $restored
}

function Set-JsonAtomic($value, [string]$path, [int]$depth = 8) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tempPath = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($path) + ".$PID.$([guid]::NewGuid().ToString('N')).tmp")
    $backupPath = $tempPath + '.bak'
    try {
        $json = $value | ConvertTo-Json -Depth $depth
        [System.IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($tempPath, $path, $backupPath) }
                else { [System.IO.File]::Move($tempPath, $path) }
                return
            }
            catch [System.IO.IOException] {
                if ($attempt -eq 2) { throw }
                Start-Sleep -Milliseconds 20
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Convert-ClaudeResponseToRows($response) {
    $rows = @()
    $limits = Get-Field $response @('limits')
    if ($null -ne $limits) {
        foreach ($limit in @($limits)) {
            if ($null -eq (Get-Field $limit @('percent'))) { continue }
            $kind = [string](Get-Field $limit @('kind'))
            if ([string]::IsNullOrWhiteSpace($kind)) { throw 'Claude limits.kind 값이 없습니다' }
            $name = switch ($kind) {
                'session'       { '5시간' }
                'weekly_all'    { '주간 전체' }
                'weekly_scoped' {
                    $scope = Get-Field $limit @('scope')
                    $model = Get-Field $scope @('model')
                    ("주간 " + [string](Get-Field $model @('display_name', 'displayName'))).Trim()
                }
                default         { $kind }
            }
            $rows += ,(New-UsageRow $name (Get-Field $limit @('percent')) (Get-Field $limit @('resets_at', 'resetsAt')))
        }
    }
    else {
        foreach ($entry in @(Get-Entries $response)) {
            $window = $entry.value
            if ($null -eq $window -or -not (Test-Field $window 'utilization')) { continue }
            if ($null -eq (Get-Field $window @('utilization'))) { continue }
            $name = switch ($entry.name) {
                'five_hour' { '5시간' }
                'seven_day' { '주간' }
                default { $entry.name -replace '^seven_day_', '주간 ' -replace '_', ' ' }
            }
            $rows += ,(New-UsageRow $name (Get-Field $window @('utilization')) (Get-Field $window @('resets_at', 'resetsAt')))
        }
    }
    if ($rows.Count -eq 0) { throw 'Claude 사용량 응답에 유효한 한도가 없습니다' }
    return @(Sort-UsageRows $rows)
}

function Convert-CodexRateLimits($rateLimits) {
    $rows = @()
    foreach ($entry in @(
            @{ window = Get-Field $rateLimits @('primary'); fallback = '기본 창' },
            @{ window = Get-Field $rateLimits @('secondary'); fallback = '보조 창' }
        )) {
        $window = $entry.window
        if ($null -eq $window) { continue }
        $minutesRaw = Get-Field $window @('windowDurationMins', 'window_minutes')
        $label = $entry.fallback
        if ($null -ne $minutesRaw -and [string]$minutesRaw -ne '') {
            $minutes = ConvertTo-FiniteDouble $minutesRaw 'window duration'
            if ($minutes -le 0) { throw 'Codex 창 길이는 양수여야 합니다' }
            $label = Format-Window $minutes
        }
        $resetRaw = Get-Field $window @('resetsAt', 'resets_at')
        $reset = $null
        if ($null -ne $resetRaw -and [string]$resetRaw -ne '') {
            $seconds = ConvertTo-FiniteDouble $resetRaw 'Codex resetsAt'
            $reset = [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Round($seconds)).LocalDateTime
        }
        $rows += ,(New-UsageRow $label (Get-Field $window @('usedPercent', 'used_percent')) $reset)
    }
    if ($rows.Count -eq 0) { throw 'Codex 응답에 사용량 창이 없습니다' }
    $planType = [string](Get-Field $rateLimits @('planType', 'plan_type'))
    return [pscustomobject]@{
        rows = @(Sort-UsageRows $rows)
        plan = $(if ($planType) { (Get-Culture).TextInfo.ToTitleCase($planType) } else { '' })
    }
}

function Convert-CodexSnapshot($result, $account) {
    $buckets = @(Get-Entries (Get-Field $result @('rateLimitsByLimitId', 'rate_limits_by_limit_id')))
    if ($buckets.Count -eq 0) {
        $legacy = Get-Field $result @('rateLimits', 'rate_limits')
        if ($legacy) { $buckets = @([pscustomobject]@{ name = ''; value = $legacy }) }
    }
    $rows = @()
    $plan = Format-Plan (Get-Field $account @('planType', 'plan_type'))
    foreach ($bucket in $buckets) {
        if ($null -eq $bucket.value) { continue }
        if (-not (Get-Field $bucket.value @('primary')) -and -not (Get-Field $bucket.value @('secondary'))) { continue }
        $converted = Convert-CodexRateLimits $bucket.value
        if (-not $plan) { $plan = $converted.plan }
        $name = [string](Get-Field $bucket.value @('limitName', 'limit_name'))
        if (-not $name) { $name = $bucket.name }
        # 짧은 화면 표시명만 적용하며 서버의 한도 식별자와 수치는 바꾸지 않는다.
        $name = $name -replace '^(?:gpt[- _]*)?5\.3(?:[- _]*codex)?[- _]*(?:spark|스파크)$', '5.3spark'
        foreach ($row in $converted.rows) {
            $row.isCodexSpark = $name -eq '5.3spark'
            $row.modelKey = $name
            if ($buckets.Count -gt 1 -and $name) { $row.name = "$name · $($row.name)" }
            $rows += ,$row
        }
    }
    if ($rows.Count -eq 0) { throw 'Codex 응답에 사용량 창이 없습니다' }
    return [pscustomobject]@{ rows = @(Sort-UsageRows $rows); plan = $plan; account = [string](Get-Field $account @('email')) }
}

function Get-UsageWindowKey($row) {
    if ($row.name -match '(?i)(?<![a-z0-9])5h(?![a-z0-9])') { return '5h' }
    if ($row.name -match '(?i)(?<![a-z0-9])weekly(?![a-z0-9])') { return 'weekly' }
    return ''
}

function Test-UsageItemVisible([string]$key) {
    return -not $script:usageVisibility.ContainsKey($key) -or $script:usageVisibility[$key]
}

function Test-CodexProPlan([string]$plan) {
    return $plan -match '(?i)^pro(?:\b|_)'
}

function Get-VisibleClaudeRows($rows) {
    return @($rows | Where-Object { Test-UsageItemVisible "claude.$(Get-UsageWindowKey $_)" })
}

function Get-VisibleCodexRows($rows, [string]$plan = '') {
    return @($rows | Where-Object {
        $window = Get-UsageWindowKey $_
        if ($_.isCodexSpark) { Test-UsageItemVisible "codex.spark.$window" }
        elseif ($_.modelKey -match '(?i)(?:\breserve\b|^base_model_inference$)') { Test-UsageItemVisible 'codex.reserve.weekly' }
        elseif ((Test-CodexProPlan $plan) -and $window -eq '5h') { $false }
        else { Test-UsageItemVisible "codex.$window" }
    })
}

function Get-AntigravityChoiceKey([string]$modelKey) {
    if ($modelKey -match '(?i)^gemini(?:\b|_)') { return 'gemini' }
    if ($modelKey -match '(?i)^(?:claude|gpt)(?:\b|_)') { return 'claude' }
    return ''
}

function Get-VisibleAntigravityRows($rows) {
    return @($rows | Where-Object {
        $choice = Get-AntigravityChoiceKey ([string]$_.modelKey)
        $window = Get-UsageWindowKey $_
        if ($choice -eq 'gemini' -and $window) { Test-UsageItemVisible "antigravity.gemini.$window" }
        elseif ($choice -eq 'claude') { Test-UsageItemVisible 'antigravity.claude' }
        else { -not $script:antigravityModelVisibility.ContainsKey([string]$_.modelKey) -or $script:antigravityModelVisibility[[string]$_.modelKey] }
    })
}

function Convert-AntigravityPayload($payload) {
    # 함수 반환의 배열 펼침을 피한다. 모델 한 개짜리 배열도 배열로 처리해야 한다.
    $quota = $payload.quota
    $entries = if ($quota -is [array]) {
        @($quota | ForEach-Object { [pscustomobject]@{ name = [string](Get-Field $_ @('name', 'id')); value = $_ } })
    } else { @(Get-Entries $quota) }
    $rows = @()
    foreach ($entry in $entries) {
        $remaining = Get-Field $entry.value @('remaining_fraction')
        # 미제공 한도는 0%로 만들지 않는다. 다른 모델의 유효한 한도는 유지한다.
        if ($null -eq $remaining) { continue }
        $fraction = ConvertTo-FiniteDouble $remaining 'remaining_fraction'
        if ($fraction -lt 0 -or $fraction -gt 1) { throw 'remaining_fraction 범위는 0..1 이어야 합니다' }
        $reset = Get-Field $entry.value @('reset_time', 'resetTime')
        if (-not $reset) {
            $secondsRaw = Get-Field $entry.value @('reset_in_seconds')
            if ($null -ne $secondsRaw) {
                $seconds = ConvertTo-FiniteDouble $secondsRaw 'reset_in_seconds'
                if ($seconds -lt 0) { throw 'reset_in_seconds 는 음수일 수 없습니다' }
                $reset = [DateTimeOffset]::UtcNow.AddSeconds($seconds)
            }
        }
        $rows += ,(New-UsageRow $entry.name (100 - $fraction * 100) $reset)
    }
    return [pscustomobject]@{
        rows = @(Sort-UsageRows $rows); plan = Format-Plan (Get-Field $payload @('plan_tier'))
        account = [string](Get-Field $payload @('email')); source = 'Antigravity CLI 상태줄'; updated = Get-Date
    }
}

function Convert-ClaudeStatusPayload($payload) {
    $limits = Get-Field $payload @('rate_limits')
    $rows = @()
    foreach ($entry in @(Get-Entries $limits)) {
        $pct = Get-Field $entry.value @('used_percentage')
        if ($null -eq $pct) { continue }
        $name = switch ($entry.name) { 'five_hour' { '5시간' }; 'seven_day' { '주간' }; default { $entry.name } }
        $rows += ,(New-UsageRow $name $pct (Get-Field $entry.value @('resets_at')) -AllowOverLimit:($entry.name -eq 'spend_limit'))
    }
    return [pscustomobject]@{ rows = @(Sort-UsageRows $rows); updated = Get-Date; source = 'Claude Code 상태줄' }
}

# 데스크톱의 비공개 로컬 프로토콜. 모델 이름·요금제·포트는 응답/프로세스에서 찾는다.
# 규격 근거: CodexBar AntigravityStatusProbe / AntigravityQuotaSummaryParser.
function Convert-AntigravityLocalPayload($statusResponse, $summaryResponse, $modelResponse) {
    $user = Get-Field $statusResponse @('userStatus')
    $tier = Get-Field $user @('userTier')
    $plan = [string](Get-Field $tier @('name'))
    if (-not $plan.Trim()) {
        $planInfo = Get-Field (Get-Field $user @('planStatus')) @('planInfo')
        foreach ($field in 'planDisplayName', 'displayName', 'productName', 'planName', 'planShortName') {
            $plan = [string](Get-Field $planInfo @($field))
            if ($plan.Trim()) { break }
        }
    }
    $summary = $summaryResponse
    foreach ($field in 'response', 'summary') {
        $nested = Get-Field $summaryResponse @($field)
        if ($null -ne $nested) { $summary = $nested; break }
    }
    $quota = @()
    foreach ($group in @(Get-Field $summary @('groups'))) {
        $groupName = [string](Get-Field $group @('displayName', 'name'))
        foreach ($bucket in @(Get-Field $group @('buckets'))) {
            if ((Get-Field $bucket @('disabled')) -eq $true) { continue }
            $fraction = Get-Field $bucket @('remainingFraction')
            $remaining = Get-Field $bucket @('remaining')
            if ($null -eq $fraction) { $fraction = Get-Field $remaining @('remainingFraction') }
            if ($null -eq $fraction -and (Get-Field $remaining @('case')) -eq 'remainingFraction') {
                $fraction = Get-Field $remaining @('value')
            }
            if ($null -eq $fraction) { continue }
            $label = [string](Get-Field $bucket @('displayName', 'name', 'bucketId', 'id'))
            $quota += @{ name = "$groupName / $label".Trim(' ', '/'); remaining_fraction = $fraction; reset_time = Get-Field $bucket @('resetTime') }
        }
    }
    $scope = if ($quota.Count) { 'summary' } else { 'models' }
    if (-not $quota.Count) {
        $models = Get-Field (Get-Field $user @('cascadeModelConfigData')) @('clientModelConfigs')
        if (-not $models) { $models = Get-Field $modelResponse @('clientModelConfigs') }
        foreach ($model in @($models)) {
            $info = Get-Field $model @('quotaInfo')
            $label = [string](Get-Field $model @('label'))
            if (-not $label) { $label = [string](Get-Field (Get-Field $model @('modelOrAlias')) @('model')) }
            if ($null -eq (Get-Field $info @('remainingFraction'))) { continue }
            $quota += @{ name = $label; remaining_fraction = Get-Field $info @('remainingFraction'); reset_time = Get-Field $info @('resetTime') }
        }
    }
    $usage = Convert-AntigravityPayload @{ plan_tier = $plan; email = Get-Field $user @('email'); quota = $quota }
    $usage | Add-Member -NotePropertyName scope -NotePropertyValue $scope
    return $usage
}

function Get-AntigravityTargets($processes, $listeners, [string]$ownerSid) {
    foreach ($process in $processes) {
        if (-not $ownerSid -or $process.OwnerSid -ne $ownerSid) { continue }
        $path = [string]$process.ExecutablePath
        $command = [string]$process.CommandLine
        $isCli = $process.Name -match '^(agy|antigravity[-_]cli)\.exe$' -or $path -match '[\\/]antigravity[-_]cli[\\/]'
        $isServer = $process.Name -match '^language[_-]server(?:[_-][a-z0-9]+)*\.exe$'
        $isDesktop = $isServer -and ($path -match '[\\/]antigravity(?: ide)?[\\/]' -or
            $command -match '--app_data_dir(?:=|\s+)"?antigravity(?:-ide)?(?:"|\s|$)')
        if (-not $isCli -and -not $isDesktop) { continue }
        $csrf = ''
        if ($command -match '(?:^|\s)--csrf_token(?:=|\s+)(?:"([^"]+)"|([^\s"]+))') {
            $csrf = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        }
        if ($isDesktop -and -not $csrf) { continue }
        $source = if ($isDesktop) { 'Antigravity 데스크톱' } else { 'Antigravity CLI 로컬 서버' }
        $seen = @{}
        foreach ($listener in $listeners) {
            if ($listener.OwningProcess -ne $process.ProcessId -or [string]$listener.State -ne 'Listen') { continue }
            $address = [string]$listener.LocalAddress
            if ($address -eq '0.0.0.0') { $address = '127.0.0.1' }
            if ($address -eq '::') { $address = '::1' }
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse($address, [ref]$ip) -or -not [System.Net.IPAddress]::IsLoopback($ip)) { continue }
            $port = [int]$listener.LocalPort
            if ($port -lt 1 -or $port -gt 65535 -or $seen["${address}:$port"]) { continue }
            $seen["${address}:$port"] = $true
            foreach ($scheme in 'https', 'http') {
                [pscustomobject]@{ address = $address; port = $port; scheme = $scheme; csrf = $csrf; source = $source; processId = $process.ProcessId }
            }
        }
    }
}

function Find-AntigravityTargets {
    $ownerSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'language_server%' OR Name LIKE 'language-server%' OR Name = 'agy.exe' OR Name = 'antigravity-cli.exe' OR Name = 'antigravity_cli.exe'" -Property ProcessId,Name,ExecutablePath -OperationTimeoutSec 2)
    foreach ($process in $candidates) {
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 2
            if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne $ownerSid) { continue }
            # 로컬 요청에만 쓰는 CSRF 값은 반환 상태·캐시·오류에 포함하지 않는다.
            $details = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.ProcessId)" -Property CommandLine -OperationTimeoutSec 2
            $record = [pscustomobject]@{ ProcessId=$process.ProcessId; Name=$process.Name; ExecutablePath=$process.ExecutablePath; CommandLine=$details.CommandLine; OwnerSid=$owner.Sid }
            $listeners = @(Get-NetTCPConnection -OwningProcess $process.ProcessId -State Listen -ErrorAction Stop)
            Get-AntigravityTargets @($record) $listeners $ownerSid
        } catch { } # 종료된 프로세스·권한 부족은 다음 후보로 진행한다.
    }
}

function Invoke-AntigravityLocalRequest($target, [string]$method, [int]$timeoutMs = 1000) {
    if ($method -notin @('GetUserStatus', 'RetrieveUserQuotaSummary', 'GetCommandModelConfigs')) { throw '지원하지 않는 로컬 조회' }
    if (-not ('AiUsage.LocalQuotaHttp' -as [type])) {
        # PS 5.1의 TLS 콜백은 작업 스레드에서 실행된다. C# 콜백으로 요청 한 개에만 적용한다.
        Add-Type -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
namespace AiUsage {
    public static class LocalQuotaHttp {
        public static string Post(string address, int port, string scheme, string method, string csrf, string body, int timeout) {
            IPAddress ip;
            if (!IPAddress.TryParse(address, out ip) || !IPAddress.IsLoopback(ip) || port < 1 || port > 65535 ||
                (scheme != "http" && scheme != "https") ||
                (method != "GetUserStatus" && method != "RetrieveUserQuotaSummary" && method != "GetCommandModelConfigs"))
                throw new InvalidOperationException("Invalid local quota endpoint");
            var uri = new UriBuilder(scheme, address, port, "/exa.language_server_pb.LanguageServerService/" + method).Uri;
#pragma warning disable
            var request = (HttpWebRequest)WebRequest.Create(uri);
#pragma warning restore
            request.Proxy = null;
            request.AllowAutoRedirect = false;
            request.Timeout = Math.Max(1, Math.Min(timeout, 2000));
            request.ReadWriteTimeout = request.Timeout;
            request.ServerCertificateValidationCallback = (sender, cert, chain, errors) => true;
            request.Method = "POST";
            request.ContentType = "application/json";
            request.Headers["Connect-Protocol-Version"] = "1";
            if (!String.IsNullOrEmpty(csrf)) request.Headers["X-Codeium-Csrf-Token"] = csrf;
            byte[] bytes = Encoding.UTF8.GetBytes(body);
            request.ContentLength = bytes.Length;
            using (var deadline = new System.Threading.Timer(state => request.Abort(), null, request.Timeout, System.Threading.Timeout.Infinite)) {
            using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
            using (var response = (HttpWebResponse)request.GetResponse()) {
                if (response.StatusCode != HttpStatusCode.OK) throw new IOException("Local quota request failed");
                using (var stream = response.GetResponseStream())
                using (var buffer = new MemoryStream()) {
                    byte[] chunk = new byte[8192];
                    int count;
                    while ((count = stream.Read(chunk, 0, chunk.Length)) > 0) {
                        if (buffer.Length + count > 1048576) throw new IOException("Local quota response too large");
                        buffer.Write(chunk, 0, count);
                    }
                    return Encoding.UTF8.GetString(buffer.ToArray());
                }
            }
            }
        }
    }
}
'@
    }
    $body = if ($method -eq 'RetrieveUserQuotaSummary') { '{"forceRefresh":true}' }
        else { '{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}' }
    $json = [AiUsage.LocalQuotaHttp]::Post($target.address, $target.port, $target.scheme, $method, $target.csrf, $body, $timeoutMs) | ConvertFrom-Json
    $code = Get-Field $json @('code')
    if ($null -ne $code -and [string]$code -notin @('0', 'OK')) { throw '로컬 사용량 응답 오류' }
    return $json
}

function Get-AntigravityLocalSnapshots {
    $script:antigravityLocalIssue = '실시간 조회 서버를 찾지 못했습니다. 앱 실행 후 새로고침하세요'
    $targets = @(Find-AntigravityTargets)
    if (-not $targets.Count) { return }
    $script:antigravityLocalIssue = '서버는 실행 중이나 사용량 조회에 실패했습니다. 앱 상태를 확인하세요'
    # 탐지에 걸린 시간 때문에 실제 요청을 시작하기도 전에 기한이 소진되지 않게 한다.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $completed = @{}
    foreach ($target in $targets) {
        if ($completed[$target.processId]) { continue }
        $responses = @{}
        foreach ($method in 'GetUserStatus', 'RetrieveUserQuotaSummary', 'GetCommandModelConfigs') {
            $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0) { break }
            try { $responses[$method] = Invoke-AntigravityLocalRequest $target $method ([Math]::Min(1000, $left)) } catch { }
            if ($method -eq 'RetrieveUserQuotaSummary') {
                try {
                    $parsed = Convert-AntigravityLocalPayload $responses.GetUserStatus $responses.RetrieveUserQuotaSummary $null
                    if ($parsed.rows.Count) { break }
                } catch { }
            }
        }
        try {
            try { $parsed = Convert-AntigravityLocalPayload $responses.GetUserStatus $responses.RetrieveUserQuotaSummary $responses.GetCommandModelConfigs }
            catch { $parsed = Convert-AntigravityLocalPayload $responses.GetUserStatus $null $responses.GetCommandModelConfigs }
            if (-not $parsed.rows.Count -and -not $parsed.account -and -not $parsed.plan) { continue }
            $parsed.source = $target.source
            $parsed | Add-Member -NotePropertyName live -NotePropertyValue $true
            if ($parsed.rows.Count) { $completed[$target.processId] = $true; $script:antigravityLocalIssue = $null }
            $parsed
        } catch { }
        if ([DateTime]::UtcNow -ge $deadline) { break }
    }
}

function Merge-AntigravitySnapshots($snapshots) {
    $groups = [ordered]@{}
    foreach ($item in $snapshots) {
        $account = ([string]$item.account).Trim()
        # 계정 미확인 출처끼리는 같은 계정이라고 추정하지 않는다.
        $key = if ($account) { $account.ToLowerInvariant() } else { [guid]::NewGuid().ToString() }
        $candidate = [pscustomobject]@{
            account=$account; plan=[string]$item.plan; source=[string]$item.source
            rows=@($item.rows); updated=ConvertTo-LocalTime $item.updated
            live=[bool]$item.live; scope=[string]$item.scope; err=$null
        }
        $previous = $groups[$key]
        if ($previous) {
            # 수치를 더하지 않고 유효한 실시간 스냅샷을 우선한다. 같은 종류는 최신 것을 쓴다.
            $takeNew = if ([bool]$candidate.rows.Count -ne [bool]$previous.rows.Count) { $candidate.rows.Count -gt 0 }
                elseif ($candidate.live -ne $previous.live) { $candidate.live }
                elseif ($candidate.live -and $candidate.scope -ne $previous.scope) { $candidate.scope -eq 'summary' }
                else { $candidate.updated -gt $previous.updated }
            $winner = if ($takeNew) { $candidate } else { $previous }
            # 사용량이 CLI 캐시뿐이어도 같은 계정의 현재 구독 이름은 로컬 응답에서 가져온다.
            $identity = if ($candidate.live -and $candidate.plan) { $candidate }
                elseif ($previous.live -and $previous.plan) { $previous } else { $null }
            if ($identity) { $winner.plan = $identity.plan }
            $winner.source = (@(($previous.source -split ' · ') + ($candidate.source -split ' · ')) | Select-Object -Unique) -join ' · '
            $candidate = $winner
        }
        $groups[$key] = $candidate
    }
    foreach ($group in $groups.Values) {
        if (-not $group.live) { $group.err = '마지막 조회 기록 — 현재 로그인 계정은 확인되지 않았습니다' }
        if (-not $group.rows.Count) { $group.err = '요금제·계정 정보만 제공됨 — 사용량 한도 확인 불가' }
        if (-not $group.account) { $group.err = '계정 미확인 — 다른 출처와 합치지 않은 사용량입니다' }
        $group
    }
}

function Read-CodexResponse($reader, [int]$id, [int]$timeoutMs) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $task = $reader.ReadLineAsync()
        if (-not $task.Wait($remaining)) { throw 'Codex app-server 응답 시간 초과' }
        $line = $task.Result
        if ($null -eq $line) { throw 'Codex app-server가 응답 전에 종료됐습니다' }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ([string](Get-Field $message @('id')) -ne [string]$id) { continue }
        $rpcError = Get-Field $message @('error')
        if ($rpcError) { throw ("Codex app-server 오류: " + [string](Get-Field $rpcError @('message'))).Trim() }
        return Get-Field $message @('result')
    }
    throw 'Codex app-server 응답 시간 초과'
}

function Get-CodexApplication {
    foreach ($name in 'codex.exe', 'codex.cmd', 'codex') {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return [string]$command.Source }
    }
    # 데스크톱 설치에 포함된 런타임도 사용한다. 버전 번호나 사용자명은 고정하지 않는다.
    $desktopRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $desktopRoot) {
        $binary = Get-ChildItem -LiteralPath $desktopRoot -Filter 'codex.exe' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($binary) { return $binary.FullName }
    }
    $packages = @()
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) { $packages = @(Get-AppxPackage -Name '*Codex*' -ErrorAction SilentlyContinue) }
    foreach ($app in $packages) {
        foreach ($relative in 'app\resources\codex.exe', 'resources\codex.exe', 'app\bin\codex.exe') {
            $binary = Join-Path $app.InstallLocation $relative
            if (Test-Path -LiteralPath $binary -PathType Leaf) { return $binary }
        }
    }
    return $null
}

function Get-ClaudeApplication {
    foreach ($name in 'claude.exe', 'claude.cmd') {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return [string]$command.Source }
    }
    return Get-FirstExisting @((Join-Path $HOME '.local\bin\claude.exe'))
}

function New-ProviderProcess([string]$executable, [string]$arguments) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ([System.IO.Path]::GetExtension($executable) -match '(?i)^\.(cmd|bat)$') {
        $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $psi.Arguments = '/d /s /c ""' + $executable + '" ' + $arguments + '"'
    }
    else { $psi.FileName = $executable; $psi.Arguments = $arguments }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    return $process
}

function Stop-ProviderProcess($process) {
    if (-not $process) { return }
    try {
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch { $process.Kill() }
            [void]$process.WaitForExit(1000)
        }
    } catch { }
    $process.Dispose()
}

function Get-ClaudeAccount {
    $cli = Get-ClaudeApplication
    if (-not $cli) { return $null }
    $process = New-ProviderProcess $cli 'auth status'
    try {
        if (-not $process.Start()) { throw 'Claude 계정 조회를 시작하지 못했습니다' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000) -or -not $stdout.Wait(1000)) { throw 'Claude 계정 조회 시간 초과' }
        $result = $stdout.Result | ConvertFrom-Json
        return [pscustomobject]@{
            loggedIn = [bool](Get-Field $result @('loggedIn'))
            account = [string](Get-Field $result @('email'))
            plan = Format-Plan (Get-Field $result @('subscriptionType'))
            authMethod = [string](Get-Field $result @('authMethod'))
        }
    }
    finally { Stop-ProviderProcess $process }
}

function Get-CodexAppServerSnapshot {
    $codex = Get-CodexApplication
    if (-not $codex) { throw 'Codex CLI를 찾지 못했습니다' }
    $process = New-ProviderProcess $codex 'app-server'
    try {
        if (-not $process.Start()) { throw 'Codex app-server를 시작하지 못했습니다' }
        $stderr = $process.StandardError.ReadToEndAsync()
        $initialize = @{
            method = 'initialize'; id = 1
            params = @{ clientInfo = @{ name = 'ai-usage-tray'; title = 'AI Usage Tray'; version = '1.0' } }
        } | ConvertTo-Json -Compress -Depth 5
        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.Flush()
        Read-CodexResponse $process.StandardOutput 1 5000 | Out-Null
        $process.StandardInput.WriteLine((@{ method = 'initialized' } | ConvertTo-Json -Compress))
        $process.StandardInput.WriteLine((@{ method = 'account/read'; id = 2; params = @{ refreshToken = $false } } | ConvertTo-Json -Compress))
        $process.StandardInput.Flush()
        $accountResult = Read-CodexResponse $process.StandardOutput 2 5000
        $account = Get-Field $accountResult @('account')
        $kind = [string](Get-Field $account @('type'))
        if (-not $account -or $kind -ne 'chatgpt') {
            return [pscustomobject]@{ account = $account; result = $null; asOf = Get-Date; unavailable = $true }
        }
        $process.StandardInput.WriteLine((@{ method = 'account/rateLimits/read'; id = 3 } | ConvertTo-Json -Compress))
        $process.StandardInput.Flush()
        $result = Read-CodexResponse $process.StandardOutput 3 5000
        return [pscustomobject]@{ result = $result; account = $account; asOf = Get-Date; unavailable = $false }
    }
    finally {
        Stop-ProviderProcess $process
    }
}

function Get-CodexUsageFromLogs([string]$sessions) {
    if (-not $sessions -or -not (Test-Path -LiteralPath $sessions)) { throw 'Codex 세션 폴더를 찾지 못했습니다' }
    $best = $null
    $buckets = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $sessions -Filter 'rollout-*.jsonl' -Recurse -File -ErrorAction SilentlyContinue)) {
        $seen = @{}
        try { $matches = @(Select-String -LiteralPath $file.FullName -Pattern '"rate_limits"\s*:' -ErrorAction Stop) }
        catch { continue }
        for ($index = $matches.Count - 1; $index -ge 0; $index--) {
            try {
                $record = $matches[$index].Line | ConvertFrom-Json
                $payload = Get-Field $record @('payload')
                $rateLimits = Get-Field $payload @('rate_limits')
                if (-not $rateLimits) { $rateLimits = Get-Field $record @('rate_limits') }
                if (-not $rateLimits -or (-not (Get-Field $rateLimits @('primary'))) -and (-not (Get-Field $rateLimits @('secondary')))) { continue }
                $bucketId = [string](Get-Field $rateLimits @('limit_id', 'limitId'))
                if (-not $bucketId) { $bucketId = 'codex' }
                if ($seen.ContainsKey($bucketId)) { continue }
                Convert-CodexRateLimits $rateLimits | Out-Null
                try { $asOf = ConvertTo-LocalTime (Get-Field $record @('timestamp')) -AssumeUtc }
                catch { $asOf = $file.LastWriteTime }
                if (-not $asOf) { $asOf = $file.LastWriteTime }
                if (-not $buckets.ContainsKey($bucketId) -or $asOf -gt $buckets[$bucketId].asOf) {
                    $buckets[$bucketId] = [pscustomobject]@{ asOf = $asOf; rateLimits = $rateLimits }
                }
                if (-not $best -or $asOf -gt $best.asOf) { $best = [pscustomobject]@{ asOf = $asOf; rateLimits = $rateLimits } }
                $seen[$bucketId] = $true
            }
            catch { continue }
        }
    }
    if (-not $best) { throw '최근 세션 로그에 사용량 스냅샷 없음' }
    $byId = @{}
    foreach ($id in $buckets.Keys) { $byId[$id] = $buckets[$id].rateLimits }
    $best | Add-Member -NotePropertyName result -NotePropertyValue ([pscustomobject]@{ rateLimitsByLimitId = $byId })
    return $best
}

# ---------- Claude 5시간 창 소진 예측 ----------
# 같은 창 안에서 모은 샘플의 증가 기울기로 100% 도달 시각을 외삽한다.
# 리셋 시각이 바뀌면 새 창이므로 샘플을 버린다 — 창을 넘긴 기울기는 의미가 없다.
# 폴링이 5분 주기라 최소 조건(10분·2샘플)을 채우려면 최소 3틱이 필요하다. 1회 수집으로는 발동하지 않는 게 정상.
$script:claudeSamples = @()

function Update-ClaudeForecast($rows) {
    $found = @($rows | Where-Object { $_.name -eq '5h' -and -not $_.stale })
    if ($found.Count -eq 0) { $script:claudeSamples = @(); return }
    $row = $found[0]
    $resetKey = if ($row.reset) { ([datetime]$row.reset).ToString('s') } else { '' }
    $last = if ($script:claudeSamples.Count -gt 0) { $script:claudeSamples[-1] } else { $null }
    if (-not $last -or $last.reset -ne $resetKey) { $script:claudeSamples = @() }
    $script:claudeSamples += , @{ t = (Get-Date); pct = [int]$row.pct; reset = $resetKey }
    if ($script:claudeSamples.Count -gt 12) {
        $script:claudeSamples = @($script:claudeSamples | Select-Object -Last 12)
    }
    $s = $script:claudeSamples
    if ($s.Count -lt 2) { return }
    if ($s[-1].pct -ge 100) { return }              # 이미 다 썼으면 예측할 게 없다
    $mins = ($s[-1].t - $s[0].t).TotalMinutes
    if ($mins -lt 10) { return }                    # 표본 구간이 짧으면 기울기가 요동친다
    $perMin = ($s[-1].pct - $s[0].pct) / $mins
    if ($perMin -le 0) { return }
    $eta = $s[-1].t.AddMinutes((100 - $s[-1].pct) / $perMin)
    if ($row.reset -and $eta -ge [datetime]$row.reset) { return }   # 리셋이 더 빠르면 경고할 일이 아니다
    $row.warn = "≈$($eta.ToString('HH:mm')) 소진"
}

function Get-RetryAfterSeconds($errorRecord) {
    try {
        $response = $errorRecord.Exception.Response
        if (-not $response) { return $null }
        if ($response.Headers.RetryAfter) {
            if ($response.Headers.RetryAfter.Delta) { return [double]$response.Headers.RetryAfter.Delta.TotalSeconds }
            if ($response.Headers.RetryAfter.Date) { return [Math]::Max(0, ($response.Headers.RetryAfter.Date.LocalDateTime - (Get-Date)).TotalSeconds) }
        }
        $value = $response.Headers['Retry-After']
        if ($value -is [array]) { $value = $value[0] }
        $seconds = 0.0
        if ([double]::TryParse([string]$value, [ref]$seconds)) { return [Math]::Max(0, $seconds) }
        $date = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$value, [ref]$date)) { return [Math]::Max(0, ($date.LocalDateTime - (Get-Date)).TotalSeconds) }
    }
    catch { }
    return $null
}

function Get-ClaudeUsage([switch]$Force) {
    $profile = Get-ClaudeProfile
    $account = $null
    try { $account = Get-ClaudeAccount } catch { }
    $state.claude.account = if ($account) { $account.account } else { '' }
    $state.claude.plan = if ($account) { $account.plan } else { '' }
    $state.claude.source = 'Claude Code'
    if ($account -and $account.account -ne $InitialClaudeAccount) {
        $script:claudeBackoffUntil = $null
        $script:claude429Count = 0
    }
    if ($account -and -not $account.loggedIn) {
        $state.claude.clear = $true
        $state.claude.err = 'Claude Code에 로그인하세요. 데스크톱 로그인만으로는 조회할 수 없습니다'
        return
    }
    if ($account -and $account.authMethod -and $account.authMethod -notin @('claude.ai', 'oauth')) {
        $state.claude.clear = $true
        $state.claude.err = 'Claude 구독 계정 로그인이 필요합니다. API 키·외부 공급자 한도는 별도로 확인하세요'
        return
    }
    # 현재 계정을 확인한 경우에만 이전 성공 값을 재사용한다.
    $cached = $null
    if ($account -and $account.account) {
        foreach ($path in @($STATE_CACHE, $CLAUDE_STATUS_CACHE)) {
            $candidate = Read-UsageCache $path $account.account $profile
            if ($candidate -and (-not $cached -or $candidate.updated -gt $cached.updated)) { $cached = $candidate }
        }
    }
    if ($cached) {
        $state.claude.rows = $cached.rows
        $state.claude.updated = $cached.updated
        $state.claude.source = $cached.source
        $state.claude.success = $true
    }
    if (-not $Force -and $script:claudeBackoffUntil -and (Get-Date) -lt $script:claudeBackoffUntil) {
        $state.claude.err = '요청 제한 대기 중 · 마지막 확인 값'
        if (-not $cached) { $state.claude.clear = $true }
        return
    }
    # CLI가 환경 변수 인증을 사용하면 다른 파일 계정의 토큰과 섞지 않는다.
    $externalAuth = (Test-Path Env:\CLAUDE_CODE_OAUTH_TOKEN) -or (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -or (Test-Path Env:\ANTHROPIC_API_KEY)
    $credPath = if (-not $externalAuth) { Get-ClaudeCredPath } else { $null }
    if (-not $credPath) {
        $state.claude.err = if ($cached) { $null } else { '사용량 확인 불가 — Claude Code 로그인 또는 [Claude 상태줄 연동 설정]이 필요합니다' }
        if (-not $cached) { $state.claude.clear = $true }
        return
    }
    try {
        $cred = (Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json).claudeAiOauth
        if (-not $cred -or [string]::IsNullOrWhiteSpace([string]$cred.accessToken)) { throw 'Claude OAuth 토큰이 없습니다' }
        $tier = Format-Plan $cred.rateLimitTier
        if ($tier) { $state.claude.plan = $tier }
        elseif (-not $state.claude.plan) { $state.claude.plan = Format-Plan $cred.subscriptionType }
        $headers = @{ Authorization = "Bearer $($cred.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -TimeoutSec 10
        $rows = @(Convert-ClaudeResponseToRows $r)
        $state.claude.rows = $rows
        $state.claude.err = $null
        $state.claude.updated = Get-Date
        $state.claude.success = $true
        $state.claude.source = 'Claude Code OAuth'
        $script:claudeBackoffUntil = $null
        $script:claude429Count = 0
        try {
            Set-JsonAtomic @{ plan = $state.claude.plan; account = $state.claude.account; profile = $profile; source = $state.claude.source; rows = $rows; updated = $state.claude.updated } $STATE_CACHE 5
        }
        catch { }
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($null -eq $status -and [string]$_ -match '(?<!\d)(401|429)(?!\d)') { $status = [int]$Matches[1] }
        if ($status -eq 401) {
            $state.claude.err = '로그인 만료 — Claude Code에서 다시 로그인하세요'
            $state.claude.clear = $true
            $state.claude.success = $false
        }
        elseif ($status -eq 429) {
            # 계정 단위 제한(관찰: Retry-After 0인데 장시간 지속). 거절된 요청도 집계될 수 있어 누진 백오프.
            $script:claude429Count = [int]$script:claude429Count + 1
            $mins = [Math]::Min(60, 15 * [Math]::Pow(2, $script:claude429Count - 1))
            $retryAfter = Get-RetryAfterSeconds $_
            if ($null -ne $retryAfter) { $mins = [Math]::Min(60, [Math]::Max($mins, [Math]::Ceiling($retryAfter / 60))) }
            $script:claudeBackoffUntil = (Get-Date).AddMinutes($mins)
            $state.claude.err = "요청 제한(429) — $([int]$mins)분 후 자동 재시도, 마지막 값 표시 중"
        }
        else { $state.claude.err = 'Claude 사용량 조회 실패 · 마지막 확인 값만 표시합니다' }
        if (-not $cached) { $state.claude.clear = $true }
    }
}

function Get-CodexUsage {
    try {
        $fallback = $false
        try {
            $snapshot = Get-CodexAppServerSnapshot
            $state.gpt.account = [string](Get-Field $snapshot.account @('email'))
            $state.gpt.plan = Format-Plan (Get-Field $snapshot.account @('planType'))
            $state.gpt.source = 'Codex CLI/데스크톱 앱 서버'
            if ($snapshot.unavailable) {
                $state.gpt.clear = $true
                $state.gpt.err = 'ChatGPT 계정 로그인이 필요합니다. API 키 계정의 구독 한도는 제공되지 않습니다'
                return
            }
            $converted = Convert-CodexSnapshot $snapshot.result $snapshot.account
        }
        catch {
            $sessions = Get-CodexSessionsPath
            if (-not $sessions) { throw }
            $snapshot = Get-CodexUsageFromLogs $sessions
            $converted = Convert-CodexSnapshot $snapshot.result $null
            $state.gpt.source = 'Codex 세션 로그'
            $state.gpt.account = ''
            $fallback = $true
        }
        $state.gpt.rows = $converted.rows
        $state.gpt.plan = $converted.plan
        $state.gpt.asOf = $snapshot.asOf
        $state.gpt.err = if ($fallback) { '실시간 조회 실패 · 로그 계정 확인 불가 · 마지막 활동 기준' } else { $null }
        if ($fallback) { foreach ($row in $state.gpt.rows) { $row.stale = $true; $row.note = '로그 스냅샷' } }
        $state.gpt.success = $true
    }
    catch {
        $state.gpt.clear = $true
        $state.gpt.err = 'Codex 요금제·사용량 확인 불가 — CLI 또는 데스크톱 설치와 ChatGPT 로그인을 확인하세요'
    }
}

function Get-AntigravityUsage {
    $snapshots = @()
    $script:antigravityLocalIssue = $null
    try { $snapshots += @(Get-AntigravityLocalSnapshots) }
    catch { $script:antigravityLocalIssue = '앱 실행 상태를 확인하지 못했습니다. 앱 재실행 후 새로고침하세요' }
    $liveSnapshots = @($snapshots)
    try {
        $saved = Get-Content -LiteralPath $ANTIGRAVITY_STATE_CACHE -Encoding UTF8 -Raw | ConvertFrom-Json
        foreach ($entry in @($saved.groups)) {
            if (-not $entry.updated -or -not (Test-Field $entry 'rows')) { continue }
            # 앱이 꺼졌으면 마지막 계정별 상태를 복원한다. 실행 중이면 확인된 같은 계정만 보완한다.
            $matching = @($liveSnapshots | Where-Object { $_.account -and $_.account -eq $entry.account })
            if ($liveSnapshots.Count -and (-not $matching.Count -or @($matching | Where-Object { $_.rows.Count }).Count)) { continue }
            $snapshots += [pscustomobject]@{
                plan=[string]$entry.plan; account=[string]$entry.account; source=[string]$entry.source
                rows=@($entry.rows | ForEach-Object { Convert-StoredUsageRow $_ })
                updated=ConvertTo-LocalTime $entry.updated; scope=[string]$entry.scope; live=$false
            }
        }
    } catch { } # 캐시 손상·부재는 실시간 조회를 막지 않는다.
    try {
        if (Test-Path -LiteralPath $ANTIGRAVITY_CACHE) {
            $cached = Get-Content -LiteralPath $ANTIGRAVITY_CACHE -Encoding UTF8 -Raw | ConvertFrom-Json
            if (-not (Test-Field $cached 'rows')) { throw 'rows 필드 없음' }
            # 구형 Gemini 전용 캐시는 계정·요금제 필드가 없고 새 데스크톱 섹션과 중복된다.
            if (-not (Test-Field $cached 'account') -or -not (Test-Field $cached 'plan')) { throw '지원 종료된 구형 캐시' }
            $snapshots += [pscustomobject]@{
                plan = Format-Plan (Get-Field $cached @('plan')); account = [string](Get-Field $cached @('account'))
                source = 'Antigravity CLI 상태줄'; live = $false; scope = 'models'
                rows = @(Sort-UsageRows @(@(Get-Field $cached @('rows')) | ForEach-Object { Convert-StoredUsageRow $_ }))
                updated = ConvertTo-LocalTime (Get-Field $cached @('updated'))
            }
        }
    } catch { } # 손상된 상태줄 캐시가 데스크톱 조회를 막지 않는다.
    $groups = @(Merge-AntigravitySnapshots $snapshots)
    if ($liveSnapshots.Count) {
        # 조회 성공 시에만 저장한다. 실패한 폴링으로 값이나 마지막 조회 시각을 덮어쓰지 않는다.
        try {
            $savedGroups = @($groups | ForEach-Object {
                @{ plan=$_.plan; account=$_.account; source=$_.source; scope=$_.scope
                   updated=$(if ($_.updated) { $_.updated.ToString('o') } else { $null })
                   rows=@($_.rows | ForEach-Object { Convert-StoredUsageRow $_ }) }
            })
            Set-JsonAtomic @{groups=$savedGroups} $ANTIGRAVITY_STATE_CACHE
        } catch { }
    }
    foreach ($group in $groups) {
        if (-not $group.live -and $script:antigravityLocalIssue) {
            $group.err = "$script:antigravityLocalIssue`n마지막 조회 기록을 표시합니다"
        }
    }
    $state.antigravity.groups = $groups
    $state.antigravity.rows = @()
    $state.antigravity.clear = $groups.Count -eq 0
    $state.antigravity.success = $groups.Count -gt 0
    $state.antigravity.err = $null
    if (-not $groups.Count) {
        $state.antigravity.plan = ''; $state.antigravity.account = ''; $state.antigravity.source = ''; $state.antigravity.asOf = $null
        $state.antigravity.err = if ($script:antigravityLocalIssue) { $script:antigravityLocalIssue }
            else { '조회 불가 — Antigravity 데스크톱을 실행하거나 CLI 상태줄을 연동하세요' }
        return
    }
    foreach ($field in 'plan', 'account', 'source') { $state.antigravity[$field] = $groups[0].$field }
    $state.antigravity.asOf = ($groups.updated | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
    foreach ($group in $groups) {
        foreach ($row in $group.rows) {
            $flatRow = Convert-StoredUsageRow $row
            # 계정별 알림 구분. 팝업은 원본 행 이름과 계정별 섹션을 사용한다.
            $identity = if ($group.account) { $group.account } else { $group.source }
            $flatRow.name = "$identity / $($row.name)"
            if (-not $group.account -or -not $group.live) { $flatRow.stale = $true }
            $state.antigravity.rows += $flatRow
        }
    }
}

function Get-ClaudeProfile {
    if ($env:CLAUDE_CONFIG_DIR) { return [System.IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR) }
    return Join-Path $HOME '.claude'
}

function Read-UsageCache([string]$path, [string]$account, [string]$profile) {
    try {
        $cached = Get-Content -LiteralPath $path -Encoding UTF8 -Raw | ConvertFrom-Json
        if (-not $account -or $cached.account -ne $account -or $cached.profile -ne $profile) { return $null }
        if (-not (Test-Field $cached 'rows') -or -not $cached.updated) { return $null }
        return [pscustomobject]@{
            rows = @($cached.rows | ForEach-Object { Convert-StoredUsageRow $_ })
            updated = ConvertTo-LocalTime $cached.updated; source = [string]$cached.source
        }
    } catch { return $null }
}

function Get-StatusLineCommand([string]$scriptPath) {
    $escaped = $scriptPath.Replace("'", "''")
    $command = "[Console]::In.ReadToEnd() | & '$escaped'"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

# ---------- 테스트·백그라운드 훅 (UI 없음) ----------

function Invoke-SyntheticSelfTest {
    $rejected = $false
    try { Convert-ClaudeResponseToRows ([pscustomobject]@{}) | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw '빈 Claude 응답 거부 실패' }
    foreach ($invalidPercent in @([double]::NaN, 101)) {
        $rejected = $false
        try {
            Convert-ClaudeResponseToRows ([pscustomobject]@{
                limits = @([pscustomobject]@{ kind = 'session'; percent = $invalidPercent })
            }) | Out-Null
        }
        catch { $rejected = $true }
        if (-not $rejected) { throw '잘못된 Claude percent 거부 실패' }
    }

    $future = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds()
    $claudeRows = @(Convert-ClaudeResponseToRows ([pscustomobject]@{
        limits = @([pscustomobject]@{ kind = 'session'; percent = 27.5; resets_at = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o') })
    }))
    if ($claudeRows.Count -ne 1 -or $claudeRows[0].pct -ne 28) { throw 'Claude 응답 변환 실패' }

    $camel = Convert-CodexRateLimits ([pscustomobject]@{
        planType = 'plus'; primary = [pscustomobject]@{ usedPercent = 42; windowDurationMins = 300; resetsAt = $future }
    })
    if ($camel.rows[0].name -ne '5h' -or $camel.rows[0].pct -ne 42 -or $camel.plan -ne 'Plus') { throw 'Codex camelCase 변환 실패' }
    $nullable = Convert-CodexRateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 3; windowDurationMins = $null; resetsAt = $null }
    })
    if ($nullable.rows[0].name -ne '기본 창' -or $nullable.rows[0].pct -ne 3) { throw 'Codex nullable window 변환 실패' }
    $stale = Convert-CodexRateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ used_percent = 91; window_minutes = 10080; resets_at = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds() }
    })
    if ($stale.rows[0].pct -ne 91 -or -not $stale.rows[0].stale -or $stale.rows[0].reset) { throw '만료 값 보존 실패' }
    $restoredStale = Convert-StoredUsageRow ([pscustomobject]@{ name = '5시간'; pct = 95; reset = $null; note = '리셋 지남'; stale = $true })
    if ($restoredStale.pct -ne 95 -or -not $restoredStale.stale -or $restoredStale.note -ne '리셋 지남') { throw '만료 캐시 복원 실패' }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aiusage-synthetic-" + [guid]::NewGuid().ToString('N'))
    $sessions = Join-Path $tmp 'sessions'
    New-Item -ItemType Directory -Path $sessions -Force | Out-Null
    try {
        for ($i = 0; $i -lt 16; $i++) {
            [System.IO.File]::WriteAllText((Join-Path $sessions ("rollout-decoy-$i.jsonl")), '{"type":"event"}')
        }
        $older = @{
            timestamp = [DateTime]::UtcNow.AddDays(-2).ToString('o')
            payload = @{ rate_limits = @{ primary = @{ used_percent = 11; window_minutes = 300; resets_at = $future } } }
        } | ConvertTo-Json -Compress -Depth 6
        [System.IO.File]::WriteAllText((Join-Path $sessions 'rollout-decoy-0.jsonl'), $older)
        $target = Join-Path $sessions 'rollout-target.jsonl'
        $valid = @{
            timestamp = [DateTime]::UtcNow.ToString('o')
            payload = @{ rate_limits = @{ primary = @{ used_percent = 37; window_minutes = 300; resets_at = $future } } }
        } | ConvertTo-Json -Compress -Depth 6
        $valid = $valid.Replace('"rate_limits":', '"rate_limits" : ')
        [System.IO.File]::WriteAllText($target, $valid + [Environment]::NewLine + '{"payload":{"rate_limits":')
        (Get-Item -LiteralPath $target).LastWriteTime = (Get-Date).AddDays(-1)
        $snapshot = Get-CodexUsageFromLogs $sessions
        $parsed = Convert-CodexRateLimits $snapshot.rateLimits
        if ($parsed.rows[0].pct -ne 37) { throw 'Codex JSONL 폴백 복구 실패' }

        $atomic = Join-Path $tmp 'atomic.json'
        Set-JsonAtomic @{ rows = @() } $atomic
        Set-JsonAtomic @{ rows = @('replaced') } $atomic
        $written = Get-Content -LiteralPath $atomic -Raw | ConvertFrom-Json
        if (-not (Test-Field $written 'rows') -or @($written.rows).Count -ne 1) { throw '원자 저장 실패' }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    'ok'
}

if ($Library) { return }
if ($SelfTest -or $SyntheticSelfTest) { Invoke-SyntheticSelfTest; return }

Initialize-DataDirectory -Migrate:(-not $Collect)

if ($Collect) {
    if ($CollectClaude) { Get-ClaudeUsage -Force:$Force }
    if ($CollectGpt) { Get-CodexUsage }
    if ($CollectAntigravity) { Get-AntigravityUsage }
    [pscustomobject]@{
        state = $state
        claudeBackoffUntil = $(if ($script:claudeBackoffUntil) { $script:claudeBackoffUntil.ToString('o') } else { $null })
        claude429Count = [int]$script:claude429Count
    } | ConvertTo-Json -Compress -Depth 9
    return
}

if ($Test) {
    Get-ClaudeUsage
    Get-CodexUsage
    Get-AntigravityUsage
    @{
        sources = @{
            claudeCredentials = Get-ClaudeCredPath
            codexSessions     = Get-CodexSessionsPath
            antigravityCache  = $(if (Test-Path -LiteralPath $ANTIGRAVITY_CACHE) { $ANTIGRAVITY_CACHE } else { $null })
            dataDir           = $DATA_DIR
        }
        state   = $state
    } | ConvertTo-Json -Depth 7
    return
}

# ---------- 단일 인스턴스 ----------

$mutex = $null
if (-not $Snapshot) {
    $mutex = New-Object System.Threading.Mutex($false, 'AiUsageTrayMutex')
    $waitMs = if ($WaitForPreviousInstance) { 30000 } else { 0 }
    try { if (-not $mutex.WaitOne($waitMs, $false)) { exit } }
    catch [System.Threading.AbandonedMutexException] { } # 종료된 이전 프로세스의 잠금을 인계받음
}

# 캐시는 수집 단계에서 현재 계정·프로필이 일치할 때만 복원한다.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResourceEx(string lpFileName, uint fl, IntPtr pdv);
[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
'@ -Name Native -Namespace Win32

# 설정 텍스트는 GDI+ 회색조 안티앨리어싱으로 그린다. 번들 Pretendard는 힌팅이 없어
# 기본 GDI / grid-fit 모드에서 작은 한글 윤곽이 거칠어지므로 설정 컨트롤에만 명시한다.
$settingsReferences = @('System.Windows.Forms', 'System.Drawing')
if ($PSVersionTable.PSEdition -eq 'Core') {
    $settingsReferences += @('System.Drawing.Common', 'System.Drawing.Primitives', 'System.ComponentModel.Primitives', 'System.Windows.Forms.Primitives')
}
Add-Type -ReferencedAssemblies $settingsReferences -WarningAction SilentlyContinue -TypeDefinition @'
using System.Drawing.Text;
using System.Windows.Forms;
namespace TraySettings {
    public class Label : System.Windows.Forms.Label {
        public Label() { UseCompatibleTextRendering = true; }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.TextRenderingHint = TextRenderingHint.AntiAlias;
            base.OnPaint(e);
        }
    }
    public class CheckBox : System.Windows.Forms.CheckBox {
        public CheckBox() { UseCompatibleTextRendering = true; }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.TextRenderingHint = TextRenderingHint.AntiAlias;
            base.OnPaint(e);
        }
    }
    public class Button : System.Windows.Forms.Button {
        public Button() { UseCompatibleTextRendering = true; }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.TextRenderingHint = TextRenderingHint.AntiAlias;
            base.OnPaint(e);
        }
    }
}
'@

# ---------- 공용 UI 리소스 ----------

[System.Windows.Forms.Application]::EnableVisualStyles()

# Pretendard TTF(스크립트 옆 파일)를 시스템 설치 없이 로드. 없거나 실패하면 맑은 고딕.
# AddFontResourceEx(FR_PRIVATE) = 이 프로세스의 GDI에만 등록 → 기본 렌더링(ClearType)으로 선명하게 그려짐.
# PrivateFontCollection 은 Font 객체 생성용(패밀리 조회). GDI+ 렌더링 강제(글자 거칠어짐)는 쓰지 않는다.
$script:pfc = [System.Drawing.Text.PrivateFontCollection]::new()
foreach ($n in 'Pretendard-Medium.ttf', 'Pretendard-Bold.ttf') {
    $fp = Join-Path $PSScriptRoot $n
    if (Test-Path $fp) {
        try {
            [Win32.Native]::AddFontResourceEx($fp, 0x10, [IntPtr]::Zero) | Out-Null   # 0x10 = FR_PRIVATE
            $script:pfc.AddFontFile($fp)
        }
        catch { }
    }
}
$fontBase = $null; $fontBold = $null; $fontSmall = $null
try {
    $famBold = @($script:pfc.Families | Where-Object { $_.Name -eq 'Pretendard' })
    if ($famBold.Count -gt 0) {
        $fontBase  = [System.Drawing.Font]::new($famBold[0], 11,   [System.Drawing.FontStyle]::Bold)
        $fontSmall = [System.Drawing.Font]::new($famBold[0], 9,    [System.Drawing.FontStyle]::Bold)
        $fontBold  = [System.Drawing.Font]::new($famBold[0], 11.5, [System.Drawing.FontStyle]::Bold)
    }
}
catch { }
if (-not $fontBase)  { $fontBase  = [System.Drawing.Font]::new('Malgun Gothic', 11, [System.Drawing.FontStyle]::Bold) }
if (-not $fontSmall) { $fontSmall = [System.Drawing.Font]::new('Malgun Gothic', 9, [System.Drawing.FontStyle]::Bold) }
if (-not $fontBold)  { $fontBold  = [System.Drawing.Font]::new('Malgun Gothic', 11.5, [System.Drawing.FontStyle]::Bold) }
# Medium 파일은 Bold와 다른 패밀리명으로 등록된다. Bold 패밀리의 Regular 스타일을 재사용하지 않는다.
$settingsFamily = $script:pfc.Families | Where-Object { $_.Name -eq 'Pretendard Medium' } | Select-Object -First 1
$fontSettings = if ($settingsFamily) { [System.Drawing.Font]::new($settingsFamily, 12, [System.Drawing.FontStyle]::Regular) }
    else { [System.Drawing.Font]::new('Malgun Gothic', 12, [System.Drawing.FontStyle]::Regular) }
$fontSettingsHeading = [System.Drawing.Font]::new($fontBase.FontFamily, 13, [System.Drawing.FontStyle]::Bold)

function Get-PctColor([int]$pct) {
    if ($pct -ge 90) { return [System.Drawing.Color]::FromArgb(255, 82, 82) }
    if ($pct -ge 70) { return [System.Drawing.Color]::FromArgb(255, 179, 0) }
    return $null    # 호출부 기본색 사용
}

function Format-Reset($dt) {
    if (-not $dt) { return '' }
    if ($dt.Date -eq (Get-Date).Date) { return $dt.ToString('HH:mm') }
    return $dt.ToString('M/d HH:mm')
}

# 스냅샷이 얼마나 낡았는지 — 1시간 미만이면 굳이 알릴 것 없으니 빈 문자열.
# 시각만 보면 "오늘 13:54" 인지 "어제 13:54" 인지 헷갈린다는 게 이 표시의 이유다.
function Format-Age($dt) {
    if (-not $dt) { return '' }
    $mins = ((Get-Date) - $dt).TotalMinutes
    if ($mins -lt 60) { return '' }
    if ($mins -ge 1440) { return " · $([int][Math]::Floor($mins / 1440))일 전" }
    return " · $([int][Math]::Floor($mins / 60))시간 전"
}

# ---------- 트레이 아이콘 ----------

$script:prevIconHandle = [IntPtr]::Zero
$script:prevIcon = $null

function Format-IconPct($row) {
    if ($null -eq $row) { return '-' }
    $p = [int]$row.pct
    if ($p -ge 100) { return '!!' }   # ponytail: 16px에 세 자리 안 들어감, 100%는 '!!'
    return [string]$p
}

# 5h 항목이 있으면 그걸, 없으면 첫 항목을 아이콘에 표시
function Get-IconRow($rows) {
    $r = @($rows | Where-Object { $_.name -match '(?i)(?<![a-z0-9])5h(?![a-z0-9])' })
    if ($r.Count -gt 0) { return $r[0] }
    $r = @($rows)
    if ($r.Count -gt 0) { return $r[0] }
    return $null
}

# 기본 글자색은 작업표시줄 테마를 따른다 — 밝은 테마면 검정, 그 외(값 없음·읽기 실패 포함)는 흰색.
# 매번 다시 읽는다: 테마를 바꿔도 재시작 없이 따라간다.
function Get-TrayTextColor {
    try {
        $p = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
            -Name 'SystemUsesLightTheme' -ErrorAction Stop
        if ([int]$p.SystemUsesLightTheme -eq 1) { return [System.Drawing.Color]::Black }
    }
    catch { }
    return [System.Drawing.Color]::White
}

# 아이콘 비트맵 그리기 — Update-TrayIcon 과 -Snapshot 프리뷰가 공유한다. Dispose 는 호출부 책임.
# 숫자 2줄 표시는 16px 에서 가시성이 나빠 'U' 글자로 되돌렸다(수치는 툴팁·팝업 담당).
# 글자색만 작업표시줄 테마를 따른다 — 밝은 테마에서 흰 글자가 안 보이던 문제 대응.
function Draw-TrayIconBitmap([int]$w, [int]$h, [System.Drawing.Color]$color = [System.Drawing.Color]::Empty) {
    $bmp = [System.Drawing.Bitmap]::new($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        # ClearType 은 투명 배경에서 색번짐 → 회색조 AA 가 트레이 아이콘에 맞다
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)
        # 16px 에서 기존과 동일한 11pt, 더 큰 아이콘(고DPI)에서는 비례 확대
        $font = [System.Drawing.Font]::new('Segoe UI Black', [single](11 * 96 / 72 * $h / 16), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = [System.Drawing.StringFormat]::new()
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        if ($color.IsEmpty) { $color = Get-TrayTextColor }
        $g.DrawString('U', $font, (Get-Brush $color), [System.Drawing.RectangleF]::new(0, 0, $w, $h), $fmt)
        $font.Dispose(); $fmt.Dispose()
    }
    finally { $g.Dispose() }
    return $bmp
}

function Get-TrayIconSize {
    # 고DPI 에서 흐려지지 않게 시스템이 요구하는 실제 크기로 그린다. 못 읽으면 16x16.
    try {
        $sz = [System.Windows.Forms.SystemInformation]::SmallIconSize
        if ($sz.Width -gt 0 -and $sz.Height -gt 0) { return $sz }
    }
    catch { }
    return [System.Drawing.Size]::new(16, 16)
}

function Update-TrayIcon {
    $cRow = if ($showClaude.Checked) { Get-IconRow @(Get-VisibleClaudeRows $state.claude.rows) } else { $null }
    $gRow = if ($showGpt.Checked) { Get-IconRow @(Get-VisibleCodexRows $state.gpt.rows $state.gpt.plan) } else { $null }
    $aRow = if ($showAntigravity.Checked) { Get-IconRow @(Get-VisibleAntigravityRows $state.antigravity.rows) } else { $null }

    $sz = Get-TrayIconSize
    $bmp = Draw-TrayIconBitmap $sz.Width $sz.Height

    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h)
    $notify.Icon = $icon
    $parts = @()
    if ($showClaude.Checked) {
        $parts += if ($cRow) { "Claude $($cRow.name) $(Format-IconPct $cRow)%" } else { 'Claude 표시할 사용량 없음' }
    }
    if ($showGpt.Checked) {
        $parts += if ($gRow) { "GPT $($gRow.name) $(Format-IconPct $gRow)%" } else { 'GPT 표시할 사용량 없음' }
    }
    if ($showAntigravity.Checked) { $parts += "AG $(Format-IconPct $aRow)%" }
    $tip = if ($parts.Count -gt 0) { $parts -join ' | ' } else { 'AI 사용량' }
    $notify.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
    if ($script:prevIconHandle -ne [IntPtr]::Zero) { [Win32.Native]::DestroyIcon($script:prevIconHandle) | Out-Null }
    if ($script:prevIcon) { $script:prevIcon.Dispose() }
    $script:prevIconHandle = $h
    $script:prevIcon = $icon
    $bmp.Dispose()
}

# ---------- 팝업 ----------

$POPUP_WIDTH = 450   # 기본 폭. 소진 예측처럼 긴 줄이 생기면 Build-Popup 이 필요한 만큼만 넓힌다.

$form = [System.Windows.Forms.Form]::new()
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.Width = $POPUP_WIDTH
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = $fontBase
$form.Padding = [System.Windows.Forms.Padding]::new(1)
$popupBody = [System.Windows.Forms.Panel]::new()
$popupBody.Dock = 'Fill'; $popupBody.AutoScroll = $true
$popupSettings = [System.Windows.Forms.Button]::new()
$popupSettings.Size = [System.Drawing.Size]::new(32, 32)
$popupSettings.FlatStyle = 'Flat'; $popupSettings.FlatAppearance.BorderSize = 0
$popupSettings.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$popupSettings.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$popupSettings.AccessibleName = '설정'
# 폰트에 의존하지 않는 톱니바퀴. 클릭·키보드·포커스 처리는 기본 Button을 사용한다.
$gearBitmap = [System.Drawing.Bitmap]::new(24, 24)
$gearGraphics = [System.Drawing.Graphics]::FromImage($gearBitmap)
$gearPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
try {
    $gearGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $points = for ($tooth = 0; $tooth -lt 8; $tooth++) {
        for ($edge = 0; $edge -lt 4; $edge++) {
            $angle = $tooth * [Math]::PI / 4 + @(-0.32, -0.20, 0.20, 0.32)[$edge]
            $radius = @(8, 10, 10, 8)[$edge]
            [System.Drawing.PointF]::new(12 + $radius * [Math]::Cos($angle), 12 + $radius * [Math]::Sin($angle))
        }
    }
    $gearPath.AddPolygon([System.Drawing.PointF[]]$points)
    $gearPath.AddEllipse(8, 8, 8, 8)
    $gearGraphics.FillPath([System.Drawing.Brushes]::Gainsboro, $gearPath)
} finally { $gearPath.Dispose(); $gearGraphics.Dispose() }
$popupSettings.Image = $gearBitmap
$popupSettings.add_Click({ Show-SettingsDialog })
$popupTip = [System.Windows.Forms.ToolTip]::new()
$popupTip.SetToolTip($popupSettings, '설정')
$popupBody.Controls.Add($popupSettings)
$form.Controls.Add($popupBody)
$form.add_Disposed({ $popupSettings.Image.Dispose(); $popupTip.Dispose() })
$form.KeyPreview = $true
$form.add_KeyDown({ param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $s.Hide() }
    elseif ($e.KeyCode -in @([System.Windows.Forms.Keys]::PageDown, [System.Windows.Forms.Keys]::PageUp)) {
        $step = if ($e.KeyCode -eq [System.Windows.Forms.Keys]::PageDown) { 240 } else { -240 }
        $popupBody.AutoScrollPosition = [System.Drawing.Point]::new(0, [Math]::Max(0, -$popupBody.AutoScrollPosition.Y + $step))
        $popupBody.Invalidate()
    }
})
$popupBody.add_Paint({ param($s, $e)
    $e.Graphics.TranslateTransform($s.AutoScrollPosition.X, $s.AutoScrollPosition.Y)
    Draw-Popup $e.Graphics | Out-Null
    $e.Graphics.ResetTransform()
})
$form.add_Paint({ param($s, $e)
    $e.Graphics.DrawRectangle([System.Drawing.Pens]::DimGray, 0, 0, $s.Width - 1, $s.Height - 1)
})
$script:lastHide = [datetime]::MinValue
$form.add_Deactivate({ $script:lastHide = Get-Date; $form.Hide() })

# 라벨 컨트롤 대신 직접 그리기 — 회색조 AA(AntiAliasGridFit)로 ClearType 색번짐(서브픽셀) 제거.
# HDMI TV 크로마 서브샘플링 등에서 GDI ClearType 글자가 지저분해 보이는 문제 대응.
$script:brushCache = @{}
function Get-Brush([System.Drawing.Color]$c) {
    $k = $c.ToArgb()
    if (-not $script:brushCache.ContainsKey($k)) { $script:brushCache[$k] = [System.Drawing.SolidBrush]::new($c) }
    return $script:brushCache[$k]
}
$COL_TEXT  = [System.Drawing.Color]::White
$COL_GRAY  = [System.Drawing.Color]::FromArgb(160, 160, 160)
$COL_RED   = [System.Drawing.Color]::FromArgb(255, 120, 120)
$COL_BARBG = [System.Drawing.Color]::FromArgb(58, 58, 58)
$COL_GREEN = [System.Drawing.Color]::FromArgb(76, 175, 80)

# 폭도 높이와 같은 방식으로 측정 패스에서 잡는다 — 소진 예측이 붙으면 값 칸이 기본 폭을 넘긴다.
$script:popupNeedWidth = 0
function Measure-PopupWidth($g, [string]$text, $font, [int]$x) {
    $w = $x + $g.MeasureString($text, $font).Width
    if ($w -gt $script:popupNeedWidth) { $script:popupNeedWidth = [int][Math]::Ceiling($w) }
}

function Draw-Section($g, [string]$title, [string]$plan, $rows, [string]$err, $asOf, [int]$y, [string]$source, [string]$account) {
    $rows = @(Sort-UsageRows $rows)
    $t = $title
    $t += if ($plan) { " — $plan" } else { ' — 요금제 확인 불가' }
    if ($asOf) { $t += "   ($(Format-Reset $asOf) 기준$(Format-Age $asOf))" }
    if ($y -eq 12) {
        # 첫 제목과 설정 버튼이 같은 줄을 공유한다. 좁은 화면에서도 서로 겹치지 않는다.
        Measure-PopupWidth $g $t $fontBold 54
        $titleWidth = [Math]::Max(1, $popupSettings.Left - $popupBody.AutoScrollPosition.X - 20)
        $titleFormat = [System.Drawing.StringFormat]::new()
        $titleFormat.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $titleFormat.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        try { $g.DrawString($t, $fontBold, (Get-Brush $COL_TEXT), [System.Drawing.RectangleF]::new(14, $y, $titleWidth, 28), $titleFormat) }
        finally { $titleFormat.Dispose() }
    } else {
        $g.DrawString($t, $fontBold, (Get-Brush $COL_TEXT), 14, $y)
        Measure-PopupWidth $g $t $fontBold 14
    }
    $y += 28
    $meta = if ($source) { $source } else { '수집 대기' }
    $meta += if ($account) { " · $account" } else { ' · 계정 확인 불가' }
    $g.DrawString($meta, $fontSmall, (Get-Brush $COL_GRAY), 18, $y)
    Measure-PopupWidth $g $meta $fontSmall 18
    $y += 24
    if ($err) {
        $errorHeight = [Math]::Max(36, [int][Math]::Ceiling($g.MeasureString($err, $fontSmall, 418).Height))
        $g.DrawString($err, $fontSmall, (Get-Brush $COL_RED), [System.Drawing.RectangleF]::new(18, $y, 418, $errorHeight))
        $y += $errorHeight + 4
    }
    $nameWidth = 108
    foreach ($r in $rows) { $nameWidth = [Math]::Max($nameWidth, [int][Math]::Ceiling($g.MeasureString([string]$r.name, $fontBase).Width)) }
    $barX = 26 + $nameWidth
    $valueX = $barX + 152
    foreach ($r in $rows) {
        $g.DrawString([string]$r.name, $fontBase, (Get-Brush $COL_TEXT), 18, ($y + 3))
        $g.FillRectangle((Get-Brush $COL_BARBG), $barX, ($y + 7), 140, 10)
        $pct = [Math]::Max(0, [Math]::Min(100, [int]$r.pct))
        if ($pct -gt 0) {
            $fc = Get-PctColor $pct
            if (-not $fc) { $fc = $COL_GREEN }
            $g.FillRectangle((Get-Brush $fc), $barX, ($y + 7), [int](140 * $pct / 100), 10)
        }
        $txt = "$($r.pct)%"
        if ($r.reset) { $txt += " · $(Format-Reset $r.reset) 리셋" }
        elseif ($r.note) { $txt += " · $($r.note)" }
        # 리셋보다 먼저 100% 에 닿을 속도면 예상 소진 시각을 붙이고 줄 전체를 적색으로 — 눈에 걸려야 의미가 있다
        $vc = $COL_TEXT
        if ($r.warn) { $txt += " · $($r.warn)"; $vc = $COL_RED }
        $g.DrawString($txt, $fontBase, (Get-Brush $vc), $valueX, ($y + 3))
        Measure-PopupWidth $g $txt $fontBase $valueX
        $y += 30
    }
    if ($rows.Count -eq 0 -and -not $err) {
        $g.DrawString('데이터 없음', $fontBase, (Get-Brush $COL_GRAY), 18, ($y + 3))
        $y += 28
    }
    return $y
}

function Draw-Popup($g) {
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $script:popupNeedWidth = 0
    $y = 12
    $drawn = 0
    if ($showClaude.Checked) {
        $y = Draw-Section $g 'Claude' $state.claude.plan @(Get-VisibleClaudeRows $state.claude.rows) $state.claude.err $state.claude.updated $y $state.claude.source $state.claude.account
        $drawn++
    }
    if ($showGpt.Checked) {
        if ($drawn -gt 0) { $y += 10 }
        $y = Draw-Section $g 'Codex' $state.gpt.plan @(Get-VisibleCodexRows $state.gpt.rows $state.gpt.plan) $state.gpt.err $state.gpt.asOf $y $state.gpt.source $state.gpt.account
        $drawn++
    }
    if ($showAntigravity.Checked) {
        $sections = @($state.antigravity.groups)
        if (-not $sections.Count -or $null -eq $sections[0]) {
            $sections = @(@{ plan=$state.antigravity.plan; rows=$state.antigravity.rows; err=$state.antigravity.err; updated=$state.antigravity.asOf; source=$state.antigravity.source; account=$state.antigravity.account })
        }
        foreach ($section in $sections) {
            if ($drawn -gt 0) { $y += 10 }
            $sectionError = if ($state.antigravity.err) { $state.antigravity.err } else { $section.err }
            $y = Draw-Section $g 'Antigravity' $section.plan @(Get-VisibleAntigravityRows $section.rows) $sectionError $section.updated $y $section.source $section.account
            $drawn++
        }
    }
    if ($drawn -eq 0) {
        $g.DrawString('표시할 항목을 선택하세요', $fontBase, (Get-Brush $COL_GRAY), 14, $y)
        $y += 28
    }
    $y += 6
    $updated = @(@($state.claude.updated, $state.gpt.asOf, $state.antigravity.asOf) |
        Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
    $upd = if ($updated.Count -gt 0) { $updated[0].ToString('HH:mm:ss') } else { '-' }
    $footer = "갱신 $upd"
    $footer += ' · 로그·상태줄은 마지막 활동 기준'
    $g.DrawString($footer, $fontSmall, (Get-Brush $COL_GRAY), 14, $y)
    $y += 22
    return $y + 10
}

function Build-Popup {
    # 그리기 없이 크기만 계산(1px 캔버스) 후 다시 그리게 무효화
    $mb = [System.Drawing.Bitmap]::new(1, 1)
    $mg = [System.Drawing.Graphics]::FromImage($mb)
    $contentHeight = Draw-Popup $mg
    # 소진 예측이 붙은 줄은 기본 폭을 넘는다. MeasureString 이 글자 앞뒤 여백을 포함하므로 그게 오른쪽 여백이 된다.
    $contentWidth = [Math]::Max($POPUP_WIDTH, $script:popupNeedWidth + 8)
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Width = [Math]::Min($contentWidth + 20, $area.Width - 16)
    $form.Height = [Math]::Min($contentHeight + 20, $area.Height - 16)
    $popupBody.AutoScrollMinSize = [System.Drawing.Size]::new($contentWidth, $contentHeight)
    $popupSettings.Location = [System.Drawing.Point]::new($popupBody.ClientSize.Width - $popupSettings.Width - 8 + $popupBody.AutoScrollPosition.X, 8 + $popupBody.AutoScrollPosition.Y)
    $mg.Dispose(); $mb.Dispose()
    $form.Invalidate($true)
}

function Show-Popup {
    # 열어보는 순간이 신선도가 필요한 순간 — 마지막 갱신이 60초 지났으면 즉시 1회 갱신
    if (-not $script:lastRefresh -or ((Get-Date) - $script:lastRefresh).TotalSeconds -gt 60) {
        Refresh-All
    }
    # 로컬 앱 서버도 서버 쪽 한도를 갱신하므로 60초 안에는 이전 수집 결과를 쓴다.
    Build-Popup
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = [System.Drawing.Point]::new($wa.Right - $form.Width - 8, $wa.Bottom - $form.Height - 8)
    $form.Show()
    $form.Activate()
}

function Toggle-Popup {
    if ($form.Visible) { $form.Hide(); return }
    # 팝업이 떠 있는 상태에서 아이콘 클릭 → Deactivate(숨김) 직후 MouseUp이 다시 열어버리는 것 방지
    if (((Get-Date) - $script:lastHide).TotalMilliseconds -lt 300) { return }
    Show-Popup
}

# ---------- 트레이 등록 ----------

# 행별 마지막 알림 주기만 보관한다. 리셋 시각이 바뀌면 새 주기라 다시 한 번 알린다.
$script:notified = @{}

function Test-UsageAlert {
    if (-not $notifyItem.Checked) { return }
    # 기동 직전 첫 수집에서 풍선이 터지지 않게 — 아이콘이 뜬 뒤에만 알린다
    if (-not $notify.Visible) { return }
    $activeSlots = @{}
    foreach ($src in @(
            @{ on = [bool]$showClaude.Checked; label = 'Claude'; rows = @(Get-VisibleClaudeRows $state.claude.rows) }
            @{ on = [bool]$showGpt.Checked; label = 'GPT'; rows = @(Get-VisibleCodexRows $state.gpt.rows $state.gpt.plan) }
            @{ on = [bool]$showAntigravity.Checked; label = 'Antigravity'; rows = @(Get-VisibleAntigravityRows $state.antigravity.rows) }
        )) {
        foreach ($r in @($src.rows)) {
            if ($null -eq $r) { continue }
            $slot = "$($src.label)|$($r.name)"
            $activeSlots[$slot] = $true
            if (-not $src.on -or [int]$r.pct -lt 90 -or [bool]$r.stale) { continue }
            if ($r.reset -and [datetime]$r.reset -le (Get-Date)) { continue }
            $cycle = if ($r.reset) { ([datetime]$r.reset).ToString('s') } else { 'no-reset' }
            if ($script:notified[$slot] -eq $cycle) { continue }
            $script:notified[$slot] = $cycle
            $msg = "$($src.label) $($r.name) $([int]$r.pct)%"
            if ($r.reset) { $msg += " — $(Format-Reset $r.reset) 리셋" }
            try { $notify.ShowBalloonTip(5000, 'AI 사용량', $msg, [System.Windows.Forms.ToolTipIcon]::Warning) }
            catch { }
        }
    }
    foreach ($slot in @($script:notified.Keys)) {
        if (-not $activeSlots.ContainsKey($slot)) { [void]$script:notified.Remove($slot) }
    }
}

function Convert-WorkerRows($rows) {
    return @(Sort-UsageRows @(@($rows) | ForEach-Object { Convert-StoredUsageRow $_ }))
}

function Merge-CollectionResult($result) {
    foreach ($name in 'claude', 'gpt', 'antigravity') {
        $incoming = $result.state.$name
        if ($incoming.success -or $incoming.err) {
            foreach ($field in 'plan', 'account', 'source') { $state[$name][$field] = [string]$incoming.$field }
        }
        if ($incoming.clear) {
            $state[$name].rows = @()
            if ($name -eq 'antigravity') { $state.antigravity.groups = @() }
            if ($name -eq 'claude') { $state.claude.updated = $null; $script:claudeSamples = @() }
            else { $state[$name].asOf = $null }
        }
    }
    if ($result.state.claude) {
        $incoming = $result.state.claude
        if ([bool]$incoming.success) {
            $state.claude.plan = [string]$incoming.plan
            $state.claude.rows = @(Convert-WorkerRows $incoming.rows)
            $state.claude.updated = ConvertTo-LocalTime $incoming.updated
            $state.claude.err = if ($incoming.err) { [string]$incoming.err } else { $null }
            Update-ClaudeForecast $state.claude.rows
        }
        elseif ($incoming.err) { $state.claude.err = [string]$incoming.err }
    }
    if ($result.state.gpt) {
        $incoming = $result.state.gpt
        if ([bool]$incoming.success) {
            $state.gpt.plan = [string]$incoming.plan
            $state.gpt.rows = @(Convert-WorkerRows $incoming.rows)
            $state.gpt.asOf = ConvertTo-LocalTime $incoming.asOf
            $state.gpt.err = if ($incoming.err) { [string]$incoming.err } else { $null }
        }
        elseif ($incoming.err) { $state.gpt.err = [string]$incoming.err }
    }
    if ($result.state.antigravity) {
        $incoming = $result.state.antigravity
        if ([bool]$incoming.success) {
            $state.antigravity.rows = @(Convert-WorkerRows $incoming.rows)
            $state.antigravity.groups = @(@($incoming.groups) | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject]@{
                    plan=[string]$_.plan; account=[string]$_.account; source=[string]$_.source; err=[string]$_.err
                    rows=@(Convert-WorkerRows $_.rows); updated=ConvertTo-LocalTime $_.updated
                }
            })
            $state.antigravity.asOf = ConvertTo-LocalTime $incoming.asOf
            $state.antigravity.err = if ($incoming.err) { [string]$incoming.err } else { $null }
        }
        elseif ($incoming.err) { $state.antigravity.err = [string]$incoming.err }
    }
    $script:claude429Count = [int]$result.claude429Count
    $script:claudeBackoffUntil = $null
    if ($result.claudeBackoffUntil) {
        try { $script:claudeBackoffUntil = ConvertTo-LocalTime $result.claudeBackoffUntil } catch { }
    }
}

$script:collectorJob = $null
$script:collectorRequest = $null
$script:pendingCollect = $null

function Start-CollectionJob($request) {
    $request.backoff = if ($script:claudeBackoffUntil) { $script:claudeBackoffUntil.ToString('o') } else { '' }
    $request.count = [int]$script:claude429Count
    $request.account = [string]$state.claude.account
    $requestJson = $request | ConvertTo-Json -Compress
    $jobScript = {
        param($scriptPath, $json)
        $request = $json | ConvertFrom-Json
        & $scriptPath -Collect `
            -CollectClaude:([bool]$request.claude) `
            -CollectGpt:([bool]$request.gpt) `
            -CollectAntigravity:([bool]$request.antigravity) `
            -Force:([bool]$request.force) `
            -InitialBackoffUntil ([string]$request.backoff) `
            -Initial429Count ([int]$request.count) `
            -InitialClaudeAccount ([string]$request.account)
    }
    try {
        $script:collectorJob = Start-Job -ScriptBlock $jobScript -ArgumentList $PSCommandPath, $requestJson
        $script:collectorRequest = $request
    }
    catch {
        foreach ($name in 'claude', 'gpt', 'antigravity') {
            if ($request[$name]) { $state[$name].err = '백그라운드 수집 작업을 시작하지 못했습니다 — 마지막 값 표시 중' }
        }
    }
}

function Request-Collection([bool]$claude, [bool]$gpt, [bool]$antigravity, [bool]$force) {
    if (-not $claude -and -not $gpt -and -not $antigravity) { return }
    $request = @{ claude = $claude; gpt = $gpt; antigravity = $antigravity; force = $force }
    if ($script:collectorJob) {
        if (-not $script:pendingCollect) { $script:pendingCollect = @{ claude = $false; gpt = $false; antigravity = $false; force = $false } }
        foreach ($name in 'claude', 'gpt', 'antigravity', 'force') {
            $script:pendingCollect[$name] = [bool]$script:pendingCollect[$name] -or [bool]$request[$name]
        }
        return
    }
    Start-CollectionJob $request
}

function Complete-CollectionJob {
    if (-not $script:collectorJob -or $script:collectorJob.State -in @('Running', 'NotStarted')) { return }
    $job = $script:collectorJob
    $request = $script:collectorRequest
    try {
        $output = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($output.Count -eq 0) { throw '수집 결과가 없습니다' }
        $result = ([string]$output[-1]) | ConvertFrom-Json
        Merge-CollectionResult $result
    }
    catch {
        foreach ($name in 'claude', 'gpt', 'antigravity') {
            if ($request[$name]) { $state[$name].err = '백그라운드 수집 작업 실패 — 마지막 값 표시 중' }
        }
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $script:collectorJob = $null
        $script:collectorRequest = $null
    }
    Update-TrayIcon
    Test-UsageAlert
    if ($form.Visible) { Build-Popup }
    if ($script:pendingCollect) {
        $next = $script:pendingCollect
        $script:pendingCollect = $null
        Start-CollectionJob $next
    }
}

function Refresh-All([switch]$Force) {
    $script:lastRefresh = Get-Date
    if ($Snapshot) {
        if ($showClaude.Checked) { Get-ClaudeUsage -Force:$Force; Update-ClaudeForecast $state.claude.rows }
        if ($showGpt.Checked) { Get-CodexUsage }
        if ($showAntigravity.Checked) { Get-AntigravityUsage }
    }
    else {
        Request-Collection ([bool]$showClaude.Checked) ([bool]$showGpt.Checked) ([bool]$showAntigravity.Checked) ([bool]$Force)
    }
    Update-TrayIcon
    Test-UsageAlert
}

function Save-DisplayState($preferences = $null) {
    if ($null -eq $preferences) {
        $preferences = @{
            claude      = [bool]$showClaude.Checked
            gpt         = [bool]$showGpt.Checked
            antigravity = [bool]$showAntigravity.Checked
            antigravityModels = $script:antigravityModelVisibility
            usageItems = $script:usageVisibility
            notify      = [bool]$notifyItem.Checked
        }
    }
    Set-JsonAtomic $preferences $DISPLAY_STATE
}

function Initialize-DisplayState {
    $saved = $null
    try { $saved = Get-Content -LiteralPath $DISPLAY_STATE -Encoding UTF8 -Raw | ConvertFrom-Json } catch { }
    foreach ($entry in @(
        @{name='showClaude';key='claude'}, @{name='showGpt';key='gpt'},
        @{name='showAntigravity';key='antigravity'},
        @{name='notifyItem';key='notify'}
    )) {
        $value = Get-Field $saved @($entry.key)
        Set-Variable -Scope Script -Name $entry.name -Value ([pscustomobject]@{Checked=$(if ($value -is [bool]) { $value } else { $true })})
    }
    $script:antigravityModelVisibility = @{}
    foreach ($entry in @(Get-Entries $saved.antigravityModels)) {
        if ($entry.value -is [bool]) { $script:antigravityModelVisibility[$entry.name] = $entry.value }
    }
    # 기존 Spark·모델 선택은 새 기간별 선택으로 옮기고, 저장된 새 선택을 우선한다.
    $script:usageVisibility = @{}
    if ($saved.codexSpark -is [bool]) {
        foreach ($period in '5h', 'weekly') { $script:usageVisibility["codex.spark.$period"] = $saved.codexSpark }
    }
    foreach ($entry in @(Get-Entries $saved.antigravityModels)) {
        if ($entry.value -isnot [bool]) { continue }
        switch (Get-AntigravityChoiceKey $entry.name) {
            'gemini' { foreach ($period in '5h', 'weekly') { $script:usageVisibility["antigravity.gemini.$period"] = $entry.value } }
            'claude' { $script:usageVisibility['antigravity.claude'] = $entry.value }
        }
    }
    foreach ($entry in @(Get-Entries $saved.usageItems)) {
        if ($entry.value -is [bool]) { $script:usageVisibility[$entry.name] = $entry.value }
    }
}

function Save-TraySettings($dialog) {
    $draft = $dialog.Tag
    $preferences = @{}
    foreach ($key in 'claude', 'gpt', 'antigravity', 'notify') {
        $preferences[$key] = [bool]$draft.Checks[$key].Checked
    }
    $preferences.antigravityModels = $script:antigravityModelVisibility.Clone()
    foreach ($key in $draft.Models.Keys) { $preferences.antigravityModels[$key] = [bool]$draft.Models[$key].Checked }
    $preferences.usageItems = $script:usageVisibility.Clone()
    foreach ($key in $draft.UsageItems.Keys) { $preferences.usageItems[$key] = [bool]$draft.UsageItems[$key].Checked }
    $previousStartup = Test-StartupEnabled
    $changeStartup = $previousStartup -ne $draft.Checks.startup.Checked
    if ($changeStartup -and -not (Set-Startup $draft.Checks.startup.Checked)) {
        throw '자동 시작 설정을 저장하지 못했습니다. 다시 시도해 주세요.'
    }
    try { Save-DisplayState $preferences }
    catch {
        if ($changeStartup) { Set-Startup $previousStartup | Out-Null }
        throw '표시 설정을 저장하지 못했습니다. 파일 접근 권한을 확인해 주세요.'
    }
}

function Start-TrayRestart {
    $shellPath = (Get-Process -Id $PID).Path
    $scriptPath = Join-Path $PSScriptRoot 'ai-usage-tray.ps1'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -WaitForPreviousInstance"
    Start-Process -FilePath $shellPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -ErrorAction Stop | Out-Null
}

function New-SettingsCheck($parent, [string]$label, [bool]$checked) {
    $check = [TraySettings.CheckBox]::new()
    $check.Text = $label; $check.AutoSize = $true; $check.Checked = $checked
    $check.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 5)
    $parent.Controls.Add($check)
    return $check
}

function New-SettingsUsageRow($parent, $draft, [string]$label, [string]$key, [string[]]$periods) {
    $row = [System.Windows.Forms.FlowLayoutPanel]::new()
    $row.AutoSize = $true; $row.AutoSizeMode = 'GrowAndShrink'; $row.WrapContents = $false
    $row.Margin = [System.Windows.Forms.Padding]::new(24, 0, 0, 0)
    $name = [TraySettings.Label]::new()
    $name.Text = $label; $name.AutoSize = $true
    $name.Margin = [System.Windows.Forms.Padding]::new(0, 3, 8, 0)
    $row.Controls.Add($name)
    foreach ($period in $periods) {
        $itemKey = "$key.$period"
        $check = New-SettingsCheck $row $period (Test-UsageItemVisible $itemKey)
        $check.AccessibleName = "$label $period"
        $check.Margin = [System.Windows.Forms.Padding]::new(0, 3, 24, 5)
        $draft.UsageItems[$itemKey] = $check
    }
    $parent.Controls.Add($row)
}

function Update-SettingsLayout($dialog) {
    if (-not $dialog -or $dialog.Tag.LayingOut -or -not $dialog.Tag.Content) { return }
    $dialog.Tag.LayingOut = $true
    $content = $dialog.Tag.Content
    $content.SuspendLayout()
    try {
        $scale = [Math]::Max(96, [Win32.Native]::GetDpiForWindow($dialog.Handle)) / 96.0
        # 화면 폭과 관계없이 한 열을 유지하고 세로 스크롤 공간을 확보한다.
        $width = [Math]::Max(1, $content.ClientSize.Width - $content.Padding.Horizontal - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth)
        foreach ($control in $content.Controls) {
            $control.MaximumSize = [System.Drawing.Size]::new([Math]::Max(1, $width - $control.Margin.Horizontal), 0)
            if ($control -is [System.Windows.Forms.FlowLayoutPanel]) {
                $control.WrapContents = $true
                $name = $control.Controls[0]
                $name.MinimumSize = [System.Drawing.Size]::new([int](100 * $scale), 0)
                $name.MaximumSize = $name.MinimumSize
            }
        }
    }
    finally { $content.ResumeLayout($true); $dialog.Tag.LayingOut = $false }
}

function Set-SettingsWindowBounds($dialog, [System.Drawing.Rectangle]$workArea) {
    $scale = [Math]::Max(96, [Win32.Native]::GetDpiForWindow($dialog.Handle)) / 96.0
    $margin = [int](16 * $scale)
    $width = [Math]::Max(1, $workArea.Width - 2 * $margin)
    $height = [Math]::Max(1, $workArea.Height - 2 * $margin)
    $frameWidth = $dialog.Width - $dialog.ClientSize.Width
    $frameHeight = $dialog.Height - $dialog.ClientSize.Height
    $dialog.MinimumSize = [System.Drawing.Size]::new([Math]::Min([int](460 * $scale), $width), [Math]::Min([int](400 * $scale), $height))
    $dialog.Size = [System.Drawing.Size]::new([Math]::Min([int](560 * $scale) + $frameWidth, $width), [Math]::Min([int](620 * $scale) + $frameHeight, $height))
    $dialog.Location = [System.Drawing.Point]::new($workArea.Left + [int](($workArea.Width - $dialog.Width) / 2), $workArea.Top + [int](($workArea.Height - $dialog.Height) / 2))
    Update-SettingsLayout $dialog
}

function New-SettingsDialog {
    # 설정 창만 시스템 DPI를 인식시킨다. 기존 트레이·사용량 팝업의 좌표계는 유지한다.
    $previousDpiContext = [IntPtr]::Zero
    try { $previousDpiContext = [Win32.Native]::SetThreadDpiAwarenessContext([IntPtr]::new(-2)) } catch { }
    try {
    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.SuspendLayout()
    $dialog.Text = 'AI 사용량 설정'
    $dialog.Font = $fontSettings
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dialog.ClientSize = [System.Drawing.Size]::new(560, 620)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $dialog.MaximizeBox = $true; $dialog.MinimizeBox = $false
    $dialog.Tag = @{Checks=@{};Models=@{};UsageItems=@{};RestartReady=$false}
    $iconBitmap = Draw-TrayIconBitmap 32 32 ([System.Drawing.SystemColors]::WindowText)
    $iconHandle = $iconBitmap.GetHicon()
    $iconView = [System.Drawing.Icon]::FromHandle($iconHandle)
    try { $dialog.Icon = [System.Drawing.Icon]$iconView.Clone() }
    finally { $iconView.Dispose(); [void][Win32.Native]::DestroyIcon($iconHandle); $iconBitmap.Dispose() }
    $dialog.add_Disposed({ param($sender, $eventArgs); $sender.Icon.Dispose() })

    $footer = [System.Windows.Forms.FlowLayoutPanel]::new()
    $footer.Dock = 'Bottom'; $footer.AutoSize = $true; $footer.FlowDirection = 'RightToLeft'
    $footer.AutoSizeMode = 'GrowAndShrink'
    $footer.Padding = [System.Windows.Forms.Padding]::new(12)
    $done = [TraySettings.Button]::new()
    $done.Text = '완료 및 재시작'; $done.AutoSize = $true; $done.Padding = [System.Windows.Forms.Padding]::new(8, 4, 8, 4)
    $cancel = [TraySettings.Button]::new()
    $cancel.Text = '취소'; $cancel.AutoSize = $true; $cancel.Padding = $done.Padding
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $footer.Controls.AddRange(@($done, $cancel))
    $dialog.AcceptButton = $done; $dialog.CancelButton = $cancel
    $status = [TraySettings.Label]::new()
    $status.Dock = 'Bottom'; $status.Height = 64; $status.Padding = [System.Windows.Forms.Padding]::new(20, 5, 20, 0)
    $status.Text = '완료하면 설정을 저장하고 자동으로 재시작합니다.'
    $dialog.Tag.Status = $status
    $content = [System.Windows.Forms.FlowLayoutPanel]::new()
    $content.Dock = 'Fill'; $content.FlowDirection = 'TopDown'; $content.WrapContents = $false
    $content.AutoScroll = $true; $content.Padding = [System.Windows.Forms.Padding]::new(20, 12, 20, 12)
    $dialog.Controls.AddRange(@($content, $status, $footer))
    $dialog.Tag.Content = $content
    foreach ($section in @('Claude', 'Codex', 'Antigravity', '알림 및 시작', 'CLI 연동')) {
        $providerKey = switch ($section) { 'Claude' { 'claude' }; 'Codex' { 'gpt' }; 'Antigravity' { 'antigravity' } }
        $sectionParent = $content
        if ($providerKey) {
            $visible = switch ($providerKey) { 'claude' { $showClaude.Checked }; 'gpt' { $showGpt.Checked }; 'antigravity' { $showAntigravity.Checked } }
            $heading = New-SettingsCheck $sectionParent $section $visible
            $dialog.Tag.Checks[$providerKey] = $heading
        } else {
            $heading = [TraySettings.Label]::new()
            $heading.Text = $section; $heading.AutoSize = $true
            $sectionParent.Controls.Add($heading)
        }
        $heading.Font = $fontSettingsHeading
        $heading.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 6)
        switch ($section) {
            'Claude' {
                New-SettingsUsageRow $sectionParent $dialog.Tag '사용량' 'claude' @('5h', 'weekly')
            }
            'Codex' {
                New-SettingsUsageRow $sectionParent $dialog.Tag '기본' 'codex' @('5h', 'weekly')
                New-SettingsUsageRow $sectionParent $dialog.Tag '5.3spark' 'codex.spark' @('5h', 'weekly')
                New-SettingsUsageRow $sectionParent $dialog.Tag 'Reserve' 'codex.reserve' @('weekly')
                if (Test-CodexProPlan $state.gpt.plan) {
                    $dialog.Tag.UsageItems['codex.5h'].Text = '5h (Pro 숨김)'
                    $dialog.Tag.UsageItems['codex.5h'].Enabled = $false
                }
            }
            'Antigravity' {
                New-SettingsUsageRow $sectionParent $dialog.Tag 'Gemini' 'antigravity.gemini' @('5h', 'weekly')
                $check = New-SettingsCheck $sectionParent 'Claude (GPT 공용)' (Test-UsageItemVisible 'antigravity.claude')
                $check.Margin = [System.Windows.Forms.Padding]::new(24, 3, 0, 5)
                $dialog.Tag.UsageItems['antigravity.claude'] = $check
                $models = @(@($state.antigravity.rows | Where-Object {
                    $choice = Get-AntigravityChoiceKey ([string]$_.modelKey)
                    -not $choice -or ($choice -eq 'gemini' -and -not (Get-UsageWindowKey $_))
                } | ForEach-Object { $_.modelKey }) + @($script:antigravityModelVisibility.Keys |
                    Where-Object { -not (Get-AntigravityChoiceKey $_) }) | Where-Object { $_ } | Sort-Object -Unique)
                foreach ($model in $models) {
                    $visible = -not $script:antigravityModelVisibility.ContainsKey([string]$model) -or $script:antigravityModelVisibility[[string]$model]
                    $check = New-SettingsCheck $sectionParent $model $visible
                    $check.Margin = [System.Windows.Forms.Padding]::new(24, 3, 0, 5)
                    $dialog.Tag.Models[[string]$model] = $check
                }
            }
            '알림 및 시작' {
                $dialog.Tag.Checks.notify = New-SettingsCheck $sectionParent '사용량 90% 알림' $notifyItem.Checked
                $dialog.Tag.Checks.startup = New-SettingsCheck $sectionParent 'Windows 시작 시 실행' (Test-StartupEnabled)
            }
            'CLI 연동' {
                $hint = [TraySettings.Label]::new()
                $hint.Text = '아래 연동 설정은 즉시 적용되며 취소해도 유지됩니다.'
                $hint.AutoSize = $true; $hint.Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 5)
                $sectionParent.Controls.Add($hint)
                foreach ($provider in 'Claude', 'Antigravity') {
                    $button = [TraySettings.Button]::new()
                    $button.Text = "$provider 상태줄 연동 설정"; $button.Tag = $provider; $button.AutoSize = $true
                    $button.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 5)
                    $button.add_Click({ param($sender, $eventArgs); Install-UsageStatusLine ([string]$sender.Tag) })
                    $sectionParent.Controls.Add($button)
                }
            }
        }
    }
    $done.add_Click({
        param($sender, $eventArgs)
        $settingsForm = $sender.FindForm()
        $sender.Enabled = $false
        try {
            Save-TraySettings $settingsForm
            Start-TrayRestart
            $settingsForm.Tag.RestartReady = $true
            $settingsForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $settingsForm.Close()
        }
        catch {
            $settingsForm.Tag.Status.ForeColor = [System.Drawing.Color]::Firebrick
            $settingsForm.Tag.Status.Text = '저장 또는 재시작에 실패했습니다. ' + $_.Exception.Message
            $sender.Enabled = $true
        }
    })
    $dialog.ResumeLayout($true)
    # HWND를 이 DPI 문맥에서 만든 뒤 호출자의 문맥을 복원한다. 자식 컨트롤은 창의 DPI를 상속한다.
    $null = $dialog.Handle
    # 컨트롤을 전부 만든 뒤 한 번만 확대한다. 생성 중 자동 확대가 섞이면 고정 높이가 중복 확대된다.
    $dialog.AutoScaleDimensions = [System.Drawing.SizeF]::new(96, 96)
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.PerformAutoScale()
    $content.add_SizeChanged({ param($sender, $eventArgs); Update-SettingsLayout ($sender.FindForm()) })
    $workArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    Set-SettingsWindowBounds $dialog $workArea
    return $dialog
    }
    finally {
        if ($previousDpiContext -ne [IntPtr]::Zero) { [void][Win32.Native]::SetThreadDpiAwarenessContext($previousDpiContext) }
    }
}

function Show-SettingsDialog {
    $form.Hide()
    $previousDpiContext = [IntPtr]::Zero
    $dialog = $null
    try {
        # 생성뿐 아니라 표시·크기 변경·메시지 처리도 같은 DPI 좌표계에서 수행한다.
        try { $previousDpiContext = [Win32.Native]::SetThreadDpiAwarenessContext([IntPtr]::new(-2)) } catch { }
        $dialog = New-SettingsDialog
        [void]$dialog.ShowDialog()
        if ($dialog.Tag.RestartReady) {
            $notify.Visible = $false
            [System.Windows.Forms.Application]::Exit()
        }
    }
    finally {
        if ($dialog) { $dialog.Dispose() }
        if ($previousDpiContext -ne [IntPtr]::Zero) { [void][Win32.Native]::SetThreadDpiAwarenessContext($previousDpiContext) }
    }
}

# ---------- Antigravity(Gemini) 연동 ----------
# Antigravity CLI 는 상태줄 명령에 사용량 JSON 을 넘겨준다. 그 명령을 이 저장소의
# antigravity-statusline.ps1 로 등록해 두면 Gemini 항목이 캐시에 쌓인다.
function Install-UsageStatusLine([string]$provider) {
    $isClaude = $provider -eq 'Claude'
    $settings = if ($isClaude) { Join-Path (Get-ClaudeProfile) 'settings.json' }
        else { Join-Path $HOME '.gemini\antigravity-cli\settings.json' }
    $scriptName = if ($isClaude) { 'claude-statusline.ps1' } else { 'antigravity-statusline.ps1' }
    $callback = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $callback -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("$scriptName 파일이 없습니다.", 'AI 사용량', 'OK', 'Error') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $settings))) {
        [System.Windows.Forms.MessageBox]::Show("$provider CLI를 설치하고 로그인한 뒤 다시 시도하세요.", 'AI 사용량', 'OK', 'Warning') | Out-Null
        return
    }
    $command = Get-StatusLineCommand $callback
    try {
        $exists = Test-Path -LiteralPath $settings
        $json = if ($exists) { Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        $previous = $json.statusLine
        if ($previous.command -and $previous.command -ne $command) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "기존 상태줄 명령을 사용량 연동으로 바꿀까요? 기존 설정은 별도 백업에 보존됩니다.",
                'AI 사용량', 'YesNo', 'Question')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if ($exists) {
            $backup = $settings + '.ai-usage-tray.' + (Get-Date).ToString('yyyyMMddHHmmssfff') + '.bak'
            Copy-Item -LiteralPath $settings -Destination $backup -ErrorAction Stop
        }
        $statusLine = if ($previous) { $previous } else { [pscustomobject]@{} }
        $statusLine | Add-Member -NotePropertyName type -NotePropertyValue 'command' -Force
        $statusLine | Add-Member -NotePropertyName command -NotePropertyValue $command -Force
        if (-not $isClaude) {
            $statusLine | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force
            $statusLine | Add-Member -NotePropertyName stack_with_default -NotePropertyValue $true -Force
        }
        $json | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine -Force
        Set-JsonAtomic $json $settings 50
        [System.Windows.Forms.MessageBox]::Show(
            "$provider CLI를 다시 실행하고 한 번 사용하면 요금제·사용량이 갱신됩니다.", 'AI 사용량', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show('설정을 저장하지 못했습니다. 파일 접근 권한과 JSON 형식을 확인하세요.', 'AI 사용량', 'OK', 'Error') | Out-Null
    }
}

# ---------- 자동 시작 ----------
# HKCU Run 키에 등록(관리자 권한 불필요). 구버전이 만든 시작프로그램 바로가기는 중복 실행을 피하려고 정리한다.
$RUN_KEY     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RUN_NAME    = 'AiUsageTray'
$STARTUP_LNK = Join-Path ([Environment]::GetFolderPath('Startup')) 'ai-usage-tray.lnk'

function Get-StartupCommand {
    $exe = Join-Path $PSScriptRoot 'AiUsageTray.exe'
    if (Test-Path -LiteralPath $exe) { return """$exe""" }
    return "wscript.exe ""$(Join-Path $PSScriptRoot 'start-hidden.vbs')"""
}

function Test-StartupEnabled {
    if (Test-Path -LiteralPath $STARTUP_LNK) { return $true }
    return $null -ne (Get-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -ErrorAction SilentlyContinue)
}

function Set-Startup([bool]$on) {
    try {
        if (Test-Path -LiteralPath $STARTUP_LNK) { Remove-Item -LiteralPath $STARTUP_LNK -Force }
        if (-not (Test-Path -Path $RUN_KEY)) { New-Item -Path $RUN_KEY -Force | Out-Null }
        if ($on) {
            $command = Get-StartupCommand
            if ($command.Length -gt 260) { throw '자동 시작 명령이 260자를 넘습니다' }
            Set-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -Value $command
        }
        else { Remove-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -ErrorAction SilentlyContinue }
        $property = Get-ItemProperty -Path $RUN_KEY -Name $RUN_NAME -ErrorAction SilentlyContinue
        $actual = if ($property) { [string]$property.$RUN_NAME } else { $null }
        if ($on) { return $actual -eq $command -and -not (Test-Path -LiteralPath $STARTUP_LNK) }
        return $null -eq $actual -and -not (Test-Path -LiteralPath $STARTUP_LNK)
    }
    catch { return $false }
}

$notify = [System.Windows.Forms.NotifyIcon]::new()
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
Initialize-DisplayState
$menu.Items.Add('설정', $null, { Show-SettingsDialog }) | Out-Null
$menu.Items.Add('새로고침', $null, { Refresh-All -Force; if ($form.Visible) { Build-Popup } }) | Out-Null
$menu.Items.Add('종료', $null, { $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() }) | Out-Null
$notify.ContextMenuStrip = $menu
$notify.add_MouseUp({ param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Popup }
})

Refresh-All

# 팝업 렌더링 자가 확인: 창을 띄우지 않고 PNG로 저장 후 종료
if ($Snapshot) {
    Build-Popup
    # 화면 밖에서 Show(핸들 생성) 후 폼 자체 렌더링 캡처 — 전체화면 앱이 덮어도 영향 없음
    $form.Location = [System.Drawing.Point]::new(-20000, -20000)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $shot = [System.Drawing.Bitmap]::new($form.Width, $form.Height)
    $form.DrawToBitmap($shot, [System.Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height))
    $out = Join-Path $PSScriptRoot 'popup-preview.png'
    $shot.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $shot.Dispose()

    # 트레이 아이콘도 실제 크기로 그려 4배 확대 저장. 부드러운 보간을 쓰면 뭉갠 건지 아닌지 알 수 없으니
    # NearestNeighbor 로 픽셀을 그대로 키운다. 배경은 투명 대신 테마에 맞춘 작업표시줄 색 — 흰 글자가 보여야 한다.
    $isz = Get-TrayIconSize
    $tray = Draw-TrayIconBitmap $isz.Width $isz.Height
    $zoom = [System.Drawing.Bitmap]::new($isz.Width * 4, $isz.Height * 4)
    $zg = [System.Drawing.Graphics]::FromImage($zoom)
    $zbg = if ((Get-TrayTextColor) -eq [System.Drawing.Color]::Black) { [System.Drawing.Color]::FromArgb(243, 243, 243) }
    else { [System.Drawing.Color]::FromArgb(32, 32, 32) }
    $zg.Clear($zbg)
    $zg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $zg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $zg.DrawImage($tray, 0, 0, $zoom.Width, $zoom.Height)
    $zg.Dispose()
    $zout = Join-Path $PSScriptRoot 'tray-zoom.png'
    $zoom.Save($zout, [System.Drawing.Imaging.ImageFormat]::Png)
    $zoom.Dispose(); $tray.Dispose()

    "saved: $out"
    "saved: $zout"
    return
}

$notify.Visible = $true
# 이미 90% 를 넘긴 채로 켠 경우도 잡는다 — 위 Refresh-All 은 아이콘이 뜨기 전이라 건너뛰었다.
Test-UsageAlert

$collectorTimer = [System.Windows.Forms.Timer]::new()
$collectorTimer.Interval = 250
$collectorTimer.add_Tick({ Complete-CollectionJob })
$collectorTimer.Start()

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = $POLL_MS
$timer.add_Tick({
    Refresh-All
    if ($form.Visible) { Build-Popup }
})
$timer.Start()

[System.Windows.Forms.Application]::Run([System.Windows.Forms.ApplicationContext]::new())

$timer.Dispose()
$collectorTimer.Dispose()
if ($script:collectorJob) {
    Stop-Job -Job $script:collectorJob -ErrorAction SilentlyContinue
    Remove-Job -Job $script:collectorJob -Force -ErrorAction SilentlyContinue
}
$notify.Dispose()
if ($script:prevIconHandle -ne [IntPtr]::Zero) { [Win32.Native]::DestroyIcon($script:prevIconHandle) | Out-Null }
$mutex.ReleaseMutex()
