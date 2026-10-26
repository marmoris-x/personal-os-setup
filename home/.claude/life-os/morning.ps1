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
    [string]$PythonExe = "{{LIFEOS_PYTHON}}",
    [string]$LockPath = "{{LIFEOS_LOCK}}",
    [string]$Prompt = '/life-os-morning',
    [string]$AllowedTools = '',
    [string]$DevRoot = '{{DEV}}\Projects',
    [string]$TrackerStatePath = "{{LIFEOS_STATE}}\projects-state.json",
    [string]$SeenPath = "{{LIFEOS_STATE}}\inbox-seen.json",
    [string]$Crawl4AiVenvPython = '',
    [string]$Crawl4AiFetchScript = '',
    [switch]$ForceAgent,
    [switch]$ForceWeekly
)

$ErrorActionPreference = 'Stop'

# Input check at the edge: the vault must be an existing absolute folder. A value that arrives
# by mistake (a hashtable handed over as the first argument becomes the text
# "System.Collections.Hashtable") would otherwise create that folder, with the tracker's and the
# transcription's files in it, in whatever folder the script was started from.
if (-not [IO.Path]::IsPathRooted($VaultPath) -or -not (Test-Path -LiteralPath $VaultPath -PathType Container)) {
    [Console]::Error.WriteLine('morning.ps1: VaultPath is not an existing absolute folder: ' + $VaultPath)
    exit 2
}

. "$PSScriptRoot\life-os-common.ps1"
. "$PSScriptRoot\morning-checks.ps1"
. "$PSScriptRoot\area-check.ps1"

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
$runStart = Get-Date
try {
    Write-RunLog ('run start (whisper model ' + $Model + ', agent timeout ' + $TimeoutMinutes + ' min)')

    # 0. projects: read-only git scan of {{DEV}}\Projects. It writes the flag file only on a
    # day with changes, attention (uncommitted/unpushed), a git error or a large file; the hint
    # lines (step 2b) and the stale-hub check of the pre-check read that file. A tracker failure
    # becomes a hint line.
    $projectsFlag = Join-Path $VaultPath '000-meta\life-os-projects.json'
    $extraHints = @()
    $trackerScript = Join-Path $PSScriptRoot 'project-tracker.ps1'
    if (Test-Path -LiteralPath $trackerScript) {
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $trackerOut = & {{PWSH_HOST}} -NoProfile -ExecutionPolicy Bypass -File $trackerScript `
            -VaultPath $VaultPath -DevRoot $DevRoot -StatePath $TrackerStatePath -LogDir $LogDir 2>&1
        $trackerExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
        Write-RunLog ('tracker exit ' + $trackerExit)
        foreach ($line in $trackerOut) { Write-RunLog ('  tracker: ' + [string]$line) }
        # A failed tracker is a hint line, not a reason for the agent: it has no shell and could
        # not do more than report it.
        if ($trackerExit -ne 0) { $extraHints += ('Projekt-Tracker fehlgeschlagen (Exit ' + $trackerExit + ')') }
    } else {
        Write-RunLog 'tracker skipped: project-tracker.ps1 missing'
        $extraHints += 'Projekt-Tracker fehlt (project-tracker.ps1)'
    }

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

    # 1a. loose notes and other files in inbox/ (token-free): written into life-os-inbox.json next
    # to the transcripts, which the transcriber has just rewritten.
    try {
        Update-InboxJson -VaultPath $VaultPath
        Write-RunLog 'inbox scan ok'
        # The script copies the notes itself: exact, free, and the agent only orders them.
        $takenNotes = Add-InboxNotesToRoh -VaultPath $VaultPath
        Write-RunLog ('loose notes taken into Roh: ' + @($takenNotes).Count)
    } catch {
        Write-RunLog ('inbox scan failed: ' + $_.Exception.Message)
        $extraHints += ('Eingang konnte nicht gelesen werden: ' + $_.Exception.Message)
    }

    # 1c. the names and aliases of the area notes (no content), for the agent's area step
    try { Write-AreasJson -VaultPath $VaultPath } catch { Write-RunLog ('areas json failed: ' + $_.Exception.Message) }

    # 1d. Mondays: which area notes are older than the newest document in their archive folder
    # (file names only, no content). The hint line is written by Write-HintBlock.
    if ((Get-Date).DayOfWeek -eq 'Monday' -or $ForceWeekly) {
        try { Update-AreasStale -VaultPath $VaultPath; Write-RunLog 'areas-stale written' }
        catch { Write-RunLog ('areas-stale failed: ' + $_.Exception.Message) }
    }

    # 1b. expiry (vault-lint): notes whose valid_until is past or within 7 days. The morning
    # skill has no shell on purpose, so the wrapper runs the read-only check and hands the
    # agent one JSON file. It never edits a note; the single line in the Morgenbericht is all.
    $expiryScript = Join-Path $VaultPath '.claude\skills\vault-lint\expiry.py'
    $expiryJson = Join-Path $VaultPath '000-meta\life-os-expiry.json'
    $expiring = 0
    if ((Test-Path -LiteralPath $PythonExe) -and (Test-Path -LiteralPath $expiryScript)) {
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $expiryOut = & $PythonExe -I -X utf8 $expiryScript --vault $VaultPath --days 7 --json $expiryJson 2>&1
        $expiryExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
        Write-RunLog ('expiry exit ' + $expiryExit)
        foreach ($line in $expiryOut) { Write-RunLog ('  expiry: ' + [string]$line) }
        try {
            $parsed = @()
            if (Test-Path -LiteralPath $expiryJson) {
                $parsed = @(Get-Content -LiteralPath $expiryJson -Raw -Encoding UTF8 | ConvertFrom-Json)
            }
            # an empty JSON array parses to $null, and @($null).Count is 1 - the same trap
            # rules/powershell-batch.md names. Treat that one null element as zero findings.
            if ($parsed.Count -eq 1 -and $null -eq $parsed[0]) { $parsed = @() }
            $expiring = $parsed.Count
        } catch {
            Write-RunLog ('expiry JSON unreadable: ' + $_.Exception.Message)
            $expiring = 0
        }
    } else {
        Write-RunLog ('expiry skipped: python or expiry.py missing')
    }

    # 1e. Crawl4AI self-test (token-free, 60 s limit): one small stable page through the same
    # helper the research runs use. On 2026-10-25 its browser folder was found empty after two
    # silent days; now a defect is a Morgenbericht line the same morning. The script writes the
    # line itself and never starts the agent for it: the agent could not repair a browser.
    $c4State = 'fail'
    $selfTest = Join-Path $PSScriptRoot 'crawl4ai-selftest.ps1'
    $c4Reason = 'crawl4ai-selftest.ps1 is missing'
    if (Test-Path -LiteralPath $selfTest) {
        $stArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $selfTest, '-TimeoutSeconds', '60')
        if ($Crawl4AiVenvPython) { $stArgs += @('-VenvPython', $Crawl4AiVenvPython) }
        if ($Crawl4AiFetchScript) { $stArgs += @('-FetchScript', $Crawl4AiFetchScript) }
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $stOut = @(& {{PWSH_HOST}} @stArgs 2>&1 | ForEach-Object { [string]$_ })
        $stExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
        $stLine = ($stOut | Where-Object { $_ -match '^crawl4ai=' } | Select-Object -Last 1)
        if ($stExit -eq 0 -and $stLine -eq 'crawl4ai=ok') { $c4State = 'ok'; $c4Reason = '' }
        elseif ($stLine -match '^crawl4ai=fail: (.*)$') { $c4Reason = $Matches[1] }
        else { $c4Reason = 'self-test gave no result (exit ' + $stExit + ')' }
    }
    Write-RunLog ('crawl4ai self-test: ' + $c4State + $(if ($c4Reason) { ' - ' + $c4Reason } else { '' }))
    if ($c4State -ne 'ok') { $extraHints += ('Crawl4AI defekt: ' + $c4Reason + ' - Abhilfe: crawl4ai-setup') }

    # 2. pre-check (owner's request 2026-10-08, narrowed 2026-10-25): the agent starts only when
    # there is something to ORDER, and the log says what. A hint that a script can write itself
    # (not committed, not pushed, a note about to expire, a transcription fallback, a failed
    # run) starts nothing: step 2b writes those lines. Reasons, see Get-AgentReasons: a waiting
    # transcript (self-healing stays: a stuck .txt from an earlier failed run counts), a sync
    # conflict, a loose note or other file in the inbox, typed text after the stored anchor, a
    # changed project whose hub is older than its repository. On any doubt (an unreadable file,
    # no clean transcription) the agent runs.
    $runsLog = Join-Path $VaultPath '000-meta\life-os-runs.log'
    $reasons = @()
    if ($ForceAgent) { $reasons += 'forced' }
    elseif ($transcribeExit -ne 0) { $reasons += ('transcribe exit ' + $transcribeExit) }
    else {
        $tLine = $null
        if (Test-Path -LiteralPath $runsLog) {
            foreach ($line in @(Get-Content -LiteralPath $runsLog -Encoding UTF8 | Select-Object -Last 15)) {
                if ($line -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} \| transcribe \|') { $tLine = $line }
            }
        }
        if (-not $tLine -or ($tLine -match 'failed=[1-9]')) { $reasons += 'transcription not clean' }
        try { $reasons += @(Get-AgentReasons -VaultPath $VaultPath -DevRoot $DevRoot -SeenPath $SeenPath) }
        catch { $reasons += ('pre-check unreadable: ' + $_.Exception.Message) }
    }

    # 2b. the hint lines (no language model): written into today's Morgenbericht after the
    # agent (or instead of it), in a block of their own that the agent never touches.
    function Write-HintBlock {
        try {
            $hints = @(Get-HintLines -VaultPath $VaultPath -Today (Get-Date)) + $extraHints
            Set-MorgenberichtBlock -VaultPath $VaultPath -Date (Get-Date).ToString('yyyy-MM-dd') -Lines $hints
            Write-RunLog ('hint lines written: ' + @($hints | Where-Object { $_ }).Count)
            return $true
        } catch {
            Write-RunLog ('hint lines failed: ' + $_.Exception.Message)
            return $false
        }
    }

    # 5 (shared). cleanup.ps1: trash queue, log rotation, and with $SkipInbox false the finished
    # recordings. Both ends of the run call it, so a quiet day also writes its own cleanup line
    # (2026-10-26: the skip path ended before it, and that morning wrote no cleanup line).
    function Invoke-CleanupStep([bool]$SkipInboxStep) {
        $cleanArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                       (Join-Path $PSScriptRoot 'cleanup.ps1'), '-VaultPath', $VaultPath, '-LogDir', $LogDir)
        if ($SkipInboxStep) { $cleanArgs += '-SkipInbox' }
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $cleanOut = & {{PWSH_HOST}} @cleanArgs 2>&1
        $cleanExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
        Write-RunLog ('cleanup exit ' + $cleanExit)
        foreach ($line in $cleanOut) { Write-RunLog ('  cleanup: ' + [string]$line) }
    }

    if ($reasons.Count -eq 0) {
        $skipReason = 'nothing to order (no transcript, loose note, conflict, typed text or stale project hub); hints are written by the script'
        $hintsOk = Write-HintBlock
        # The flag is a signal for this run: with the hints written and no agent needed, it is used up.
        if ($hintsOk -and (Test-Path -LiteralPath $projectsFlag)) {
            Remove-Item -LiteralPath $projectsFlag -Force -ErrorAction SilentlyContinue
            Write-RunLog 'project flag consumed'
        }
        Write-RunLog ('agent skipped: ' + $skipReason)
        # No agent ran, so no recording may leave the inbox; the trash queue and the logs still go.
        Invoke-CleanupStep $true
        Append-Utf8 $runsLog ((Get-Date).ToString('s') + ' | morning | skip | ' + $skipReason + ' | crawl4ai=' + $c4State + "`n")
        Write-RunLog ('vault: ' + (Save-VaultCommit -VaultPath $VaultPath -Message ('chore(morning): daily run ' + (Get-Date).ToString('yyyy-MM-dd'))))
        Write-RunLog 'run end: skip'
        exit 0
    }
    Write-RunLog ('agent reasons: ' + ($reasons -join '; '))
    try { Set-FlagHubStale -VaultPath $VaultPath -Reasons $reasons }
    catch { Write-RunLog ('hub_stale not written: ' + $_.Exception.Message) }

    # The area notes as they stand before the agent: the safety net after the agent compares
    # with and restores from this copy (area-check.ps1).
    $areaSnapshot = Join-Path $LogDir 'area-snapshot'
    $areaSnapshotOk = $false
    try { New-AreaSnapshot -VaultPath $VaultPath -SnapshotDir $areaSnapshot; $areaSnapshotOk = $true }
    catch { Write-RunLog ('area snapshot failed (the area step is not checked, so it is not trusted): ' + $_.Exception.Message) }

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
    $turns = ''; $cost = ''; $costDs = ''; $costDsText = ''
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
            try { $costDs = Get-DeepSeekCost -ModelUsage $res.modelUsage -AtUtc ([datetime]::UtcNow) } catch { $costDs = '' }
            if ("$costDs" -eq 'unknown') { $costDsText = ' cost_ds=unknown' }
            elseif ("$costDs" -ne '') { $costDsText = ' cost_ds=' + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.######}', $costDs)) }
            $resultText = [string]$res.result
            Write-RunLog ('agent result: is_error=' + $isError + ' subtype=' + $res.subtype +
                          ' turns=' + $turns + ' cost=' + $cost + $costDsText)
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

    # 4-. safety net for 300-areas: restore every area note whose change has no source
    if ($areaSnapshotOk) {
        try {
            $areaResults = @(Invoke-AreaCheck -VaultPath $VaultPath -SnapshotDir $areaSnapshot)
            foreach ($r in ($areaResults | Where-Object { $_.status -ne 'unchanged' })) {
                Write-RunLog ('  area-check: ' + $r.status + ' ' + $r.file + ' ' + (@($r.reasons) -join '; '))
            }
            $extraHints += @(Format-AreaResultLines $areaResults)
        } catch {
            Write-RunLog ('area-check failed: ' + $_.Exception.Message)
            $extraHints += ('Bereichspr' + [char]0x00FC + 'fung fehlgeschlagen: ' + $_.Exception.Message)
        }
    } else {
        $extraHints += ('Bereichspr' + [char]0x00FC + 'fung nicht m' + [char]0x00F6 + 'glich (kein Stand vor dem Agenten); Bereichsnotizen bitte ansehen')
    }
    # The snapshot is a plain copy of the area notes outside the vault; it is not kept.
    if (Test-Path -LiteralPath $areaSnapshot) {
        try { Remove-Item -LiteralPath $areaSnapshot -Recurse -Force -ErrorAction Stop }
        catch { Write-RunLog ('area snapshot not removed: ' + $_.Exception.Message) }
    }

    # 4a. one task list: tasks the agent wrote into a daily note's "## Aufgaben" move to todo.md
    try {
        Move-DailyTasksToTodo -VaultPath $VaultPath -Since $runStart
        Write-RunLog 'tasks moved to todo.md'
    } catch {
        Write-RunLog ('tasks not moved to todo.md: ' + $_.Exception.Message)
        $extraHints += ('Aufgaben nicht nach todo.md verschoben: ' + $_.Exception.Message)
    }
    # An entry that became a task is not "unclear" as well.
    try { Remove-ResolvedUnclearLines -VaultPath $VaultPath -Since $runStart }
    catch { Write-RunLog ('unclear lines not cleaned: ' + $_.Exception.Message) }

    # 4b. the hint block goes in after the agent, also after a failed one (it reads the flag
    # file, so it comes before the flag is consumed): whatever the agent wrote into
    # "## Morgenbericht", this block stays the script's own.
    [void](Write-HintBlock)

    $success = (-not $timedOut) -and ($null -ne $res) -and (-not $isError)
    if ($success) { try { Save-InboxSeen -VaultPath $VaultPath -SeenPath $SeenPath } catch { Write-RunLog ('seen list failed: ' + $_.Exception.Message) } }
    # The flag is a signal, not a log: a successful agent has consumed it. On a failure it
    # stays, so the next morning's pre-check starts the agent again instead of losing the
    # Timeline/Next-step update.
    if ($success -and (Test-Path -LiteralPath $projectsFlag)) {
        Remove-Item -LiteralPath $projectsFlag -Force -ErrorAction SilentlyContinue
        Write-RunLog 'project flag consumed'
    }
    $firstLine = ''
    if ($resultText) { $firstLine = (($resultText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) }
    if ($firstLine.Length -gt 150) { $firstLine = $firstLine.Substring(0, 150) }
    if ($success) { $summary = 'turns=' + $turns + ' cost=' + $cost + $costDsText + ' crawl4ai=' + $c4State + ' | ' + $firstLine }
    else { $summary = 'FAILED timedOut=' + $timedOut + ' exit=' + $exitText + ' crawl4ai=' + $c4State + ' | ' + $firstLine }

    # 5. cleanup (only after a successful agent run may recordings leave the inbox)
    Invoke-CleanupStep (-not $success)

    $state = 'ok'; if (-not $success) { $state = 'fail' }
    Append-Utf8 (Join-Path $VaultPath '000-meta\life-os-runs.log') `
        ((Get-Date).ToString('s') + ' | morning | ' + $state + ' | ' + $summary + "`n")
    # one commit for the whole run, after the cleanup (a failure is logged and named in the Morgenbericht)
    $commitResult = Save-VaultCommit -VaultPath $VaultPath -Message ('chore(morning): daily run ' + (Get-Date).ToString('yyyy-MM-dd'))
    Write-RunLog ('vault: ' + $commitResult)
    if ($commitResult -like 'commit failed*') {
        $extraHints += ('Vault-Commit fehlgeschlagen: ' + $commitResult)
        [void](Write-HintBlock)
    }
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
