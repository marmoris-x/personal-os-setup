# morning.ps1 - Life OS morning run. Called by the two scheduled tasks (logon + 2 min, {{MORNING_TIME}}).
#
# Order (the order's part 5.1): lock -> transcribe.ps1 -> headless agent -> cleanup.ps1.
# The agent runs with the claude-ds profile (DeepSeek), no shell, no web, no MCP tools, and
# file writes only inside the vault (scoped Edit rule; proved 2026-10-08: write inside the
# working directory passed, a write outside was denied). Never --bare: that would switch off
# the security hooks. The run is capped at $TimeoutMinutes; on overrun the process tree is
# killed. The JSON result and everything the child printed go into the log file.

param(
    [string]$VaultPath = '{{VAULT}}',
    [string]$Model = 'large-v3-turbo',
    [string]$LogDir = '{{DEV}}\Temp\life-os-logs',
    [int]$TimeoutMinutes = 30,
    [string]$ClaudeExe = "{{HOME_ENV}}\.local\bin\claude.exe",
    [string]$SettingsPath = "{{HOME_ENV}}\.claude\profiles\deepseek.json",
    [string]$LockPath = "{{LIFEOS_LOCK}}",
    [string]$Prompt = '/life-os-morning',
    [string]$AllowedTools = '',
    [switch]$ForceAgent
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\life-os-common.ps1"

if (-not $AllowedTools) {
    # Path-scoped write approval for the vault only, in the normalized form Claude Code
    # matches on Windows ("//c/..." - see the permissions page, Windows note).
    $drive = $VaultPath.Substring(0, 1).ToLower()
    $rest = $VaultPath.Substring(3) -replace '\\', '/'
    $AllowedTools = "Edit(//$drive/$rest/**)"
}

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$logFile = Get-LifeOsLogPath $LogDir 'morning'
function Write-RunLog([string]$text) {
    Append-Utf8 $logFile ((Get-Date).ToString('s') + ' ' + $text + "`n")
}

if (-not (Acquire-LifeOsLock $LockPath)) {
    Write-RunLog 'another Life OS run is active - this run stops'
    exit 0
}

$success = $false
$summary = 'not started'
try {
    Write-RunLog ('run start (whisper model ' + $Model + ', agent timeout ' + $TimeoutMinutes + ' min)')

    # 1. transcribe (child process: it holds its own exit codes)
    $prevEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $transcribeOut = & {{PWSH_HOST}} -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $PSScriptRoot 'transcribe.ps1') -VaultPath $VaultPath -Model $Model `
        -CalledByRunner -LockPath $LockPath 2>&1
    $transcribeExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEA
    Write-RunLog ('transcribe exit ' + $transcribeExit)
    foreach ($line in $transcribeOut) { Write-RunLog ('  transcribe: ' + [string]$line) }

    # 2. pre-check (owner's request 2026-10-08): when there is nothing to do, the agent must
    # not start - an empty run would cost money for nothing. Nothing to do means, all at once:
    # no waiting transcript (self-healing stays: a stuck .txt from an earlier failed run
    # counts), no sync conflict in conflicts.json, no failed file in this run's transcribe
    # line, and no change under 100-daily since the last "morning" line in the run log.
    # On any doubt (unreadable file, no run log yet, transcription not clean) the agent runs.
    $runsLog = Join-Path $VaultPath '000-meta\life-os-runs.log'
    $skipAgent = $false
    $skipReason = ''
    if ((-not $ForceAgent) -and ($transcribeExit -eq 0)) {
        $waiting = -1
        $conflicts = -1
        $dailyChanged = $true
        $transcribeClean = $false
        try {
            $runsLines = @()
            if (Test-Path -LiteralPath $runsLog) { $runsLines = @(Get-Content -LiteralPath $runsLog -Encoding UTF8 | Select-Object -Last 15) }
            $lastRun = $null
            foreach ($line in $runsLines) {
                if ($line -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} \| morning \| [a-z]+ \|') { $lastRun = $line.Substring(0, 19) }
            }
            $tLine = $null
            foreach ($line in $runsLines) {
                if ($line -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} \| transcribe \|') { $tLine = $line }
            }
            if ($tLine -and ($tLine -notmatch 'failed=[1-9]')) { $transcribeClean = $true }

            $inboxPath = Join-Path $VaultPath '000-meta\life-os-inbox.json'
            if (Test-Path -LiteralPath $inboxPath) {
                $t = (Get-Content -LiteralPath $inboxPath -Raw -Encoding UTF8 | ConvertFrom-Json).transcripts
                $waiting = 0
                if ($t) { $waiting = @($t).Count }
            } else { $waiting = 0 }

            $conflictPath = Join-Path $VaultPath '000-meta\life-os-conflicts.json'
            if (Test-Path -LiteralPath $conflictPath) {
                $c = (Get-Content -LiteralPath $conflictPath -Raw -Encoding UTF8 | ConvertFrom-Json).conflicts
                $conflicts = 0
                if ($c) { $conflicts = @($c).Count }
            } else { $conflicts = 0 }

            if ($lastRun) {
                $newest = Get-ChildItem -LiteralPath (Join-Path $VaultPath '100-daily') -Filter '*.md' -File -ErrorAction Stop |
                          Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $dailyChanged = ($null -ne $newest) -and ($newest.LastWriteTime -gt [datetime]$lastRun)
            }
        } catch {
            Write-RunLog ('pre-check unreadable, the agent runs: ' + $_.Exception.Message)
        }
        if ($transcribeClean -and $waiting -eq 0 -and $conflicts -eq 0 -and (-not $dailyChanged)) {
            $skipAgent = $true
            $skipReason = 'nothing to do (no waiting transcripts, no conflicts, no 100-daily change since ' + $lastRun + ')'
        }
    }
    if ($skipAgent) {
        Write-RunLog ('agent skipped: ' + $skipReason)
        Append-Utf8 $runsLog ((Get-Date).ToString('s') + ' | morning | skip | ' + $skipReason + "`n")
        Write-RunLog 'run end: skip'
        exit 0
    }

    # 3. the agent
    if (-not (Test-Path -LiteralPath $ClaudeExe)) {
        Write-RunLog ('claude not found at ' + $ClaudeExe)
        throw 'claude executable missing'
    }
    $outFile = Join-Path $LogDir ('morning-' + (Get-Date).ToString('yyyy-MM-dd-HHmmss') + '.json')
    $errFile = $outFile + '.err'
    $arguments = '--settings "' + $SettingsPath + '" -p "' + $Prompt + '"' +
                 ' --permission-mode dontAsk' +
                 ' --tools "Read,Edit,Write,Glob,Grep,Skill"' +
                 ' --allowedTools "' + $AllowedTools + '"' +
                 ' --disallowedTools "mcp__*"' +
                 ' --max-turns 60 --output-format json'
    Write-RunLog ('agent start: ' + $ClaudeExe)
    $proc = Start-Process -FilePath $ClaudeExe -ArgumentList $arguments -WorkingDirectory $VaultPath `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $waited = Wait-Process -Id $proc.Id -Timeout ($TimeoutMinutes * 60) -ErrorAction SilentlyContinue
    $proc.Refresh()
    $timedOut = -not $proc.HasExited
    if ($timedOut) {
        Write-RunLog ('agent timeout after ' + $TimeoutMinutes + ' min - killing process tree')
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | ForEach-Object { Write-RunLog ('  taskkill: ' + [string]$_) }
        Start-Sleep -Seconds 3
        $proc.Refresh()
    }
    # Note (measured 2026-10-08): in Windows PowerShell 5.1, Start-Process -PassThru with
    # redirection leaves ExitCode empty ($null); PowerShell 7 fills it. The verdict therefore
    # rests on the JSON result, and the exit code is only logged when it exists.
    $agentExit = $null
    if ($proc.HasExited) { try { $agentExit = $proc.ExitCode } catch { $agentExit = $null } }
    $exitText = 'n/a'
    if ($null -ne $agentExit -and [string]$agentExit -ne '') { $exitText = [string]$agentExit }
    Write-RunLog ('agent exit ' + $exitText + ' (timed out: ' + $timedOut + ')')

    # 4. evaluate the JSON result
    $resultText = ''
    $isError = $true
    $res = $null
    $turns = ''; $cost = ''
    if (Test-Path -LiteralPath $outFile) {
        $raw = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
        $res = $null
        if ($raw) {
            try { $res = $raw | ConvertFrom-Json } catch {
                # stdout may carry warnings before the JSON: take the outermost {...} block
                $start = $raw.IndexOf('{'); $end = $raw.LastIndexOf('}')
                if ($start -ge 0 -and $end -gt $start) {
                    try { $res = $raw.Substring($start, $end - $start + 1) | ConvertFrom-Json } catch { }
                }
            }
        }
        if ($res) {
            $isError = [bool]$res.is_error
            $turns = $res.num_turns
            $cost = $res.total_cost_usd
            $resultText = [string]$res.result
            Write-RunLog ('agent result: is_error=' + $isError + ' subtype=' + $res.subtype +
                          ' turns=' + $turns + ' cost=' + $cost)
        } else {
            Write-RunLog 'agent produced no readable JSON output'
        }
    }
    if (Test-Path -LiteralPath $errFile) {
        $errText = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8
        if ($errText -and $errText.Trim()) {
            foreach ($line in ($errText -split "`r?`n" | Select-Object -First 20)) {
                Write-RunLog ('  agent stderr: ' + $line)
            }
        }
    }

    $success = (-not $timedOut) -and ($null -ne $res) -and (-not $isError)
    $firstLine = ''
    if ($resultText) { $firstLine = (($resultText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) }
    if ($firstLine.Length -gt 150) { $firstLine = $firstLine.Substring(0, 150) }
    if ($success) { $summary = 'turns=' + $turns + ' cost=' + $cost + ' | ' + $firstLine }
    else { $summary = 'FAILED timedOut=' + $timedOut + ' exit=' + $exitText + ' | ' + $firstLine }

    # 5. cleanup (only after a successful agent run may recordings leave the inbox)
    $cleanArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                   (Join-Path $PSScriptRoot 'cleanup.ps1'), '-VaultPath', $VaultPath, '-LogDir', $LogDir)
    if (-not $success) { $cleanArgs += '-SkipInbox' }
    $prevEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $cleanOut = & {{PWSH_HOST}} @cleanArgs 2>&1
    $cleanExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEA
    Write-RunLog ('cleanup exit ' + $cleanExit)
    foreach ($line in $cleanOut) { Write-RunLog ('  cleanup: ' + [string]$line) }

    $state = 'ok'; if (-not $success) { $state = 'fail' }
    Append-Utf8 (Join-Path $VaultPath '000-meta\life-os-runs.log') `
        ((Get-Date).ToString('s') + ' | morning | ' + $state + ' | ' + $summary + "`n")
    Write-RunLog ('run end: ' + $state)
    if ($success) { exit 0 } else { exit 1 }
} catch {
    Write-RunLog ('run crashed: ' + $_.Exception.Message)
    try {
        Append-Utf8 (Join-Path $VaultPath '000-meta\life-os-runs.log') `
            ((Get-Date).ToString('s') + ' | morning | fail | ' + $_.Exception.Message + "`n")
    } catch { }
    exit 1
} finally {
    Release-LifeOsLock $LockPath
}
