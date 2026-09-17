param([switch]$SelfTest)

$runSelfTest = $SelfTest
. (Join-Path $PSScriptRoot 'ai-usage-tray.ps1') -Library

if ($runSelfTest) {
    $result = Convert-AntigravityPayload ('{"plan_tier":"Ultra","email":"sample@example.invalid","quota":{"gemini-new":{"remaining_fraction":0.72},"claude-new":{"remaining_fraction":0.5}}}' | ConvertFrom-Json)
    if ($result.rows.Count -ne 2 -or $result.plan -ne 'Ultra' -or ($result.rows | Where-Object name -eq 'gemini-new').pct -ne 28) { throw 'Antigravity 상태줄 검사 실패' }
    'ok'
    return
}

try {
    $rawInput = $input | Out-String
    if ([string]::IsNullOrWhiteSpace($rawInput)) { return }
    $usageSnapshot = Convert-AntigravityPayload ($rawInput | ConvertFrom-Json)
    # 전체 입력 대신 계정·요금제·한도만 저장한다.
    Set-JsonAtomic $usageSnapshot $ANTIGRAVITY_CACHE
}
catch { exit 1 }
