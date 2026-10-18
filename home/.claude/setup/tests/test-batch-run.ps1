# test-batch-run.ps1 - prove the batch runner's state machine.
#
#   pwsh -NoProfile -File setup/tests/test-batch-run.ps1 [-BatchRun <path>]
#
# One fake claude command answers success, failure and invalid JSON. The suite checks:
# one fresh call per item, the JSONL state, resume (done items are not called again),
# the 3-failures-in-a-row stop, the cost field from the JSON, dry run and the >20 confirm.
# The fake is written into a scratch folder; nothing in the repository is touched.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [string]$BatchRun = (Join-Path $PSScriptRoot '..\powershell\batch-run.ps1')
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$pwsh = (Get-Process -Id $PID).Path
$workRoot = if ($env:POS_BATCH_TEST_DIR) { $env:POS_BATCH_TEST_DIR } else { [IO.Path]::GetTempPath() }
$work = Join-Path $workRoot ('batch-run-test-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Output ('work folder: ' + $work)

$errors = 0
$total = 0
function Judge([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:total++
    if (-not $Ok) { $script:errors++ }
    $tag = if ($Ok) { 'OK   ' } else { 'FAIL ' }
    # Detail only on a failure: a passing line that echoes a batch summary ("done=3 failed=0")
    # would match check.ps1's failure regex and turn a green suite red (measured in CI).
    if ($Detail -and -not $Ok) { $Detail = '  ' + $Detail } else { $Detail = '' }
    Write-Output ((("{0} {1}" -f $tag, $Name)) + $Detail)
}

$fake = Join-Path $work 'fake-claude.ps1'
$fakeBody = @'
# fake claude: answers by the item marker in the prompt; logs every call.
$prompt = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-p' -and ($i + 1) -lt $args.Count) { $prompt = [string]$args[$i + 1] }
}
$item = ''
if ($prompt -match 'ITEM=(\S+)') { $item = $Matches[1] }
if ($env:FAKE_CALLS) { Add-Content -LiteralPath $env:FAKE_CALLS -Value $item -Encoding utf8 }
if ($env:FAKE_ARGS) { Add-Content -LiteralPath $env:FAKE_ARGS -Value ($args -join '|') -Encoding utf8 }
if ($item -like 'sleep*') { Start-Sleep -Seconds 20 }
if ($item -like 'badjson*') { Write-Output 'this is not json'; exit 0 }
if ($item -like 'fail*') {
    $o = @{ type = 'result'; is_error = $true; total_cost_usd = 0.10; session_id = ('sess-' + $item); result = 'failed on purpose' } | ConvertTo-Json -Compress
    Write-Output $o
    exit 1
}
$o = @{ type = 'result'; is_error = $false; total_cost_usd = 0.25; session_id = ('sess-' + $item); result = ('done ' + $item) } | ConvertTo-Json -Compress
Write-Output $o
exit 0
'@
[IO.File]::WriteAllText($fake, $fakeBody, (New-Object Text.UTF8Encoding($false)))

$promptFile = Join-Path $work 'prompt.txt'
[IO.File]::WriteAllText($promptFile, 'ITEM={item}', (New-Object Text.UTF8Encoding($false)))

function New-List([string]$Name, [string[]]$Items) {
    $path = Join-Path $work $Name
    [IO.File]::WriteAllText($path, (($Items -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Invoke-Batch {
    param([string]$List, [string[]]$Extra = @(), [string]$StdinText = '', [switch]$AskConfirm, [string]$ProfileArg = 'none')
    $calls = Join-Path $work ('calls-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
    $argsLog = Join-Path $work ('args-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
    $env:FAKE_CALLS = $calls
    $env:FAKE_ARGS = $argsLog
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BatchRun,
                   '-List', $List, '-PromptFile', $promptFile, '-Profile', $ProfileArg,
                   '-ClaudeExe', $fake)
    if (-not $AskConfirm) { $arguments += '-Confirm:$false' }
    $arguments += $Extra
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($StdinText) {
            $out = $StdinText | & $pwsh @arguments 2>&1 | Out-String
        } else {
            $out = & $pwsh @arguments 2>&1 | Out-String
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
        Remove-Item Env:FAKE_CALLS -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_ARGS -ErrorAction SilentlyContinue
    }
    $callList = @()
    if (Test-Path -LiteralPath $calls) { $callList = @(Get-Content -LiteralPath $calls -Encoding utf8 | Where-Object { $_.Trim() }) }
    $argList = @()
    if (Test-Path -LiteralPath $argsLog) { $argList = @(Get-Content -LiteralPath $argsLog -Encoding utf8 | Where-Object { $_.Trim() }) }
    [pscustomobject]@{ Output = $out; Code = $code; Calls = $callList; CallsFile = $calls; Args = $argList }
}

function Read-State([string]$List) {
    $statePath = $List + '.state.jsonl'
    if (-not (Test-Path -LiteralPath $statePath)) { return @() }
    $rows = @()
    foreach ($line in (Get-Content -LiteralPath $statePath -Encoding utf8)) {
        if ($line.Trim()) { $rows += ($line | ConvertFrom-Json) }
    }
    return $rows
}

function Last-Per-Item($Rows) {
    $map = @{}
    foreach ($r in $Rows) { $map[[string]$r.item] = $r }
    return $map
}

if (-not (Test-Path -LiteralPath $BatchRun)) {
    Write-Output ('FAIL  batch-run.ps1 not found: ' + $BatchRun)
    Write-Output ''
    Write-Output ('0 of 1 cases as expected, 1 errors')
    exit 1
}

# --- 1. one call per item, state done, cost parsed ---------------------------
$list = New-List 'ok.list' @('ok1', 'ok2', 'ok3')
$r = Invoke-Batch -List $list
$state = Read-State $list
$last = Last-Per-Item $state
Judge 'success path: exit 0' ($r.Code -eq 0) ('exit=' + $r.Code)
Judge 'success path: one call per item' (($r.Calls.Count -eq 3) -and (($r.Calls -join ',') -eq 'ok1,ok2,ok3')) ('calls=' + ($r.Calls -join ','))
Judge 'success path: three done records' (($state.Count -eq 3) -and (@($state | Where-Object { $_.status -eq 'done' }).Count -eq 3))
Judge 'success path: cost 0.25 per item' (($last['ok1'].total_cost_usd -eq 0.25) -and ($last['ok3'].total_cost_usd -eq 0.25)) ('cost=' + $last['ok1'].total_cost_usd)
Judge 'success path: session id recorded' ($last['ok2'].session_id -eq 'sess-ok2') ('sid=' + $last['ok2'].session_id)
Judge 'success path: summary line' ($r.Output -match 'BATCH done=3 failed=0') ('output=' + ($r.Output -split "`n" | Select-Object -Last 2 | Out-String).Trim())
$argText = ($r.Args -join "`n")
Judge 'call: never --bare' ($argText -notmatch '(^|\|)--bare(\||$)') ''
Judge 'call: json output and budget' (($argText -match '(^|\|)--output-format\|json(\||$)') -and ($argText -match '(^|\|)--max-budget-usd\|')) ''
Judge 'call: the item is inside one prompt argument' (($r.Args.Count -eq 3) -and ($argText -match 'ITEM=ok1')) ('args=' + ($r.Args[0] -replace '\|', ' '))

# --- 2. resume: done items are not called again ------------------------------
$r2 = Invoke-Batch -List $list
Judge 'resume: no call for done items' ($r2.Calls.Count -eq 0) ('calls=' + $r2.Calls.Count)
Judge 'resume: no duplicate state lines' ((Read-State $list).Count -eq 3) ('lines=' + (Read-State $list).Count)
Judge 'resume: summary counts skipped' ($r2.Output -match 'BATCH done=0 failed=0 skipped=3') ''

# --- 3. three failures in a row stop the batch ------------------------------
$list3 = New-List 'fail.list' @('ok1', 'ok2', 'fail1', 'fail2', 'fail3', 'ok3')
$r3 = Invoke-Batch -List $list3
$state3 = Read-State $list3
$last3 = Last-Per-Item $state3
Judge 'stop after 3: exit code 1' ($r3.Code -eq 1) ('exit=' + $r3.Code)
Judge 'stop after 3: item 6 never called' (($r3.Calls -notcontains 'ok3') -and ($r3.Calls.Count -eq 5)) ('calls=' + ($r3.Calls -join ','))
Judge 'stop after 3: failed records' (($last3['fail1'].status -eq 'failed') -and ($last3['fail3'].status -eq 'failed'))
Judge 'stop after 3: remaining marked skipped' ($last3['ok3'].status -eq 'skipped') ('ok3=' + $last3['ok3'].status)
Judge 'stop after 3: summary failed=3' ($r3.Output -match 'BATCH done=2 failed=3 skipped=1') ('output=' + ($r3.Output -split "`n" | Select-Object -Last 2 | Out-String).Trim())

# --- 3b. a success resets the failure counter -------------------------------
$list3b = New-List 'reset.list' @('fail1', 'fail2', 'ok1', 'fail3', 'fail4', 'fail5', 'ok2')
$r3b = Invoke-Batch -List $list3b
$last3b = Last-Per-Item (Read-State $list3b)
Judge 'failure counter resets after a success' (($r3b.Calls.Count -eq 6) -and ($r3b.Calls -notcontains 'ok2')) ('calls=' + ($r3b.Calls -join ','))
Judge 'failure counter reset: ok2 skipped' ($last3b['ok2'].status -eq 'skipped') ('ok2=' + $last3b['ok2'].status)

# --- 3c. profile mapping and unknown profile --------------------------------
$listP = New-List 'profile.list' @('ok1')
$rP = Invoke-Batch -List $listP -ProfileArg 'claude'
Judge 'profile claude: no --settings' (($rP.Args -join "`n") -notmatch '--settings') ('calls=' + $rP.Calls.Count)
$listP2 = New-List 'profile2.list' @('ok1')
$rP2 = Invoke-Batch -List $listP2 -ProfileArg 'nosuch'
Judge 'unknown profile: exit 2, no call' (($rP2.Code -eq 2) -and ($rP2.Calls.Count -eq 0)) ('exit=' + $rP2.Code)

# --- 4. invalid JSON is a failure, not a silent success ---------------------
$list4 = New-List 'bad.list' @('badjson1')
$r4 = Invoke-Batch -List $list4
$state4 = Read-State $list4
Judge 'invalid JSON: exit code 1' ($r4.Code -eq 1) ('exit=' + $r4.Code)
Judge 'invalid JSON: failed record' ((@($state4)[0].status) -eq 'failed') ('status=' + (@($state4)[0].status))
Judge 'invalid JSON: no cost invented' ($null -eq (@($state4)[0].total_cost_usd)) ('cost=' + (@($state4)[0].total_cost_usd))

# --- 5. dry run writes nothing and calls nobody -----------------------------
$list5 = New-List 'dry.list' @('ok1', 'ok2')
$r5 = Invoke-Batch -List $list5 -Extra @('-DryRun')
Judge 'dry run: exit 0' ($r5.Code -eq 0) ('exit=' + $r5.Code)
Judge 'dry run: no claude call' ($r5.Calls.Count -eq 0) ('calls=' + $r5.Calls.Count)
Judge 'dry run: no state file' (-not (Test-Path -LiteralPath ($list5 + '.state.jsonl')))
Judge 'dry run: names the items' (($r5.Output -match 'ok1') -and ($r5.Output -match 'ok2'))

# --- 6. more than 20 items needs an explicit yes ----------------------------
$many = @(); 1..21 | ForEach-Object { $many += ('ok' + $_) }
$list6 = New-List 'many.list' $many
$r6 = Invoke-Batch -List $list6 -StdinText 'no' -AskConfirm
Judge 'confirm: 21 items with "no" does not start' (($r6.Calls.Count -eq 0) -and ($r6.Output -match 'yes')) ('calls=' + $r6.Calls.Count)
$list6b = New-List 'many-yes.list' $many
$r6b = Invoke-Batch -List $list6b -StdinText 'yes' -AskConfirm
Judge 'confirm: 21 items with "yes" starts' (($r6b.Calls.Count -eq 21) -and ($r6b.Code -eq 0)) ('calls=' + $r6b.Calls.Count + ' exit=' + $r6b.Code)

# --- 7. prompt template without {item} is refused ---------------------------
$badPrompt = Join-Path $work 'bad-prompt.txt'
[IO.File]::WriteAllText($badPrompt, 'no placeholder', (New-Object Text.UTF8Encoding($false)))
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out7 = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $BatchRun -List $list5 -PromptFile $badPrompt -Profile none -ClaudeExe $fake -Confirm:$false 2>&1 | Out-String
$code7 = $LASTEXITCODE
$ErrorActionPreference = $old
Judge 'bad prompt: exit code 2' ($code7 -eq 2) ('exit=' + $code7)
Judge 'bad prompt: names the placeholder' ($out7 -match '\{item\}') ''

Write-Output ''
Write-Output ("{0} of {1} cases as expected, {2} errors" -f ($total - $errors), $total, $errors)
if ($errors -gt 0) { exit 1 } else { exit 0 }
