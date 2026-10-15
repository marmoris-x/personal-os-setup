<#
archive-name-scan.ps1 - does a candidate tree leak the private folder names of the archive?

The folder names under the vault's archive folder and its life-area folder are personal: they
say what the owner keeps and how his life is cut up. They belong to the personal layer and to
the vault, never to a repository. This scan proves that: it reads those names from the vault at
run time, searches a candidate tree - file names, file contents, directory names and, with
-Repo, the commit messages - for every one of them, and prints ONLY how many hits there were
and WHERE they are. A name itself is never printed: it would land in a log, a CI output or a
session transcript, which is exactly what this scan exists to prevent.

A hit is reported as
  HIT  <location>  [name#<i> len <n>]
so a reader learns the place without learning the word.

In a git tree the scan judges exactly what git would hand over - tracked plus
untracked-not-ignored files - so its own ignored scratch (tests/_tmp) cannot report a hit for
every name there is. A plain folder is walked whole. A name matches as a whole word: the rule
comes from setup/lib/personal.ps1, the same builder privacy-scan.ps1 uses.

This is the counterpart of privacy-scan.ps1: that one finds the category names the personal
layer lists (it knows them by name), this one finds every folder name the vault really holds
(including the sub-folders nobody wrote down). Both read the personal layer through
setup/lib/personal.ps1.

Usage:
  pwsh setup/tools/archive-name-scan.ps1                       # the repository of this file
  pwsh setup/tools/archive-name-scan.ps1 -Path <tree> -Repo <git repo>
  pwsh setup/tools/archive-name-scan.ps1 -ConfigPath <personal.yaml>

Exit 0 = clean (hits: 0), 1 = at least one hit, 2 = a needed value or folder is missing.
ASCII-only: Windows PowerShell 5.1 reads BOM-less files in the ANSI code page.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$Repo,
    [string]$ConfigPath,
    [int]$MaxFileMB = 5
)

$ErrorActionPreference = 'Stop'

# A size limit of 0 would skip every file and still print "hits: 0" - a verdict about nothing
# (review 22, F5). Refused instead of obeyed.
if ($MaxFileMB -lt 1) {
    Write-Output ('ARCHIVE-NAME-SCAN: -MaxFileMB must be at least 1, found ' + $MaxFileMB + ' - a scan that skips every file would report a clean tree')
    exit 2
}

function Write-Fail([string]$why) {
    Write-Output ('ARCHIVE-NAME-SCAN: ' + $why)
    exit 2
}

function Get-Mask([int]$index, [int]$len) {
    return ('[name#' + $index + ' len ' + $len + ']')
}

$repoOfThisScript = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Path) { $Path = $repoOfThisScript }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Fail ('the candidate tree does not exist: ' + $Path) }
$root = (Resolve-Path -LiteralPath $Path).Path

# --- the personal layer -----------------------------------------------------
if (-not $ConfigPath) {
    # Same route as privacy-scan.ps1: the home folder is a platform question, answered in one
    # place, and the answer is needed on every system.
    . (Join-Path $repoOfThisScript 'setup/lib/manifest.ps1')
    . (Join-Path $repoOfThisScript 'setup/lib/platform.ps1')
    $ConfigPath = Join-Path (Join-Path (Get-PlatformHome) '.personal-os') 'personal.yaml'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Fail ('the personal values are missing: ' + $ConfigPath) }
. (Join-Path $repoOfThisScript 'setup/lib/personal.ps1')
$vaultPath = Get-ConfigScalar -ConfigPath $ConfigPath -Key 'vault_path'
$archiveDirName = Get-ConfigScalar -ConfigPath $ConfigPath -Key 'archive_dir_name'
if ([string]::IsNullOrWhiteSpace($vaultPath)) { Write-Fail 'the personal values file has no vault_path' }
if ([string]::IsNullOrWhiteSpace($archiveDirName)) { Write-Fail 'the personal values file has no archive_dir_name' }

# --- the names that must not appear -----------------------------------------
# Read from the vault at run time and held in this process only: not written into a file, not
# printed below. The two folders are the archive (one folder per category, sub-folders inside)
# and the life-area folder of the vault; the archive folder's own name comes from the personal
# layer, so this script names no folder of this machine by hand.
$nameIndex = 0
$names = New-Object System.Collections.Generic.List[object]
foreach ($folder in @($archiveDirName, '600-archive', '300-areas')) {
    foreach ($base in @((Join-Path $vaultPath $folder), (Join-Path (Split-Path $vaultPath -Parent) $folder))) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $base -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
            $nameIndex++
            # The rule comes from setup/lib/personal.ps1, the same builder privacy-scan.ps1 uses.
            # Without its word boundaries a three-letter folder name matches the same three
            # letters inside an ordinary word, and the scan reports hits in eighty files that
            # have nothing to do with the personal material (measured 2026-10-15).
            $rx = New-Object System.Text.RegularExpressions.Regex((ConvertTo-TermRule $d.Name), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $names.Add([pscustomobject]@{ Index = $nameIndex; Value = $d.Name; Rule = $rx })
        }
    }
}
if ($names.Count -eq 0) { Write-Fail 'no folder name was found under the archive and the life-area folder of the vault' }

# --- scanning ---------------------------------------------------------------
$binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.bmp', '.webp', '.pdf', '.zip',
    '.gz', '.tgz', '.tar', '.7z', '.rar', '.exe', '.dll', '.so', '.dylib', '.bin', '.pyc',
    '.woff', '.woff2', '.ttf', '.eot', '.mp3', '.mp4', '.wav', '.ogg', '.webm')
$maxBytes = [int64]$MaxFileMB * 1MB
$hits = New-Object System.Collections.Generic.List[string]
$scannedFiles = 0
$scannedCommits = 0
# Files this scan did not look INTO, counted so that "hits: 0" never rests on a silent skip
# (review 22, F5: a name in a file over the size limit or behind a binary extension was
# invisible, and the report still read "hits: 0").
$script:skippedBinary = 0
$script:skippedSize = 0

function Add-Hit([string]$where, [int]$index, [int]$len) {
    $hits.Add(('HIT  ' + $where + '  ' + (Get-Mask $index $len)))
}

$gitDir = Join-Path $root '.git'

# What git would hand over: tracked plus untracked-not-ignored files. Its own scratch folders
# (tests/_tmp, *.log) are ignored on purpose and hold rendered copies of the whole system, so
# they would report a hit for every name there is - and they never reach the repository, which
# is what this scan is about. The same rule privacy-scan.ps1 uses, so the two agree.
#
# An empty answer is not an answer: a folder that lies inside a repository but whose own files
# are all ignored (a test work folder) lists nothing, and then the walk below is the honest
# judge - not a scan that reports zero because it looked at nothing (measured 2026-10-15).
$script:candidateRels = $null
try {
    $rels = @(& git -C $root -c core.quotePath=false ls-files --cached --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -eq 0 -and $rels.Count -gt 0) { $script:candidateRels = $rels }
} catch { $script:candidateRels = $null }

function Get-CandidateFiles {
    if ($null -ne $script:candidateRels) {
        foreach ($rel in $script:candidateRels) {
            if (-not $rel) { continue }
            $full = Join-Path $root $rel
            if (Test-Path -LiteralPath $full -PathType Leaf) { $full }
        }
        return
    }
    Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike ($gitDir + '*') } |
        ForEach-Object { $_.FullName }
}

function Get-CandidateDirs {
    if ($null -eq $script:candidateRels) {
        # A plain folder is walked whole, empty folders included - a folder that holds no file
        # is still part of the tree a reader sees.
        Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike ($gitDir + '*') } |
            ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/') }
        return
    }
    # In a git tree the folders are the ones its files sit in: git stores no folders of its own.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($full in (Get-CandidateFiles)) {
        $rel = $full.Substring($root.Length).TrimStart('\', '/')
        $dir = Split-Path $rel -Parent
        while ($dir) {
            if ($seen.Add($dir)) { $dir }
            $parent = Split-Path $dir -Parent
            if ($parent -eq $dir) { break }
            $dir = $parent
        }
    }
}

$files = @(Get-CandidateFiles)
if ($files.Count -gt 0) {
    Get-Item -LiteralPath $files -ErrorAction SilentlyContinue | ForEach-Object {
        $scannedFiles++
        $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
        foreach ($n in $names) {
            if ($n.Rule.IsMatch($_.Name)) {
                # the leaf itself holds the name: report the folder and the fact, never the leaf
                $dir = Split-Path $rel -Parent
                Add-Hit ($(if ($dir) { $dir + '/ ' } else { '' }) + '(file name matches)') $n.Index $n.Value.Length
            }
        }
        if ($binaryExtensions -contains $_.Extension.ToLowerInvariant()) { $script:skippedBinary++; return }
        if ($_.Length -gt $maxBytes) { $script:skippedSize++; return }
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $_.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $lineNo++
            if ($line.Length -eq 0) { continue }
            foreach ($n in $names) {
                if ($n.Rule.IsMatch($line)) {
                    Add-Hit ($rel + ':' + $lineNo) $n.Index $n.Value.Length
                }
            }
        }
    }
}

# Directory names of the candidate tree as well: a folder named after one is a leak too.
foreach ($dir in (Get-CandidateDirs)) {
    $leaf = Split-Path $dir -Leaf
    foreach ($n in $names) {
        if ($n.Rule.IsMatch($leaf)) {
            $parent = Split-Path $dir -Parent
            Add-Hit ($(if ($parent) { $parent + '/ ' } else { '' }) + '(directory name matches)') $n.Index $n.Value.Length
        }
    }
}

# --- commit messages --------------------------------------------------------
if (-not $Repo) { $Repo = $Path }
if (Test-Path -LiteralPath (Join-Path $Repo '.git')) {
    Push-Location $Repo
    # One entry per commit, not per line: %x1e closes each message, so a multi-line body stays one
    # entry. Counting the log's output lines reported 5 messages for a repository with one commit
    # (measured 2026-10-15), and a body was only ever matched line by line.
    $raw = (& git log --all --format='%h%x09%B%x1e' 2>$null) -join "`n"
    Pop-Location
    foreach ($entry in ($raw -split [char]0x1e)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $scannedCommits++
        $sha = $entry.Split("`t")[0]
        foreach ($n in $names) {
            if ($n.Rule.IsMatch($entry)) {
                Add-Hit ('commit ' + $sha + ': message') $n.Index $n.Value.Length
            }
        }
    }
}

# --- report -----------------------------------------------------------------
# The skips are part of the verdict: "hits: 0" without them would read as "this tree was looked
# at", although a large text file or a file behind a binary extension was passed over.
$skipInfo = ''
if (($script:skippedBinary + $script:skippedSize) -gt 0) {
    $skipInfo = '; NOT looked into: ' + $script:skippedSize + ' file(s) over ' + $MaxFileMB + ' MB, ' + $script:skippedBinary + ' file(s) with a binary extension (their names were judged)'
}
Write-Output ('ARCHIVE-NAME-SCAN: ' + $names.Count + ' folder name(s) from the personal layer; ' +
    $scannedFiles + ' file(s) and ' + $scannedCommits + ' commit message(s) scanned in ' + $root + $skipInfo)
foreach ($h in $hits) { Write-Output ('  ' + $h) }
Write-Output ('hits: ' + $hits.Count)
if ($hits.Count -gt 0) { exit 1 }
exit 0
