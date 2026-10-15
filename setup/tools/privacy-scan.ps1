<#
privacy-scan.ps1 - privacy scanner for personal-os-setup.

What it does
  Finds personal data and secret-shaped strings in a folder, in staged changes or in the
  full git history. Two sources of patterns:
    1. general patterns (emails, IBAN, German social-insurance numbers, phone numbers,
       API-key shapes, private keys, JWTs, Syncthing device IDs) - defined below, generic;
    2. a local denylist file with the owner's personal terms. That file lives OUTSIDE the
       repo, in the home folder of the signed-in user under .personal-os/ - its full path is
       never written into this repository.
    3. the archive category list of the personal layer (the key `archive_categories` of
       personal.yaml in the same folder). Those folder names say what the owner keeps, so
       they get the same treatment as a denylist term. Read with setup/lib/personal.ps1 -
       the one reader the repository tools share, so the scan and the live archive script
       cannot disagree about the list. Absent on CI, like the denylist, and reported as such.

Denylist format
  One term per line. '#' starts a comment line. A '*' inside a term matches any run of
  letters/digits/_/- (e.g. 'examp*' matches 'example' and 'examples'). Matching is
  case-insensitive and uses word boundaries, so a term does not match inside a longer word.

Output and exit codes
  Prints one line per finding with file, line number, rule NAME and a MASKED snippet
  (never the raw value). Ends with a summary line. Exit 0 = clean, 1 = findings, 2 = usage.
  The scanner never prints matched values in full, for secrets and personal terms alike.

Modes
  -Path <dir>   scan a folder tree (default: current directory)
  -Staged       scan the currently staged changes (used by the pre-commit hook)
  -History      scan every commit (git log -p --all) - content and commit messages

Examples
  pwsh setup/tools/privacy-scan.ps1                    # scan the worktree
  pwsh setup/tools/privacy-scan.ps1 -History           # scan the whole history
  pwsh setup/tools/privacy-scan.ps1 -Staged            # what the pre-commit hook runs

This file is written in plain PowerShell, no external modules.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$History,
    [switch]$Staged,
    [string]$DenylistPath,
    # the personal values file whose archive_categories join the denylist; default: next to it
    [string]$PersonalPath,
    [switch]$NoDenylist,
    [int]$MaxFileMB = 5
)

$ErrorActionPreference = 'Stop'

# A size limit of 0 would skip every file and still print "clean" - a verdict about nothing
# (review 22, F5). Refused instead of obeyed.
if ($MaxFileMB -lt 1) {
    Write-Output ('PRIVACY-SCAN: -MaxFileMB must be at least 1, found ' + $MaxFileMB + ' - a scan that skips every file would report a clean tree')
    exit 2
}

function Get-Masked([string]$s) {
    if ($null -eq $s -or $s.Length -eq 0) { return '(empty)' }
    $n = $s.Length
    if ($n -le 2) { return ('*' * $n) + ' (len ' + $n + ')' }
    return $s.Substring(0, 1) + ('*' * 3) + ' (len ' + $n + ')'
}

# --- pattern tables ---------------------------------------------------------
# name = what is printed; regex = what is searched. Values here are GENERIC shapes,
# no personal data. Regexes are built to not match their own definition text.
$generalRules = @(
    # email: reserved example domains (RFC 2606) are documentation, not personal data
    @{ Name = 'email'; regex = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'; skipIf = '@(example\.(com|org|net)|test\.com|localhost|invalid)$' },
    @{ Name = 'iban'; regex = '\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,3})?\b' },
    @{ Name = 'svnr-letters'; regex = '\b\d{2}[ ]?\d{6}[ ]?[A-Z][ ]?\d{3}\b' },
    @{ Name = 'svnr-digits'; regex = '\b[1-9]\d{11}\b' },
    @{ Name = 'phone-intl'; regex = '(?<!\d)(?:\+49|0049)[ /-]?\d{2,5}[ /-]?\d{4,}' },
    @{ Name = 'phone-de'; regex = '(?<!\d)0\d{2,5}[ /-]\d{5,}(?!\d)' },
    @{ Name = 'api-key-sk'; regex = 'sk-[A-Za-z0-9_-]{20,}' },
    @{ Name = 'api-key-github'; regex = '(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}' },
    @{ Name = 'api-key-github-pat'; regex = 'github_pat_[A-Za-z0-9_]{30,}' },
    @{ Name = 'api-key-aws'; regex = 'AKIA[0-9A-Z]{16}' },
    @{ Name = 'api-key-slack'; regex = 'xox[baprs]-[A-Za-z0-9-]{10,}' },
    @{ Name = 'api-key-google'; regex = 'AIza[0-9A-Za-z_-]{35}' },
    @{ Name = 'private-key'; regex = '-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----' },
    @{ Name = 'jwt'; regex = 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' },
    @{ Name = 'syncthing-device-id'; regex = '\b[A-Z2-7]{8}(?:-[A-Z2-7]{7,8}){7}\b' }
)

# --- one term -> one rule ----------------------------------------------------
# The rule builder itself stands in setup/lib/personal.ps1: archive-name-scan.ps1 asks the
# same question of a different tree, and "a hit" must mean the same thing in both.

# --- load the local denylist and the archive categories (optional) ----------
$denyRules = @()
$denyInfo = 'denylist: not found (skipped)'
$catInfo = 'categories: not found (skipped)'
if (-not $NoDenylist) {
    # Where the home folder is, is a platform question - and the answer is needed before this
    # scan can do its job, on every system. setup/lib/platform.ps1 is the one place that
    # answers it; loading it pulls in setup/lib/manifest.ps1 (it uses Get-ManifestField) and
    # nothing else - the YAML module is imported only when the platform map is read.
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $repoRoot 'setup/lib/manifest.ps1')
    . (Join-Path $repoRoot 'setup/lib/platform.ps1')
    . (Join-Path $repoRoot 'setup/lib/personal.ps1')
    $personalDir = Join-Path (Get-PlatformHome) '.personal-os'
    if (-not $DenylistPath) { $DenylistPath = Join-Path $personalDir 'privacy-denylist.txt' }
    if (-not $PersonalPath) { $PersonalPath = Join-Path $personalDir 'personal.yaml' }
    if (Test-Path -LiteralPath $DenylistPath) {
        $i = 0
        foreach ($line in (Get-Content -LiteralPath $DenylistPath -Encoding UTF8)) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            $i++
            $denyRules += @{ Name = 'denylist#' + $i; regex = (ConvertTo-TermRule $t) }
        }
        $denyInfo = 'denylist: ' + $i + ' term(s) loaded'
    }
    # The archive category list of the personal layer. It is the same kind of value as a
    # denylist term - a folder name only the owner's machine has - so it becomes the same
    # kind of rule, through the same conversion and the same reader the archive script uses.
    if (Test-Path -LiteralPath $PersonalPath) {
        try {
            $j = 0
            foreach ($c in @(Get-PersonalCategoryList -ConfigPath $PersonalPath)) {
                $j++
                $denyRules += @{ Name = 'category#' + $j; regex = (ConvertTo-TermRule $c) }
            }
            $catInfo = 'categories: ' + $j + ' term(s) loaded'
        }
        catch { $catInfo = 'categories: NOT READABLE (' + $_.Exception.Message + ')' }
    }
}
# Case is not a property of a leak. The header promises case-insensitive matching, and a term
# was caught only in the letter case it happened to be written in until 2026-10-15 (measured:
# [regex]::IsMatch('FOO','foo') is $false, and no call passed RegexOptions). The flag goes on
# here, once, so the worktree, staged and history modes and every site match alike.
$allRules = @($generalRules + $denyRules | ForEach-Object {
    @{ Name = $_.Name; regex = ('(?i)' + $_.regex); skipIf = $_.skipIf }
})

# --- helpers ----------------------------------------------------------------
$binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.bmp', '.webp',
    '.pdf', '.zip', '.gz', '.tgz', '.tar', '.7z', '.rar',
    '.exe', '.dll', '.so', '.dylib', '.bin', '.pyc', '.woff', '.woff2', '.ttf', '.eot',
    '.mp3', '.mp4', '.wav', '.ogg', '.webm')

$findings = New-Object System.Collections.Generic.List[string]
$scannedFiles = 0
# Files this scan did not look INTO, counted so that a clean report never rests on a silent
# skip (review 22, F5: a personal name in a file over the size limit or behind a binary
# extension was invisible, and the report still read "0 findings").
$script:skippedBinary = 0
$script:skippedSize = 0

function Test-Text([string]$file) {
    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
    if ($binaryExtensions -contains $ext) { return $false }
    return $true
}

function Scan-Text([string]$text, [string]$where) {
    foreach ($rule in $script:allRules) {
        foreach ($m in [regex]::Matches($text, $rule.regex)) {
            $script:findings.Add('[' + $rule.Name + '] ' + $where + '  ' + (Get-Masked $m.Value))
        }
    }
}

function Scan-PathString([string]$relPath) {
    foreach ($rule in $script:allRules) {
        $m = [regex]::Match($relPath, $rule.regex)
        if ($m.Success) {
            # The matched text is masked, not printed. A path hit usually IS the personal term -
            # a folder named after an archive category, a file named after a person - so printing
            # the path would print exactly what this scan exists to keep out of a log. The rest of
            # the path stays readable, or nobody could find the file (review 22, F3).
            $shown = $relPath.Substring(0, $m.Index) + (Get-Masked $m.Value) + $relPath.Substring($m.Index + $m.Length)
            $script:findings.Add('[' + $rule.Name + '/path] ' + $shown + '  (path name)')
        }
    }
}

function Scan-FileLines([string]$fullPath, [string]$relPath) {
    $script:scannedFiles++
    Scan-PathString $relPath
    if (-not (Test-Text $fullPath)) { $script:skippedBinary++; return }
    $info = Get-Item -LiteralPath $fullPath -ErrorAction SilentlyContinue
    if ($null -eq $info -or $info.Length -gt ($script:MaxBytes)) { $script:skippedSize++; return }
    $nr = 0
    foreach ($line in (Get-Content -LiteralPath $fullPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $nr++
        foreach ($rule in $script:allRules) {
            foreach ($m in [regex]::Matches($line, $rule.regex)) {
                if ($rule.skipIf -and ($m.Value -match $rule.skipIf)) { continue }
                $script:findings.Add('[' + $rule.Name + '] ' + $relPath + ':' + $nr + '  ' + (Get-Masked $m.Value))
            }
        }
    }
}

function Test-SkipLine([string]$line) {
    # git metadata inside log/diff output - not content
    return [regex]::IsMatch($line, '^(commit [0-9a-f]{40}|Author:|Date:|Merge:|diff --git |index [0-9a-f]|new file mode|deleted file mode|similarity index|rename (from|to)|old mode|new mode|@@|\+\+\+ |--- )')
}

# --- mode: worktree ---------------------------------------------------------
if (-not $History -and -not $Staged) {
    if (-not $Path) { $Path = '.' }
    $root = (Resolve-Path -LiteralPath $Path).Path
    $script:MaxBytes = [int64]$MaxFileMB * 1MB
    # Only what git would hand over: tracked plus untracked-not-ignored files. Ignored
    # scratch (tests/_tmp, *.log) never reaches the repo and may hold real values on
    # purpose (the suites render with the real HOME), so it stays out of the scan.
    $rels = $null
    try { $rels = @(git -C $root -c core.quotePath=false ls-files --cached --others --exclude-standard 2>$null) } catch { $rels = $null }
    if ($null -ne $rels -and $LASTEXITCODE -eq 0) {
        foreach ($rel in $rels) {
            if (-not $rel) { continue }
            $full = Join-Path $root $rel
            if (Test-Path -LiteralPath $full -PathType Leaf) { Scan-FileLines $full $rel }
            else { Scan-PathString $rel }
        }
    }
    else {
        # Not a git checkout (plain folder): fall back to walking every file.
        $gitDir = Join-Path $root '.git'
        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike ($gitDir + '*') } |
            ForEach-Object {
                $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                Scan-FileLines $_.FullName $rel
            }
    }
    $summary = 'worktree: ' + $scannedFiles + ' file(s) scanned'
}

# --- mode: staged -----------------------------------------------------------
elseif ($Staged) {
    $script:MaxBytes = [int64]$MaxFileMB * 1MB
    $repoRoot = (git rev-parse --show-toplevel)
    foreach ($rel in (git diff --cached --name-only --diff-filter=ACM)) {
        if (-not $rel) { continue }
        $full = Join-Path $repoRoot $rel
        if (Test-Path -LiteralPath $full -PathType Leaf) { Scan-FileLines $full $rel }
        else { Scan-PathString $rel }
    }
    $summary = 'staged: ' + $scannedFiles + ' file(s) scanned'
}

# --- mode: history ----------------------------------------------------------
if ($History) {
    $script:MaxBytes = [int64]$MaxFileMB * 1MB
    $repoRoot = (git rev-parse --show-toplevel)
    $raw = git log -p --all --no-color --no-ext-diff 2>$null
    $commit = '(none)'
    $nr = 0
    foreach ($line in $raw) {
        $nr++
        if ($line -match '^commit ([0-9a-f]{40})') { $commit = $Matches[1].Substring(0, 8); continue }
        if (Test-SkipLine $line) { continue }
        $content = $line
        if ($content.Length -gt 0 -and ('+', '-', ' ') -contains $content.Substring(0, 1)) {
            $content = $content.Substring(1)
        }
        foreach ($rule in $allRules) {
            foreach ($m in [regex]::Matches($content, $rule.regex)) {
                if ($rule.skipIf -and ($m.Value -match $rule.skipIf)) { continue }
                $findings.Add('[' + $rule.Name + '] history:' + $commit + '  ' + (Get-Masked $m.Value))
            }
        }
    }
    $summary = 'history: all commits scanned'
}

# --- report -----------------------------------------------------------------
# The skips are part of the verdict: "clean" without them would read as "this tree was looked
# at", although a large text file or a file behind a binary extension was passed over.
$skipInfo = ''
if (($script:skippedBinary + $script:skippedSize) -gt 0) {
    $skipInfo = '; NOT looked into: ' + $script:skippedSize + ' file(s) over ' + $MaxFileMB + ' MB, ' + $script:skippedBinary + ' file(s) with a binary extension (their names were judged)'
}
Write-Output ('PRIVACY-SCAN ' + $denyInfo + '; ' + $catInfo + $skipInfo)
if ($findings.Count -gt 0) {
    foreach ($f in $findings) { Write-Output ('  FINDING ' + $f) }
    Write-Output ('PRIVACY-SCAN: ' + $findings.Count + ' finding(s) - ' + $summary)
    exit 1
}
Write-Output ('PRIVACY-SCAN: clean (0 findings) - ' + $summary)
exit 0
