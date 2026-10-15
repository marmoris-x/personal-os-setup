# block-dangerous.ps1  --  Version 12 (2026-09-29)
#
# PreToolUse hook for the Bash and PowerShell tools. Keeps the agent
# autonomous and only steps in for the few things that lose data by accident:
#
#   BLOCK always:        deleting anything in a ".claude" folder,
#                        formatting / wiping a whole disk.
#   BLOCK until you say yes: deleting a whole FOLDER (recursive delete),
#                        deleting a dependency lock file or anything in .git,
#                        throwing away uncommitted git work
#                        (reset --hard, clean -f, checkout/restore of ".",
#                        stash drop/clear). The agent is told to ask you in
#                        the chat; after your yes it re-runs the command
#                        with the marker  #confirmed-by-user  appended.
#   ALLOW (everything else): single-file deletes, deleting regenerable
#                        build folders (node_modules, dist, build, ...),
#                        force-push, installs, scripts, ...
#
#   Version 10 adds one ALLOW: a whole folder INSIDE a scratch root
#   ({{DEV}}\Temp and %TEMP%/%TMP%) may be deleted without asking. Scratch
#   work is meant to be cleaned up by the agent itself, and a confirmation
#   prompt on every cleanup teaches the user to click yes.
#   The scratch roots themselves are NOT scratch: deleting {{DEV}}\Temp
#   still asks. And inside a scratch root the rules above still hold -
#   nothing in a ".claude" folder, no lock file, nothing in ".git".
#
#   Version 11 adds the other spellings of the same roots. {{DEV_FWD}}/Temp and
#   {{DEV_BASH}}/Temp were already judged correctly - they are normalized before the
#   comparison - and are now in the test suite as regression guards. %TEMP% and
#   %TMP%, cmd's spelling, are expanded too, but ONLY in a segment that runs
#   cmd: in bash and in PowerShell the very same text is a folder literally
#   named "%TEMP%", so expanding it there would judge a different path than the
#   one the command deletes. Both directions are in the test suite.
#
#   Corrected the same day, after the first version was measured: it required
#   EVERY argument to be a path, so the two ordinary spellings
#     if (Test-Path {{DEV}}\Temp\x) { Remove-Item {{DEV}}\Temp\x -Recurse -Force }
#     Remove-Item {{DEV}}\Temp\x -Recurse -Force    # tidy up
#   asked for confirmation, because "if", "{", "}" and the comment's words were
#   read as paths. They are not paths, and now they are not read as any: only
#   tokens that could be a path are judged, and one rooted path with no drive
#   letter (\Windows\System32) is refused rather than ignored. Both forms are
#   in the test suite.
#
#   Version 12 makes the guard fail closed. Before, input it could not parse (for
#   example JSON with a leading byte order mark, which the agent's PowerShell tool
#   sends) ended in "exit 0" = let everything through, and a crash ended in exit 1,
#   which Claude Code also treats as "go ahead". Now a leading BOM is removed, input
#   that is still empty or not JSON is refused with exit 2 and a clear message, and
#   a trap turns any unexpected error into exit 2. Valid JSON that carries no command
#   (a tool without one) is still allowed. What no hook can do is guard against its own
#   file being missing or unparsable: hooks/session-check.ps1 warns about that at every
#   session start.
#
# Claude Code itself already protects drive roots, top-level folders
# ({{DEV}}, {{VAULT}}, C:\Windows), your home folder and wildcard
# Remove-Item in every permission mode. This hook covers the gap below that:
# project folders such as {{DEV}}\Projects\buttercup.
#
# Best effort, not a sandbox: code that deletes from inside a script file
# cannot be seen here. Inline one-liners (python -c shutil.rmtree, node
# rmSync, [IO.Directory]::Delete) are caught.
#
# ASCII ONLY: Windows PowerShell 5.1 reads BOM-less .ps1 files in the ANSI
# codepage; a non-ASCII character can crash the script, and a crashed hook
# lets the command through. Keep this file plain ASCII.
#
# Why "block + confirm in chat" and not the hook "ask" decision: several
# open Claude Code issues report that a hook "ask" is silently treated as
# "allow" in auto mode on Windows (#89561) and in the VS Code extension
# (#86754). Exit code 2 is documented to block in EVERY mode, including
# bypassPermissions, and has worked on this machine since Version 3.
#
# The marker is self-declared, so this protects against ACCIDENTS (wrong
# path, over-eager cleanup), not against a deliberately hostile agent.
#
# Output contract: exit 2 + message on stderr = blocked (message goes to
# the model). exit 0 = normal permission flow.

$ErrorActionPreference = 'SilentlyContinue'

function Send-Block([string]$reason) {
    [Console]::Error.WriteLine($reason)
    exit 2
}

function Send-Confirm([string]$what) {
    if ($script:confirmed) { return }
    Send-Block ("NEEDS CONFIRMATION: $what. Ask the user in the chat (AskUserQuestion) and show the exact command. " +
                "Only if the user says yes, run the same command again with the marker  #confirmed-by-user  appended at the end.")
}

# Fail closed (version 12): only exit 2 blocks, every other exit code lets the command
# through. So an unexpected error must end in exit 2, never in the default exit 1.
trap {
    Send-Block 'BLOCKED: the delete guard hit an unexpected error and cannot judge this command. Tell the user; do not work around it.'
}

# A UTF-8 byte order mark (bytes EF BB BF) in front of the JSON makes ConvertFrom-Json fail;
# the agent's PowerShell tool sends one. [Console]::In would decode those bytes with the
# console's OEM code page into three stray characters (measured: ibm850 gives 180, 9559,
# 9488), so the bytes are read raw, the mark is cut off there, and the rest is decoded
# as UTF-8. Input that is then still empty or not JSON is refused.
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Send-Block 'BLOCKED: the delete guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.'
}
try { $cmd = ($raw | ConvertFrom-Json -ErrorAction Stop).tool_input.command }
catch { Send-Block 'BLOCKED: the delete guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.' }
if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }
$script:confirmed = $cmd -imatch '#\s*confirmed-by-user'
$script:isCmd = $false                 # set per segment; read by Test-AllScratch

# --- 1. Whole-disk wipes: always refused ----------------------------------
foreach ($p in @('\bFormat-Volume\b', '\bClear-Disk\b', '\bmkfs(\.\w+)?\b',
                 '\bdd\b[^\n]*\bof=/dev/', '\bformat(\.com)?\s+[A-Za-z]:',
                 '\bdiskpart\b')) {
    if ($cmd -imatch $p) {
        Send-Block 'BLOCKED by user policy: this command wipes a whole disk or volume.'
    }
}

# Folder names that are safe to delete because a build or install recreates them.
$regenerable = @('node_modules', 'dist', 'build', 'out', '.next', '.nuxt',
    '.turbo', '.cache', '.parcel-cache', 'coverage', '__pycache__',
    '.pytest_cache', '.mypy_cache', '.ruff_cache', 'target', 'bin', 'obj',
    '.gradle', '.venv', 'venv')

function Get-PathTokens([string]$segment) {
    # All arguments that are not the command itself and not a flag.
    $tokens = [regex]::Matches($segment, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value }
    $paths = @()
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i].Trim('"', "'", ',')
        if ($t -eq '') { continue }
        if ($t -match '^-') { continue }                 # -r, -Recurse, --force
        if ($t -match '^/[A-Za-z]$') { continue }       # cmd flags /s /q
        if ($t -imatch '^(cmd|/c|rm|rmdir|rd|del|erase|ri|Remove-Item)$') { continue }
        $paths += $t
    }
    return ,$paths
}

function Test-AllRegenerable([string[]]$paths) {
    if ($paths.Count -eq 0) { return $false }            # target unknown -> ask
    foreach ($p in $paths) {
        if ($p -match '[\$\*\?%`]') { return $false }    # variables / wildcards -> ask
        $leaf = ($p -replace '[\\/]+$', '') -split '[\\/]' | Select-Object -Last 1
        if ($regenerable -notcontains $leaf.ToLower()) { return $false }
    }
    return $true
}

# Scratch roots (version 10): folders whose whole purpose is to be thrown away
# again. A delete strictly inside one of them needs no confirmation.
$scratchRoots = @()
foreach ($r in @('{{DEV}}\Temp', {{TEMP_ENV}}, {{TMP_ENV}})) {
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    if ($r -notmatch '^[A-Za-z]:[\\/]') { continue }     # absolute local paths only
    try { $scratchRoots += ([IO.Path]::GetFullPath($r)).TrimEnd('\') } catch { }
}
$scratchRoots = @($scratchRoots | Select-Object -Unique)

function Test-AllScratch([string[]]$paths) {
    # True only when every path-like argument is strictly inside a scratch root.
    #
    # It cannot require that EVERY token is a path. A segment is raw command text,
    # so it also holds the words of an if-block and of a trailing comment:
    #   if (Test-Path {{DEV}}\Temp\x) { Remove-Item {{DEV}}\Temp\x -Recurse -Force }
    #   Remove-Item {{DEV}}\Temp\x -Recurse -Force   # tidy up
    # Both are ordinary ways to write the same delete, and with an every-token rule
    # both asked for confirmation, which made the exception look broken. So: take
    # only the tokens that can be a path at all -- a drive letter, or a rooted \ or
    # / -- and require every one of them to be inside scratch. A token that carries
    # a variable or a wildcard anywhere still asks, and a segment with no path-like
    # token at all is an unknown target and still asks.
    if ($scratchRoots.Count -eq 0) { return $false }
    $found = 0
    foreach ($p in $paths) {
        # "C:\x)" and "C:\x," come from an if-block and from a list; the path is
        # what is left of them. Trimming can only shorten a path, never move it
        # out of scratch, so a mis-trim is safe in the asking direction.
        $t = $p.TrimEnd(')', '}', ']', ',', ';', '"', "'")
        if ($t -eq '') { continue }

        # {{TEMP_ENV}}\x names a scratch root by definition -- but expand it rather
        # than skip it, so "{{TEMP_ENV}}\..\..\x" is resolved and judged like any
        # other path instead of being waved through.
        if ($t -imatch '^\$env:(TEMP|TMP)(.*)$') {
            # Read both groups out first. A second -match anywhere below would
            # overwrite $Matches, and the tail of the path would be lost.
            $which = $Matches[1]
            $rest = $Matches[2]
            $root = if ($which -ieq 'TEMP') { {{TEMP_ENV}} } else { {{TMP_ENV}} }
            if ([string]::IsNullOrWhiteSpace($root)) { return $false }
            $t = $root.TrimEnd('\') + $rest
        }

        # cmd.exe spells the same roots %TEMP% and %TMP%. Expand them only in a
        # segment that actually runs cmd: in bash and in PowerShell the same text
        # names a folder literally called "%TEMP%", and expanding it there would
        # judge a path the command does not touch. Anything else stays an unknown
        # target and asks.
        if ($script:isCmd -and $t -imatch '^%(TEMP|TMP)%(.*)$') {
            # Both groups first, for the same reason as above: a later -match
            # would overwrite $Matches and lose the tail of the path.
            $which = $Matches[1]
            $rest = $Matches[2]
            $root = if ($which -ieq 'TEMP') { {{TEMP_ENV}} } else { {{TMP_ENV}} }
            if ([string]::IsNullOrWhiteSpace($root)) { return $false }
            $t = $root.TrimEnd('\') + $rest
        }

        # Git Bash spells the same folder {{DEV_BASH}}/Temp/x. Normalize before judging.
        $norm = $t
        if ($norm -match '^/([A-Za-z])(/.*)$') { $norm = $Matches[1] + ':' + ($Matches[2] -replace '/', '\') }

        if ($norm -notmatch '^[A-Za-z]:[\\/]') {
            # Rooted but with no drive letter (\Windows\System32) can never be
            # inside a scratch root. A variable (%TEMP%\x, $dir) is an unknown
            # target. Everything else -- "if", "{", "}", the words of a comment --
            # is not a path at all and is skipped.
            if ($norm -match '^[\\/$%]') { return $false }
            if ($norm -match '[%`]') { return $false }
            continue
        }
        $found++

        if ($t -match '[\$\*\?%`]') { return $false }    # variable / wildcard inside a path

        $full = $null
        # GetFullPath resolves ".." first, so "{{DEV}}\Temp\..\Projects\x" is judged
        # as {{DEV}}\Projects\x and is therefore NOT scratch.
        try { $full = [IO.Path]::GetFullPath($norm).TrimEnd('\') } catch { return $false }
        $inside = $false
        foreach ($r in $scratchRoots) {
            if ($full -imatch ('^' + [regex]::Escape($r) + '\\')) { $inside = $true; break }
        }
        if (-not $inside) { return $false }
    }
    return ($found -gt 0)                                # no path seen -> unknown -> ask
}

# Split compound commands so each part is judged on its own.
$segments = $cmd -split '\r?\n|;|&&|\|\||\|'

foreach ($seg in $segments) {
    $s = $seg.Trim()
    if ($s -eq '') { continue }
    if ($s -imatch '^(git\s+commit|echo|Write-(Output|Host))\b') { continue }   # text, not an action

    # Does this segment run cmd? Only then do %TEMP% and %TMP% mean the temp
    # folder rather than a literal folder of that name (see Test-AllScratch).
    $script:isCmd = [bool]($s -imatch '(^|[\s(&|])cmd(\.exe)?\b')

    $isDelete = $s -imatch '(^|[\s(&])(rm|rmdir|rd|del|erase|ri|Remove-Item)(\s|$)' -or
                $s -imatch 'shutil\.rmtree|\brmSync\b|\brimraf\b|IO\.Directory\]::Delete|\bos\.remove\b|\bunlink(Sync)?\b'

    # --- 2. Anything inside a .claude folder: always refused --------------
    if ($isDelete -and $s -imatch '\.claude([\\/"''\s]|$)') {
        Send-Block 'BLOCKED by user policy: nothing inside a .claude folder may be deleted. Edit or overwrite files instead, or ask the user to delete it by hand.'
    }

    # --- 2b. Lock files and git internals: confirm before deleting ---------
    # Deleting a dependency lock file (package-lock.json, yarn.lock, ...) to make an
    # install "work" silently changes versions; deleting files inside .git (index.lock
    # while git is running, refs, objects) can corrupt the repository.
    if ($isDelete -and $s -inotmatch '\bgit\s+rm\b.*--cached') {
        if ($s -imatch '(^|[\\/\s"''])(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|poetry\.lock|uv\.lock|Pipfile\.lock|Cargo\.lock|composer\.lock|Gemfile\.lock|packages\.lock\.json)(["''\s]|$)') {
            Send-Confirm "this deletes a dependency lock file -> $s"
        }
        if ($s -imatch '(^|[\\/\s"''])\.git([\\/]|["''\s]|$)') {
            Send-Confirm "this deletes something inside a .git folder -> $s"
        }
    }

    # --- 3. Git commands that throw away uncommitted work ------------------
    if ($s -imatch '\bgit\b') {
        $gitAsk = $null
        if ($s -imatch '\bgit\s+reset\b.*--hard') { $gitAsk = 'git reset --hard discards all uncommitted changes' }
        elseif ($s -imatch '\bgit\s+clean\b' -and $s -imatch '\s(-[a-zA-Z]*f[a-zA-Z]*|--force)\b' -and $s -inotmatch '\s(-[a-zA-Z]*n[a-zA-Z]*|--dry-run)\b') { $gitAsk = 'git clean deletes untracked files' }
        elseif ($s -imatch '\bgit\s+(checkout|restore)\b.*\s(\.|\*|:/)(\s|$)') { $gitAsk = 'this discards uncommitted changes in every file' }
        elseif ($s -imatch '\bgit\s+stash\s+(drop|clear)\b') { $gitAsk = 'this deletes stashed work' }
        elseif ($s -imatch '\bgit\s+rm\b' -and $s -imatch '\s-[a-zA-Z]*r' -and $s -inotmatch '--cached') { $gitAsk = 'git rm -r deletes a whole folder' }
        if ($gitAsk) { Send-Confirm $gitAsk }
        if ($s -imatch '\bgit\s+rm\b') { continue }      # git rm handled above
    }

    if (-not $isDelete) { continue }

    # --- 4. Recursive (whole-folder) deletes -------------------------------
    $recursive = $false
    $hasRecurseFlag = ($s -imatch '\s-rec(u(r(s(e)?)?)?)?(\s|:|$)') -or   # PowerShell -Recurse / -Rec
                      ($s -cmatch '\s-[rRfvId]*[rR][rRfvId]*(\s|$)') -or    # rm -r, -rf, -fr, -Rf
                      ($s -imatch '\s(--recursive|/s)(\s|$)')              # rm --recursive, cmd /s
    if ($s -imatch '(^|\s)(rm|ri|del|erase|rd|rmdir|Remove-Item)(\s|$)' -and $hasRecurseFlag) { $recursive = $true }
    if ($s -imatch '(^|\s)(rmdir|rd)(\s|$)') { $recursive = $true }   # removes a folder by definition
    if ($s -imatch 'shutil\.rmtree|\brimraf\b|IO\.Directory\]::Delete|recursive\s*:\s*true') { $recursive = $true }

    if ($recursive) {
        $targets = Get-PathTokens $s
        if (Test-AllRegenerable $targets) { continue }
        if (Test-AllScratch $targets) { continue }
        Send-Confirm "this deletes a whole folder -> $s"
    }
}

exit 0
