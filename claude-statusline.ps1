param([switch]$SelfTest)

$runSelfTest = $SelfTest
. (Join-Path $PSScriptRoot 'ai-usage-tray.ps1') -Library

if ($runSelfTest) {
    $usageSnapshot = Convert-ClaudeStatusPayload ('{"rate_limits":{"five_hour":{"used_percentage":27,"resets_at":2000000000},"seven_day":{"used_percentage":46}}}' | ConvertFrom-Json)
    if ($usageSnapshot.rows.Count -ne 2 -or $usageSnapshot.rows[0].pct -ne 27) { throw 'Claude 상태줄 검사 실패' }
    'ok'
    return
}

try {
    $rawInput = $input | Out-String
    if ([string]::IsNullOrWhiteSpace($rawInput)) { return }
    $usageSnapshot = Convert-ClaudeStatusPayload ($rawInput | ConvertFrom-Json)
    $account = Get-ClaudeAccount
    if (-not $account -or -not $account.loggedIn -or -not $account.account) { return }
    $usageSnapshot | Add-Member -NotePropertyName account -NotePropertyValue $account.account
    $usageSnapshot | Add-Member -NotePropertyName plan -NotePropertyValue $account.plan
    $usageSnapshot | Add-Member -NotePropertyName profile -NotePropertyValue (Get-ClaudeProfile)
    Save-UsageCache $usageSnapshot $CLAUDE_STATUS_CACHE
}
catch { exit 1 }
