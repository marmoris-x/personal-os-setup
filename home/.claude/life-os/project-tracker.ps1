# project-tracker.ps1 - Life OS project change tracker. Runs before the morning agent.
#
# For every git repository directly under {{DEV}}\Projects it reads, read-only and with
# `git --no-optional-locks`:
#   HEAD, `git status --porcelain` (count + hash), commits ahead of upstream, stashes.
# The checks follow mgitstatus (https://www.mankier.com/1/mgitstatus): dirty, untracked,
# ahead/behind, no upstream, detached HEAD, stashes.
#
# It compares with the last seen state in %LOCALAPPDATA%\life-os\projects-state.json, not with
# a time window, so days with the PC off are never missed. Edge cases: a new repo, a repo that
# is gone or renamed, rewritten history (the old HEAD is not an ancestor), a folder without
# git, and uncommitted changes that are reported once until they change again.
#
# On a day with changes it appends one line per changed project to
# <vault>\000-meta\project-activity.md and updates only these frontmatter keys in
# <vault>\200-projects\<name>.md: last_activity, uncommitted, unpushed. It never touches the
# body or another key. On a quiet day it writes nothing and removes its own stale flag.
#
# On any day with changes, attention (uncommitted or unpushed) or a large file, it writes
# <vault>\000-meta\life-os-projects.json for the morning agent. That file also carries the
# "Next step" from each changed project's PROGRESS.md, so the agent never reads outside the
# vault. The safety net lists every file above 1 GB under {{DEV}}\Projects outside media\raw
# and not ignored by a .kopiaignore, plus the total size of all media\raw folders.
#
# It reads projects only and never writes into them.
# ASCII only (Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page).

param(
    [string]$DevRoot = '{{DEV}}\Projects',
    [string]$VaultPath = '{{VAULT}}',
    [string]$StatePath = "{{LIFEOS_STATE}}\projects-state.json",
    [string]$LogDir = "{{LIFEOS_STATE}}\logs"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\life-os-common.ps1"
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$today = (Get-Date).ToString('yyyy-MM-dd')
$activityFile = Join-Path $VaultPath '000-meta\project-activity.md'
$flagFile = Join-Path $VaultPath '000-meta\life-os-projects.json'
# Frontmatter as the vault requires for every note (type, status, date).
$activityHeader = "---`ntype: note`nstatus: active`ndate: " + $today + "`n---`n# Projekt-Aktivitaet`n`n"

function Get-Git([string]$repo, [string[]]$gitArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & git --no-optional-locks -C $repo @gitArgs 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Lines = @($out) }
}

function Get-StatusHash([string[]]$lines) {
    $text = (@($lines) -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $hash = $sha.ComputeHash($bytes)
    } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Read-State([string]$path) {
    $empty = [pscustomobject]@{ version = 1; last_run = ''; repos = [pscustomobject]@{}; no_git = @() }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $obj.repos) { $obj | Add-Member -NotePropertyName repos -NotePropertyValue ([pscustomobject]@{}) -Force }
        if (-not $obj.no_git) { $obj | Add-Member -NotePropertyName no_git -NotePropertyValue @() -Force }
        return $obj
    } catch { return $empty }
}

function Get-StateValue($repoState, [string]$name) {
    if ($null -eq $repoState) { return $null }
    $prop = $repoState.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-DirtyDays($since) {
    if (-not $since) { return 0 }
    try { return [int](([datetime]$today) - ([datetime]$since)).Days } catch { return 0 }
}

function Get-NextStep([string]$repo) {
    # The agent has no shell and may not read outside the vault, so the tracker carries the
    # "Next step" from PROGRESS.md in the flag file.
    $path = Join-Path $repo 'PROGRESS.md'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lines = Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue
    $inside = $false
    $parts = @()
    foreach ($line in $lines) {
        if ($line -match '^##\s+(Next step|Next steps|Next|N.chster Schritt)\b') { $inside = $true; continue }
        if ($inside -and $line -match '^##\s+') { break }
        if ($inside -and $line.Trim()) { $parts += $line.Trim() }
    }
    if ($parts.Count -eq 0) { return $null }
    $text = ($parts -join ' ')
    if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
    return $text
}

function Update-Frontmatter([string]$path, [string]$lastActivity, [bool]$uncommitted, [int]$unpushed) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $text = [IO.File]::ReadAllText($path)
    $m = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return $false }
    $newline = "`n"
    if ($text.Contains("`r`n")) { $newline = "`r`n" }
    $lines = @($m.Groups[1].Value -split '\r?\n')
    $values = [ordered]@{
        last_activity = $lastActivity
        uncommitted   = $uncommitted.ToString().ToLower()
        unpushed      = [string]$unpushed
    }
    foreach ($key in $values.Keys) {
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^' + [regex]::Escape($key) + '\s*:')) {
                $lines[$i] = $key + ': ' + $values[$key]
                $found = $true
                break
            }
        }
        if (-not $found) { $lines += ($key + ': ' + $values[$key]) }
    }
    $newBlock = ($lines -join $newline)
    $newText = $text.Substring(0, $m.Groups[1].Index) + $newBlock + $text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
    if ($newText -ne $text) {
        [IO.File]::WriteAllText($path, $newText, (New-Object Text.UTF8Encoding($false)))
        return $true
    }
    return $false
}

function Convert-KopiaPattern([string]$pattern, [bool]$anchored) {
    $p = $pattern -replace '\\', '/'
    $p = $p.Trim('/')
    $out = ''
    $i = 0
    while ($i -lt $p.Length) {
        $c = $p[$i]
        if ($c -eq '*') {
            if (($i + 1) -lt $p.Length -and $p[$i + 1] -eq '*') { $out += '.*'; $i += 2; continue }
            $out += '[^/]*'; $i++; continue
        }
        if ($c -eq '?') { $out += '[^/]'; $i++; continue }
        $out += [regex]::Escape([string]$c)
        $i++
    }
    if ($anchored -or $pattern.Contains('/')) { return '^' + $out + '(/|$)' }
    return '(^|/)' + $out + '(/|$)'
}

function Test-KopiaIgnored([string]$projectRoot, [string]$relativePath) {
    # Best effort, Kopia/gitignore-like: root and subfolder .kopiaignore files, comments,
    # negation with !, anchored /, **, * and ?, directory patterns ending in /.
    $rel = ($relativePath -replace '\\', '/').TrimStart('/')
    $ignoreDirs = @($projectRoot)
    $parentRel = ($rel -split '/')[0..([Math]::Max(0, (($rel -split '/').Count - 2)))]
    $acc = $projectRoot
    $segments = @($rel -split '/')
    for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
        $acc = Join-Path $acc $segments[$i]
        if (Test-Path -LiteralPath $acc) { $ignoreDirs += $acc }
    }
    $ignored = $false
    foreach ($dir in $ignoreDirs) {
        $file = Join-Path $dir '.kopiaignore'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        foreach ($raw in (Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            $negate = $false
            if ($line.StartsWith('!')) { $negate = $true; $line = $line.Substring(1).Trim() }
            $directory = $line.EndsWith('/')
            $anchored = $line.StartsWith('/')
            $line = $line.Trim('/')
            if (-not $line) { continue }
            $rx = Convert-KopiaPattern $line $anchored
            if ($directory) { $rx = $rx -replace '\(/|$\)$', '(/|$)' }
            if ($rel -match $rx) { $ignored = -not $negate }
        }
    }
    return $ignored
}

# --- projects -----------------------------------------------------------------------------
$oldState = Read-State $StatePath
$projectDirs = @(Get-ChildItem -LiteralPath $DevRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
$newRepos = [ordered]@{}
$changedProjects = @()
$attention = @()
$noGitNow = @()
$noGitNew = @()
$missingNew = @()
$stateChanged = $false

foreach ($dir in $projectDirs) {
    $name = $dir.Name
    $gitPath = Join-Path $dir.FullName '.git'
    if (-not (Test-Path -LiteralPath $gitPath)) {
        $noGitNow += $name
        $wasKnown = ($oldState.no_git -contains $name)
        if (-not $wasKnown) { $noGitNew += $name; $stateChanged = $true }
        continue
    }

    $old = Get-StateValue $oldState.repos $name
    $isNew = ($null -eq $old)
    $returned = $false
    if ($old -and ($old.PSObject.Properties['missing'] -and $old.missing -eq $true)) { $returned = $true; $isNew = $false }

    $headOut = Get-Git $dir.FullName @('rev-parse', 'HEAD')
    $head = ''
    if ($headOut.Code -eq 0 -and $headOut.Lines.Count -gt 0) { $head = [string]$headOut.Lines[0] }

    $statusOut = Get-Git $dir.FullName @('status', '--porcelain')
    $statusLines = @($statusOut.Lines | Where-Object { [string]$_ -ne '' })
    $dirty = ($statusLines.Count -gt 0)
    $statusHash = Get-StatusHash $statusLines

    $upstream = Get-Git $dir.FullName @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    $noUpstream = ($upstream.Code -ne 0)
    $unpushed = 0
    if (-not $noUpstream) {
        $countOut = Get-Git $dir.FullName @('rev-list', '--count', '@{upstream}..HEAD')
        if ($countOut.Code -eq 0 -and $countOut.Lines.Count -gt 0) { $unpushed = [int]$countOut.Lines[0] }
    }

    $stashOut = Get-Git $dir.FullName @('stash', 'list')
    $stashes = @($stashOut.Lines | Where-Object { [string]$_ -ne '' }).Count

    $oldHead = ''
    $oldDirty = $false
    $oldHash = ''
    $oldUnpushed = 0
    $oldStashes = 0
    $oldDirtySince = $null
    if ($old) {
        if ($old.PSObject.Properties['head']) { $oldHead = [string]$old.head }
        if ($old.PSObject.Properties['dirty']) { $oldDirty = [bool]$old.dirty }
        if ($old.PSObject.Properties['status_hash']) { $oldHash = [string]$old.status_hash }
        if ($old.PSObject.Properties['unpushed']) { $oldUnpushed = [int]$old.unpushed }
        if ($old.PSObject.Properties['stashes']) { $oldStashes = [int]$old.stashes }
        if ($old.PSObject.Properties['dirty_since']) { $oldDirtySince = $old.dirty_since }
    }

    $rewritten = $false
    if ($oldHead -and $head -and ($oldHead -ne $head)) {
        $ancestor = Get-Git $dir.FullName @('merge-base', '--is-ancestor', $oldHead, $head)
        if ($ancestor.Code -ne 0) { $rewritten = $true }
    }

    $headChanged = ($isNew -or $returned -or ($oldHead -ne $head))
    $statusChanged = (-not $isNew -and -not $returned -and ($oldHash -ne $statusHash))
    $unpushedChanged = (-not $isNew -and -not $returned -and ($oldUnpushed -ne $unpushed))
    $stashChanged = (-not $isNew -and -not $returned -and ($oldStashes -ne $stashes))
    $dirtyEvent = ($dirty -and ($isNew -or $returned -or (-not $oldDirty) -or ($oldHash -ne $statusHash)))
    $changed = ($isNew -or $returned -or $headChanged -or $statusChanged -or $unpushedChanged -or $stashChanged -or $dirtyEvent)

    $dirtySince = $null
    if ($dirty) {
        if ($isNew -or $returned -or (-not $oldDirty) -or ($oldHash -ne $statusHash) -or (-not $oldDirtySince)) {
            $dirtySince = $today
        } else { $dirtySince = $oldDirtySince }
    }
    $dirtyDays = Get-DirtyDays $dirtySince

    $subjects = @()
    if ($changed -and $head) {
        $logArgs = @('log', '--format=%s', '-n', '20')
        if (-not $rewritten -and -not $isNew -and -not $returned -and $oldHead) {
            $logArgs = @('log', '--format=%s', ($oldHead + '..' + $head))
        }
        $logOut = Get-Git $dir.FullName $logArgs
        if ($logOut.Code -eq 0) { $subjects = @($logOut.Lines | Where-Object { [string]$_ -ne '' }) }
    }

    if ($changed) {
        $note = Join-Path $VaultPath ('200-projects\' + $name + '.md')
        $noteMissing = -not (Test-Path -LiteralPath $note)
        $nextStep = Get-NextStep $dir.FullName
        if (-not $noteMissing) { $null = Update-Frontmatter $note $today $dirty $unpushed }

        $parts = @()
        if ($isNew) { $parts += 'neu' }
        if ($returned) { $parts += 'wieder da' }
        if ($rewritten) { $parts += 'Historie umgeschrieben' }
        if ($subjects.Count -gt 0) {
            $joined = ($subjects -join '; ')
            if ($joined.Length -gt 300) { $joined = $joined.Substring(0, 300) }
            $parts += ('Commits: ' + $joined)
        }
        if ($dirtyEvent) { $parts += ('nicht committet: ' + $(if ($dirty) { 'ja' } else { 'nein' })) }
        if ($isNew -or $returned -or $unpushedChanged) { $parts += ('nicht gepusht: ' + $unpushed) }
        if ($stashChanged) { $parts += ('Stashes: ' + $stashes) }
        if ($parts.Count -eq 0) { $parts += 'Aenderung' }
        $line = '- ' + $today + ' - ' + $name + ' - ' + ($parts -join ' - ')
        if (-not (Test-Path -LiteralPath $activityFile)) {
            Write-Utf8 $activityFile $activityHeader
        }
        Append-Utf8 $activityFile ($line + "`n")

        $changedProjects += [pscustomobject]@{
            name           = $name
            changed        = $true
            new            = $isNew
            returned       = $returned
            rewritten      = $rewritten
            commits        = @($subjects)
            uncommitted    = $dirty
            dirty_days     = $dirtyDays
            unpushed       = $unpushed
            no_upstream    = $noUpstream
            stashes        = $stashes
            note           = $note
            note_missing   = $noteMissing
            next_step      = $nextStep
        }
    }

    if ($dirty -or $unpushed -gt 0) {
        $attention += [pscustomobject]@{
            name        = $name
            uncommitted = $dirty
            dirty_days  = $dirtyDays
            unpushed    = $unpushed
            no_upstream = $noUpstream
        }
    }

    $newRepos[$name] = [pscustomobject]@{
        head        = $head
        status_hash = $statusHash
        dirty       = $dirty
        dirty_since = $dirtySince
        unpushed    = $unpushed
        stashes     = $stashes
        missing     = $false
    }
}

foreach ($prop in $oldState.repos.PSObject.Properties) {
    $name = $prop.Name
    if ($newRepos.Contains($name)) { continue }
    $old = $prop.Value
    $alreadyMissing = ($old.PSObject.Properties['missing'] -and $old.missing -eq $true)
    if (-not $alreadyMissing) {
        $missingNew += $name
        $stateChanged = $true
        $line = '- ' + $today + ' - ' + $name + ' - verschwunden oder umbenannt'
        if (-not (Test-Path -LiteralPath $activityFile)) { Write-Utf8 $activityFile $activityHeader }
        Append-Utf8 $activityFile ($line + "`n")
    }
    $newRepos[$name] = [pscustomobject]@{
        head        = $(if ($old.PSObject.Properties['head']) { [string]$old.head } else { '' })
        status_hash = $(if ($old.PSObject.Properties['status_hash']) { [string]$old.status_hash } else { '' })
        dirty       = $false
        dirty_since = $null
        unpushed    = 0
        stashes     = 0
        missing     = $true
    }
}

if ($changedProjects.Count -gt 0 -or $missingNew.Count -gt 0) { $stateChanged = $true }
if ($stateChanged -or -not (Test-Path -LiteralPath $StatePath)) {
    $stateObject = [pscustomobject]@{
        version  = 1
        last_run = (Get-Date).ToString('s')
        repos    = $newRepos
        no_git   = @($noGitNow)
    }
    Write-Utf8 $StatePath ($stateObject | ConvertTo-Json -Depth 8)
}

# --- safety net: large files and media/raw --------------------------------------------------
$largeFiles = @()
$mediaRawTotal = 0.0
foreach ($dir in $projectDirs) {
    $raw = Join-Path $dir.FullName 'media\raw'
    if (Test-Path -LiteralPath $raw) {
        $sum = (Get-ChildItem -LiteralPath $raw -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($sum) { $mediaRawTotal += [double]$sum }
    }
}
$allFiles = Get-ChildItem -LiteralPath $DevRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 1GB }
foreach ($file in $allFiles) {
    if ($file.FullName -match '\\media\\raw\\') { continue }
    $rel = $file.FullName.Substring($DevRoot.Length).TrimStart('\')
    $parts = $rel -split '\\'
    $projectName = $parts[0]
    $projectRoot = Join-Path $DevRoot $projectName
    $relToProject = ($parts | Select-Object -Skip 1) -join '\'
    if ($relToProject -and (Test-KopiaIgnored $projectRoot $relToProject)) { continue }
    $largeFiles += [pscustomobject]@{
        path    = $file.FullName
        size_gb = [math]::Round($file.Length / 1GB, 2)
    }
}
$mediaRawTotal = [math]::Round($mediaRawTotal / 1GB, 2)

# --- flag file for the morning agent --------------------------------------------------------
$needsFlag = ($changedProjects.Count -gt 0 -or $attention.Count -gt 0 -or $missingNew.Count -gt 0 -or $noGitNew.Count -gt 0 -or $largeFiles.Count -gt 0)
if ($needsFlag) {
    $flag = [pscustomobject]@{
        generated          = (Get-Date).ToString('s')
        state_file         = $StatePath
        changed            = ($changedProjects.Count -gt 0)
        projects           = @($changedProjects)
        attention          = @($attention)
        missing            = @($missingNew)
        no_git             = @($noGitNew)
        large_files        = @($largeFiles)
        media_raw_total_gb = $mediaRawTotal
    }
    Write-Utf8 $flagFile ($flag | ConvertTo-Json -Depth 8)
} elseif (Test-Path -LiteralPath $flagFile) {
    Remove-Item -LiteralPath $flagFile -Force -ErrorAction SilentlyContinue
}

Write-Host ('projects: changed=' + $changedProjects.Count + ' attention=' + $attention.Count +
            ' no_git_new=' + $noGitNew.Count + ' missing=' + $missingNew.Count +
            ' large_files=' + $largeFiles.Count + ' state=' + $StatePath)
exit 0
