# onedrive-guard.ps1  --  Version 1.1 (2026-10-09)
#
# 1.1: after an independent review found about two dozen ways round 1.0:
#      - statements are split NAIVELY (every ; & newline CR || is a cut, quotes
#        are not modelled): a quote trick can no longer hide a second command
#      - the text-only exemption (commit message, echo) is strict: no ( ) { } $
#        backtick | < > @
#      - obfuscation is caught: ` ^ ' " and a backslash before a letter are
#        removed before matching, and a path that only matches after that is
#        refused outright; ${env:OneDrive}, %OneDriveConsumer%, Env:OneDrive and
#        wildcards under the user folder (One*, ~\*\) count as the path
#      - a recursive search / copy / delete started from a parent folder
#        (C:\Users\<name>, ~, {{HOME_CMD}}, C:\) is refused
#      - file tools: the content check covers every file type except .md .txt
#        .csv .json (package.json included), NotebookEdit too; the exemption
#        for the guard's own files compares the full path; Grep from a parent
#        folder is refused; the path test works on whole path segments, so a
#        note called "OneDrive setup.md" is no longer a hit
#      - other tools that can carry a path (Artifact, Monitor, LSP, WebFetch,
#        mcp__*) are judged on their parameters
#      - nothing runs in a loop over characters unless the command names the
#        path; a statement over 4000 characters that does is refused
#
# PreToolUse hook. Makes the document archive in OneDrive
# (OneDrive\Dokumentenarchiv) ADD-ONLY for the agent. Rule 2 of the vault's
# AGENTS.md, enforced here:
#
#   ALLOWED:
#     - listing names inside Dokumentenarchiv (Get-ChildItem / ls / dir / Glob)
#     - checking that a path exists (Test-Path, Get-Item)
#     - hashing ONE named file there (Get-FileHash)
#     - copying ONE named file OUT of it into PersonalOS\outbox (the way a
#       document is fetched)
#     - adding new files, but only through setup\powershell\add-to-archive.ps1
#       (copy only, never overwrites, fixed folders and name scheme, logged).
#       The hook needs no special case for it: the script gets the target from
#       its own parameters, so the command never names the OneDrive path.
#   BLOCKED (always, no approval marker, no exception):
#     - Read / Grep / Edit / Write / NotebookEdit on anything in OneDrive
#     - every shell statement that names an OneDrive path and is not one of the
#       allowed shapes above: delete, move, rename, overwrite (Copy-Item -Force
#       INTO it), Set-Content, Out-File, redirection, type/cat, scripts, cd ...
#     - writing a file whose text names an OneDrive path (a script would hide
#       the real command from this hook)
#
#   There is deliberately NO marker like #approved-by-user. The user does the
#   rest by hand.
#
#   How the shell check works: a statement that mentions OneDrive as a path, as
#   %OneDrive% / $env:OneDrive, or Dokumentenarchiv as a path, must match one of
#   the allowed shapes token by token. Anything with $ ` ( ) { } < > @ & in it
#   fails the shapes. A pipe may only continue into pure formatting commands.
#   Allow-list, not block-list: an unknown command never passes.
#
#   Best effort, not a sandbox. Known gaps, accepted and written down:
#     - a path built at run time ("One"+"Drive", a variable filled elsewhere,
#       -EncodedCommand, Invoke-Expression of a pieced string)
#     - a script file written by something other than the file tools
#     - hard links; a junction created before this hook existed
#     - the agent can edit this hook, the door script and settings.json (same
#       as every other hook); decision of the user, see the vault's log
#     - a hook that runs into the 10 s timeout, fails to start or whose
#       {{PWSH_HOST}} is missing does not block (Claude Code treats those as a
#       non-blocking error); the session-check hook warns about missing files
#   Second line of defence: OneDrive keeps deleted files in its online recycle
#   bin and old versions in version history.
#
#   Fail closed like block-dangerous.ps1: input that cannot be read is refused
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
    # UTF-8 BYTES, not [Console]::Error.WriteLine: that one writes in the console's OEM code
    # page, so an umlaut in a quoted path reached the agent as mojibake (measured 2026-10-16).
    # The decision was never affected by this - the message that explains it was. The try keeps
    # the fail-closed promise if the stream cannot be opened: exit 2 still happens.
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($reason + [Environment]::NewLine)
        $err = [Console]::OpenStandardError()
        $err.Write($bytes, 0, $bytes.Length)
        $err.Flush()
    } catch { }
    exit 2
}

trap {
    Send-Block 'BLOCKED: the OneDrive guard hit an unexpected error and cannot judge this call. Tell the user; do not work around it.'
}

# --- read the tool call (byte handling identical to block-dangerous.ps1) ----
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Send-Block 'BLOCKED: the OneDrive guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.'
}
try { $call = $raw | ConvertFrom-Json -ErrorAction Stop }
catch { Send-Block 'BLOCKED: the OneDrive guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.' }
$tool = [string]$call.tool_name
$inp = $call.tool_input
if ([string]::IsNullOrWhiteSpace($tool)) { exit 0 }

# --- patterns ---------------------------------------------------------------
# A real path field (file tools): the folder names as whole path segments, an
# 8.3 short name, or an environment variable that points there.
$script:WidePath = '(?i)(^|[\\/:])onedrive([\\/]|$)|(^|[\\/])dokumentenarchiv([\\/]|$)|onedri~|env:[\\/]?\{?onedrive|%onedrive|\$\{?onedrive'
# Shell text: only forms that are a path, so a search for the WORD OneDrive in a
# note is not blocked. Includes the variable spellings and wildcards that could
# reach the folder (OneDri*, a wildcard right under the user folder).
$script:NarrowText = '(?i)(onedrive[\\/]|[\\/]onedrive(?![A-Za-z0-9_.~-])|env:[\\/]?\{?onedrive|\$\{?onedrive|%onedrive\w*%|[\\/]dokumentenarchiv|dokumentenarchiv[\\/]|[\\/]onedri~|\bone(d(r(i(v)?)?)?)?[*?]|users[\\/][^\\/\s"'']*[*?]|(users[\\/][^\\/\s"'']+|~|%userprofile%|\$env:userprofile|\$home)[\\/][^\\/\s"'']*[*?])'
# The only OneDrive paths the allowed shapes accept: literal, rooted, inside
# Dokumentenarchiv, no ".." segment.
$script:ArchivePath = '(?i)^(?:[A-Z]:[\\/]|/[a-z]/)Users[\\/][^\\/]+[\\/]OneDrive[\\/]Dokumentenarchiv(?:[\\/][^\\/]+)*[\\/]?$'
$script:OutboxPath  = '(?i)^(?:[A-Z]:[\\/]|/[a-z]/)PersonalOS[\\/]outbox[\\/][^\\/*?\[]+(?:[\\/][^\\/*?\[]+)*$'
# A folder that contains the archive: scanning or copying from it reaches it.
$script:Ancestor = '(?i)^(?:[A-Z]:[\\/]?|[A-Z]:[\\/]Users[\\/]?|[A-Z]:[\\/]Users[\\/][^\\/]+[\\/]?|/[a-z]/?|/[a-z]/Users/?|/[a-z]/Users/[^/]+/?|~[\\/]?|{{HOME_CMD}}[\\/]?|\$HOME[\\/]?|\{{HOME_ENV}}[\\/]?)(\*{1,2})?$'
$script:BroadOp = '(?i)(-recurse|(^|\s)-r[a-z]*(\s|$)|\s/s\b|\bfind\b|\bgrep\b|\brg\b|robocopy|xcopy|select-string|remove-item|\brm\b|\bdel\b|copy-item|\bcp\b|move-item|\bmv\b|get-content|\bcat\b)'
$script:SafeSinks = @('select-object', 'sort-object', 'measure-object', 'format-table', 'format-list', 'group-object', 'out-string', 'head', 'tail', 'wc', 'sort')
$script:ListCmds  = @('get-childitem', 'gci', 'ls', 'dir')
$script:ExistCmds = @('test-path', 'get-item')
$script:HashCmds  = @('get-filehash', 'sha256sum')
$script:CopyCmds  = @('copy-item', 'cp', 'copy')
$script:PlainFlags = @('-name', '-file', '-directory', '-recurse', '-force')
$script:ValueFlags = @('-depth', '-filter', '-include', '-exclude', '-erroraction', '-pathtype', '-algorithm')
$script:PathFlags  = @('-literalpath', '-path')

$userHome = {{HOME_ENV}}
$exemptFiles = @(
    (Join-Path $userHome '.claude\hooks\onedrive-guard.ps1'),
    (Join-Path $userHome '.claude\setup\powershell\add-to-archive.ps1'),
    (Join-Path $userHome '.claude\setup\tests\test-onedrive-guard.ps1'),
    (Join-Path $userHome '.claude\setup\tests\test-add-to-archive.ps1')
)

$blockMsg = 'BLOCKED: the document archive in OneDrive is add-only for the agent. Allowed: listing names, Test-Path, Get-FileHash on one file, copying one file OUT to PersonalOS\outbox, and adding new files with setup\powershell\add-to-archive.ps1. Everything else there (read, change, overwrite, rename, move, delete) is done by the user, not the agent. Tell the user what you wanted; do not work around this.'

# --- helpers ----------------------------------------------------------------
function Get-Squashed([string]$text) {
    # Remove what a shell strips before it runs a word: ` ^ ' " and a
    # backslash in front of a letter (bash). Two variants.
    $a = $text -replace '[`^''"]', ''
    $b = $a -replace '\\(?=[A-Za-z])', ''
    return @($a, $b)
}

function Split-Pipes([string]$text) {
    $parts = @()
    $cur = ''
    $quote = [char]0
    foreach ($c in $text.ToCharArray()) {
        if ($quote -ne [char]0) {
            $cur += $c
            if ($c -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($c -eq [char]34 -or $c -eq [char]39) { $quote = $c; $cur += $c; continue }
        if ($c -eq '|') { $parts += $cur; $cur = ''; continue }
        $cur += $c
    }
    $parts += $cur
    return , $parts
}

function Get-Tokens([string]$text) {
    # Whitespace tokens; quotes group and are dropped. $null = unbalanced quote.
    $tokens = @()
    $cur = ''
    $has = $false
    $quote = [char]0
    foreach ($c in $text.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($c -eq $quote) { $quote = [char]0 } else { $cur += $c }
            continue
        }
        if ($c -eq [char]34 -or $c -eq [char]39) { $quote = $c; $has = $true; continue }
        if ([char]::IsWhiteSpace($c)) {
            if ($cur -ne '' -or $has) { $tokens += $cur; $cur = ''; $has = $false }
            continue
        }
        $cur += $c
    }
    if ($quote -ne [char]0) { return $null }
    if ($cur -ne '' -or $has) { $tokens += $cur }
    return , $tokens
}

function Test-TextOnly([string]$stmt) {
    # A commit message or an echo that merely MENTIONS the path is text, not an
    # operation. Strict: nothing that can run, redirect, pipe or expand.
    if ($stmt -notmatch '(?i)^\s*(git(\s+-C\s+\S+)?\s+(commit|tag)\b|echo\b|Write-(Output|Host)\b)') { return $false }
    if ($stmt -match '[`$(){}<>|@]') { return $false }
    return $true
}

function Test-ArchiveToken([string]$t, [bool]$allowWildcard) {
    if ($t -notmatch $script:ArchivePath) { return $false }
    if ($t -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    if (-not $allowWildcard -and $t -match '[*?\[\]]') { return $false }
    return $true
}

function Test-AncestorScan([string]$stmt) {
    # A recursive search / copy / delete that starts at a parent folder of the
    # archive reaches it without ever naming it.
    if ($stmt -notmatch $script:BroadOp) { return $false }
    foreach ($t in ($stmt -split '\s+')) {
        $u = $t.Trim('"', "'")
        if ($u -ne '' -and $u -match $script:Ancestor) { return $true }
    }
    return $false
}

function Test-Statement([string]$stmt) {
    # Returns $true when the statement is one of the allowed shapes.
    if ($stmt -match '[`$(){}<>@&]') { return $false }
    $segments = Split-Pipes $stmt
    $main = [string]$segments[0]
    for ($i = 1; $i -lt $segments.Count; $i++) {
        $t = Get-Tokens ([string]$segments[$i])
        if ($null -eq $t -or $t.Count -eq 0) { return $false }
        if ($script:SafeSinks -notcontains $t[0].ToLower()) { return $false }
        if (([string]$segments[$i]) -match $script:NarrowText) { return $false }
    }
    $tok = Get-Tokens $main
    if ($null -eq $tok -or $tok.Count -eq 0) { return $false }
    $name = $tok[0].ToLower()
    $isList = $script:ListCmds -contains $name
    $isExist = $script:ExistCmds -contains $name
    $isHash = $script:HashCmds -contains $name
    $isCopy = $script:CopyCmds -contains $name
    if (-not ($isList -or $isExist -or $isHash -or $isCopy)) { return $false }

    $positional = @()
    $i = 1
    while ($i -lt $tok.Count) {
        $t = [string]$tok[$i]
        $lt = $t.ToLower()
        if ($t.StartsWith('-')) {
            if ($script:PlainFlags -contains $lt) {
                # Copying out takes one named file; -Recurse (a folder) and the
                # listing flags are not part of that shape. -Force only
                # overwrites the copy in outbox.
                if ($isCopy -and $lt -ne '-force') { return $false }
                $i++; continue
            }
            if ($script:ValueFlags -contains $lt) {
                if ($i + 1 -ge $tok.Count) { return $false }
                if (([string]$tok[$i + 1]) -match $script:NarrowText) { return $false }
                $i += 2; continue
            }
            if ($script:PathFlags -contains $lt) {
                if ($i + 1 -ge $tok.Count) { return $false }
                $positional += [string]$tok[$i + 1]
                $i += 2; continue
            }
            if ($lt -eq '-destination' -and $isCopy) {
                if ($i + 1 -ge $tok.Count) { return $false }
                $positional += [string]$tok[$i + 1]
                $i += 2; continue
            }
            if ($t -match '^-[A-Za-z0-9]{1,6}$' -and $isList -and $name -eq 'ls') { $i++; continue }   # bash ls -la
            return $false
        }
        $positional += $t
        $i++
    }

    if ($isCopy) {
        # exactly: <one named file inside Dokumentenarchiv> <file in PersonalOS\outbox>
        if ($positional.Count -ne 2) { return $false }
        if (-not (Test-ArchiveToken $positional[0] $false)) { return $false }
        if ($positional[0] -notmatch '(?i)Dokumentenarchiv[\\/]([^\\/]+[\\/])*[^\\/]+[.][A-Za-z0-9]{1,5}$') { return $false }   # a named file, not a folder
        if ($positional[1] -notmatch $script:OutboxPath) { return $false }
        if ($positional[1] -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
        if ($positional[1] -match $script:NarrowText) { return $false }
        return $true
    }
    if ($positional.Count -lt 1) { return $false }
    foreach ($p in $positional) {
        if ($p -match $script:NarrowText) {
            if (-not (Test-ArchiveToken $p ($isList -or $isExist))) { return $false }
        }
    }
    if ($isHash -and $positional.Count -ne 1) { return $false }
    return $true
}

function Test-Mentions([string]$text) {
    # Returns 0 = no mention, 1 = plain mention, 2 = only after de-obfuscation.
    if ($text -match $script:NarrowText) { return 1 }
    foreach ($v in (Get-Squashed $text)) { if ($v -match $script:NarrowText) { return 2 } }
    return 0
}

# --- file tools: Read / Edit / Write / NotebookEdit -------------------------
if ($tool -eq 'Read' -or $tool -eq 'Edit' -or $tool -eq 'Write' -or $tool -eq 'NotebookEdit') {
    $path = [string]$inp.file_path
    if ($tool -eq 'NotebookEdit') { $path = [string]$inp.notebook_path }
    if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }
    if ($path -match $script:WidePath) { Send-Block $blockMsg }

    if ($tool -ne 'Read') {
        # A file whose text names the OneDrive path could run it out of this
        # hook's sight (a script, a Makefile, a package.json). Plain notes are
        # exempt, and so are the guard's own files, compared by full path.
        $isNote = ($path -match '(?i)[.](md|txt|csv)$') -or (($path -match '(?i)[.]json$') -and ($path -notmatch '(?i)package[.]json$'))
        if (-not $isNote) {
            $full = $path
            try { $full = [IO.Path]::GetFullPath($path) } catch { }
            $isExempt = $false
            foreach ($e in $exemptFiles) { if ($full.Equals($e, [StringComparison]::OrdinalIgnoreCase)) { $isExempt = $true } }
            if (-not $isExempt) {
                $text = [string]$inp.content + "`n" + [string]$inp.new_string + "`n" + [string]$inp.new_source
                if ((Test-Mentions $text) -ne 0) {
                    Send-Block 'BLOCKED: a file may not name the OneDrive document archive (the guard cannot see what a script does with it). Use setup\powershell\add-to-archive.ps1 to add files, or ask the user.'
                }
            }
        }
    }
    exit 0
}

# --- Grep -------------------------------------------------------------------
if ($tool -eq 'Grep') {
    $target = ([string]$inp.path) + ' ' + ([string]$inp.glob)
    if ($target -match $script:WidePath) { Send-Block $blockMsg }
    $gp = ([string]$inp.path).Trim()
    if ($gp -ne '' -and $gp -match $script:Ancestor) {
        Send-Block 'BLOCKED: a search that starts at a parent folder of the OneDrive document archive would read it. Search a narrower folder.'
    }
    exit 0
}

# --- Glob: names only, and only inside Dokumentenarchiv ---------------------
if ($tool -eq 'Glob') {
    $target = ([string]$inp.pattern) + ' ' + ([string]$inp.path)
    if ($target -notmatch $script:WidePath) { exit 0 }
    if (([string]$inp.path) -match $script:WidePath -and -not (Test-ArchiveToken ([string]$inp.path).Trim() $true)) { Send-Block $blockMsg }
    $pat = [string]$inp.pattern
    if ($pat -match $script:WidePath -and -not (Test-ArchiveToken $pat.Trim() $true)) { Send-Block $blockMsg }
    exit 0
}

# --- Bash / PowerShell / Monitor --------------------------------------------
if ($tool -eq 'Bash' -or $tool -eq 'PowerShell' -or $tool -eq 'Monitor') {
    $cmd = [string]$inp.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

    $mentionsAny = (Test-Mentions $cmd) -ne 0
    $scanWords = $cmd -match '(?i)(users|~|\$home|userprofile|[a-z]:[\\/]|/[a-z]/)'
    if (-not $mentionsAny -and -not $scanWords) { exit 0 }
    if ($mentionsAny -and $cmd.Length -gt 100000) { Send-Block ($blockMsg + ' (the command is too long to judge)') }

    # Naive split: every ; & newline CR and || is a cut. Quotes are not
    # modelled on purpose - a quote trick cannot hide a second command.
    foreach ($seg in [regex]::Split($cmd, '\r\n|[\r\n;&]|\|\|')) {
        $s = $seg.Trim()
        if ($s -eq '') { continue }
        if (Test-AncestorScan $s) {
            Send-Block ('BLOCKED: a recursive search, copy or delete that starts at a parent folder of the OneDrive document archive would reach it. Name a narrower folder. Statement: ' + $s)
        }
        $m = Test-Mentions $s
        if ($m -eq 0) { continue }
        if ($m -eq 2) { Send-Block ($blockMsg + ' (the path is written with escape characters)') }
        if ($s.Length -gt 4000) { Send-Block ($blockMsg + ' (statement too long to judge)') }
        if (Test-TextOnly $s) { continue }
        if (Test-Statement $s) { continue }
        $hint = ''
        if ($s -match '(?i)^\s*(git\b|echo\b|Write-(Output|Host)\b)') { $hint = ' (A commit message or echo that only mentions the path must be plain text without ( ) { } $ | < > @ and backtick; or leave the path out and say "OneDrive archive".)' }
        Send-Block ($blockMsg + ' Blocked statement: ' + $s + $hint)
    }
    exit 0
}

# --- any other tool that can carry a path (Artifact, LSP, WebFetch, mcp__*) --
$paramText = ''
try { $paramText = $inp | ConvertTo-Json -Compress -Depth 8 } catch { $paramText = [string]$inp }
if ((Test-Mentions $paramText) -ne 0) { Send-Block $blockMsg }
exit 0
