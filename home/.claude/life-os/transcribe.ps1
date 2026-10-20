# transcribe.ps1 - Life OS "script before": transcribe new voice recordings, collect the
# morning-run inputs. Called by morning.ps1 (inside its lock) or by hand.
#
# What it does, in order:
#   1. find new audio in <vault>\inbox\audio (top level only; files with a .txt are done,
#      files younger than 30 s are still syncing and wait)
#   2. transcribe them with the chosen engine:
#        groq  -> groq_worker.py, Groq's whisper-large-v3-turbo (default)
#        local -> transcribe_worker.py, faster-whisper in the Life OS venv
#      The Groq engine falls back to local, never silently, when the key is missing, the
#      daily cap is reached, Groq answers 429 or is unreachable, or the worker fails.
#      One .txt per recording is written next to the audio.
#   3. write <vault>\000-meta\life-os-inbox.json  - every .txt waiting in the inbox
#      (all of them, not only the new ones: self-healing if an agent run fails later)
#   4. write <vault>\000-meta\life-os-conflicts.json - sync conflicts found by
#      .claude\skills\vault-lint\conflicts.py (the agent has no shell, so it reads this file)
#   5. write <vault>\000-meta\life-os-transcribe.json - engine, fallbacks and the German
#      reason, so the morning report can name it in one line
#   6. append one line to <vault>\000-meta\life-os-runs.log
#
# Exit code 0 when everything it tried worked (including "nothing to do"), 1 on a hard
# failure (python, worker or vault missing). A single broken audio file does not fail the run.
#
# Groq quota: the free limits are shared with OpenWhispr dictation. groq_worker.py keeps its
# own daily log of the audio seconds it sent (default %LOCALAPPDATA%\life-os\groq-audio.jsonl)
# and stops at 21600 s per day (6 of the 8 free hours) and 7200 s per hour; above either cap
# the file goes local. All files of one run go through ONE worker process, so the 20-requests-
# per-minute limit is shared across files and not reset per file.
#
# Lock: takes morning.lock itself unless -CalledByRunner says the runner already holds it.

param(
    [string]$VaultPath = '{{VAULT}}',
    [string]$Model = 'large-v3-turbo',
    [ValidateSet('groq', 'local')]
    [string]$Engine = 'groq',
    [string]$Language = 'de',
    [string]$PythonExe = "{{LIFEOS_PYTHON}}",
    [string]$Worker = "{{HOME_ENV}}\.claude\life-os\transcribe_worker.py",
    [string]$GroqWorker = "{{HOME_ENV}}\.claude\life-os\groq_worker.py",
    [string]$GroqModel = 'whisper-large-v3-turbo',
    [string]$GroqBaseUrl = 'https://api.groq.com/openai/v1/audio/transcriptions',
    [string]$GroqDailyLog = "{{LIFEOS_STATE}}\groq-audio.jsonl",
    [int]$DailyCapSeconds = 21600,
    [int]$HourCapSeconds = 7200,
    [int]$GroqRequestsPerMinute = 20,
    [string]$LockPath = "{{LIFEOS_LOCK}}",
    [switch]$CalledByRunner,
    [switch]$SkipUserKeyImport
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\life-os-common.ps1"
$script:log = @()

# A scheduled task or a shell started before winget changed PATH keeps the old value. The
# Groq worker needs ffmpeg and ffprobe from the winget package, so read the current value once.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

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

function Get-FallbackReasonGerman([string]$code) {
    # One plain German reason for the run log and the morning report. The JSON keeps the
    # code as well, so a later reader can tell the cases apart without parsing German text.
    switch ($code) {
        'missing_key'      { return 'kein API-Schluessel hinterlegt' }
        'daily_cap'        { return 'Tageslimit fuer die Transkription erreicht' }
        'rate_limit'       { return 'Groq-Anfragelimit erreicht (429)' }
        'auth_error'       { return 'API-Schluessel abgelehnt (401)' }
        'network'          { return 'Groq nicht erreichbar' }
        'api_error'        { return 'Fehler der Groq-API' }
        'preprocess_error' { return 'Audiodatei konnte nicht vorbereitet werden' }
        'hourly_cap'       { return 'Stundenlimit fuer die Transkription erreicht' }
        'groq_worker_failed' { return 'Groq-Worker ohne Ergebnis' }
        'worker_missing'   { return 'Groq-Worker fehlt, lokal transkribiert' }
        'unknown'          { return 'unbekannter Fehler' }
        default            { return $code }
    }
}

function ConvertFrom-WorkerLines([string[]]$lines) {
    # Turns the JSON lines of a worker into objects and passes text lines through the log.
    $objects = @()
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text.TrimStart().StartsWith('{')) {
            try { $objects += ($text | ConvertFrom-Json) }
            catch { Write-LogLine ('unparsable worker line: ' + $text) }
        } else {
            Write-LogLine ('worker: ' + $text)
        }
    }
    return @($objects)
}

# --- main ---------------------------------------------------------------------------------

if (-not $env:GROQ_API_KEY -and -not $SkipUserKeyImport) {
    # A shell started before the key was set keeps the old environment; read the user value
    # once for this run. The value is never printed. SkipUserKeyImport exists for the
    # missing-key fallback test only; a normal run always imports the user value.
    $userKey = [Environment]::GetEnvironmentVariable('GROQ_API_KEY', 'User')
    if ($userKey) { $env:GROQ_API_KEY = $userKey }
}

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
    $localFallback = 0
    $groqOk = 0
    $fallbackReasons = @()
    $groqSummary = $null
    $localSummary = $null

    if ($candidates.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $PythonExe)) {
            Write-LogLine 'python missing - transcription skipped'
            $ok = $false
        } else {
            Write-LogLine ('transcribing ' + $candidates.Count + ' file(s), engine ' + $Engine + ', language ' + $Language)

            if ($Engine -eq 'groq' -and (Test-Path -LiteralPath $GroqWorker)) {
                $fallbackFiles = @()
                $fallbackMap = @{}
                $candidateByName = @{}
                $handled = @{}
                foreach ($c in $candidates) { $candidateByName[$c.Name] = $c }
                # ONE worker process for the whole run: its request list is shared, so the
                # 20-requests-per-minute limit and both audio caps hold across files. A per-file
                # process reset the list and sent far more than 20 requests a minute.
                $paths = @($candidates | ForEach-Object { $_.FullName })
                $prevEA = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $stdout = & $PythonExe -I -X utf8 $GroqWorker @paths --model $GroqModel `
                    --language $Language --base-url $GroqBaseUrl --daily-log $GroqDailyLog `
                    --cap-seconds $DailyCapSeconds --hour-cap-seconds $HourCapSeconds `
                    --requests-per-minute $GroqRequestsPerMinute 2>&1
                $groqExit = $LASTEXITCODE
                $ErrorActionPreference = $prevEA
                $parsed = ConvertFrom-WorkerLines @($stdout)
                foreach ($p in $parsed) {
                    if ($p.type -eq 'summary') { $groqSummary = $p; continue }
                    if ($p.type -ne 'file') { continue }
                    $audioName = [string]$p.audio
                    $handled[$audioName] = $true
                    if ($p.ok) {
                        $results += $p
                        $groqOk++
                    } else {
                        $reason = 'groq_worker_failed'
                        if ($p.PSObject.Properties['reason'] -and $p.reason) { $reason = [string]$p.reason }
                        if ($candidateByName.ContainsKey($audioName)) {
                            $fallbackFiles += $candidateByName[$audioName]
                            $fallbackMap[$audioName] = $reason
                        }
                        $fallbackReasons += $reason
                        Write-LogLine ('groq fallback for ' + $audioName + ': ' + (Get-FallbackReasonGerman $reason))
                    }
                }
                # The process died before it reported a file: fall back for it, never drop it.
                foreach ($c in $candidates) {
                    if ($handled.ContainsKey($c.Name)) { continue }
                    $fallbackFiles += $c
                    $fallbackMap[$c.Name] = 'groq_worker_failed'
                    $fallbackReasons += 'groq_worker_failed'
                    Write-LogLine ('groq fallback for ' + $c.Name + ': ' + (Get-FallbackReasonGerman 'groq_worker_failed'))
                }
                if ($groqExit -ne 0 -and $parsed.Count -eq 0) {
                    Write-LogLine ('groq worker exit ' + $groqExit)
                }

                if ($fallbackFiles.Count -gt 0) {
                    $localFallback = $fallbackFiles.Count
                    if (-not (Test-Path -LiteralPath $Worker)) {
                        Write-LogLine 'local worker missing - fallback not possible'
                        $ok = $false
                    } else {
                        $paths = @($fallbackFiles | ForEach-Object { $_.FullName })
                        $prevEA = $ErrorActionPreference
                        $ErrorActionPreference = 'Continue'
                        $stdout = & $PythonExe -I -X utf8 $Worker --model $Model --language $Language @paths 2>&1
                        $localExit = $LASTEXITCODE
                        $ErrorActionPreference = $prevEA
                        $parsed = ConvertFrom-WorkerLines @($stdout)
                        foreach ($p in $parsed) {
                            if ($p.type -eq 'summary') { $localSummary = $p; continue }
                            if ($p.type -ne 'file') { continue }
                            $reason = 'unknown'
                            if ($fallbackMap.ContainsKey([string]$p.audio)) { $reason = [string]$fallbackMap[[string]$p.audio] }
                            $p | Add-Member -NotePropertyName engine -NotePropertyValue 'local' -Force
                            $p | Add-Member -NotePropertyName fallback_reason -NotePropertyValue $reason -Force
                            $results += $p
                        }
                        if ($localExit -ne 0 -and $localExit -ne 2) {
                            Write-LogLine ('local worker exit ' + $localExit)
                            $ok = $false
                        }
                    }
                }
            } else {
                if ($Engine -eq 'groq') {
                    Write-LogLine 'groq worker missing - falling back to local for every file'
                    $fallbackReasons += 'worker_missing'
                    $localFallback = $candidates.Count
                }
                if (-not (Test-Path -LiteralPath $Worker)) {
                    Write-LogLine 'local worker missing - transcription skipped'
                    $ok = $false
                } else {
                    $paths = @($candidates | ForEach-Object { $_.FullName })
                    $prevEA = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    $stdout = & $PythonExe -I -X utf8 $Worker --model $Model --language $Language @paths 2>&1
                    $exitCode = $LASTEXITCODE
                    $ErrorActionPreference = $prevEA
                    $parsed = ConvertFrom-WorkerLines @($stdout)
                    foreach ($p in $parsed) {
                        if ($p.type -eq 'summary') { $localSummary = $p; continue }
                        $results += $p
                    }
                    if ($exitCode -ne 0 -and $exitCode -ne 2) {
                        Write-LogLine ('worker exit code ' + $exitCode)
                        $ok = $false
                    }
                }
            }

            foreach ($r in $results) {
                if ($r.type -eq 'file') {
                    if ($r.ok) {
                        $engineText = 'local'
                        if ($r.PSObject.Properties['engine'] -and $r.engine) { $engineText = [string]$r.engine }
                        $reasonText = ''
                        if ($r.PSObject.Properties['fallback_reason'] -and $r.fallback_reason) { $reasonText = ', fallback=' + $r.fallback_reason }
                        $secondsText = ''
                        if ($r.PSObject.Properties['seconds']) { $secondsText = [string]$r.seconds }
                        elseif ($r.PSObject.Properties['seconds_sent']) { $secondsText = [string]$r.seconds_sent }
                        Write-LogLine ('ok: ' + $r.audio + ' (' + $r.audio_seconds + 's audio, ' + $secondsText + 's, ' + $engineText + $reasonText + ')')
                    } else {
                        Write-LogLine ('failed: ' + $r.audio + ' - ' + $r.error)
                    }
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

    # 5. transcribe.json - one German reason for the morning report, never a silent fallback
    $reasonText = ''
    $reasonTextDe = ''
    if ($fallbackReasons.Count -gt 0) {
        $reasonCodes = @($fallbackReasons | Select-Object -Unique)
        $reasonText = ($reasonCodes -join ', ')
        $reasonTextDe = (($reasonCodes | ForEach-Object { Get-FallbackReasonGerman ([string]$_) }) -join ', ')
    }
    $groqSecondsToday = 0
    if ($groqSummary -and $groqSummary.PSObject.Properties['today_seconds']) { $groqSecondsToday = [double]$groqSummary.today_seconds }
    $device = 'groq'
    if ($localSummary -and $localSummary.PSObject.Properties['device']) { $device = [string]$localSummary.device }
    if ($Engine -eq 'local') { $device = '' }
    if ($Engine -eq 'local' -and $localSummary -and $localSummary.PSObject.Properties['device']) { $device = [string]$localSummary.device }
    $transcribeState = [pscustomobject]@{
        generated            = (Get-Date).ToString('s')
        engine               = $Engine
        files                = $candidates.Count
        groq_ok              = $groqOk
        local_fallback       = $localFallback
        fallback_reasons     = @($fallbackReasons | Select-Object -Unique)
        fallback_reasons_de  = @($reasonTextDe -split ', ' | Where-Object { $_ })
        groq_model           = $GroqModel
        local_model          = $Model
        groq_seconds_today   = $groqSecondsToday
        daily_cap_seconds    = $DailyCapSeconds
        hour_cap_seconds     = $HourCapSeconds
        device               = $device
    }
    Write-Utf8 (Join-Path $VaultPath '000-meta\life-os-transcribe.json') ($transcribeState | ConvertTo-Json -Depth 4)

    # 6. runs.log
    $failedCount = @($results | Where-Object { $_.type -eq 'file' -and -not $_.ok }).Count
    $detail = 'files=' + $candidates.Count + ' ok=' + @($results | Where-Object { $_.type -eq 'file' -and $_.ok }).Count +
              ' failed=' + $failedCount + ' device=' + $device + ' engine=' + $Engine +
              ' model=' + $(if ($Engine -eq 'groq' -and $localFallback -eq 0) { $GroqModel } else { $Model })
    if ($localFallback -gt 0) { $detail += ' local_fallback=' + $localFallback }
    if ($reasonTextDe) { $detail += ' fallback_reason=' + $reasonTextDe }
    $state = 'ok'; if (-not $ok) { $state = 'fail' }
    elseif ($failedCount -gt 0) { $state = 'warn' }
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
