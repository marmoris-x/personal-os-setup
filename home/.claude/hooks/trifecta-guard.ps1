# trifecta-guard.ps1  --  Version 1.1 (2026-10-08)
#
# 1.1: the state write retries on sharing violations between parallel hook
#      processes and re-reads the file before each retry, so no mark is lost.
#      No verdict changes - a write that stays locked still fails closed
#      through the trap below.
#
# PreToolUse hook: outside web content and 600-archive content must never meet
# in one session. Once one of the two has been taken in, every call that would
# bring in the other is blocked with exit 2 and asks the user to start a new
# session for the other kind of work.
#
#   Foreign content (marks the session): WebFetch, WebSearch, any mcp__ tool,
#   shell commands with curl / curl.exe / iwr / Invoke-WebRequest /
#   Invoke-RestMethod / irm, and shell commands that run the research scripts
#   (skills\research\scripts, research-v2), a wayback fetch, or archive.org.
#
#   600-archive content (marks the session): Read/Edit/Write/NotebookEdit/
#   Grep/Glob on a 600-archive path, and shell commands that mention
#   600-archive as a folder. Text-only segments (git commit messages, echo)
#   never count. Writing notes under 400-knowledge / 500-sources does not
#   count - only 600-archive.
#
#   Planning note (2026-10-08, after the life-os part 2 order): a session that
#   must spell the folder's name in a shell command, or read the folder, has to
#   do that BEFORE its first web fetch - afterwards only a fresh session can.
#   The file tools go by path, not by content: an Edit/Write on a file whose
#   text merely repeats the name (the vault's .stignore, for example) stays
#   possible either way. This guard is deliberately strict; it is never
#   loosened for convenience.
#
#   The mark is set when the call is ATTEMPTED (a fetch that then fails still
#   marks the session). That is the safe direction: it can only make the
#   guard stricter. There is no marker to bypass this hook on purpose - the
#   only way is a new session.
#
#   State: {{HOME_ENV}}\.claude\state\trifecta-<session_id>.json
#   ({ foreign: true/false, archive: true/false }), removed after 7 days.
#   State that cannot be read is treated as empty - the guard only ever runs
#   forward from the moment it is registered; earlier history of a running
#   session is unknown to it by design.
#
#   Fail closed like block-dangerous.ps1: input that cannot be read at all is
#   refused with exit 2, and a trap turns any unexpected error into exit 2.
#   Best effort, not a sandbox: a program that fetches on its own from inside
#   a script file cannot be seen here.
#
#   ASCII ONLY (Windows PowerShell 5.1 reads BOM-less .ps1 files in the ANSI
#   code page; a non-ASCII character can crash the hook, and a crashed hook
#   lets the call through. The user-facing sentence is relayed by the model
#   with proper umlauts.)
#
# Output contract: exit 2 + message on stderr = blocked (the message goes to
# the model). exit 0 = normal permission flow.

$ErrorActionPreference = 'SilentlyContinue'
$script:StateMaxAgeDays = 7

function Send-Block([string]$reason) {
    [Console]::Error.WriteLine($reason)
    exit 2
}

function Split-OutsideQuotes([string]$text) {
    # Split a command into segments on newline, ';', '&&' and '|' - but never
    # inside single or double quotes. A commit message like
    #   git commit -m "cleanup; note about 600-archive"
    # is ONE segment and stays exempt as text; a naive split would cut it at
    # the ';' and read the tail as an archive access (measured 2026-10-08: the
    # guard blocked its own commit this way). Best effort: doubled or escaped
    # quotes inside strings are not modelled.
    $parts = @()
    $cur = ''
    $quote = [char]0
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($quote -ne [char]0) {
            $cur += $c
            if ($c -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($c -eq [char]34 -or $c -eq [char]39) { $quote = $c; $cur += $c; continue }
        if ($c -eq [char]10) { $parts += $cur; $cur = ''; continue }
        if ($c -eq ';') { $parts += $cur; $cur = ''; continue }
        if ($c -eq '&' -or $c -eq '|') {
            $parts += $cur
            $cur = ''
            if ($i + 1 -lt $text.Length -and $text[$i + 1] -eq $c) { $i++ }
            continue
        }
        $cur += $c
    }
    $parts += $cur
    return $parts
}

trap {
    Send-Block 'BLOCKED: the session guard hit an unexpected error and cannot judge this call. Tell the user; do not work around it.'
}

# --- read the tool call (byte handling identical to block-dangerous.ps1) ----
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Send-Block 'BLOCKED: the session guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.'
}
try { $call = $raw | ConvertFrom-Json -ErrorAction Stop }
catch { Send-Block 'BLOCKED: the session guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.' }
$tool = [string]$call.tool_name
$inp = $call.tool_input
if ([string]::IsNullOrWhiteSpace($tool)) { exit 0 }

$sessionId = [string]$call.session_id
if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'nosession' }
$sessionId = ($sessionId -replace '[^A-Za-z0-9-]', '_')
$stateDir = Join-Path {{HOME_ENV}} '.claude\state'
$statePath = Join-Path $stateDir ('trifecta-' + $sessionId + '.json')

# --- classify this call -----------------------------------------------------
$isForeign = $false
$isArchive = $false

if ($tool -eq 'WebFetch' -or $tool -eq 'WebSearch') {
    $isForeign = $true
}
elseif ($tool -like 'mcp__*') {
    $isForeign = $true
}
elseif ($tool -eq 'Bash' -or $tool -eq 'PowerShell') {
    $cmd = [string]$inp.command
    if (-not [string]::IsNullOrWhiteSpace($cmd)) {
        if ($cmd -imatch '\b(curl(\.exe)?|iwr|Invoke-WebRequest|Invoke-RestMethod|irm)\b') { $isForeign = $true }
        if ($cmd -imatch 'skills[\\/]research[\\/]scripts') { $isForeign = $true }
        if ($cmd -imatch 'research-v2[\\/]') { $isForeign = $true }
        if ($cmd -imatch 'wayback') { $isForeign = $true }
        if ($cmd -imatch 'web\.archive\.org|archive\.org') { $isForeign = $true }

        # Text-only segments never count as archive access. git commit/tag is
        # matched with its global options (-C <path>, -c k=v, --no-pager): the
        # -C form slipped through the first version.
        $action = ''
        foreach ($seg in (Split-OutsideQuotes $cmd)) {
            $s = $seg.Trim()
            if ($s -eq '') { continue }
            if ($s -imatch '^\s*git(\s+-C\s+\S+|\s+-c\s+\S+|\s+--no-pager)?\s+(commit|tag)\b') { continue }
            if ($s -imatch '^\s*(echo|Write-(Output|Host))\b') { continue }
            $action = $action + ' ' + $s
        }
        if ($action -match '(?i)(^|[^A-Za-z0-9_.-])600-archive([^A-Za-z0-9_-]|$)') { $isArchive = $true }
    }
}
elseif ($tool -eq 'Read' -or $tool -eq 'Edit' -or $tool -eq 'Write' -or $tool -eq 'NotebookEdit' -or $tool -eq 'Grep' -or $tool -eq 'Glob') {
    $target = ''
    if ($tool -eq 'NotebookEdit') { $target = [string]$inp.notebook_path }
    elseif ($tool -eq 'Grep') { $target = ([string]$inp.path) + ' ' + ([string]$inp.glob) }
    elseif ($tool -eq 'Glob') { $target = ([string]$inp.pattern) + ' ' + ([string]$inp.path) }
    else { $target = [string]$inp.file_path }
    if ($target -match '(?i)(^|[^A-Za-z0-9_.-])600-archive([^A-Za-z0-9_-]|$)') { $isArchive = $true }
}

if (-not $isForeign -and -not $isArchive) { exit 0 }

# --- load state -------------------------------------------------------------
Get-ChildItem -LiteralPath $stateDir -Filter 'trifecta-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$script:StateMaxAgeDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
$foreign = $false
$archive = $false
if (Test-Path -LiteralPath $statePath) {
    try {
        $saved = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $foreign = [bool]$saved.foreign
        $archive = [bool]$saved.archive
    } catch { $foreign = $false; $archive = $false }
}

# --- judge ------------------------------------------------------------------
if ($isForeign -and $archive) {
    Send-Block 'BLOCKED: this session has already read content from 600-archive, and this call would bring in outside web content. The two must never meet in one session (user policy against prompt-injection chains). Tell the user to start a new session for this other work - in German: "Fuer das andere bitte eine neue Sitzung starten."'
}
if ($isArchive -and $foreign) {
    Send-Block 'BLOCKED: this session has already taken in outside web content, and this call touches 600-archive. The two must never meet in one session (user policy against prompt-injection chains). Tell the user to start a new session for the archive work - in German: "Fuer das andere bitte eine neue Sitzung starten."'
}

if ($isForeign -or $isArchive) {
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    if ($isForeign) { $foreign = $true }
    if ($isArchive) { $archive = $true }
    # Parallel tool calls run this hook as parallel processes for ONE session,
    # so two writers can meet on the one state file (measured 2026-10-08: a
    # System.IO.IOException on this line under a held lock, and once in a
    # storm of 40 concurrent calls). A collision is a normal race, not a
    # fault: retry. A retry re-reads the file and unions what stands there,
    # so a mark another process wrote in the meantime is never dropped (the
    # union only ever adds flags). A write that stays locked throws into the
    # trap above (fail closed, unchanged).
    $stateWritten = $false
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $json = @{ foreign = $foreign; archive = $archive } | ConvertTo-Json -Compress -Depth 4
        try {
            [IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
            $stateWritten = $true
            break
        } catch [System.IO.IOException] {
            try {
                $reread = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($reread.foreign) { $foreign = $true }
                if ($reread.archive) { $archive = $true }
            } catch { }
            Start-Sleep -Milliseconds 120
        }
    }
    if (-not $stateWritten) {
        $json = @{ foreign = $foreign; archive = $archive } | ConvertTo-Json -Compress -Depth 4
        [IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
}
exit 0
