# archive-guard.ps1  --  Version 1.1 (2026-10-08)
#
# 1.1: the state write retries on sharing violations between parallel hook
#      processes and re-reads the file before each retry, so no entry is
#      lost (same race as trifecta-guard 1.1). No verdict changes - a write
#      that stays locked still fails closed through the trap below.
#
# PreToolUse hook for the Read/Edit/Write/NotebookEdit/Grep/Glob/Bash/PowerShell
# tools. Protects the personal archive in the vault:
#   600-archive   sidecars of personal documents (finances, health, ...)
#   300-areas     life-area hub notes
#
#   ALLOWED without asking:
#     - one explicit file at a time (Read/Edit/Write on a single note)
#     - keyword searches via the Grep tool with head_limit <= MaxGrepHits
#     - a shell command that names explicit .md/.txt files (each named
#       600-archive file counts as a document read)
#     - anything the user approved: a Bash/PowerShell command carrying the
#       marker #approved-by-user (the agent only adds it after the user said
#       yes in the chat)
#
#   NEEDS THE USER'S YES (exit 2 + message; the agent asks in the chat):
#     - a folder-wide listing or search (Glob, Get-ChildItem, dir, ...)
#     - the 11th distinct archive document read in one session
#     - opening an original document (PDF / image / office file)
#     - any other whole-folder operation (git, scripts, copies, ...)
#
#   Thresholds (change only here; both tests pin these values):
$script:MaxArchiveDocs = 10   # the 11th distinct document read in a session asks
$script:MaxGrepHits    = 50   # a Grep over the archive needs head_limit <= this
$script:StateMaxAgeDays = 7   # read counters of older sessions are deleted
#
#   State: {{HOME_ENV}}\.claude\state\archive-guard-<session_id>.json
#   holds the 600-archive documents this session has read. State that cannot
#   be read is treated as empty: a damaged counter must not block normal work.
#   Old state files are removed on every run. State files are scratch; they
#   never belong in git.
#
#   Fail closed like block-dangerous.ps1: input that cannot be read at all is
#   refused with exit 2, and a trap turns any unexpected error into exit 2.
#   Best effort, not a sandbox: code that reads the archive from inside a
#   script file, loops over variables, or paths with spaces cannot be judged
#   here. Known gap, accepted: a shell one-liner with the marker bypasses any
#   rule below - the marker is a self-declaration by the agent, exactly like
#   #confirmed-by-user in the delete guard.
#
#   ASCII ONLY (Windows PowerShell 5.1 reads BOM-less .ps1 files in the ANSI
#   code page; a non-ASCII character can crash the hook, and a crashed hook
#   lets the call through).
#
# Output contract: exit 2 + message on stderr = blocked (the message goes to
# the model). exit 0 = normal permission flow.

$ErrorActionPreference = 'SilentlyContinue'

function Send-Block([string]$reason) {
    [Console]::Error.WriteLine($reason)
    exit 2
}

trap {
    Send-Block 'BLOCKED: the archive guard hit an unexpected error and cannot judge this call. Tell the user; do not work around it.'
}

# --- read the tool call (byte handling identical to block-dangerous.ps1) ----
# A UTF-8 byte order mark in front of the JSON makes ConvertFrom-Json fail;
# the agent's PowerShell tool sends one. The bytes are read raw, the mark is
# cut off, the rest is decoded as UTF-8. Empty or non-JSON input is refused.
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Send-Block 'BLOCKED: the archive guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.'
}
try { $call = $raw | ConvertFrom-Json -ErrorAction Stop }
catch { Send-Block 'BLOCKED: the archive guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.' }
$tool = [string]$call.tool_name
$inp = $call.tool_input
if ([string]::IsNullOrWhiteSpace($tool)) { exit 0 }

$sessionId = [string]$call.session_id
if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'nosession' }
$sessionId = ($sessionId -replace '[^A-Za-z0-9-]', '_')
$stateDir = Join-Path {{HOME_ENV}} '.claude\state'
$statePath = Join-Path $stateDir ('archive-guard-' + $sessionId + '.json')

# --- helpers ----------------------------------------------------------------
function Test-ArchiveText([string]$text) {
    # Does the text mention one of the protected folders as a folder?
    if ($text -match '(?i)(^|[^A-Za-z0-9_.-])600-archive([^A-Za-z0-9_-]|$)') { return $true }
    if ($text -match '(?i)(^|[^A-Za-z0-9_.-])300-areas([^A-Za-z0-9_-]|$)') { return $true }
    return $false
}

function Split-OutsideQuotes([string]$text) {
    # Split a command into segments on newline, ';', '&&' and '|' - but never
    # inside single or double quotes, so a commit message that merely tells
    # about an archive command ("cleanup; Get-ChildItem 600-archive") stays
    # ONE text segment and stays exempt. A naive split cut it at the ';' and
    # judged the tail as an archive operation (same class as the pipe split in
    # block-dangerous; measured 2026-10-08). Best effort: doubled or escaped
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

function Save-ArchiveState {
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    # Parallel tool calls run this hook as parallel processes for ONE session,
    # so two writers can meet on the one state file (same race as in
    # trifecta-guard 1.1). A collision is a normal race, not a fault: retry.
    # A retry re-reads the counter and unions it, so entries another process
    # recorded in the meantime are never dropped (the count only grows). A
    # write that stays locked throws into the trap above (fail closed).
    $stateWritten = $false
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $json = @{ read = @($script:read) } | ConvertTo-Json -Compress -Depth 4
        try {
            [IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
            $stateWritten = $true
            break
        } catch [System.IO.IOException] {
            try {
                $reread = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                foreach ($e in @($reread.read)) { if ($e -and ($script:read -notcontains $e)) { $script:read += $e } }
            } catch { }
            Start-Sleep -Milliseconds 120
        }
    }
    if (-not $stateWritten) {
        $json = @{ read = @($script:read) } | ConvertTo-Json -Compress -Depth 4
        [IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
}

# Housekeeping first, so a session's counter never survives its 7th day.
Get-ChildItem -LiteralPath $stateDir -Filter 'archive-guard-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$script:StateMaxAgeDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$script:read = @()
if (Test-Path -LiteralPath $statePath) {
    try {
        $saved = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $script:read = @($saved.read | Where-Object { $_ })
    } catch { $script:read = @() }
}

$docExt = '(?i)[.](pdf|docx|doc|xlsx|xls|pptx|ppt|jpg|jpeg|png|gif|tif|tiff|odt|ods)$'

# --- file tools: Read / Edit / Write / NotebookEdit -------------------------
if ($tool -eq 'Read' -or $tool -eq 'Edit' -or $tool -eq 'Write' -or $tool -eq 'NotebookEdit') {
    $path = [string]$inp.file_path
    if ($tool -eq 'NotebookEdit') { $path = [string]$inp.notebook_path }
    if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }
    if (-not (Test-ArchiveText $path)) { exit 0 }
    $leaf = Split-Path -Leaf $path

    if ($path -match $docExt) {
        Send-Block ('NEEDS CONFIRMATION: this opens an original document from the archive -> ' + $leaf +
            '. Originals are not opened by the agent. Ask the user in the chat (AskUserQuestion); only if the user says yes, open it with a Bash/PowerShell command carrying the marker #approved-by-user.')
    }

    # A single note in 300-areas is normal work; a single file is editable.
    if ($path -match '(?i)(^|[^A-Za-z0-9_.-])300-areas([^A-Za-z0-9_-]|$)') { exit 0 }
    if ($tool -ne 'Read') { exit 0 }

    if ($path -notmatch '(?i)[.](md|txt)$') {
        Send-Block ('NEEDS CONFIRMATION: this reads a file in 600-archive that is not a plain text note -> ' + $leaf +
            '. Ask the user in the chat (AskUserQuestion); if the user says yes, read it with a Bash/PowerShell command carrying the marker #approved-by-user.')
    }
    $key = $path.ToLower()
    if ($script:read -contains $key) { exit 0 }
    if (($script:read.Count + 1) -gt $script:MaxArchiveDocs) {
        Send-Block ('NEEDS CONFIRMATION: this would be archive document number ' + ($script:read.Count + 1) +
            ' read in this session (the limit is ' + $script:MaxArchiveDocs +
            '). Ask the user in the chat (AskUserQuestion); if the user says yes, read it with a Bash/PowerShell command carrying the marker #approved-by-user, or start a fresh session.')
    }
    $script:read += $key
    Save-ArchiveState
    exit 0
}

# --- Grep: keyword search, only with a bounded number of hits ---------------
if ($tool -eq 'Grep') {
    $target = ([string]$inp.path) + ' ' + ([string]$inp.glob)
    if (-not (Test-ArchiveText $target)) { exit 0 }
    $limitText = [string]$inp.head_limit
    $limit = 0
    if ($limitText -eq '' -or -not [int]::TryParse($limitText, [ref]$limit)) { $limit = -1 }
    if ($limit -lt 0 -or $limit -gt $script:MaxGrepHits) {
        Send-Block ('BLOCKED: a keyword search over the archive must be bounded - set head_limit to ' +
            $script:MaxGrepHits + ' or less and search again. Without a limit the search would pour the whole archive into one answer.')
    }
    exit 0
}

# --- Glob: a whole-folder listing needs the user's yes ----------------------
if ($tool -eq 'Glob') {
    $pattern = [string]$inp.pattern
    $target = $pattern + ' ' + ([string]$inp.path)
    if (-not (Test-ArchiveText $target)) { exit 0 }
    if ($target -notmatch '[*?\[]') { exit 0 }   # one explicit path, no listing
    Send-Block ('NEEDS CONFIRMATION: this lists a whole archive folder (Glob). Single notes (Read) and bounded keyword searches (Grep with head_limit <= ' +
        $script:MaxGrepHits + ') need no permission. If the user asked for the listing, ask them in the chat (AskUserQuestion); after their yes, run it as a Bash/PowerShell command with the marker #approved-by-user.')
}

# --- Bash / PowerShell ------------------------------------------------------
if ($tool -eq 'Bash' -or $tool -eq 'PowerShell') {
    $cmd = [string]$inp.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }
    if ($cmd -imatch '#\s*approved-by-user') { exit 0 }   # the user said yes

    # Segments that only carry text (a commit message, an echo) never count.
    # git commit/tag is matched with its global options (-C <path>, -c k=v,
    # --no-pager): the -C form slipped through the first version.
    $action = ''
    foreach ($seg in (Split-OutsideQuotes $cmd)) {
        $s = $seg.Trim()
        if ($s -eq '') { continue }
        if ($s -imatch '^\s*git(\s+-C\s+\S+|\s+-c\s+\S+|\s+--no-pager)?\s+(commit|tag)\b') { continue }
        if ($s -imatch '^\s*(echo|Write-(Output|Host))\b') { continue }
        $action = $action + ' ' + $s
    }
    if (-not (Test-ArchiveText $action)) { exit 0 }

    # Originals are never opened through a shell command either.
    foreach ($m in [regex]::Matches($action, '(?i)(600-archive|300-areas)[\\/][^"''\s;,|&()<>]*[.](pdf|docx|doc|xlsx|xls|pptx|ppt|jpg|jpeg|png|gif|tif|tiff)')) {
        $p = $m.Value
        if ($p -match '[$*?\[\]`]') { continue }
        Send-Block ('NEEDS CONFIRMATION: this opens an original document from the archive -> ' + $p +
            '. Ask the user in the chat (AskUserQuestion); only if the user says yes, re-run with the marker #approved-by-user.')
    }

    # Explicit .md/.txt files named in the command are the allowed case.
    $files = @()
    $masked = $action
    foreach ($m in [regex]::Matches($action, '(?i)(600-archive|300-areas)[\\/][^"''\s;,|&()<>]*[.](md|txt)')) {
        $p = $m.Value
        if ($p -match '[$*?\[\]`]') { continue }   # wildcard or variable -> stays a folder operation
        $files += $p
        $masked = $masked.Replace($p, ' <file> ')
    }

    if (Test-ArchiveText $masked) {
        Send-Block ('NEEDS CONFIRMATION: this command works on an archive folder as a whole, not on single named notes -> ' + $action.Trim() +
            '. If the user asked for it, ask them in the chat (AskUserQuestion); after their yes, re-run with the marker #approved-by-user appended.')
    }

    $newOnes = @()
    foreach ($f in $files) {
        if ($f -match '(?i)(^|[^A-Za-z0-9_.-])600-archive([^A-Za-z0-9_-]|$)') {
            $key = $f.ToLower()
            if ($script:read -notcontains $key -and $newOnes -notcontains $key) { $newOnes += $key }
        }
    }
    if ($newOnes.Count -gt 0) {
        if (($script:read.Count + $newOnes.Count) -gt $script:MaxArchiveDocs) {
            Send-Block ('NEEDS CONFIRMATION: this would pass archive document number ' + ($script:read.Count + $newOnes.Count) +
                ' read in this session (the limit is ' + $script:MaxArchiveDocs +
                '). Ask the user in the chat (AskUserQuestion); if the user says yes, re-run with the marker #approved-by-user, or start a fresh session.')
        }
        foreach ($key in $newOnes) { $script:read += $key }
        Save-ArchiveState
    }
    exit 0
}

exit 0
