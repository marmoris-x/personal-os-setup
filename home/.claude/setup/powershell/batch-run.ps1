#!/usr/bin/env pwsh
# batch-run.ps1 - one fresh headless Claude Code session per item.
#
#   pwsh batch-run.ps1 -List items.txt -PromptFile prompt.txt [-Profile claude-ds]
#
# Why: a long session loses quality as its context grows (Context Rot). For many similar
# items one fresh `claude -p` run per item keeps every context clean. The flags and the JSON
# result are the documented headless interface (code.claude.com/docs/en/headless).
#
# The prompt template must contain {item}; the item text replaces it and reaches Claude as one
# argument - never through a shell. Never pass --bare: bare mode skips hooks and CLAUDE.md, so
# the guards would not run. The profile name maps to the same --settings file the user's
# launcher function uses; hooks and deny rules come from the global settings either way.
# A workflow launched inside a -p item dies when the item's turn ends and the session exits:
# run workflows in the main session, not through this script.
#
# State: <list>.state.jsonl, one JSON line per item and attempt:
#   item, status (done/failed/skipped), exit_code, total_cost_usd, duration_ms, session_id,
#   reason, finished_at. A re-run skips the items whose last status is done.
# Log: <list>.log, the full stdout/stderr of every call.
#
# Exit codes: 0 all attempted items done, 1 at least one failure, 2 bad input or missing tool.
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [string]$List,
    [string]$PromptFile,
    [string]$Profile = 'claude-ds',
    [string]$WorkDir = '',
    [int]$MaxItems = 0,
    [double]$MaxBudgetUsd = 1.00,
    [string]$ClaudeExe = 'claude',
    [bool]$Confirm = $true,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$Message) {
    [Console]::Error.WriteLine('batch-run: ' + $Message)
    exit 2
}

if (-not $List) { Fail '-List is required' }
if (-not $PromptFile) { Fail '-PromptFile is required' }
if (-not (Test-Path -LiteralPath $List)) { Fail ('list not found: ' + $List) }
if (-not (Test-Path -LiteralPath $PromptFile)) { Fail ('prompt template not found: ' + $PromptFile) }
if ($MaxBudgetUsd -le 0) { Fail '-MaxBudgetUsd must be greater than 0' }
if ($MaxItems -lt 0) { Fail '-MaxItems must be 0 or greater' }

$ListFull = (Resolve-Path -LiteralPath $List).Path
$PromptFull = (Resolve-Path -LiteralPath $PromptFile).Path
$template = [IO.File]::ReadAllText($PromptFull)
if (-not $template.Contains('{item}')) { Fail 'the prompt template must contain {item}' }

if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $WorkDir)) { Fail ('working directory not found: ' + $WorkDir) }

# The launcher functions map a profile to one --settings file. The same map here keeps the
# batch on the user's provider, settings and hooks without needing the profile in this process.
$profilePath = $null
if ($Profile -eq 'none' -or $Profile -eq 'claude') {
    $profilePath = $null
} else {
    $homePath = [Environment]::GetFolderPath('UserProfile')
    if ($Profile -eq 'claude-ds') { $profilePath = Join-Path $homePath '.claude/profiles/deepseek.json' }
    elseif ($Profile -eq 'claude-or') { $profilePath = Join-Path $homePath '.claude/profiles/openrouter.json' }
    elseif ($Profile.EndsWith('.json')) { $profilePath = $Profile }
    else { Fail ('unknown profile: ' + $Profile) }
    if (-not (Test-Path -LiteralPath $profilePath)) { Fail ('profile file not found: ' + $profilePath) }
}

$resolvedExe = $ClaudeExe
if (Test-Path -LiteralPath $ClaudeExe) {
    $resolvedExe = (Resolve-Path -LiteralPath $ClaudeExe).Path
} else {
    $cmd = Get-Command $ClaudeExe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Fail ('claude command not found: ' + $ClaudeExe) }
    $resolvedExe = $cmd.Source
    if (-not $resolvedExe) { $resolvedExe = $cmd.Name }
}

# --- the list ---------------------------------------------------------------
$items = @()
$seen = @{}
foreach ($line in ([IO.File]::ReadAllLines($ListFull))) {
    $item = $line.Trim()
    if (-not $item) { continue }
    if ($item.StartsWith('#')) { continue }
    if ($seen.ContainsKey($item)) { continue }
    $seen[$item] = $true
    $items += $item
}
if ($items.Count -eq 0) { Fail 'the list has no items' }

# --- the state --------------------------------------------------------------
$statePath = $ListFull + '.state.jsonl'
$logPath = $ListFull + '.log'
$lastStatus = @{}
if (Test-Path -LiteralPath $statePath) {
    $lineNo = 0
    foreach ($line in ([IO.File]::ReadAllLines($statePath))) {
        $lineNo++
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json } catch { Fail ('state file is corrupt at line ' + $lineNo + ': ' + $statePath) }
        if ($row.item) { $lastStatus[[string]$row.item] = [string]$row.status }
    }
}

$pending = @()
foreach ($item in $items) {
    if ($lastStatus.ContainsKey($item) -and $lastStatus[$item] -eq 'done') { continue }
    $pending += $item
}
$alreadyDone = $items.Count - $pending.Count

$plan = $pending
if ($MaxItems -gt 0 -and $plan.Count -gt $MaxItems) { $plan = @($plan | Select-Object -First $MaxItems) }

Write-Output ('batch-run: ' + $items.Count + ' items, ' + $pending.Count + ' open, ' + $plan.Count + ' in this run')
if ($DryRun) {
    foreach ($item in $plan) { Write-Output ('[dry] ' + $item) }
    Write-Output ('BATCH dry=' + $plan.Count + ' skipped=' + $alreadyDone)
    exit 0
}

if ($Confirm -and $plan.Count -gt 20) {
    Write-Output ('This batch will run ' + $plan.Count + ' items. Type yes to continue:')
    $answer = [Console]::In.ReadLine()
    if ($null -eq $answer -or $answer.Trim().ToLowerInvariant() -ne 'yes') {
        Write-Output 'batch-run: not confirmed, nothing was run (pass -Confirm:$false to skip the question)'
        exit 2
    }
}

if ($plan.Count -eq 0) {
    Write-Output ('BATCH done=0 failed=0 skipped=' + $alreadyDone + ' cost=0.0000 time=0.0s')
    exit 0
}

# --- the runs ---------------------------------------------------------------
[IO.File]::AppendAllText($logPath, (
    "=== batch start " + (Get-Date).ToString('s') + " list=" + $ListFull +
    " items=" + $plan.Count + " profile=" + $Profile + "`n"), $utf8)

$done = 0
$failed = 0
$skipped = $alreadyDone
$totalCost = 0.0
$totalWatch = [Diagnostics.Stopwatch]::StartNew()
$failuresInARow = 0
$stopped = $false
$index = 0

foreach ($item in $plan) {
    $index++
    $prompt = $template.Replace('{item}', $item)
    $arguments = @()
    if ($profilePath) { $arguments += @('--settings', $profilePath) }
    $arguments += @('-p', $prompt, '--output-format', 'json', '--max-budget-usd', $MaxBudgetUsd.ToString([CultureInfo]::InvariantCulture))

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $safe = ($index.ToString('D4') + '-' + $stamp)
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('batch-run-' + $safe + '.out')
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ('batch-run-' + $safe + '.err')

    [IO.File]::AppendAllText($logPath, ("--- item " + $index + "/" + $plan.Count + ": " + $item + "`n"), $utf8)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $exitCode = $null
    $global:LASTEXITCODE = 0
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location -LiteralPath $WorkDir
        try { & $resolvedExe @arguments 1> $outFile 2> $errFile } finally { Pop-Location }
        $exitCode = $LASTEXITCODE
    } catch {
        [IO.File]::AppendAllText($errFile, ('launch error: ' + $_.Exception.Message + "`n"), $utf8)
    } finally {
        $ErrorActionPreference = $previous
        $watch.Stop()
    }

    $rawOut = ''
    if (Test-Path -LiteralPath $outFile) { $rawOut = [IO.File]::ReadAllText($outFile) }
    $rawErr = ''
    if (Test-Path -LiteralPath $errFile) { $rawErr = [IO.File]::ReadAllText($errFile) }

    $result = $null
    if ($rawOut.Trim()) {
        try { $result = $rawOut | ConvertFrom-Json } catch {
            $start = $rawOut.IndexOf('{'); $end = $rawOut.LastIndexOf('}')
            if ($start -ge 0 -and $end -gt $start) {
                try { $result = $rawOut.Substring($start, $end - $start + 1) | ConvertFrom-Json } catch { $result = $null }
            }
        }
    }

    $cost = $null
    $sessionId = $null
    $isError = $true
    $reason = ''
    if ($null -eq $exitCode -or [string]$exitCode -eq '') { $exitCode = 0 }
    if ($result) {
        $isError = [bool]$result.is_error
        if ($null -ne $result.total_cost_usd) { $cost = [double]$result.total_cost_usd }
        if ($result.session_id) { $sessionId = [string]$result.session_id }
        if ($isError) { $reason = 'is_error' }
    } else {
        $reason = 'invalid-json'
    }
    if ($exitCode -ne 0) { $reason = 'exit-' + $exitCode; $isError = $true }

    $ok = ($exitCode -eq 0) -and ($null -ne $result) -and (-not $isError) -and ($reason -eq '')
    $status = if ($ok) { 'done' } else { 'failed' }
    if ($ok) { $done++ } else { $failed++ }
    if ($null -ne $cost) { $totalCost += $cost }

    $record = [ordered]@{
        item           = $item
        status         = $status
        exit_code      = $exitCode
        total_cost_usd = $cost
        duration_ms    = [int]$watch.ElapsedMilliseconds
        session_id     = $sessionId
        reason         = if ($reason) { $reason } else { $null }
        finished_at    = (Get-Date).ToString('s')
    }
    [IO.File]::AppendAllText($statePath, (($record | ConvertTo-Json -Compress) + "`n"), $utf8)

    [IO.File]::AppendAllText($logPath, ("stdout:`n" + $rawOut + "`nstderr:`n" + $rawErr + "`n"), $utf8)
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    $costText = if ($null -ne $cost) { $cost.ToString('F4', [CultureInfo]::InvariantCulture) } else { '-' }
    $line = '[' + $index + '/' + $plan.Count + '] ' + $status.PadRight(6) + ' ' + $item + '  cost=' + $costText + ' time=' + $watch.Elapsed.TotalSeconds.ToString('F1', [CultureInfo]::InvariantCulture) + 's'
    if (-not $ok) { $line += ' exit=' + $exitCode + ' reason=' + $reason }
    Write-Output $line

    if ($ok) { $failuresInARow = 0 } else { $failuresInARow++ }
    if ($failuresInARow -ge 3 -and $index -lt $plan.Count) {
        $stopped = $true
        for ($rest = $index; $rest -lt $plan.Count; $rest++) {
            $restItem = $plan[$rest]
            $skipRecord = [ordered]@{
                item           = $restItem
                status         = 'skipped'
                exit_code      = $null
                total_cost_usd = $null
                duration_ms    = 0
                session_id     = $null
                reason         = 'stopped-after-3-failures'
                finished_at    = (Get-Date).ToString('s')
            }
            [IO.File]::AppendAllText($statePath, (($skipRecord | ConvertTo-Json -Compress) + "`n"), $utf8)
            $skipped++
        }
        Write-Output ('batch-run: stopped after 3 failures in a row; ' + ($plan.Count - $index) + ' remaining item(s) marked skipped')
        break
    }
}

$totalWatch.Stop()
[IO.File]::AppendAllText($logPath, (
    "=== batch end " + (Get-Date).ToString('s') + " done=$done failed=$failed skipped=$skipped stopped=$stopped`n"), $utf8)

Write-Output ('BATCH done=' + $done + ' failed=' + $failed + ' skipped=' + $skipped +
    ' cost=' + $totalCost.ToString('F4', [CultureInfo]::InvariantCulture) +
    ' time=' + $totalWatch.Elapsed.TotalSeconds.ToString('F1', [CultureInfo]::InvariantCulture) + 's')
if ($failed -gt 0) { exit 1 }
exit 0
