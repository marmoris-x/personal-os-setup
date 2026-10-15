# downloads-guard.ps1  --  Version 1.1 (2026-10-09)
#
# 1.1: after an independent review of 1.0. Fixed false positives: a folder name
#      now counts only directly under the owner's Downloads folder (or as a
#      relative/variable path after a cd or an assignment to it), not as the
#      DESTINATION of an ordinary move elsewhere (C:\...\Documents\); each
#      statement is judged on its own (pipelines stay one statement); other
#      folders named "Downloads" and tools with "downloads" in the name no
#      longer match. Closed gaps: deleting or moving the Downloads folder
#      itself or a glob directly under it; text segments (git commit, echo)
#      are no longer exempt when they hold $( ), a backtick, an escaped or an
#      unbalanced quote; the hook input's working directory counts as a cd;
#      more verbs (find -delete, unlink, rmSync, RenameFile, MoveHere, ...);
#      the marker must be a trailing comment, not a string in the middle.
#
# PreToolUse hook for the Bash and PowerShell tools. Protects the owner's
# permanent storage folders inside the Downloads folder:
#   Compressed, Documents, Images, Music, Programs, Videos
# ({{HOME}}\Downloads\<name>). The owner made them on purpose as targets
# for browser downloads. Rule (CLAUDE.md, Safety): no agent moves, renames or
# deletes anything in them, or moves anything into them, without his explicit
# yes. Loose files directly in Downloads may still be sorted.
#
#   A STATEMENT (split on newline, ';', '&&', '||'; a pipeline is ONE
#   statement) is BLOCKED (exit 2 + message) when it holds a move / rename /
#   delete verb (Move-Item, mv, Rename-Item, Remove-Item, rm, del, rmdir,
#   [IO.File]::Move/Delete, DeleteFile, shutil.move, find -delete, robocopy
#   /MOV /MIR /PURGE, git clean, ...) AND one of:
#     a. a path directly under Downloads: ...\Downloads\Images\..., ~/Downloads/Music,
#        {{HOME_ENV}}\Downloads\Videos
#     b. a relative or variable path to one of the six folders (Images\a.png,
#        "$d\Images\a.png") while an EARLIER statement named Downloads (a cd
#        or an assignment) or the tool call's working directory is Downloads
#     c. the Downloads folder itself or a glob directly under it
#        (...\Downloads, ...\Downloads\*, ...\Downloads\I*) - unless it is
#        limited to files (-File without -Recurse), which leaves the folders alone.
#
#   ALLOWED: listing, reading and copying (no verb), anything on loose files
#   in Downloads, any command that does not name Downloads, and any command
#   ending in the marker comment #approved-by-user (the agent adds it only
#   after the owner said yes in the chat - the same self-declaration as in
#   archive-guard.ps1). Statements that only carry text (git commit/tag,
#   echo, Write-Output, Write-Host) are skipped.
#
#   Best effort, not a sandbox. Known gaps, accepted: a script FILE that does
#   the work, a path built from pieces ('Down'+'loads', 8.3 short names), a
#   pipeline whose first half sits in an earlier statement
#   ($d = ...Downloads; gci $d | rm -r), a bare glob after a cd (rm -r I*),
#   -EncodedCommand, and GUI actions. A loose file whose name starts with a
#   folder name and a space ("Documents scan.pdf") is blocked and asks.
#
#   Fail closed like the other guards: input that cannot be read is refused
#   with exit 2, and a trap turns any unexpected error into exit 2.
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
    Send-Block 'BLOCKED: the Downloads guard hit an unexpected error and cannot judge this call. Tell the user; do not work around it.'
}

# --- read the tool call (byte handling identical to archive-guard.ps1) -----
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Send-Block 'BLOCKED: the Downloads guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.'
}
try { $call = $raw | ConvertFrom-Json -ErrorAction Stop }
catch { Send-Block 'BLOCKED: the Downloads guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.' }
$tool = [string]$call.tool_name
$inp = $call.tool_input
if ($tool -ne 'Bash' -and $tool -ne 'PowerShell') { exit 0 }

$cmd = [string]$inp.command
if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

# The owner said yes: the marker is accepted only as the trailing comment.
if ($cmd -imatch '#\s*approved-by-user\s*$') { exit 0 }

# --- patterns ---------------------------------------------------------------
$folders = '(Compressed|Documents|Images|Music|Programs|Videos)'
$endOfPath = '(?=[\\/''"\s;,)|&*]|$)'
# The owner's Downloads folder: ...\Users\<name>\Downloads, ~\Downloads, {{HOME_CMD}}, {{HOME_ENV}},
# $HOME, or a bare "Downloads" that starts a path. NOT ...\External\Downloads, NOT downloads-tool.
$dlRx = '(?i)((Users[\\/][^\\/\s''"]+|~|{{HOME_CMD}}|\{{HOME_ENV}}|\$HOME|\$env:HOMEPATH)[\\/]+|(^|[\s''"(=,]))Downloads(?![A-Za-z0-9_.-])'
$directRx = $dlRx + '[\\/]+' + $folders + $endOfPath
$rootRx = $dlRx + '([\\/]+\*?(?=[''"\s;,)|&]|$)|[\\/]+[^\\/\s''"]*[*?][^\\/\s''"]*(?=[\\/''"\s;,)|&]|$)|(?=[''"\s;,)|&]|$))'
$relRx = '(?i)((^|[\s''"(=,])|\$\{?[A-Za-z_][A-Za-z0-9_:]*\}?[\\/]+)' + $folders + '[\\/]+'
$relBareRx = '(?i)(^|[\s''"(=,])' + $folders + $endOfPath

$verbRx = '(?i)((?<![A-Za-z0-9_-])(Move-Item|Rename-Item|Remove-Item|mv|move|ren|rename|rm|rmdir|rd|del|erase|mi|rni|ri|unlink)(?![A-Za-z0-9_-]))' +
          '|(::(Move|Delete|DeleteFile|DeleteDirectory|MoveFile|MoveDirectory|Rename|RenameFile|RenameDirectory)\b)' +
          '|(\.(Delete|MoveTo|MoveHere|Rename)\()' +
          '|(DeleteFile|DeleteDirectory|MoveFile|MoveDirectory|RenameFile|RenameDirectory|MoveHere)' +
          '|(robocopy\b.*/(mov|move|mir|purge)\b)' +
          '|(\bgit\s+(clean|rm|mv)\b)' +
          '|(\bfind\b.*\s-delete\b)|(--remove-(source-)?files)|(\s-sdel\b)' +
          '|((rm|unlink|rename|rmdir)Sync\b)|(fs\.(rm|unlink|rename|rmdir)\b)' +
          '|(shutil\.(move|rmtree)|os\.(remove|removedirs|rename|replace|unlink|rmdir)|\.unlink\(|\.rmdir\()'

# --- helpers ----------------------------------------------------------------
$script:unbalanced = $false
function Split-Statements([string]$text) {
    # Split on newline, ';', '&&' and '||' - never inside single or double
    # quotes. A single '|' does NOT split: a pipeline is one statement.
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
        if ($c -eq [char]10 -or $c -eq ';') { $parts += $cur; $cur = ''; continue }
        if (($c -eq '&' -or $c -eq '|') -and $i + 1 -lt $text.Length -and $text[$i + 1] -eq $c) {
            $parts += $cur
            $cur = ''
            $i++
            continue
        }
        $cur += $c
    }
    $parts += $cur
    if ($quote -ne [char]0) { $script:unbalanced = $true }
    return , $parts
}

# A heredoc body that is only written to a file or into a commit message (cat, tee, git, gh,
# printf, echo) is text, not a command - unless the heredoc is piped on into a shell or
# interpreter. Without this, a changelog entry that merely talks about "Move-Item ... Downloads\Images"
# would be refused. The body of `bash <<EOF`, `python - <<EOF` and `cat <<EOF | bash` stays in.
$heredocRx = '(?ms)^([^\n]*?\b(?:cat|tee|git|gh|printf|echo)\b[^\n]*?)<<-?\s*[''"]?(\w+)[''"]?([^\n]*)\n.*?^[ \t]*\2[ \t]*\r?$'
$heredocEval = [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    if ($m.Groups[3].Value -match '(?i)\|\s*(sudo\s+)?(ba|z|da)?sh\b|\|\s*(powershell|pwsh|python3?|node|perl|ruby|iex|Invoke-Expression)\b') { return $m.Value }
    return $m.Groups[1].Value + ' ' + $m.Groups[3].Value
}
$cmd = [regex]::Replace($cmd, $heredocRx, $heredocEval)

$statements = Split-Statements $cmd

# Text-only statements (commit message, echo) are skipped - but not when the
# quoting cannot be trusted: an unbalanced or escaped quote could hide a real
# command inside what looks like text.
$textExemptOk = (-not $script:unbalanced) -and ($cmd -notmatch '\\["'']') -and ($cmd -notmatch '`["'']')

$cwd = [string]$call.cwd
$priorDownloads = ($cwd -match '(?i)Users[\\/][^\\/]+[\\/]Downloads([\\/]|$)')

foreach ($stmt in $statements) {
    $s = $stmt.Trim()
    if ($s -eq '') { continue }

    $isText = ($s -imatch '^\s*git(\s+-C\s+\S+|\s+-c\s+\S+|\s+--no-pager)?\s+(commit|tag)\b') -or ($s -imatch '^\s*(echo|Write-(Output|Host))\b')
    $hasSubstitution = ($s -match '\$\(') -or ($s -match '<\(') -or ($s.Contains([string][char]96))
    if ($isText -and $textExemptOk -and -not $hasSubstitution) { continue }

    if ($s -match $verbRx) {
        $hit = $false
        if ($s -match $directRx) { $hit = $true }
        elseif ($priorDownloads -and (($s -match $relRx) -or ($s -match $relBareRx))) { $hit = $true }
        elseif ($s -match $rootRx) {
            # the Downloads folder itself or a glob under it; files only (no recursion) leaves the folders alone
            $filesOnly = ($s -imatch '(?<![A-Za-z0-9_-])-File\b') -and ($s -inotmatch '-Recurse|\s-r\b')
            if (-not $filesOnly) { $hit = $true }
        }
        if ($hit) {
            Send-Block ('NEEDS CONFIRMATION: this command moves, renames or deletes something in (or into) one of the owner''s permanent Downloads folders ' +
                '(Compressed, Documents, Images, Music, Programs, Videos), or the Downloads folder itself -> ' + $s +
                '. Rule: no agent touches these without his explicit yes. Ask the owner in the chat (AskUserQuestion) and show the exact command; ' +
                'only after his yes, re-run it with the marker comment #approved-by-user at the very end. Never add the marker on your own.')
        }
    }
    if ($s -match $dlRx) { $priorDownloads = $true }
}

exit 0
