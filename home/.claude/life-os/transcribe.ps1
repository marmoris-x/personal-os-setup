# transcribe.ps1 - Life OS "script before": transcribe new voice recordings, collect the
# morning-run inputs. Called by morning.ps1 (inside its lock) or by hand.
#
# What it does, in order:
#   1. find new audio in <vault>\inbox\audio (top level only; files with a .txt are done,
#      files younger than 30 s are still syncing and wait)
#   2. transcribe them with faster-whisper (worker: transcribe_worker.py, venv beside it);
#      one .txt per recording, written next to the audio
#   3. write <vault>\000-meta\life-os-inbox.json  - every .txt waiting in the inbox
#      (all of them, not only the new ones: self-healing if an agent run fails later)
#   4. write <vault>\000-meta\life-os-conflicts.json - sync conflicts found by
#      .claude\skills\vault-lint\conflicts.py (the agent has no shell, so it reads this file)
#   5. append one line to <vault>\000-meta\life-os-runs.log
#
# Exit code 0 when everything it tried worked (including "nothing to do"), 1 on a hard
# failure (python, worker or vault missing). A single broken audio file does not fail the run.
#
# Lock: takes morning.lock itself unless -CalledByRunner says the runner already holds it.

param(
    [string]$VaultPath = '{{VAULT}}',
    [string]$Model = 'large-v3-turbo',
    [string]$PythonExe = "{{LIFEOS_PYTHON}}",
    [string]$Worker = "{{HOME_ENV}}\.claude\life-os\transcribe_worker.py",
    [string]$LockPath = "{{LIFEOS_LOCK}}",
    [switch]$CalledByRunner
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\life-os-common.ps1"
$script:log = @()

function Write-LogLine([string]$text) {
    $script:log += ((Get-Date).ToString('s') + ' ' + $text)
    Write-Host $text
}

function Get-ConflictEntries([string]$vault) {
    # Runs the vault-lint conflict check and turns its FINDING lines into objects.
    $checker = Join-Path $vault '.claude\skills\vault-lint\conflicts.py'
    if (-not (Test-Path -LiteralPath $checker)) { Write-LogLine 'conflict check not found, skipped'; return @() }
    # Relaxed preference: a native program writing to stderr would be fatal under 'Stop' in 5.1.
    $prevEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = & $PythonExe -I -X utf8 $checker --vault $vault 2>&1
    $ErrorActionPreference = $prevEA
    $entries = @()
    foreach ($line in $lines) {
        $m = [regex]::Match([string]$line, '^FINDING sync conflict: (.+?) \(modified (.+?), (\d+) bytes\)$')
        if ($m.Success) {
            $rel = $m.Groups[1].Value
            # Syncthing names the losing copy <name>.sync-conflict-<date>-<time>-<id>.<ext>.
            # The original is <name>: drop the conflict segment and the appended extension.
            $om = [regex]::Match($rel, '^(.*)\.sync-conflict-\d{8}-\d{6}-[A-Za-z0-9]+(\.[^.]*)$')
            if ($om.Success) { $original = $om.Groups[1].Value }
            else { $original = [regex]::Replace($rel, '\.sync-conflict-\d{8}-\d{6}-[A-Za-z0-9]+', '') }
            $entries += [pscustomobject]@{ file = $rel; original = $original
                                           modified = $m.Groups[2].Value; bytes = [int]$m.Groups[3].Value }
        }
    }
    return @($entries)
}

# --- main ---------------------------------------------------------------------------------

$ok = $true
if (-not (Test-Path -LiteralPath (Join-Path $VaultPath '000-meta'))) {
    Write-Host "vault not found at $VaultPath"
    exit 1
}
$lockIsOurs = $false
if (-not $CalledByRunner) {
    if (-not (Acquire-LifeOsLock $LockPath)) { Write-Host 'another Life OS run is active, transcribe skipped'; exit 0 }
    $lockIsOurs = $true
}

try {
    $audioDir = Join-Path $VaultPath 'inbox\audio'
    if (-not (Test-Path -LiteralPath $audioDir)) { New-Item -ItemType Directory -Force -Path $audioDir | Out-Null }

    $extensions = @('.m4a', '.wav', '.mp3', '.ogg', '.opus', '.flac', '.3gp', '.mp4')
    $now = Get-Date
    $candidates = @()
    foreach ($f in (Get-ChildItem -LiteralPath $audioDir -File)) {
        if ($f.Name.StartsWith('.')) { continue }
        if ($extensions -notcontains $f.Extension.ToLower()) { continue }
        $txt = [IO.Path]::ChangeExtension($f.FullName, '.txt')
        if (Test-Path -LiteralPath $txt) { continue }                    # already transcribed
        if (($now - $f.LastWriteTime).TotalSeconds -lt 30) { continue }  # still being written/synced
        $candidates += $f
    }

    $results = @()
    if ($candidates.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $PythonExe) -or -not (Test-Path -LiteralPath $Worker)) {
            Write-LogLine 'python or worker missing - transcription skipped'
            $ok = $false
        } else {
            Write-LogLine ('transcribing ' + $candidates.Count + ' file(s) with model ' + $Model)
            $paths = @($candidates | ForEach-Object { $_.FullName })
            $prevEA = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $stdout = & $PythonExe -I -X utf8 $Worker --model $Model --language de @paths 2>&1
            $exitCode = $LASTEXITCODE
            $ErrorActionPreference = $prevEA
            foreach ($line in $stdout) {
                $text = [string]$line
                if ($text.TrimStart().StartsWith('{')) {
                    try { $results += ($text | ConvertFrom-Json) } catch { Write-LogLine ('unparsable worker line: ' + $text) }
                } else {
                    Write-LogLine ('worker: ' + $text)
                }
            }
            if ($exitCode -ne 0 -and $exitCode -ne 2) {
                Write-LogLine ('worker exit code ' + $exitCode)
                $ok = $false
            }
            foreach ($r in $results) {
                if ($r.type -eq 'file') {
                    if ($r.ok) { Write-LogLine ('ok: ' + $r.audio + ' (' + $r.audio_seconds + 's audio, ' + $r.seconds + 's, ' + $r.device + ')') }
                    else { Write-LogLine ('failed: ' + $r.audio + ' - ' + $r.error) }
                }
            }
        }
    } else {
        Write-LogLine 'no new recordings'
    }

    # 3. inbox.json - every transcript waiting in the inbox root
    $transcripts = @()
    foreach ($t in (Get-ChildItem -LiteralPath $audioDir -File -Filter '*.txt')) {
        $base = [IO.Path]::GetFileNameWithoutExtension($t.Name)
        $audioName = $null
        foreach ($ext in $extensions) {
            if (Test-Path -LiteralPath (Join-Path $audioDir ($base + $ext))) { $audioName = $base + $ext; break }
        }
        $raw = Get-Content -LiteralPath $t.FullName -Raw -Encoding UTF8
        $chars = 0
        if ($raw) { $chars = $raw.Length }
        $transcripts += [pscustomobject]@{
            txt      = $t.Name
            audio    = $audioName
            recorded = $t.LastWriteTime.ToString('s')
            chars    = $chars
        }
    }
    $inbox = [pscustomobject]@{ generated = (Get-Date).ToString('s'); transcripts = $transcripts }
    Write-Utf8 (Join-Path $VaultPath '000-meta\life-os-inbox.json') ($inbox | ConvertTo-Json -Depth 4)

    # 4. conflicts.json - for the agent's conflict merge step
    $conflicts = Get-ConflictEntries $VaultPath
    $cf = [pscustomobject]@{ generated = (Get-Date).ToString('s'); conflicts = @($conflicts) }
    Write-Utf8 (Join-Path $VaultPath '000-meta\life-os-conflicts.json') ($cf | ConvertTo-Json -Depth 4)
    if ($conflicts.Count -gt 0) { Write-LogLine ('conflict files: ' + $conflicts.Count) }

    # 5. runs.log
    $summary = $results | Where-Object { $_.type -eq 'summary' } | Select-Object -First 1
    $detail = 'files=' + $candidates.Count
    if ($summary) { $detail += ' ok=' + $summary.ok + ' failed=' + $summary.failed + ' device=' + $summary.device + ' model=' + $summary.model }
    $state = 'ok'; if (-not $ok) { $state = 'fail' }
    elseif ($summary -and $summary.failed -gt 0) { $state = 'warn' }
    Append-Utf8 (Join-Path $VaultPath '000-meta\life-os-runs.log') `
        ((Get-Date).ToString('s') + ' | transcribe | ' + $state + ' | ' + $detail + "`n")

    if (-not $ok) { exit 1 }
    exit 0
} catch {
    Append-Utf8 (Join-Path $VaultPath '000-meta\life-os-runs.log') `
        ((Get-Date).ToString('s') + ' | transcribe | fail | ' + $_.Exception.Message + "`n")
    Write-Host ('transcribe failed: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($lockIsOurs) { Release-LifeOsLock $LockPath }
}
