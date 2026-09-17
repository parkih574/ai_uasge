param([switch]$SingleHost)

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
if (-not $SingleHost) {
    foreach ($hostName in 'powershell.exe', 'pwsh.exe') {
        $shellPath = (Get-Command $hostName -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        & $shellPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -SingleHost
        if ($LASTEXITCODE -ne 0) { throw "$hostName verification failed" }
    }
    'PASS: Windows PowerShell 5.1 and PowerShell 7'
    return
}

function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Assert-Rejected([scriptblock]$action, [string]$message) {
    $rejected = $false
    try { & $action | Out-Null } catch { $rejected = $true }
    Assert $rejected $message
}

$sourcePath = Join-Path $projectDir 'ai-usage-tray.ps1'
$parseTokens = $null; $parseErrors = $null
foreach ($name in 'ai-usage-tray.ps1', 'antigravity-statusline.ps1', 'claude-statusline.ps1', 'build-exe.ps1') {
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectDir $name), [ref]$parseTokens, [ref]$parseErrors)
    Assert (-not $parseErrors) "$name syntax"
}
. $sourcePath -Library
Invoke-SyntheticSelfTest | Out-Null
$futureTime = [DateTimeOffset]::UtcNow.AddHours(2)
$window = @{ usedPercent = 42; windowDurationMins = 15; resetsAt = $futureTime.ToUnixTimeSeconds() }
$converted = Convert-CodexSnapshot @{
    rateLimits = @{ primary = @{ usedPercent = 99; windowDurationMins = 300 } }
    rateLimitsByLimitId = @{
        codex = @{ primary = $window; planType = 'plus' }
        new_model = @{ limitName = 'GPT-5.3-Codex-Spark'; primary = @{ usedPercent = 76; windowDurationMins = 90 } }
        credits_only = @{ primary = $null; secondary = $null }
    }
} @{ planType = 'business'; email = 'codex@example.invalid' }
Assert ($converted.rows.Count -eq 2 -and $converted.plan -eq 'business') 'All Codex buckets/account plan'
Assert (@($converted.rows | Where-Object { $_.name -like '*15 분' -and $_.pct -eq 42 }).Count -eq 1) '15-minute window'
Assert (@($converted.rows | Where-Object { $_.name -like '*90 분' -and $_.pct -eq 76 }).Count -eq 1) '90-minute window'
Assert ($converted.account -eq 'codex@example.invalid') 'Codex account identity'
$selectionUsage=Convert-CodexSnapshot @{rateLimitsByLimitId=@{
    codex=@{primary=@{usedPercent=42;windowDurationMins=300};secondary=@{usedPercent=55;windowDurationMins=10080}}
    spark=@{limitName='GPT-5.3-Codex-Spark';primary=@{usedPercent=76;windowDurationMins=300};secondary=@{usedPercent=64;windowDurationMins=10080}}
    base_model_inference=@{limitName='gpt-reserve';secondary=@{usedPercent=18;windowDurationMins=10080}}
}} @{planType='pro'}
Assert (@(Get-VisibleCodexRows $selectionUsage.rows 'plus').Count -eq 5) 'Plus includes all five selected windows'
$proRows=@(Get-VisibleCodexRows $selectionUsage.rows 'pro')
Assert ($proRows.Count -eq 4 -and @($proRows | Where-Object { $_.modelKey -eq 'codex' -and $_.name -match '5h' }).Count -eq 0 -and @($proRows | Where-Object { $_.isCodexSpark -and $_.name -match '5h' }).Count -eq 1) 'Pro hides base 5h but keeps Spark 5h'
$script:usageVisibility=@{'codex.spark.5h'=$false}
Assert (@(Get-VisibleCodexRows $selectionUsage.rows 'plus').Count -eq 4) 'Spark 5h hides independently'
$script:usageVisibility['codex.spark.weekly']=$false
Assert (@(Get-VisibleCodexRows $selectionUsage.rows 'plus').Count -eq 3) 'Spark weekly hides independently'
$storedCodex=@{rows=$selectionUsage.rows} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$workerCodexRows=@($storedCodex.rows | ForEach-Object { Convert-StoredUsageRow $_ })
Assert (@(Get-VisibleCodexRows $workerCodexRows 'plus').Count -eq 3) 'Spark identity survives worker serialization'
$script:usageVisibility['codex.reserve.weekly']=$false
Assert (@(Get-VisibleCodexRows $workerCodexRows 'plus').Count -eq 2) 'Reserve weekly has a separate selection'
$script:usageVisibility['codex.5h']=$false
Assert (@(Get-VisibleCodexRows $workerCodexRows 'plus').Count -eq 1) 'Base 5h has a separate selection'
$script:usageVisibility['codex.weekly']=$false
Assert (@(Get-VisibleCodexRows $workerCodexRows 'plus').Count -eq 0 -and $selectionUsage.rows.Count -eq 5) 'All hidden choices preserve collected data'
Assert (@(Get-VisibleCodexRows $converted.rows 'plus').Count -eq 2) 'Unknown window lengths remain available'
$script:usageVisibility=@{}
$legacyRows = @(Convert-ClaudeResponseToRows @{
    five_hour = @{ utilization = 10 }
    seven_day = @{ utilization = 20 }
    seven_day_new_model = @{ utilization = 91 }
    extra_usage = @{ utilization = $null; is_enabled = $false }
    unrelated = @{ value = 1 }
})
Assert ($legacyRows.Count -eq 3 -and @($legacyRows.pct) -contains 91) 'Claude dynamic legacy quotas'
Assert (($legacyRows.name -join '|') -eq '5h|weekly|weekly new model') 'Claude short labels and fixed window order'
$script:usageVisibility=@{'claude.5h'=$false}
Assert (@(Get-VisibleClaudeRows $legacyRows).Count -eq 2) 'Claude 5h selection keeps weekly model rows'
$script:usageVisibility=@{'claude.weekly'=$false}
Assert (@(Get-VisibleClaudeRows $legacyRows).Count -eq 1) 'Claude weekly selection covers all weekly model rows'
$script:usageVisibility=@{}
$reversedWindows=@{primary=@{usedPercent=70;windowDurationMins=10080};secondary=@{usedPercent=20;windowDurationMins=300}}
$orderedCodex=Convert-CodexSnapshot @{rateLimitsByLimitId=[ordered]@{z_model=$reversedWindows;a_model=$reversedWindows}} $null
Assert (($orderedCodex.rows.name -join '|') -eq 'a_model · 5h|a_model · weekly|z_model · 5h|z_model · weekly') 'Codex groups and windows sort independently of response order'
Assert ((Format-UsageLabel 'Model 5.3 / 15시간') -eq 'Model 5.3 / 15시간') 'Short labels preserve model versions and unrelated durations'
$spend = Convert-ClaudeStatusPayload @{ rate_limits = @{ spend_limit = @{ used_percentage = 123.5; resets_at = $futureTime.ToUnixTimeSeconds() } } }
Assert ($spend.rows[0].pct -eq 124) 'Documented spend limit can exceed 100 percent'
$restoredSpend = Convert-StoredUsageRow ($spend.rows[0] | ConvertTo-Json | ConvertFrom-Json)
Assert ($restoredSpend.pct -eq 124) 'Over-limit cache round trip'
$ag = Convert-AntigravityPayload @{
    plan_tier = 'Future Premium'; email = 'ag@example.invalid'
    quota = [ordered]@{
        'gemini-new' = @{ remaining_fraction = 0.72; reset_in_seconds = 60 }
        'claude-new' = @{ remaining_fraction = 0.5 }
        'gpt-new' = @{ remaining_fraction = 0.0 }
        'unknown' = @{ remaining_fraction = $null }
    }
}
Assert ($ag.plan -eq 'Future Premium' -and $ag.account -eq 'ag@example.invalid') 'Antigravity plan/account'
Assert ($ag.rows.Count -eq 3 -and ($ag.rows | Where-Object name -eq 'gemini-new').pct -eq 28 -and ($ag.rows | Where-Object name -eq 'gpt-new').pct -eq 100) 'All Antigravity model families'
Assert (($ag.rows | Where-Object name -eq 'gemini-new').reset -gt (Get-Date)) 'Antigravity relative reset'
foreach ($invalid in @($true, -0.1, 1.1, [double]::NaN, [double]::PositiveInfinity, 'bad')) {
    Assert-Rejected { Convert-AntigravityPayload @{ quota = @{ model = @{ remaining_fraction = $invalid } } } } 'Invalid fraction accepted'
}
Assert ((Convert-AntigravityPayload @{ quota = @{} }).rows.Count -eq 0) 'Empty quota is not zero usage'
Assert ((Convert-AntigravityPayload @{ plan_tier = 'Pro'; email = 'new@example.invalid' }).rows.Count -eq 0) 'Missing quota must clear old usage while keeping new account metadata'

$desktopStatus = @{ userStatus = @{
    email='AG@example.invalid'; userTier=@{name='Google AI Ultra'}; planStatus=@{planInfo=@{planName='Pro'}}
    cascadeModelConfigData=@{clientModelConfigs=@(@{label='Future Model'; modelOrAlias=@{model='future'}; quotaInfo=@{remainingFraction=0.4;resetTime=$futureTime.ToString('o')}})}
} }
$quotaGroups = @(@{ displayName='Future Family'; buckets=@(
    @{bucketId='session';displayName='5 hours';remainingFraction=0.8;resetTime=$futureTime.ToString('o')}
    @{bucketId='weekly';displayName='Weekly';remaining=@{case='remainingFraction';value=0.3}}
    @{bucketId='unavailable';remainingFraction=$null}
    @{bucketId='disabled';remainingFraction=0;disabled=$true}
) })
$desktopUsage = Convert-AntigravityLocalPayload $desktopStatus @{response=@{groups=$quotaGroups}} $null
Assert ($desktopUsage.plan -eq 'Google AI Ultra' -and $desktopUsage.rows.Count -eq 2) 'Desktop plan preference and quota groups'
Assert ($desktopUsage.rows[0].pct -eq 20 -and $desktopUsage.rows[1].pct -eq 70) 'Desktop remaining fraction / nested oneof'
$modelControlsUsage=Convert-AntigravityLocalPayload $desktopStatus @{groups=@(
    @{displayName='Gemini Models';buckets=@(@{displayName='Weekly Limit Remaining';remainingFraction=0.3},@{displayName='Five Hour Limit Remaining';remainingFraction=0.8})}
    @{displayName='Claude and GPT models';buckets=@(@{displayName='Weekly Limit Remaining';remainingFraction=0.3},@{displayName='Five Hour Limit Remaining';remainingFraction=0.8})}
)} $null
Assert (($modelControlsUsage.rows.name -join '|') -eq 'Claude and GPT models / 5h|Claude and GPT models / weekly|Gemini Models / 5h|Gemini Models / weekly') 'Antigravity long labels shorten and sort within each group'
$script:usageVisibility=@{'antigravity.gemini.5h'=$false}
Assert (@(Get-VisibleAntigravityRows $modelControlsUsage.rows).Count -eq 3) 'Antigravity Gemini 5h hides independently'
$script:usageVisibility['antigravity.gemini.weekly']=$false
Assert (@(Get-VisibleAntigravityRows $modelControlsUsage.rows).Count -eq 2) 'Antigravity Gemini weekly hides independently'
$script:usageVisibility['antigravity.claude']=$false
Assert (@(Get-VisibleAntigravityRows $modelControlsUsage.rows).Count -eq 0) 'Antigravity Claude choice covers both shared Claude/GPT windows'
Assert (@(Get-VisibleAntigravityRows $desktopUsage.rows).Count -eq 2) 'Unrecognized Antigravity groups remain available'
$script:antigravityModelVisibility=@{'Future Family'=$false}
Assert (@(Get-VisibleAntigravityRows $desktopUsage.rows).Count -eq 0) 'Unrecognized Antigravity groups keep their saved selection'
$script:antigravityModelVisibility=@{'gemini-new'=$false}
Assert (@(Get-VisibleAntigravityRows $ag.rows).Count -eq 0) 'Periodless Gemini fallback respects legacy model hiding while known choices are off'
$script:antigravityModelVisibility['gemini-new']=$true
Assert (@(Get-VisibleAntigravityRows $ag.rows).Count -eq 1) 'Periodless Gemini fallback can be reenabled without inventing its duration'
$script:usageVisibility=@{}
$script:antigravityModelVisibility=@{}
foreach ($summaryShape in @(@{summary=@{groups=$quotaGroups}}, @{groups=$quotaGroups})) {
    Assert ((Convert-AntigravityLocalPayload $desktopStatus $summaryShape $null).rows.Count -eq 2) 'Summary response wrappers'
}
$modelUsage = Convert-AntigravityLocalPayload $desktopStatus $null $null
Assert ($modelUsage.rows.Count -eq 1 -and $modelUsage.rows[0].pct -eq 60) 'Older IDE model quota fallback'
$configUsage = Convert-AntigravityLocalPayload $null $null @{clientModelConfigs=$desktopStatus.userStatus.cascadeModelConfigData.clientModelConfigs}
Assert ($configUsage.rows.Count -eq 1 -and -not $configUsage.account) 'Model config fallback must not invent account'
Assert ((Convert-AntigravityLocalPayload $null @{groups=@(@{buckets=@(@{id='unknown'})})} $null).rows.Count -eq 0) 'Missing desktop quota is not zero'
$desktopUsage | Add-Member -NotePropertyName live -NotePropertyValue $true
$desktopUsage.source = 'Antigravity 데스크톱'
$modelUsage | Add-Member -NotePropertyName live -NotePropertyValue $true
$modelUsage.source = 'Antigravity CLI 로컬 서버'
$merged = @(Merge-AntigravitySnapshots @($desktopUsage, $ag, $modelUsage))
Assert ($merged.Count -eq 1 -and $merged[0].rows.Count -eq 2 -and $merged[0].rows[0].pct -eq 20) 'Same-account sources must not add or duplicate usage; summary wins'
Assert ($merged[0].source -match '데스크톱' -and $merged[0].source -match 'CLI') 'Merged source labels'
$differentAccount = Convert-AntigravityPayload @{email='other@example.invalid';plan_tier='Pro';quota=@{model=@{remaining_fraction=0.5}}}
Assert (@(Merge-AntigravitySnapshots @($desktopUsage, $differentAccount)).Count -eq 2) 'Different accounts must remain separate'
Assert (@(Merge-AntigravitySnapshots @($configUsage, $configUsage)).Count -eq 2) 'Unknown account sources must not merge'
$metadataOnly=Convert-AntigravityLocalPayload @{userStatus=@{email='ag@example.invalid';userTier=@{name='Current Ultra'}}} $null $null
$metadataOnly | Add-Member -NotePropertyName live -NotePropertyValue $true
$withCache=@(Merge-AntigravitySnapshots @($metadataOnly,$ag))
Assert ($withCache.Count -eq 1 -and $withCache[0].plan -eq 'Current Ultra' -and -not $withCache[0].live -and $withCache[0].rows.Count -eq 3) 'Live plan with clearly dated CLI usage'
$storedDesktop=$desktopUsage.PSObject.Copy(); $storedDesktop.live=$false; $storedDesktop.updated=(Get-Date).AddMinutes(-10)
$newestOffline=@(Merge-AntigravitySnapshots @($storedDesktop,$ag))
Assert ($newestOffline.Count -eq 1 -and $newestOffline[0].rows.Count -eq 3 -and $newestOffline[0].updated -eq $ag.updated) 'Newer offline CLI usage takes precedence over an older desktop summary'
$unknownFraction = @{groups=@(@{buckets=@(@{id='bad';remainingFraction=$true})})}
Assert-Rejected { Convert-AntigravityLocalPayload $null $unknownFraction $null } 'Invalid desktop fraction accepted'

$fakeProcesses = @(
    @{ProcessId=501;OwnerSid='test-user';Name='language_server_windows_x64.exe';ExecutablePath='C:\Apps\Antigravity\bin\language_server_windows_x64.exe';CommandLine='language_server_windows_x64.exe --csrf_token="synthetic-csrf"'}
    @{ProcessId=502;OwnerSid='other-user';Name='agy.exe';ExecutablePath='C:\Tools\agy.exe';CommandLine='agy.exe'}
    @{ProcessId=503;OwnerSid='test-user';Name='language_server.exe';ExecutablePath='C:\Other\language_server.exe';CommandLine='language_server.exe --csrf_token=fake'}
    @{ProcessId=504;OwnerSid='test-user';Name='language_server.exe';ExecutablePath='C:\Antigravity\language_server.exe';CommandLine='language_server.exe'}
    @{ProcessId=505;OwnerSid='test-user';Name='agy.exe';ExecutablePath='C:\Tools\agy.exe';CommandLine='agy.exe'}
)
$fakeListeners = @(501..505 | ForEach-Object { @{OwningProcess=$_;State='Listen';LocalAddress='127.0.0.1';LocalPort=19000+$_} })
$fakeListeners += @{OwningProcess=501;State='Listen';LocalAddress='192.0.2.1';LocalPort=32000}
$fakeListeners += @{OwningProcess=999;State='Listen';LocalAddress='127.0.0.1';LocalPort=33000}
$targets = @(Get-AntigravityTargets $fakeProcesses $fakeListeners 'test-user')
Assert ($targets.Count -eq 4 -and @($targets.processId | Select-Object -Unique).Count -eq 2) 'Only same-user identified app/CLI listener targets'
Assert (@($targets | Where-Object {$_.processId -eq 501 -and $_.csrf -eq 'synthetic-csrf'}).Count -eq 2) 'Quoted desktop CSRF flag'
Assert (@($targets | Where-Object {$_.processId -eq 505 -and -not $_.csrf}).Count -eq 2) 'CLI may be tokenless'
# 실제 프로세스 명령줄과 계정에는 접근하지 않는다. 이후 수집은 합성 대상만 사용한다.
function Find-AntigravityTargets { return @() }
$noLocalUsage=@(Get-AntigravityLocalSnapshots)
Assert ($noLocalUsage.Count -eq 0 -and $script:antigravityLocalIssue -match '조회 서버를 찾지') 'Missing app has an actionable diagnostic'

$workRoot = [System.IO.Path]::GetFullPath((Join-Path $projectDir 'work'))
$testDir = Join-Path $workRoot ('verification-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
try {
    $STATE_CACHE = Join-Path $testDir 'claude-state.json'
    $CLAUDE_STATUS_CACHE = Join-Path $testDir 'claude-status.json'
    $CODEX_STATE_CACHE = Join-Path $testDir 'codex-state.json'
    $cachePath = Join-Path $testDir 'usage.json'
    Set-JsonAtomic @{ account = 'a@example.invalid'; profile = 'profile-a'; updated = Get-Date; source = '합성 상태줄'; rows = $legacyRows } $cachePath
    Assert ($null -eq (Read-UsageCache $cachePath 'b@example.invalid' 'profile-a')) 'Cross-account cache leaked'
    Assert ($null -eq (Read-UsageCache $cachePath 'a@example.invalid' 'profile-b')) 'Cross-profile cache leaked'
    Assert ((Read-UsageCache $cachePath 'a@example.invalid' 'profile-a').rows.Count -eq 3) 'Matching cache lost'
    Assert ((Read-UsageCache $cachePath 'a@example.invalid' 'profile-a').source -eq '합성 상태줄') 'UTF-8 usage cache source'
    $accountTime=(Get-Date).Date.AddHours(1)
    $accountA=@{account='a@example.invalid';profile='profile-a';plan='Pro';source='합성 기록';updated=$accountTime;rows=@(New-UsageRow '5h' 21 $futureTime.LocalDateTime)}
    $accountB=@{account='b@example.invalid';profile='profile-a';plan='Max';source='합성 기록';updated=$accountTime.AddMinutes(1);rows=@(New-UsageRow '5h' 74 $futureTime.LocalDateTime)}
    Set-JsonAtomic $accountA $cachePath
    Save-UsageCache $accountB $cachePath
    $restoredA=Read-UsageCache $cachePath 'a@example.invalid' 'profile-a'
    Assert ($restoredA.rows[0].pct -eq 21 -and $restoredA.plan -eq 'Pro' -and $restoredA.updated -eq $accountTime) 'Switching A to B migrates and preserves A usage, plan and original time'
    Assert ((Read-UsageCache $cachePath 'B@example.invalid' 'profile-a').rows[0].pct -eq 74) 'Each account has its own case-insensitive record'
    Assert ($null -eq (Read-UsageCache $cachePath 'c@example.invalid' 'profile-a') -and $null -eq (Read-UsageCache $cachePath 'a@example.invalid' 'profile-b')) 'Account history cannot leak across users or profiles'
    $olderA=$accountA.Clone(); $olderA.updated=$accountTime.AddMinutes(-1); $olderA.rows=@(New-UsageRow '5h' 9 $null)
    Save-UsageCache $olderA $cachePath
    Assert ((Read-UsageCache $cachePath 'a@example.invalid' 'profile-a').rows[0].pct -eq 21) 'Late older writes cannot replace newer account history'
    [IO.File]::WriteAllText($cachePath,'{broken')
    Assert ((Read-UsageCache $cachePath 'b@example.invalid' 'profile-a').rows[0].pct -eq 74) 'Broken latest cache does not destroy other account records'
    Set-JsonAtomic @{account='a@example.invalid';profile='profile-a';updated=$accountTime.AddDays(1);rows=@(@{name='5h';pct='invalid'})} $cachePath
    Save-UsageCache $accountB $cachePath
    Assert ((Read-UsageCache $cachePath 'b@example.invalid' 'profile-a').rows[0].pct -eq 74 -and (Read-UsageCache $cachePath 'a@example.invalid' 'profile-a').rows[0].pct -eq 21) 'Malformed legacy rows do not block valid new data or overwrite existing history'
    $ANTIGRAVITY_CACHE = Join-Path $testDir 'antigravity.json'
    $ANTIGRAVITY_STATE_CACHE = Join-Path $testDir 'antigravity-state.json'
    Set-JsonAtomic @{ plan='Pro'; account='ag@example.invalid'; rows=@(); updated=Get-Date } $ANTIGRAVITY_CACHE
    Get-AntigravityUsage
    Assert ($state.antigravity.success -and $state.antigravity.plan -eq 'Pro' -and $state.antigravity.rows.Count -eq 0) 'Plan-only Antigravity snapshot'
    Assert ($state.antigravity.groups[0].err -match '앱 실행 후 새로고침') 'Cached usage explains missing live server'

    # 실제 HTTP 어댑터를 임시 loopback 서버에 연결한다. 사용자 앱/계정은 실행하지 않는다.
    $serverPath = Join-Path $testDir 'fake-antigravity-server.ps1'
    $serverSource = @'
$ErrorActionPreference='Stop'
$listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,0)
$listener.Start()
[Console]::WriteLine($listener.LocalEndpoint.Port)
try {
    for ($i=0; $i -lt 3; $i++) {
        $client=$listener.AcceptTcpClient()
        try {
            $stream=$client.GetStream()
            $reader=[System.IO.StreamReader]::new($stream,[System.Text.Encoding]::UTF8)
            $requestLine=$reader.ReadLine()
            $length=0; $csrf=''; $protocol=''
            while ($line=$reader.ReadLine()) {
                if ($line -match '^Content-Length: (\d+)') { $length=[int]$Matches[1] }
                if ($line -match '^X-Codeium-Csrf-Token: (.+)') { $csrf=$Matches[1] }
                if ($line -match '^Connect-Protocol-Version: (.+)') { $protocol=$Matches[1] }
                if ($line -match '^Expect: 100-continue') {
                    $continue=[System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                    $stream.Write($continue,0,$continue.Length)
                }
            }
            $chars=New-Object char[] $length
            $offset=0
            while ($offset -lt $length) { $count=$reader.Read($chars,$offset,$length-$offset); if ($count -le 0) { throw 'body missing' }; $offset+=$count }
            @{path=$requestLine;csrf=$csrf;protocol=$protocol;body=(-join $chars)} | ConvertTo-Json -Compress | ForEach-Object {[Console]::WriteLine($_)}
            $body=if ($requestLine -match '/GetUserStatus ') { '{"userStatus":{"email":"ag@example.invalid","userTier":{"name":"Ultra"}}}' }
                else { '{"response":{"groups":[{"displayName":"Family","buckets":[{"bucketId":"five_hour","remainingFraction":0.25}]}]}}' }
            $status=if ($i -eq 2) { "302 Found`r`nLocation: http://127.0.0.1:1/" } else {'200 OK'}
            $bytes=[System.Text.Encoding]::UTF8.GetBytes($body)
            $header=[System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($header,0,$header.Length); $stream.Write($bytes,0,$bytes.Length)
        } finally { $client.Dispose() }
    }
} finally { $listener.Stop() }
'@
    [System.IO.File]::WriteAllText($serverPath,$serverSource,[System.Text.UTF8Encoding]::new($true))
    $serverProcess=New-ProviderProcess 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -File "' + $serverPath + '"')
    try {
        Assert ($serverProcess.Start()) 'Synthetic Antigravity server start'
        $serverError=$serverProcess.StandardError.ReadToEndAsync()
        $portRead=$serverProcess.StandardOutput.ReadLineAsync()
        Assert ($portRead.Wait(5000)) 'Synthetic server port timeout'
        $fakeTarget=@{address='127.0.0.1';port=[int]$portRead.Result;scheme='http';csrf='synthetic-csrf';source='Antigravity 데스크톱';processId=501}
        function Find-AntigravityTargets { return $fakeTarget }
        $localUsage=@(Get-AntigravityLocalSnapshots)
        Assert ($localUsage.Count -eq 1 -and $localUsage[0].rows[0].pct -eq 75 -and $localUsage[0].account -eq 'ag@example.invalid') 'Actual local HTTP quota/identity flow'
        Assert (-not $script:antigravityLocalIssue) 'Successful local request clears previous diagnostic'
        Assert (($localUsage | ConvertTo-Json -Depth 10) -notmatch 'synthetic-csrf') 'Local token escaped into snapshot'
        $sent=@(1..2 | ForEach-Object { $serverProcess.StandardOutput.ReadLine() | ConvertFrom-Json })
        Assert ($sent[0].csrf -eq 'synthetic-csrf' -and $sent[0].protocol -eq '1') 'Local protocol headers'
        Assert (($sent[1].body | ConvertFrom-Json).forceRefresh) 'Quota refresh request'
        Assert-Rejected { Invoke-AntigravityLocalRequest $fakeTarget 'GetCommandModelConfigs' } 'Redirected local request accepted'
        Assert ($serverProcess.WaitForExit(3000) -and $serverProcess.ExitCode -eq 0) 'Synthetic local server completion'
        Assert-Rejected { Invoke-AntigravityLocalRequest @{address='192.0.2.1';port=80;scheme='http'} 'GetUserStatus' } 'Non-loopback endpoint accepted'
        Assert-Rejected { Invoke-AntigravityLocalRequest $fakeTarget 'MutatingMethod' } 'Unknown local method accepted'
        $realLocalRequest=${function:Invoke-AntigravityLocalRequest}
        try {
            function Invoke-AntigravityLocalRequest($target,$method,$timeoutMs) {
                switch ($method) {
                    'GetUserStatus' { return @{userStatus=@{email='ag@example.invalid';userTier=@{name='Ultra'}}} }
                    'RetrieveUserQuotaSummary' { throw 'synthetic older IDE: method unavailable' }
                    'GetCommandModelConfigs' { return @{clientModelConfigs=$desktopStatus.userStatus.cascadeModelConfigData.clientModelConfigs} }
                }
            }
            $olderIde=@(Get-AntigravityLocalSnapshots)
            Assert ($olderIde.Count -eq 1 -and $olderIde[0].rows[0].pct -eq 60 -and $olderIde[0].plan -eq 'Ultra') 'Older IDE actual collector fallback'
            function Invoke-AntigravityLocalRequest($target,$method,$timeoutMs) {
                if ($method -eq 'GetUserStatus') { return $desktopStatus }
                if ($method -eq 'RetrieveUserQuotaSummary') { return $unknownFraction }
                return @{}
            }
            $malformedSummary=@(Get-AntigravityLocalSnapshots)
            Assert ($malformedSummary.Count -eq 1 -and $malformedSummary[0].rows[0].pct -eq 60) 'Malformed summary must preserve valid model fallback'
            function Invoke-AntigravityLocalRequest($target,$method,$timeoutMs) { throw 'synthetic protocol failure' }
            $failedLocal=@(Get-AntigravityLocalSnapshots)
            Assert ($failedLocal.Count -eq 0 -and $script:antigravityLocalIssue -match '서버는 실행 중') 'Running server failure differs from stopped app'
        } finally { Set-Item Function:\Invoke-AntigravityLocalRequest -Value $realLocalRequest }
        function Get-AntigravityLocalSnapshots { return @($desktopUsage) }
        Set-JsonAtomic @{updated=Get-Date;rows=@(New-UsageRow 'gemini-5h' 25 $null)} $ANTIGRAVITY_CACHE
        Get-AntigravityUsage
        Assert ($state.antigravity.groups.Count -eq 1 -and $state.antigravity.rows.Count -eq 2) 'Obsolete cache must not add a duplicate desktop section'
        $lastDesktopTime=$state.antigravity.asOf
        $lastDesktopCache=[System.IO.File]::ReadAllText($ANTIGRAVITY_STATE_CACHE)
        function Get-AntigravityLocalSnapshots { $script:antigravityLocalIssue='실시간 조회 서버를 찾지 못했습니다. 앱 실행 후 새로고침하세요'; return @() }
        # 수집 프로세스나 트레이를 재시작해 메모리 상태가 없어져도 복원되어야 한다.
        $state.antigravity=@{rows=@();groups=@()}
        Get-AntigravityUsage
        Assert ($state.antigravity.success -and -not $state.antigravity.clear -and $state.antigravity.groups.Count -eq 1 -and $state.antigravity.rows.Count -eq 2) 'Stopped desktop restores last successful rows, never obsolete CLI data'
        Assert ($state.antigravity.plan -eq $desktopUsage.plan -and $state.antigravity.account -eq $desktopUsage.account -and $state.antigravity.asOf -eq $lastDesktopTime) 'Stopped desktop preserves plan, account and original collection time'
        Assert ($state.antigravity.groups[0].err -match '마지막 조회 기록' -and @($state.antigravity.rows | Where-Object { -not $_.stale }).Count -eq 0) 'Cached desktop usage is clearly offline and cannot trigger alerts'
        Assert ([System.IO.File]::ReadAllText($ANTIGRAVITY_STATE_CACHE) -eq $lastDesktopCache) 'Failed polling must not rewrite last successful snapshot'
        $offlineAgState=$state.antigravity.Clone()
        function Get-AntigravityLocalSnapshots { return @($metadataOnly) }
        Get-AntigravityUsage
        Assert ($state.antigravity.plan -eq 'Current Ultra' -and $state.antigravity.rows.Count -eq 2 -and $state.antigravity.asOf -eq $lastDesktopTime) 'Live plan-only response keeps same-account last usage with its original time'
        function Get-AntigravityLocalSnapshots { return @($desktopUsage) }
        $desktopUsage.rows[0].pct=35
        $desktopUsage.updated=(Get-Date).AddSeconds(1)
        $lastReopenedTime=$desktopUsage.updated
        Get-AntigravityUsage
        Assert ($state.antigravity.rows[0].pct -eq 35 -and -not $state.antigravity.rows[0].stale -and -not $state.antigravity.groups[0].err) 'Reopened desktop replaces cached values and clears offline status'
        $desktopUsage.rows[0].pct=20
        $newAccountUsage=Convert-AntigravityLocalPayload @{userStatus=@{email='new@example.invalid';userTier=@{name='New Plan'}}} $null $null
        $newAccountUsage | Add-Member -NotePropertyName live -NotePropertyValue $true
        function Get-AntigravityLocalSnapshots { return @($newAccountUsage) }
        Get-AntigravityUsage
        Assert ($state.antigravity.account -eq 'new@example.invalid' -and $state.antigravity.rows.Count -eq 0 -and $state.antigravity.groups.Count -eq 1) 'Account switch never inherits another account cached usage'
        function Get-AntigravityLocalSnapshots { return @() }
        Get-AntigravityUsage
        Assert ($state.antigravity.account -eq 'new@example.invalid' -and $state.antigravity.plan -eq 'New Plan' -and $state.antigravity.rows.Count -eq 0) 'Closing after account switch restores only the new account metadata'
        function Get-AntigravityLocalSnapshots { return @($metadataOnly) }
        $state.antigravity=@{rows=@();groups=@()}
        Get-AntigravityUsage
        Assert ($state.antigravity.account -eq 'ag@example.invalid' -and $state.antigravity.rows[0].pct -eq 35 -and $state.antigravity.plan -eq 'Current Ultra' -and $state.antigravity.asOf -eq $lastReopenedTime) 'Returning to A after B and restart restores only A last quotas with original time'
        function Get-AntigravityLocalSnapshots { return @() }
        [System.IO.File]::WriteAllText($ANTIGRAVITY_STATE_CACHE,'{broken')
        Get-AntigravityUsage
        Assert ($state.antigravity.clear -and $state.antigravity.rows.Count -eq 0) 'Corrupt last-state cache and obsolete CLI cache never fabricate data'
        function Get-AntigravityLocalSnapshots { return @($desktopUsage) }
        Set-JsonAtomic $ag $ANTIGRAVITY_CACHE
        Get-AntigravityUsage
        Assert ($state.antigravity.groups.Count -eq 1 -and $state.antigravity.rows.Count -eq 2) 'Collector account deduplication'
        Set-JsonAtomic $differentAccount $ANTIGRAVITY_CACHE
        Get-AntigravityUsage
        Assert ($state.antigravity.groups.Count -eq 2 -and $state.antigravity.rows.Count -eq 3) "Collector separate accounts: $($state.antigravity.groups.Count) groups / $($state.antigravity.rows.Count) rows"
        $separateAgState=$state.antigravity.Clone()
        function Get-AntigravityLocalSnapshots { throw 'synthetic desktop unavailable' }
        Get-AntigravityUsage
        Assert ($state.antigravity.groups.Count -eq 2 -and @($state.antigravity.groups | Where-Object account -eq 'other@example.invalid').Count -eq 1) 'Desktop offline cache and CLI fallback keep separate accounts without duplicates'
    } finally { Stop-ProviderProcess $serverProcess }

    $fakeScript = Join-Path $testDir 'fake-provider.ps1'
    $fakeCmd = Join-Path $testDir 'fake-provider.cmd'
    $fakeSource = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$RequestArgs)
if ($RequestArgs[0] -eq 'auth') {
    '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"claude@example.invalid"}'
    exit 0
}
while ($null -ne ($line = [Console]::ReadLine())) {
    $request = $line | ConvertFrom-Json
    switch ($request.method) {
        'initialize' { @{ id=$request.id; result=@{} } | ConvertTo-Json -Compress }
        'initialized' { }
        'account/read' {
            if ($request.params.refreshToken) { exit 4 }
            @{ id=$request.id; result=@{account=@{type='chatgpt';email='codex@example.invalid';planType='pro'}} } | ConvertTo-Json -Depth 5 -Compress
        }
        'account/rateLimits/read' {
            if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fail-quota')) {
                @{id=$request.id;error=@{code=-32000;message='synthetic quota failure'}} | ConvertTo-Json -Compress
                continue
            }
            @{ id=$request.id; result=@{rateLimitsByLimitId=@{
                codex=@{primary=@{usedPercent=12;windowDurationMins=300}}
                additional=@{primary=@{usedPercent=87;windowDurationMins=15}}
            }} } | ConvertTo-Json -Depth 7 -Compress
        }
        default { exit 5 }
    }
}
'@
    [System.IO.File]::WriteAllText($fakeScript, $fakeSource, [System.Text.UTF8Encoding]::new($true))
    [System.IO.File]::WriteAllText($fakeCmd, '@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-provider.ps1" %*', [System.Text.Encoding]::ASCII)
    function Get-CodexApplication { return $fakeCmd }
    function Get-ClaudeApplication { return $fakeCmd }
    $rpcSnapshot = Get-CodexAppServerSnapshot
    $rpcUsage = Convert-CodexSnapshot $rpcSnapshot.result $rpcSnapshot.account
    Assert ($rpcUsage.rows.Count -eq 2 -and $rpcUsage.plan -eq 'pro') 'Actual JSON-RPC process handshake'
    [IO.File]::WriteAllText((Join-Path $testDir 'fail-quota'),'1')
    $failedQuotaSnapshot=Get-CodexAppServerSnapshot
    Assert ($failedQuotaSnapshot.account.email -eq 'codex@example.invalid' -and -not $failedQuotaSnapshot.unavailable -and $null -eq $failedQuotaSnapshot.result) 'Quota RPC failure retains the confirmed account for isolated history lookup'
    Remove-Item -LiteralPath (Join-Path $testDir 'fail-quota')
    $cliAccount = Get-ClaudeAccount
    Assert ($cliAccount.loggedIn -and $cliAccount.plan -eq 'max' -and $cliAccount.account -eq 'claude@example.invalid') 'Claude auth status process'

    # CLI 등록은 예전 경로를 교체하고 해제 시 등록 항목만 지운다. 실사용 설정에는 접근하지 않는다.
    foreach ($provider in 'claude', 'antigravity') {
        $integrationSettings=Join-Path $testDir ($provider + '-settings.json')
        $callback=Join-Path $projectDir ($provider + '-statusline.ps1')
        $oldCallback="C:\old install\$provider-statusline.ps1"
        foreach ($oldCommand in @((Get-StatusLineCommand $oldCallback), "powershell.exe -File `"$oldCallback`"")) {
            Set-JsonAtomic @{theme='keep';custom=@{value=42};statusLine=@{type='command';command=$oldCommand;obsolete='remove'}} $integrationSettings
            Assert (Test-UsageStatusLineCommand $oldCommand ([IO.Path]::GetFileName($callback))) 'Recognize previous encoded and plain registration paths'
            Assert (Write-UsageStatusLineSettings $integrationSettings $callback ($provider -eq 'claude')) 'Register current callback'
            $installed=Get-Content -LiteralPath $integrationSettings -Raw | ConvertFrom-Json
            Assert ($installed.statusLine.command -eq (Get-StatusLineCommand $callback) -and -not $installed.statusLine.obsolete -and $installed.theme -eq 'keep' -and $installed.custom.value -eq 42) 'Replace old registration without changing other settings'
            if ($provider -eq 'antigravity') { Assert ($installed.statusLine.enabled -and $installed.statusLine.stack_with_default) 'Antigravity registration enables the callback alongside its default status line' }
            Assert (Write-UsageStatusLineSettings $integrationSettings $callback ($provider -eq 'claude') -Remove) 'Remove current callback registration'
            $removed=Get-Content -LiteralPath $integrationSettings -Raw | ConvertFrom-Json
            Assert (-not (Test-Field $removed 'statusLine') -and $removed.custom.value -eq 42) 'Disconnect deletes the registered path and retains unrelated settings'
            Assert (-not (Write-UsageStatusLineSettings $integrationSettings $callback ($provider -eq 'claude') -Remove)) 'Repeated disconnect is a no-op'
            Set-JsonAtomic @{statusLine=@{command=$oldCommand}} $integrationSettings
            Assert (Write-UsageStatusLineSettings $integrationSettings $oldCallback ($provider -eq 'claude') -Remove) 'Old paths can be disconnected even when the callback file no longer exists'
        }
        Set-JsonAtomic @{statusLine=@{command='unrelated-custom-status.exe'};theme='keep'} $integrationSettings
        $beforeUnrelated=[IO.File]::ReadAllText($integrationSettings)
        Assert (-not (Write-UsageStatusLineSettings $integrationSettings $callback ($provider -eq 'claude') -Remove) -and [IO.File]::ReadAllText($integrationSettings) -eq $beforeUnrelated) 'Disconnect preserves a status line owned by another tool'
        [IO.File]::WriteAllText($integrationSettings,'{broken')
        Assert-Rejected { Write-UsageStatusLineSettings $integrationSettings $callback ($provider -eq 'claude') } 'Invalid settings refuse registration'
        Assert ([IO.File]::ReadAllText($integrationSettings) -eq '{broken') 'Invalid settings are not overwritten'
        Assert (@(Get-ChildItem -LiteralPath $testDir -Filter ($provider + '-settings.json.ai-usage-tray.*.bak')).Count -ge 6) 'Original settings are backed up before registration changes'
    }
    Assert (-not (Write-UsageStatusLineSettings (Join-Path $testDir 'missing-settings.json') $callback $false -Remove)) 'Disconnect does not create a missing settings file'

    # 상태줄 입력은 공백·작은따옴표가 포함된 설치 경로에서도 그대로 전달되어야 한다.
    $echoScript = Join-Path $testDir "echo ' quoted path.ps1"
    [System.IO.File]::WriteAllText($echoScript, '$input | Out-String', [System.Text.UTF8Encoding]::new($true))
    $encodedCommand = Get-StatusLineCommand $echoScript
    $echoProcess = New-ProviderProcess 'powershell.exe' ($encodedCommand -replace '^powershell\.exe ', '')
    try {
        Assert ($echoProcess.Start()) 'Status line child start'
        $echoOutput = $echoProcess.StandardOutput.ReadToEndAsync()
        $echoError = $echoProcess.StandardError.ReadToEndAsync()
        $echoProcess.StandardInput.WriteLine('{"quota":{"model":{"remaining_fraction":0.25}}}')
        $echoProcess.StandardInput.Close()
        Assert ($echoProcess.WaitForExit(5000)) 'Status line timeout'
        Assert ($echoOutput.Wait(1000)) 'Status line output timeout'
        $echoPayload = $echoOutput.Result | ConvertFrom-Json
        Assert ($echoProcess.ExitCode -eq 0 -and $echoPayload.quota.model.remaining_fraction -eq 0.25) 'Quoted path/stdin transfer'
    } finally { Stop-ProviderProcess $echoProcess }

    # 실제 콜백도 실행하되 자식 프로세스의 저장 폴더·실행 경로는 합성 환경으로 격리한다.
    Copy-Item -LiteralPath $fakeCmd -Destination (Join-Path $testDir 'claude.cmd')
    foreach ($provider in 'claude', 'antigravity') {
        $callbackPath = Join-Path $projectDir ($provider + '-statusline.ps1')
        $callbackCommand = Get-StatusLineCommand $callbackPath
        $callbackProcess = New-ProviderProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') ($callbackCommand -replace '^powershell\.exe ', '')
        $callbackProcess.StartInfo.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $testDir 'local-data'
        $callbackProcess.StartInfo.EnvironmentVariables['PATH'] = $testDir + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
        $payloadJson = if ($provider -eq 'claude') { '{"rate_limits":{"five_hour":{"used_percentage":31}},"workspace":{"current_dir":"not-for-cache"}}' }
            else { '{"plan_tier":"Ultra","email":"ag@example.invalid","quota":{"new-model":{"remaining_fraction":0.2}},"workspace":{"current_dir":"not-for-cache"}}' }
        try {
            Assert ($callbackProcess.Start()) 'Real status line start'
            $callbackOut = $callbackProcess.StandardOutput.ReadToEndAsync()
            $callbackErr = $callbackProcess.StandardError.ReadToEndAsync()
            $callbackProcess.StandardInput.WriteLine($payloadJson)
            $callbackProcess.StandardInput.Close()
            Assert ($callbackProcess.WaitForExit(10000)) 'Real status line timeout'
            Assert ($callbackProcess.ExitCode -eq 0) 'Real status line failure'
            $cacheName = if ($provider -eq 'claude') { 'claude-statusline-cache.json' } else { 'antigravity-cache.json' }
            $writtenPath = Join-Path $testDir ('local-data\ai-usage-tray\' + $cacheName)
            $writtenJson = [System.IO.File]::ReadAllText($writtenPath)
            $writtenUsage = $writtenJson | ConvertFrom-Json
            Assert ($writtenUsage.rows.Count -eq 1 -and $writtenUsage.plan -and $writtenUsage.account) 'Real callback missing plan/account/usage'
            Assert ($writtenJson -notmatch 'not-for-cache') 'Callback cached unrelated session data'
            $archivedUsage=Read-UsageCache $writtenPath $writtenUsage.account ([string]$writtenUsage.profile)
            Assert ($archivedUsage.rows.Count -eq 1 -and (Test-Path -LiteralPath (Get-AccountCachePath $writtenPath $writtenUsage.account ([string]$writtenUsage.profile)))) 'Real status line callback also writes account-specific history'
        } finally { Stop-ProviderProcess $callbackProcess }
    }

    # 실계정 접근은 금지: 아래 실패/계정 전환 검사는 모든 외부 경로를 대체한다.
    function Get-ClaudeCredPath { return $null }
    $accountA.profile=Get-ClaudeProfile
    Save-UsageCache $accountA $CLAUDE_STATUS_CACHE
    $accountB.profile=Get-ClaudeProfile
    Save-UsageCache $accountB $CLAUDE_STATUS_CACHE
    function Get-ClaudeAccount { return [pscustomobject]@{loggedIn=$true;account='a@example.invalid';plan='';authMethod='oauth'} }
    $state.claude=@{rows=@()}
    Get-ClaudeUsage
    Assert ($state.claude.success -and $state.claude.rows[0].pct -eq 21 -and $state.claude.plan -eq 'Pro' -and $state.claude.updated -eq $accountTime -and $state.claude.rows[0].cached) 'Claude A-B-A restores A history after restart without credentials or fresh quota'
    function Get-ClaudeAccount { return [pscustomobject]@{loggedIn=$true;account='c@example.invalid';plan='Pro';authMethod='oauth'} }
    $state.claude=@{rows=@()}
    Get-ClaudeUsage
    Assert ($state.claude.clear -and -not $state.claude.rows.Count) 'An unknown Claude account never displays saved A or B usage'

    $realCodexSnapshot=${function:Get-CodexAppServerSnapshot}
    try {
        $script:fakeCodexEmail='a@example.invalid'; $script:fakeCodexPct=22; $script:fakeCodexFailure=$false
        function Get-CodexAppServerSnapshot {
            return [pscustomobject]@{
                account=@{type='chatgpt';email=$script:fakeCodexEmail;planType='pro'};unavailable=$false;asOf=$accountTime
                result=$(if ($script:fakeCodexFailure) { $null } else { @{rateLimits=@{primary=@{usedPercent=$script:fakeCodexPct;windowDurationMins=300;resetsAt=$futureTime.ToUnixTimeSeconds()}}} })
            }
        }
        $state.gpt=@{rows=@()}
        Get-CodexUsage
        $script:fakeCodexEmail='b@example.invalid'; $script:fakeCodexPct=81
        Get-CodexUsage
        $script:fakeCodexEmail='a@example.invalid'; $script:fakeCodexFailure=$true
        $state.gpt=@{rows=@()}
        Get-CodexUsage
        Assert ($state.gpt.success -and $state.gpt.account -eq 'a@example.invalid' -and $state.gpt.rows[0].pct -eq 22 -and $state.gpt.rows[0].cached -and $state.gpt.asOf -eq $accountTime) 'Codex A-B-A restores confirmed account history on quota failure after restart'
        $roundTripCached=Convert-StoredUsageRow ($state.gpt.rows[0] | ConvertTo-Json | ConvertFrom-Json)
        Assert ($roundTripCached.cached -and $roundTripCached.reset -and -not $roundTripCached.stale) 'Cached history preserves its reset time and no-alert flag across worker serialization'
        $script:fakeCodexEmail='c@example.invalid'
        $state.gpt=@{rows=@()}
        Get-CodexUsage
        Assert ($state.gpt.clear -and -not $state.gpt.rows.Count) 'Confirmed unknown Codex account cannot inherit another account or anonymous logs'
    } finally { Set-Item Function:\Get-CodexAppServerSnapshot -Value $realCodexSnapshot }

    function Get-ClaudeAccount { return [pscustomobject]@{ loggedIn=$false; account=''; plan=''; authMethod='' } }
    function Get-ClaudeCredPath { throw 'Real credentials must not be accessed' }
    Get-ClaudeUsage
    Assert ($state.claude.clear -and $state.claude.err) 'Logged-out Claude must clear previous account'
    function Get-CodexAppServerSnapshot { return [pscustomobject]@{ unavailable=$true; account=@{type='apiKey'} } }
    function Get-CodexSessionsPath { throw 'API key account must not fall back to old logs' }
    Get-CodexUsage
    Assert ($state.gpt.clear -and $state.gpt.rows.Count -eq 0) 'API-key Codex must not reuse subscription logs'

    $launcherPath = Join-Path $projectDir 'AiUsageTray.exe'
    if (Test-Path -LiteralPath $launcherPath) {
        $launcherProcess = New-ProviderProcess $launcherPath '-SyntheticSelfTest'
        try {
            Assert ($launcherProcess.Start()) 'Packaged launcher start'
            Assert ($launcherProcess.WaitForExit(15000)) 'Packaged launcher timeout'
            Assert ($launcherProcess.ExitCode -eq 0) 'Packaged launcher compatibility'
        } finally { Stop-ProviderProcess $launcherProcess }
    }

    # UI 초기화만 실행한다. 실제 수집·설정·트레이 시작은 실행하지 않는다.
    $source = [System.IO.File]::ReadAllText($sourcePath)
    $uiStart = $source.IndexOf('Add-Type -AssemblyName System.Windows.Forms')
    $uiEnd = $source.IndexOf('$notify = [System.Windows.Forms.NotifyIcon]::new()')
    Assert ($uiStart -gt 0 -and $uiEnd -gt $uiStart) 'UI test boundaries'
    # 실제 단일 인스턴스 진입부를 별도 이름의 잠금으로 격리해 재시작 인계를 검사한다.
    $mutexStart=$source.IndexOf('$mutex = $null')
    $mutexName='AiUsageTrayTest-' + [guid]::NewGuid().ToString('N')
    $mutexSource=$source.Substring($mutexStart,$uiStart-$mutexStart).Replace('AiUsageTrayMutex',$mutexName)
    $mutexScript=Join-Path $testDir 'restart-gate.ps1'
    [System.IO.File]::WriteAllText($mutexScript, "param([switch]`$WaitForPreviousInstance)`r`n[Console]::WriteLine('ready')`r`n" + $mutexSource + "`r`n[Console]::WriteLine('acquired')`r`n`$mutex.ReleaseMutex()", [System.Text.UTF8Encoding]::new($true))
    foreach ($restartSwitch in @('', '-WaitForPreviousInstance')) {
        $heldMutex=[System.Threading.Mutex]::new($false,$mutexName)
        $held=$heldMutex.WaitOne(0)
        Assert $held 'Synthetic old instance owns lock'
        $gateProcess=New-ProviderProcess (Get-Process -Id $PID).Path "-NoProfile -ExecutionPolicy Bypass -File `"$mutexScript`" $restartSwitch"
        try {
            Assert ($gateProcess.Start()) 'Restart gate child starts'
            $ready=$gateProcess.StandardOutput.ReadLineAsync()
            Assert ($ready.Wait(5000) -and $ready.Result -eq 'ready') 'Restart gate readiness'
            $gateOutput=$gateProcess.StandardOutput.ReadToEndAsync()
            if ($restartSwitch) {
                Assert (-not $gateProcess.WaitForExit(250)) 'Restart waits while old instance holds lock'
                $heldMutex.ReleaseMutex(); $held=$false
                Assert ($gateProcess.WaitForExit(5000) -and $gateOutput.Result.Trim() -eq 'acquired') 'Restart takes over after old instance releases lock'
            } else {
                Assert ($gateProcess.WaitForExit(5000) -and -not $gateOutput.Result.Trim()) 'Normal duplicate exits without starting another tray'
            }
        } finally {
            if ($held) { $heldMutex.ReleaseMutex() }
            $heldMutex.Dispose()
            Stop-ProviderProcess $gateProcess
        }
    }
    . ([scriptblock]::Create($source.Substring($uiStart, $uiEnd - $uiStart).Replace('$PSScriptRoot', '$projectDir')))
    $beforeForecastState=$state.claude
    $state.claude=@{account='a@example.invalid';rows=@()}
    $script:claudeSamples=@(@{t=(Get-Date).AddMinutes(-20);pct=10;reset=$futureTime.LocalDateTime.ToString('s')})
    Merge-CollectionResult (@{state=@{claude=@{}};claude429Count=0} | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    Assert ($script:claudeSamples.Count -eq 1) 'A worker that did not collect Claude does not discard its forecast samples'
    Merge-CollectionResult (@{state=@{claude=@{success=$true;account='b@example.invalid';rows=@(New-UsageRow '5h' 20 $futureTime.LocalDateTime);updated=Get-Date}};claude429Count=0} | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    Assert ($script:claudeSamples.Count -eq 1 -and $script:claudeSamples[0].pct -eq 20) 'Changing account starts a new forecast rather than mixing A and B samples'
    $state.claude=$beforeForecastState; $script:claudeSamples=@()
    $popupTestArea=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $popupTestArea.X=-20000; $popupTestArea.Y=-20000
    $state.claude = @{ plan='Max 20x'; account='claude@example.invalid'; source='Claude Code 상태줄'; rows=$legacyRows; err=$null; updated=Get-Date }
    $state.gpt = @{ plan='Business'; account='codex@example.invalid'; source='Codex CLI/데스크톱 앱 서버'; rows=$selectionUsage.rows; err=$null; asOf=Get-Date }
    $state.antigravity = $separateAgState
    $showClaude = [pscustomobject]@{Checked=$true}; $showGpt = [pscustomobject]@{Checked=$true}; $showAntigravity = [pscustomobject]@{Checked=$true}
    $script:usageVisibility=@{}
    Build-Popup $popupTestArea
    Assert ($form.Height -le [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height) 'Popup exceeds screen'
    $bitmap = [System.Drawing.Bitmap]::new($popupBody.AutoScrollMinSize.Width, $popupBody.AutoScrollMinSize.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear($form.BackColor)
        Draw-Popup $graphics | Out-Null
        $bitmap.Save((Join-Path $workRoot ("usage-preview-$($PSVersionTable.PSVersion.Major).png")), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $heightWithSpark=$popupBody.AutoScrollMinSize.Height
    $script:usageVisibility=@{'codex.spark.5h'=$false;'codex.spark.weekly'=$false}
    Build-Popup $popupTestArea
    Assert ($popupBody.AutoScrollMinSize.Height -eq $heightWithSpark - 60) 'Spark choices remove both visible rows'
    # 실제 알림 경로도 같은 표시 필터를 사용한다.
    $showClaude.Checked=$false; $showAntigravity.Checked=$false
    $notifyItem=[pscustomobject]@{Checked=$true}
    $script:balloons=0
    $notify=[pscustomobject]@{Visible=$true;Text='';Icon=$null}
    $notify | Add-Member ScriptMethod ShowBalloonTip { param($duration,$title,$text,$icon); $script:balloons++ }
    $sparkRow=$state.gpt.rows | Where-Object isCodexSpark | Select-Object -First 1
    $sparkRow.pct=95
    Test-UsageAlert
    Assert ($script:balloons -eq 0) 'Hidden Spark must not alert'
    $script:usageVisibility['codex.spark.5h']=$true
    Test-UsageAlert
    Assert ($script:balloons -eq 1) 'Visible Spark alerts normally'
    $sparkRow.pct=76
    $script:usageVisibility['codex.spark.5h']=$false
    $baseRow=$state.gpt.rows | Where-Object { $_.modelKey -eq 'codex' -and (Get-UsageWindowKey $_) -eq '5h' } | Select-Object -First 1
    $baseRow.pct=95; $state.gpt.plan='pro'
    Test-UsageAlert
    Assert ($script:balloons -eq 1) 'Pro base 5h never alerts even when selected'
    Update-TrayIcon
    Assert ($notify.Text -match 'weekly' -and $notify.Text -notmatch '5h') 'Pro tooltip uses selected weekly instead of hidden base 5h'
    $state.gpt.plan='plus'
    $baseRow.cached=$true
    Test-UsageAlert
    Assert ($script:balloons -eq 1) 'Restored account history cannot trigger a fresh usage alert'
    $baseRow.cached=$false
    Test-UsageAlert
    Assert ($script:balloons -eq 2) 'Plus base 5h alerts when selected'
    Update-TrayIcon
    Assert ($notify.Text -match '5h 95%') 'Plus tooltip uses selected base 5h'
    $script:usageVisibility['codex.5h']=$false
    $script:usageVisibility['codex.weekly']=$false
    $script:usageVisibility['codex.reserve.weekly']=$false
    Update-TrayIcon
    Assert ($notify.Text -eq 'GPT 표시할 사용량 없음') 'No selected rows must not fabricate a 5h tooltip'
    $baseRow.pct=42
    $showClaude.Checked=$true; $showAntigravity.Checked=$true
    $script:usageVisibility['codex.spark.5h']=$false
    $DISPLAY_STATE=Join-Path $testDir 'display-state.json'
    Set-JsonAtomic @{codexSpark=$false;antigravityModels=@{'Gemini Models'=$false;'Claude and GPT models'=$false};usageItems=@{'antigravity.gemini.weekly'=$true}} $DISPLAY_STATE
    Initialize-DisplayState
    Assert (-not $script:usageVisibility['codex.spark.5h'] -and -not $script:usageVisibility['codex.spark.weekly']) 'Legacy Spark selection migrates to both periods'
    Assert (-not $script:usageVisibility['antigravity.gemini.5h'] -and -not $script:usageVisibility['antigravity.claude'] -and $script:usageVisibility['antigravity.gemini.weekly']) 'Legacy model selections migrate with new period preferences taking precedence'
    $script:usageVisibility=@{'codex.spark.5h'=$false;'codex.spark.weekly'=$false}
    $script:antigravityModelVisibility=@{}
    Save-DisplayState
    Assert ((Get-Content -LiteralPath $DISPLAY_STATE -Raw | ConvertFrom-Json).usageItems.'codex.spark.5h' -eq $false) 'Spark period preference saved'
    # 실제 메뉴와 설정 창을 쓰되 자동 시작·재시작은 합성 환경으로 격리한다.
    $menuStart=$source.IndexOf('$menu = [System.Windows.Forms.ContextMenuStrip]::new()')
    $menuEnd=$source.IndexOf('$notify.ContextMenuStrip = $menu')
    . ([scriptblock]::Create($source.Substring($menuStart,$menuEnd-$menuStart)))
    Assert (($menu.Items.Text -join '|') -eq '설정|새로고침|종료') 'Context menu contains only settings, refresh and exit'
    Assert (-not (Test-UsageItemVisible 'codex.spark.5h') -and -not (Test-UsageItemVisible 'codex.spark.weekly')) 'Spark period preferences restored'
    $notify.Visible=$false
    $originalAgState=$state.antigravity
    $originalClaudeRows=$state.claude.rows; $originalCodexRows=$state.gpt.rows
    $state.gpt.plan='Pro'
    $state.antigravity=@{groups=@($modelControlsUsage);rows=$modelControlsUsage.rows}
    $script:syntheticStartup=$false; $script:restartCount=0
    function Test-StartupEnabled { return $script:syntheticStartup }
    function Set-Startup([bool]$on) { $script:syntheticStartup=$on; return $true }
    # 실제 재시작의 명령과 숨김 실행 옵션도 확인한다.
    function Start-Process { param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,$ErrorAction); $script:restartArgs=$PSBoundParameters }
    Start-TrayRestart
    Assert ($script:restartArgs.WindowStyle -eq 'Hidden' -and $script:restartArgs.ArgumentList -match '-WaitForPreviousInstance' -and $script:restartArgs.ArgumentList.Contains('"' + $sourcePath + '"')) 'Restart launches current script hidden and waits for old instance'
    Remove-Item Function:\Start-Process
    function Start-TrayRestart { $script:restartCount++ }
    $settingsDialog=$null
    Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
[DllImport("user32.dll")] public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr hwnd);
[DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
'@ -Name DpiInspection -Namespace TrayTests
    $originalDpiContext=[TrayTests.DpiInspection]::GetThreadDpiAwarenessContext()
    $testUiContext=[IntPtr]::Zero
    try {
        $knownAgRows=$state.antigravity.rows
        $state.antigravity.rows=$ag.rows
        $fallbackDialog=New-SettingsDialog
        try { Assert ($fallbackDialog.Tag.Models.ContainsKey('gemini-new')) 'Periodless Gemini fallback retains an available model control' }
        finally { $fallbackDialog.Dispose(); $state.antigravity.rows=$knownAgRows }
        $settingsDialog=New-SettingsDialog
        $realIntegrationAction=${function:Set-UsageStatusLine}; $realIntegrationHelp=${function:Show-UsageStatusLineHelp}
        try {
            $script:integrationClicks=@(); $script:helpClicks=0
            function Set-UsageStatusLine { param($provider,[switch]$Remove,$Owner); $script:integrationClicks += "$provider/$([bool]$Remove)" }
            function Show-UsageStatusLineHelp { param($owner); $script:helpClicks++ }
            $clickMethod=[System.Windows.Forms.Button].GetMethod('OnClick',[System.Reflection.BindingFlags]'NonPublic,Instance')
            foreach ($button in $settingsDialog.Tag.CliButtons) { $clickMethod.Invoke($button,@([EventArgs]::Empty)) }
            $clickMethod.Invoke($settingsDialog.Tag.CliHelp,@([EventArgs]::Empty))
            Assert (($script:integrationClicks -join '|') -eq 'Claude/False|Claude/True|Antigravity/False|Antigravity/True') 'Each integration button routes its own provider and setup or disconnect action'
            Assert ($script:helpClicks -eq 1 -and $settingsDialog.Tag.CliHelp.AccessibleName -eq 'CLI 연동 도움말' -and $settingsDialog.Tag.CliHelp.TabStop) 'Question button opens accessible CLI help'
        } finally {
            Set-Item Function:\Set-UsageStatusLine -Value $realIntegrationAction
            Set-Item Function:\Show-UsageStatusLineHelp -Value $realIntegrationHelp
        }
        Assert ($settingsDialog.Font.SizeInPoints -eq 12 -and $settingsDialog.Font.Name -eq 'Pretendard Medium' -and -not $settingsDialog.Font.Bold) 'Settings use the actual medium font family, separate from bold headings'
        Assert ($settingsDialog.Icon.Size.Width -eq 32 -and $settingsDialog.Icon.Handle -ne [System.Drawing.SystemIcons]::Application.Handle) 'Settings use the custom U icon instead of the default application icon'
        # 글꼴 속성만으로 통과시키지 않는다. 실제 글자 가장자리에 회색조가 있는지 검사한다.
        $textProbe=[TraySettings.Label]::new()
        $textProbe.Text='설정 Settings'; $textProbe.Font=$fontSettings
        $textProbe.BackColor=[System.Drawing.Color]::White; $textProbe.ForeColor=[System.Drawing.Color]::Black
        $textProbe.Size=[System.Drawing.Size]::new(240,40)
        $textBitmap=[System.Drawing.Bitmap]::new(240,40)
        try {
            $textProbe.DrawToBitmap($textBitmap,[System.Drawing.Rectangle]::new(0,0,240,40))
            $grayPixels=0; $fringePixels=0
            for ($x=0; $x -lt 240; $x++) { for ($y=0; $y -lt 40; $y++) {
                $pixel=$textBitmap.GetPixel($x,$y)
                if ($pixel.R -eq $pixel.G -and $pixel.G -eq $pixel.B) {
                    if ($pixel.R -gt 0 -and $pixel.R -lt 255) { $grayPixels++ }
                } else { $fringePixels++ }
            } }
            Assert ($grayPixels -gt 100 -and $fringePixels -eq 0) 'Actual settings glyphs have smooth grayscale edges without colored fringes'
        } finally { $textBitmap.Dispose(); $textProbe.Dispose() }
        Assert ($settingsDialog.Tag.Checks.claude -is [TraySettings.CheckBox] -and $settingsDialog.AcceptButton -is [TraySettings.Button] -and $settingsDialog.Tag.Status -is [TraySettings.Label]) 'Checks, buttons and notices share the smooth renderer'
        Assert ([TrayTests.DpiInspection]::GetThreadDpiAwarenessContext() -eq $originalDpiContext) 'Settings creation restores the tray DPI context'
        Assert ([TrayTests.DpiInspection]::GetAwarenessFromDpiAwarenessContext([TrayTests.DpiInspection]::GetWindowDpiAwarenessContext($settingsDialog.Handle)) -eq 1) 'Settings window renders with system DPI awareness'
        Assert ($settingsDialog.Tag.UsageItems.Count -eq 10 -and $settingsDialog.Tag.Models.Count -eq 0) 'Settings contain the requested ten company/model/window choices without duplicate Antigravity groups'
        Assert (($settingsDialog.Tag.Checks.claude.Text,$settingsDialog.Tag.Checks.gpt.Text,$settingsDialog.Tag.Checks.antigravity.Text -join '|') -eq 'Claude|Codex|Antigravity') 'Provider headings control company visibility'
        Assert (-not $settingsDialog.Tag.UsageItems['codex.spark.5h'].Checked -and -not $settingsDialog.Tag.UsageItems['codex.spark.weekly'].Checked) 'Settings restore both Spark choices'
        Assert ($settingsDialog.Tag.UsageItems['codex.5h'].Checked -and -not $settingsDialog.Tag.UsageItems['codex.5h'].Enabled -and $settingsDialog.Tag.UsageItems['codex.5h'].AccessibleDescription -match 'Pro') 'Pro base 5h explains automatic hiding while retaining saved selection'
        Assert ($settingsDialog.Tag.UsageItems['codex.5h'].Parent.Tag.NameCell.Controls[1].Text -eq 'Pro · 5h 숨김') 'Pro hiding remains visible beside the model label'
        $toggle=$settingsDialog.Tag.Checks.startup
        $toggle.Checked=$false
        $onClick=[System.Windows.Forms.CheckBox].GetMethod('OnClick',[System.Reflection.BindingFlags]'NonPublic,Instance')
        $onClick.Invoke($toggle,@([EventArgs]::Empty))
        Assert ($toggle.Checked -and (($toggle.AccessibilityObject.State -band [System.Windows.Forms.AccessibleStates]::Checked) -ne 0)) 'Toggle preserves native activation and checked accessibility state'
        $toggle.Checked=$false
        $savedBefore=[System.IO.File]::ReadAllText($DISPLAY_STATE)
        $settingsDialog.Tag.UsageItems['antigravity.gemini.5h'].Checked=$false
        $settingsDialog.Tag.Checks.startup.Checked=$true
        $settingsDialog.Dispose()
        Assert ([System.IO.File]::ReadAllText($DISPLAY_STATE) -eq $savedBefore -and -not $script:syntheticStartup -and $script:restartCount -eq 0) 'Closing settings discards drafts without changing startup or restarting'
        $testUiContext=[Win32.Native]::SetThreadDpiAwarenessContext([IntPtr]::new(-2))
        $settingsDialog=New-SettingsDialog
        $settingsDialog.StartPosition='Manual'; $settingsDialog.Location=[System.Drawing.Point]::new(-20000,-20000)
        $settingsDialog.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Assert ($settingsDialog.BackColor.ToArgb() -eq [System.Drawing.Color]::White.ToArgb()) 'Settings background is white'
        Assert ([Win32.Native]::SendMessage($settingsDialog.Handle,0x7F,[IntPtr]::new(1),[IntPtr]::Zero) -eq $settingsDialog.Tag.TaskbarIcon.Handle) 'Large window icon uses the taskbar U'
        Assert ([Win32.Native]::SendMessage($settingsDialog.Handle,0x7F,[IntPtr]::Zero,[IntPtr]::Zero) -eq $settingsDialog.Tag.CaptionIcon.Handle) 'Small caption icon remains separate from the taskbar U'
        foreach ($kind in 'Taskbar','Caption') {
            $iconBitmap=$settingsDialog.Tag[$kind+'Icon'].ToBitmap()
            try {
                $solidPixels=0
                for ($x=0; $x -lt $iconBitmap.Width; $x++) { for ($y=0; $y -lt $iconBitmap.Height; $y++) {
                    $pixel=$iconBitmap.GetPixel($x,$y)
                    if ($pixel.A -eq 255) {
                        $solidPixels++
                        Assert (($kind -eq 'Taskbar' -and $pixel.R -eq 255 -and $pixel.G -eq 255 -and $pixel.B -eq 255) -or ($kind -eq 'Caption' -and $pixel.R -lt 80 -and $pixel.G -lt 80 -and $pixel.B -lt 80)) "Settings $kind icon has the requested color"
                    }
                } }
                Assert ($solidPixels -gt 20) "Settings $kind icon contains a visible U"
            } finally { $iconBitmap.Dispose() }
        }
        $settingsContent=$settingsDialog.Controls | Where-Object { $_ -is [System.Windows.Forms.FlowLayoutPanel] -and $_.Dock -eq 'Fill' }
        $defaultSize=$settingsDialog.Size
        $settingsDialog.Size=$settingsDialog.MinimumSize
        [System.Windows.Forms.Application]::DoEvents()
        Assert ($settingsContent.VerticalScroll.Visible) "Small settings window scrolls while completion stays available: dialog=$($settingsDialog.Size), content=$($settingsContent.ClientSize), display=$($settingsContent.DisplayRectangle), last=$($settingsContent.Controls[$settingsContent.Controls.Count-1].Bounds), footer=$($settingsDialog.Tag.Footer.Bounds)"
        Assert ($settingsDialog.AcceptButton.Bottom -le $settingsDialog.AcceptButton.Parent.ClientSize.Height) 'Completion button remains inside fixed footer'
        Assert ($settingsContent.FlowDirection -eq 'TopDown' -and -not $settingsContent.WrapContents) 'Settings keep a single column at minimum size'
        $settingsDialog.Size=$defaultSize
        [System.Windows.Forms.Application]::DoEvents()
        foreach ($viewport in @(
            @{name='preview';width=1280;height=900},
            @{name='compact';width=800;height=600},
            @{name='narrow';width=500;height=500}
        )) {
            $screenScale=[Win32.Native]::GetDpiForWindow($settingsDialog.Handle) / 96.0
            $area=[System.Drawing.Rectangle]::new(-20000,-20000,[int]($viewport.width * $screenScale),[int]($viewport.height * $screenScale))
            Set-SettingsWindowBounds $settingsDialog $area
            [System.Windows.Forms.Application]::DoEvents()
            Assert ($area.Contains($settingsDialog.Bounds)) "Settings fit $($viewport.width)x$($viewport.height) working area: $($settingsDialog.Bounds), DPI=$($settingsDialog.DeviceDpi)"
            Assert (-not $settingsContent.HorizontalScroll.Visible) "Settings avoid horizontal scrolling in $($viewport.name) layout"
            if ($viewport.name -eq 'preview') {
                Assert (-not $settingsContent.VerticalScroll.Visible -and $settingsDialog.Height -gt 680 * $screenScale) 'Settings grow taller to keep comfortable rows and show everything when the working area allows it'
            }
            Assert ($settingsContent.FlowDirection -eq 'TopDown' -and -not $settingsContent.WrapContents) "Settings always use one column in $($viewport.name) layout"
            $previousBottom=[int]::MinValue
            foreach ($control in $settingsContent.Controls) {
                Assert ($control.Top -ge $previousBottom) "Settings sections remain vertically ordered in $($viewport.name) layout"
                $previousBottom=$control.Bottom
            }
            Assert ($settingsDialog.AcceptButton.Bottom -le $settingsDialog.AcceptButton.Parent.ClientSize.Height -and $settingsDialog.AcceptButton.Left -ge 0) 'Completion button stays in the footer at each screen size'
            Assert ($settingsDialog.Font.SizeInPoints -eq 12) 'Smaller screens do not shrink settings text'
            $paintControls=@($settingsDialog.Tag.Checks.Values) + @($settingsDialog.Tag.UsageItems.Values) + @($settingsDialog.AcceptButton,$settingsDialog.CancelButton,$settingsDialog.Tag.CliHelp) + @($settingsDialog.Tag.CliButtons)
            foreach ($paintControl in $paintControls) {
                $paintBitmap=[System.Drawing.Bitmap]::new($paintControl.Width,$paintControl.Height)
                $paintBitmap.SetResolution(96 * $screenScale,96 * $screenScale)
                $paintGraphics=[System.Drawing.Graphics]::FromImage($paintBitmap)
                $paintEvent=[System.Windows.Forms.PaintEventArgs]::new($paintGraphics,$paintControl.ClientRectangle)
                try {
                    # WM_PAINT의 불투명 버퍼처럼 부모 배경 없이 그린다. DrawToBitmap만으로는 누락된 배경을 잡지 못한다.
                    $paintGraphics.Clear([System.Drawing.Color]::Magenta)
                    $paintMethod=$paintControl.GetType().GetMethod('OnPaint',[System.Reflection.BindingFlags]'NonPublic,Instance')
                    $paintMethod.Invoke($paintControl,@($paintEvent))
                    Assert ($paintBitmap.GetPixel(0,0).ToArgb() -eq [System.Drawing.Color]::White.ToArgb()) "Opaque custom control paints its own white background: $($paintControl.Text)"
                    if ($paintControl -is [TraySettings.CheckBox]) {
                        $textSize=$paintGraphics.MeasureString($paintControl.Text,$paintControl.Font)
                        Assert ($paintControl.Height -ge 35 * $screenScale -and $paintControl.Height - $textSize.Height -ge 8 * $screenScale) "Toggle row keeps vertical breathing room at screen DPI: $($paintControl.Text)"
                        Assert ($paintControl.Width - 50 * $screenScale -ge $textSize.Width) "Text stays clear of its toggle at screen DPI: $($paintControl.Text)"
                        Assert ($paintControl.ForeColor.ToArgb() -eq [System.Drawing.Color]::Black.ToArgb()) 'Settings toggle labels use uniform black text'
                    }
                } finally { $paintEvent.Dispose(); $paintGraphics.Dispose(); $paintBitmap.Dispose() }
            }
            foreach ($usageRow in @($settingsContent.Controls | Where-Object { $_ -is [System.Windows.Forms.TableLayoutPanel] })) {
                $rowLabel=$usageRow.Tag.NameLabel
                $labelGraphics=$rowLabel.CreateGraphics()
                try { Assert ($rowLabel.Width -ge $labelGraphics.MeasureString($rowLabel.Text,$rowLabel.Font).Width) "Model label stays complete at current DPI: $($rowLabel.Text)" }
                finally { $labelGraphics.Dispose() }
                foreach ($namePart in $usageRow.Tag.NameCell.Controls) {
                    Assert ($namePart.Right -le $usageRow.Tag.NameCell.ClientSize.Width -and $namePart.Bottom -le $usageRow.Tag.NameCell.ClientSize.Height) "Model label and Pro badge fit in $($viewport.name) layout: $($namePart.Text)"
                }
            }
            foreach ($button in $settingsDialog.Tag.CliButtons) {
                $buttonGraphics=$button.CreateGraphics()
                try { Assert ($button.Width - 8 * $screenScale -ge $buttonGraphics.MeasureString($button.Text,$button.Font).Width) 'CLI button labels fit at screen DPI' }
                finally { $buttonGraphics.Dispose() }
                Assert ($button.Right -le $button.Parent.ClientSize.Width -and $button.Bottom -le $button.Parent.ClientSize.Height) 'CLI actions remain inside their row'
                $providerLabel=$button.Parent.Parent.Controls | Where-Object { $_ -is [TraySettings.Label] }
                $labelGraphics=$providerLabel.CreateGraphics()
                try { Assert ($providerLabel.Width -ge $labelGraphics.MeasureString($providerLabel.Text,$providerLabel.Font).Width) 'CLI provider label stays clear of both buttons' }
                finally { $labelGraphics.Dispose() }
            }
            $settingsBitmap=[System.Drawing.Bitmap]::new($settingsDialog.Width,$settingsDialog.Height)
            $settingsBitmap.SetResolution(96 * $screenScale,96 * $screenScale)
            try {
                $settingsDialog.DrawToBitmap($settingsBitmap,[System.Drawing.Rectangle]::new(0,0,$settingsBitmap.Width,$settingsBitmap.Height))
                $settingsBitmap.Save((Join-Path $workRoot "settings-$($viewport.name)-$($PSVersionTable.PSVersion.Major).png"))
                $settingsContent.ScrollControlIntoView($settingsContent.Controls[$settingsContent.Controls.Count-1])
                if ($settingsContent.VerticalScroll.Visible) { $settingsContent.AutoScrollPosition=[System.Drawing.Point]::new(0,$settingsContent.DisplayRectangle.Height) }
                [System.Windows.Forms.Application]::DoEvents()
                Assert ($settingsContent.Controls[$settingsContent.Controls.Count-1].Bottom -le $settingsContent.ClientSize.Height) 'Bottom CLI action remains fully visible at the end of the scroll range'
                $settingsDialog.DrawToBitmap($settingsBitmap,[System.Drawing.Rectangle]::new(0,0,$settingsBitmap.Width,$settingsBitmap.Height))
                $settingsBitmap.Save((Join-Path $workRoot "settings-cli-$($viewport.name)-$($PSVersionTable.PSVersion.Major).png"))
            } finally { $settingsBitmap.Dispose() }
        }
        Build-Popup $popupTestArea
        $heightWithAllAgModels=$popupBody.AutoScrollMinSize.Height
        $settingsDialog.Tag.UsageItems['antigravity.gemini.5h'].Checked=$false
        $settingsDialog.Tag.Checks.startup.Checked=$true
        $settingsDialog.AcceptButton.PerformClick()
        Assert ($script:restartCount -eq 1 -and $settingsDialog.Tag.RestartReady -and $script:syntheticStartup) 'Done saves startup and requests one restart'
        Initialize-DisplayState
        Build-Popup $popupTestArea
        Assert ($popupBody.AutoScrollMinSize.Height -eq $heightWithAllAgModels - 30) 'Saved Gemini 5h choice hides only its popup row after restart'
        $savedModelState=Get-Content -LiteralPath $DISPLAY_STATE -Encoding UTF8 -Raw | ConvertFrom-Json
        Assert ($savedModelState.usageItems.'antigravity.gemini.5h' -eq $false -and $savedModelState.usageItems.'antigravity.gemini.weekly' -and -not $savedModelState.usageItems.'codex.spark.weekly') 'Done persists independent model periods and Spark preferences'
        $workerModelRows=Convert-WorkerRows (@{rows=$state.antigravity.rows} | ConvertTo-Json -Depth 8 | ConvertFrom-Json).rows
        Assert (@(Get-VisibleAntigravityRows $workerModelRows).Count -eq 3) 'Period visibility survives worker serialization'
        $state.claude.rows=@(); $state.gpt.rows=@()
        $notify.Visible=$true
        $modelControlsUsage.rows[2].pct=95
        $beforeAgAlert=$script:balloons
        Test-UsageAlert
        Assert ($script:balloons -eq $beforeAgAlert) 'Hidden Antigravity models must not alert'
        $script:usageVisibility['antigravity.gemini.5h']=$true
        Test-UsageAlert
        Assert ($script:balloons -eq $beforeAgAlert + 1) 'Reenabled Antigravity model alerts normally'
        $modelControlsUsage.rows[2].pct=20
        $notify.Visible=$false
        $settingsDialog.Dispose()
        Initialize-DisplayState
        $settingsDialog=New-SettingsDialog
        Assert (-not $settingsDialog.Tag.UsageItems['antigravity.gemini.5h'].Checked -and $settingsDialog.Tag.UsageItems['antigravity.gemini.weekly'].Checked) 'Independent Gemini preferences restored in reopened settings'
        $settingsDialog.Tag.Checks.startup.Checked=$false
        $validDisplayPath=$DISPLAY_STATE
        $DISPLAY_STATE=$testDir # 파일 대신 기존 디렉터리를 대상으로 지정해 저장 실패를 재현
        Assert-Rejected { Save-TraySettings $settingsDialog } 'Save failure must be reported'
        Assert ($script:syntheticStartup -and $script:restartCount -eq 1) 'Failed save restores startup and does not restart'
        $DISPLAY_STATE=$validDisplayPath
        function Set-Startup([bool]$on) { return $false }
        Assert-Rejected { Save-TraySettings $settingsDialog } 'Startup failure must be reported'
        function Set-Startup([bool]$on) { $script:syntheticStartup=$on; return $true }
        $settingsDialog.Tag.Checks.startup.Checked=$true
        function Start-TrayRestart { throw 'synthetic start failure' }
        $settingsDialog.StartPosition='Manual'; $settingsDialog.Location=[System.Drawing.Point]::new(-20000,-20000)
        $settingsDialog.Show()
        $settingsDialog.AcceptButton.PerformClick()
        Assert (-not $settingsDialog.Tag.RestartReady -and $settingsDialog.AcceptButton.Enabled -and $settingsDialog.Tag.Status.Text -match '실패') 'Restart failure keeps settings open for retry'
    } finally {
        if ($settingsDialog) { $settingsDialog.Dispose() }
        if ($testUiContext -ne [IntPtr]::Zero) { [void][Win32.Native]::SetThreadDpiAwarenessContext($testUiContext) }
        $script:antigravityModelVisibility=@{}
        $script:usageVisibility=@{}
        $state.antigravity=$originalAgState
        $state.claude.rows=$originalClaudeRows; $state.gpt.rows=$originalCodexRows
    }
    $realSettingsFactory=${function:New-SettingsDialog}
    try {
        function New-SettingsDialog {
            $testDialog=& $realSettingsFactory
            $testDialog.Location=[System.Drawing.Point]::new(-20000,-20000)
            $testDialog.add_Shown({ param($sender,$eventArgs)
                $script:settingsShownCount++
                $script:settingsShownAwareness=[TrayTests.DpiInspection]::GetAwarenessFromDpiAwarenessContext([TrayTests.DpiInspection]::GetThreadDpiAwarenessContext())
                $sender.Close()
            })
            return $testDialog
        }
        $script:settingsShownCount=0
        Build-Popup $popupTestArea
        $form.Location=[System.Drawing.Point]::new(-20000,-20000)
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Assert ($popupSettings.AccessibleName -eq '설정' -and $popupSettings.TabStop -and $popupTip.GetToolTip($popupSettings) -eq '설정') 'Gear button exposes a keyboard-accessible settings name and tooltip'
        $popupSettings.PerformClick()
        Assert ($script:settingsShownCount -eq 1 -and -not $form.Visible) 'Gear click opens the real settings modal once and hides the usage popup'
        Assert ($script:settingsShownAwareness -eq 1 -and [TrayTests.DpiInspection]::GetThreadDpiAwarenessContext() -eq $originalDpiContext) 'Settings modal uses its DPI context throughout and restores the tray context on close'
    } finally { Set-Item Function:\New-SettingsDialog -Value $realSettingsFactory }
    # 무료 Claude 계정으로 실측할 수 없는 화면은 실제 렌더러에 가상 수치만 넣어 한 장 만든다.
    $beforeSampleState=$state
    $state=@{
        claude=@{plan='Pro (샘플)';source='실제 계정 데이터 아님';account='샘플 계정';updated=$null;rows=@(
            (New-UsageRow '5h' 32 (Get-Date).AddHours(2))
            (New-UsageRow 'weekly' 61 (Get-Date).AddDays(4))
        )}
        gpt=@{};antigravity=@{}
    }
    $showGpt.Checked=$false; $showAntigravity.Checked=$false
    Build-Popup $popupTestArea
    $form.Location=[System.Drawing.Point]::new(-20000,-20000)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Assert ($form.Height -eq $popupBody.AutoScrollMinSize.Height + $form.Padding.Vertical -and $popupBody.Bottom -eq $form.ClientSize.Height - 1) "Usage popup adds only its border below the compact content: form=$($form.Size), content=$($popupBody.AutoScrollMinSize), body=$($popupBody.ClientSize), horizontal=$($popupBody.HorizontalScroll.Visible), vertical=$($popupBody.VerticalScroll.Visible)"
    Assert ($popupSettings.Parent -eq $popupBody -and $popupSettings.Top -eq 8 -and $popupSettings.Right -eq $popupBody.ClientSize.Width - 8) 'Gear shares the first model title line at the top right'
    $popupBitmap=[System.Drawing.Bitmap]::new($form.Width,$form.Height)
    try {
        $form.DrawToBitmap($popupBitmap,[System.Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $popupBitmap.Save((Join-Path $workRoot "usage-settings-button-$($PSVersionTable.PSVersion.Major).png"))
    } finally { $popupBitmap.Dispose(); $form.Hide() }
    $state.claude.rows[0].warn='긴 예측 문구 ' * 100
    Build-Popup $popupTestArea
    Assert ($popupBody.HorizontalScroll.Visible -and $popupBody.ClientSize.Height -ge $popupBody.AutoScrollMinSize.Height) 'Horizontal scrollbar leaves the final usage row fully visible without permanent bottom padding'
    Assert ($popupTestArea.Contains($form.Bounds) -and $form.Right -eq $popupTestArea.Right - 8 -and $form.Bottom -eq $popupTestArea.Bottom - 8) 'Popup stays anchored inside its monitor when loading widens the content'
    $state.claude.rows[0].warn=$null
    Build-Popup $popupTestArea
    $sampleBitmap=[System.Drawing.Bitmap]::new($popupBody.AutoScrollMinSize.Width,$popupBody.AutoScrollMinSize.Height)
    $sampleGraphics=[System.Drawing.Graphics]::FromImage($sampleBitmap)
    try {
        $sampleGraphics.Clear($form.BackColor)
        Draw-Popup $sampleGraphics | Out-Null
        $sampleBitmap.Save((Join-Path $workRoot 'claude-sample.png'),[System.Drawing.Imaging.ImageFormat]::Png)
        $sampleGraphics.Clear($form.BackColor)
        Draw-Section $sampleGraphics 'Claude' ('긴 요금제 이름 ' * 20) @() '' $null 12 '' '' | Out-Null
        for ($x=$popupSettings.Left; $x -lt $sampleBitmap.Width; $x++) {
            for ($y=12; $y -lt 40; $y++) {
                Assert ($sampleBitmap.GetPixel($x,$y).ToArgb() -eq $form.BackColor.ToArgb()) 'Long first title must not draw beneath the gear button'
            }
        }
    } finally {
        $sampleGraphics.Dispose(); $sampleBitmap.Dispose()
        $state=$beforeSampleState
        $showGpt.Checked=$true; $showAntigravity.Checked=$true
    }
    $state.antigravity.groups[0].rows = @(1..40 | ForEach-Object { New-UsageRow "Model $_" 37 $null })
    Build-Popup $popupTestArea
    Assert ($popupBody.AutoScrollMinSize.Height -gt $popupBody.Height) 'Many quotas must scroll'
    Assert ($popupTestArea.Contains($form.Bounds) -and $form.Right -eq $popupTestArea.Right - 8 -and $form.Bottom -eq $popupTestArea.Bottom - 8) 'Popup stays inside its monitor when loading adds many rows'
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $gearBounds=$popupSettings.RectangleToScreen($popupSettings.ClientRectangle)
    $popupBody.AutoScrollPosition=[System.Drawing.Point]::new(0,$popupBody.AutoScrollMinSize.Height)
    [System.Windows.Forms.Application]::DoEvents()
    Build-Popup $popupTestArea
    Assert ($popupBody.AutoScrollPosition.Y -lt 0 -and $popupSettings.Top - $popupBody.AutoScrollPosition.Y -eq 8) 'Gear scrolls with its first model title instead of covering quota rows'
    $popupBody.AutoScrollPosition=[System.Drawing.Point]::Empty
    [System.Windows.Forms.Application]::DoEvents()
    Assert ($popupSettings.RectangleToScreen($popupSettings.ClientRectangle) -eq $gearBounds) 'Scrolling back restores the gear beside the first model title'
    $popupBitmap=[System.Drawing.Bitmap]::new($form.Width,$form.Height)
    try {
        $form.DrawToBitmap($popupBitmap,[System.Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $popupBitmap.Save((Join-Path $workRoot "usage-settings-button-scroll-$($PSVersionTable.PSVersion.Major).png"))
    } finally { $popupBitmap.Dispose(); $form.Hide() }
    $clearResult = [pscustomobject]@{ state=@{claude=@{clear=$true;err='sign in';account='new@example.invalid';plan='Pro';source='CLI'}}; claude429Count=0 }
    Merge-CollectionResult $clearResult
    Assert ($state.claude.rows.Count -eq 0 -and $state.claude.account -eq 'new@example.invalid') 'Old account rows survived worker merge'
    $agResult=@{state=@{antigravity=$separateAgState};claude429Count=0} | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    Merge-CollectionResult $agResult
    Assert ($state.antigravity.groups.Count -eq 2 -and $state.antigravity.groups[0].updated -is [datetime]) 'Antigravity worker groups/date round trip'
    $offlineAgState.rows[0].pct=95
    $offlineResult=@{state=@{antigravity=$offlineAgState};claude429Count=0} | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    Merge-CollectionResult $offlineResult
    # Windows PowerShell의 작업 결과 DateTime JSON은 밀리초 정밀도다. 캐시 파일은 위에서 원래 정밀도로 검사한다.
    Assert ($state.antigravity.plan -eq $desktopUsage.plan -and [Math]::Abs(($state.antigravity.asOf - $lastDesktopTime).TotalMilliseconds) -lt 1 -and $state.antigravity.groups[0].err -match '마지막 조회 기록') 'Offline plan, timestamp and notice survive collector-to-UI transfer'
    $showClaude.Checked=$false; $showGpt.Checked=$false; $notify.Visible=$true
    $beforeOfflineAlert=$script:balloons
    Test-UsageAlert
    Assert ($script:balloons -eq $beforeOfflineAlert) 'Restored offline desktop quota above 90 percent must not notify'
    $notify.Visible=$false
    Build-Popup $popupTestArea
    $cachedPopupHeight=$popupBody.AutoScrollMinSize.Height
    $cachedGroup=$state.antigravity.groups[0]
    $cachedError=$cachedGroup.err; $cachedUpdated=$cachedGroup.updated
    $cachedGroup.err=$null
    Build-Popup $popupTestArea
    Assert ($popupBody.AutoScrollMinSize.Height -eq $cachedPopupHeight) 'Cached usage with a timestamp renders without the missing-server notice or its blank space'
    $cachedGroup.err=$cachedError; $cachedGroup.updated=$null
    Build-Popup $popupTestArea
    Assert ($popupBody.AutoScrollMinSize.Height -gt $cachedPopupHeight) 'Missing-server diagnostic stays visible when no last-query timestamp is available'
    $cachedGroup.updated=$cachedUpdated
    Build-Popup $popupTestArea
    $offlineBitmap=[System.Drawing.Bitmap]::new($popupBody.AutoScrollMinSize.Width,$popupBody.AutoScrollMinSize.Height)
    $offlineGraphics=[System.Drawing.Graphics]::FromImage($offlineBitmap)
    try {
        $offlineGraphics.Clear($form.BackColor)
        Draw-Popup $offlineGraphics | Out-Null
        $offlineBitmap.Save((Join-Path $workRoot "antigravity-offline-$($PSVersionTable.PSVersion.Major).png"),[System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $offlineGraphics.Dispose(); $offlineBitmap.Dispose() }
    Merge-CollectionResult @{state=@{antigravity=@{clear=$true;err='unavailable'}};claude429Count=0}
    Assert ($state.antigravity.groups.Count -eq 0 -and $state.antigravity.rows.Count -eq 0) 'Explicit no-data result clears unavailable Antigravity when no valid cache exists'
    $form.Dispose()
    $menu.Dispose()
    if ($script:prevIconHandle -ne [IntPtr]::Zero) { [Win32.Native]::DestroyIcon($script:prevIconHandle) | Out-Null }
    if ($script:prevIcon) { $script:prevIcon.Dispose() }
    foreach ($brush in $script:brushCache.Values) { $brush.Dispose() }
    foreach ($font in @($fontBase,$fontBold,$fontSmall,$fontSettings,$fontSettingsHeading,$fontSettingsSmall)) { $font.Dispose() }
    $script:pfc.Dispose()
}
finally {
    $resolvedTestDir = [System.IO.Path]::GetFullPath($testDir)
    if ($resolvedTestDir.StartsWith($workRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestDir) -match '^verification-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedTestDir -Recurse -Force
    }
}
foreach ($callbackName in 'claude-statusline.ps1', 'antigravity-statusline.ps1') {
    & (Join-Path $projectDir $callbackName) -SelfTest | Out-Null
}
"PASS: PowerShell $($PSVersionTable.PSVersion) parsers, account isolation, RPC, status line, popup"
