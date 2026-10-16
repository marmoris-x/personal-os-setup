<#
export.ps1 - live system -> repo. The only direction this script ever writes.

What it does
  Reads manifest.yaml, copies every copy/template component into the repo mirror folders
  (home/, vault/, dev/ - the mapping is in lib/manifest.ps1), applies the base replacements
  (paths, personal names -> {{PLACEHOLDERS}}), applies the per-entry replace/drop filters,
  removes files it wrote in a previous run that are no longer part of the manifest, and finally
  runs setup/tools/privacy-scan.ps1 over the repo as a gate.
  If the scan finds anything, export ends with exit 1 and you fix the filters - nothing is
  committed automatically, ever.

Base replacements (always applied, values come from local personal.yaml and the environment):
  home/documents/vault/dev roots -> {{HOME}} {{DOCUMENTS}} {{VAULT}} {{DEV}}
  personal name parts            -> {{USER_NAME}} {{USER_GIVEN}} {{USER_FAMILY}} (and UPPER forms)
  github account                 -> {{GITHUB_ACCOUNT}}
  times                          -> {{MORNING_TIME}} {{BACKUP_TIME}}

Parameters
  -WhatIf      show the report without writing anything
  -SkipScan    skip the privacy scan gate (debug only; the default is to always scan)

Exit codes: 0 ok, 1 privacy findings, 2 manifest/config error.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ManifestPath,
    [string]$ConfigPath,
    [string]$StatePath,
    [switch]$WhatIf,
    [switch]$SkipScan
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }   # this script lives in setup/
# the two naming rules and the platform rules come first: everything below asks them
. (Join-Path $PSScriptRoot 'lib\manifest.ps1')       # Get-RepoFileRel: the naming rules
. (Join-Path $PSScriptRoot 'lib\platform.ps1')       # Get-PlatformId and the platform half
$exportOs = Get-PlatformId
$platforms = Get-PlatformData -RepoRoot $RepoRoot

if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot 'manifest.yaml' }
if (-not $ConfigPath) { $ConfigPath = Join-Path (Get-PlatformHome) '.personal-os/personal.yaml' }
# run state is local, not repo content: it names every file the last run wrote.
if (-not $StatePath) { $StatePath = Join-Path (Get-PlatformHome) '.personal-os/state/export-state.json' }

Import-Module powershell-yaml -ErrorAction Stop
$manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $ManifestPath -Raw)
if (-not $manifest -or -not $manifest.components) { throw "manifest.yaml has no components" }

$config = @{}
if (Test-Path -LiteralPath $ConfigPath) {
    $loaded = ConvertFrom-Yaml (Get-Content -LiteralPath $ConfigPath -Raw)
    if ($loaded -is [System.Collections.IDictionary]) {
        foreach ($key in $loaded.Keys) { $config[[string]$key] = $loaded[$key] }
    }
    else {
        foreach ($p in $loaded.PSObject.Properties) { $config[$p.Name] = $p.Value }
    }
}

# --- resolved roots ---------------------------------------------------------
# D4: HOME comes from the platform, DOCUMENTS is the Windows known folder or <home>/Documents,
# VAULT and DEV are the person's own decision and live in personal.yaml on every system.
$roots = Get-PlatformRoots -ConfigValues $config -Os $exportOs
foreach ($k in @('VAULT', 'DEV')) {
    if ([string]::IsNullOrWhiteSpace($roots[$k])) { throw "personal.yaml is missing $($k.ToLower())_path" }
}

# --- sources that never leave the machine, even by manifest typo -------------
# The two pattern lists live in lib/manifest.ps1 now: drift-check.ps1's unmanaged scan needs
# the same source list, and two copies would drift apart.
$forbiddenSourcePatterns = @(Get-ForbiddenSourcePatterns)
$forbiddenTargetPatterns = @(Get-ForbiddenTargetPatterns)
function Assert-SourceAllowed([string]$resolved) {
    foreach ($p in $forbiddenSourcePatterns) {
        if ($resolved -match $p) { throw "refusing to export forbidden source: $resolved (pattern $p)" }
    }
}
function Assert-TargetAllowed([string]$repoRel) {
    $asWin = $repoRel -replace '/', '\'
    foreach ($p in $forbiddenTargetPatterns) {
        if ($asWin -match $p) { throw "refusing to write forbidden target: $repoRel (pattern $p)" }
    }
}

function Resolve-Source([string]$tmpl) {
    $s = $tmpl
    foreach ($k in $roots.Keys) { $s = $s.Replace('{' + $k + '}', $roots[$k]) }
    return $s
}

# --- base replacements ------------------------------------------------------
$baseReplacements = New-Object System.Collections.Generic.List[hashtable]
function Add-Pair([string]$from, [string]$to) {
    if (-not [string]::IsNullOrEmpty($from)) {
        $baseReplacements.Add(@{ from = $from; to = $to })
    }
}
. (Join-Path $PSScriptRoot 'lib\placeholders.ps1')
function Add-StylePair([string]$value, [string]$placeholder, [string]$style) {
    $conv = Convert-PathStyle $value $style
    if (-not $conv) { return }
    if ($style -eq 'back') { Add-Pair $conv $placeholder }
    else { Add-Pair $conv ($placeholder -replace '\}\}$', ('_' + $style.ToUpperInvariant() + '}}')) }
}
# All representation styles a file may use for the same path: JSON files escape backslashes,
# git-bash uses /c/Users/..., Markdown may use forward slashes. Within one style, the longer
# path (archive under documents under home) must be replaced before the shorter one.
# the archive folder sits BESIDE the Documents folder (both inside the same synced parent
# folder); derive it at runtime so no literal path is baked into this script
$archiveDirName = [string]$config['archive_dir_name']
if ([string]::IsNullOrWhiteSpace($archiveDirName)) { throw 'personal.yaml is missing archive_dir_name' }
$archiveRoot = Join-Path (Split-Path $roots.DOCUMENTS -Parent) $archiveDirName
foreach ($style in @('back', 'json', 'fwd', 'bash')) {
    Add-StylePair $archiveRoot       '{{ARCHIVE}}'   $style
    Add-StylePair $roots.DOCUMENTS   '{{DOCUMENTS}}' $style
    Add-StylePair $roots.VAULT       '{{VAULT}}'     $style
    Add-StylePair $roots.DEV         '{{DEV}}'       $style
    Add-StylePair $roots.HOME        '{{HOME}}'      $style
}
$given = [string]$config['user_given']; $family = [string]$config['user_family']; $uname = [string]$config['user_name']
if ($uname)  { Add-Pair $uname '{{USER_NAME}}' }
if ($given)  { Add-Pair $given '{{USER_GIVEN}}' }
if ($family) { Add-Pair $family.ToUpperInvariant() '{{USER_FAMILY_UPPER}}'; Add-Pair $family '{{USER_FAMILY}}' }
if ($config['github_account']) { Add-Pair ([string]$config['github_account']) '{{GITHUB_ACCOUNT}}' }
if ($config['b2_bucket'])      { Add-Pair ([string]$config['b2_bucket']) '{{B2_BUCKET}}' }
if ($config['morning_time'])   { Add-Pair ([string]$config['morning_time']) '{{MORNING_TIME}}' }
if ($config['backup_time'])    { Add-Pair ([string]$config['backup_time']) '{{BACKUP_TIME}}' }

# The platform half of the vocabulary (setup/lib/platform.ps1). It runs in the other
# direction too: the text THIS system uses is paired with the placeholder, and install.ps1
# renders the placeholder back per operating system. On Windows every one of these pairs is
# its own inverse, which is what keeps the mirror byte-identical (check 8 of verify-all).
$platformPairs = Get-PlatformExportPairs -Os $exportOs

# {{INSTALL_DATE}} deliberately has no pair here: a mirrored file that carries a render-time
# value cannot round-trip reliably. A partial install run (install.ps1 -Components) moves the
# journal's date without re-rendering every file, so the export could not reverse the date in
# the live vault/000-meta/backup.md and reported it changed (drift-check.ps1 went red for real
# on 2026-10-13). The placeholder belongs only in the install-once skeletons (type: doc-only),
# which the export never mirrors; tests/Roundtrip.Tests.ps1 enforces that.

function Apply-Replacements([string]$text, $extraPairs) {
    # base first: uppercase forms before their lowercase base (USER_FAMILY_UPPER before USER_FAMILY).
    # The platform pairs come last: their Windows texts never contain a root path, so no base
    # pair can have eaten them, and they must not run before the longer path pair of the same
    # prefix ({{LIFEOS_STATE}} before {{LIFEOS_PYTHON}}).
    $pairs = @()
    foreach ($p in $baseReplacements) { $pairs += $p }
    if ($extraPairs) { foreach ($p in $extraPairs) { $pairs += $p } }
    foreach ($p in $pairs) {
        $text = $text -replace [regex]::Escape($p.from), $p.to
    }
    # The platform pairs are replaced CASE-SENSITIVELY (-creplace). PowerShell's -replace folds
    # case, and a guard that says `%userprofile%` inside a `(?i)` detection regex is not the
    # same text as `%USERPROFILE%`: a folded replacement rewrote it, and the Windows install
    # then handed back a different file than the one the export read (measured 2026-10-14 on
    # onedrive-guard.ps1 line 112 and test-block-dangerous.ps1).
    foreach ($p in $platformPairs) {
        $text = $text -creplace [regex]::Escape($p.from), $p.to
    }
    return $text
}

function Apply-DropLines([string]$text, $patterns) {
    if (-not $patterns) { return $text }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($text -split "`r?`n")) {
        $drop = $false
        foreach ($p in $patterns) { if ($line -match $p) { $drop = $true; break } }
        if (-not $drop) { $out.Add($line) }
    }
    return ($out -join "`r`n")
}

# --- filters from a manifest entry -----------------------------------------
function Get-EntryPairs($entry) {
    $pairs = @()
    if ($entry.replace) {
        foreach ($r in $entry.replace) {
            if ($r.root) {
                $val = $roots[[string]$r.root]
                $from = if ($r.slash -eq 'forward') { $val.Replace('\', '/') } else { $val }
                $pairs += @{ from = $from; to = [string]$r.to }
            }
            elseif ($r.var) {
                $name = [string]$r.var
                $val = ''
                switch ($name) {
                    'USER_NAME'      { $val = $uname }
                    'USER_GIVEN'     { $val = $given }
                    'USER_FAMILY'    { $val = $family }
                    'GITHUB_ACCOUNT' { $val = [string]$config['github_account'] }
                    # Render-time values have no pair on purpose (see the comment above): naming
                    # one here again fails loudly instead of silently pairing nothing.
                    { $name -in @('INSTALL_DATE', 'USER_SID', 'START_BOUNDARY') } {
                        throw ('entry names render-time placeholder ' + $name + ' - mirrored files must not carry render-time values (docs/decisions/0003-placeholders.md)')
                    }
                    default          { $val = [string]$config[$name.ToLowerInvariant()] }
                }
                if ($val) { $pairs += @{ from = $val; to = [string]$r.to } }
            }
        }
    }
    return $pairs
}

# --- exclusion helper -------------------------------------------------------
# Test-Excluded lives in lib/manifest.ps1: tests/Roundtrip.Tests.ps1 needs exactly the same
# matching, and the two copies had drifted apart (see the function's own note).

$binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.bmp', '.webp', '.pdf', '.zip', '.gz',
    '.exe', '.dll', '.so', '.pyc', '.woff', '.woff2', '.ttf', '.eot', '.mp3', '.mp4', '.wav')

function Write-RepoFile([string]$repoRel, [string]$content, [System.Collections.Generic.List[string]]$registry) {
    $repoPath = Join-Path $RepoRoot $repoRel
    $registry.Add($repoRel)
    $exists = Test-Path -LiteralPath $repoPath
    if ($exists) {
        $old = [IO.File]::ReadAllText($repoPath)
        if ($old -ceq $content) { return 'unchanged' }
        if (-not $WhatIf) { [IO.File]::WriteAllText($repoPath, $content, (New-Object Text.UTF8Encoding($false))) }
        return 'changed'
    }
    if (-not $WhatIf) {
        New-Item -ItemType Directory -Force -Path (Split-Path $repoPath -Parent) | Out-Null
        [IO.File]::WriteAllText($repoPath, $content, (New-Object Text.UTF8Encoding($false)))
    }
    return 'new'
}

function Convert-File([string]$src, $entry) {
    $raw = [IO.File]::ReadAllText($src)
    $text = Apply-DropLines $raw $entry.drop_lines
    $text = Apply-Replacements $text (Get-EntryPairs $entry)
    if ($entry.append -and -not $text.Contains($entry.append.Trim())) { $text = $text.TrimEnd() + "`r`n" + $entry.append }
    return $text
}

# --- the run ----------------------------------------------------------------
$registryPath = $StatePath
$null = [IO.Directory]::CreateDirectory((Split-Path $registryPath -Parent))
$oldRegistry = @()
if (Test-Path -LiteralPath $registryPath) {
    $oldRegistry = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json)
}

$newRegistry = New-Object System.Collections.Generic.List[string]
$results = @{ new = 0; changed = 0; unchanged = 0 }
$changedPaths = New-Object System.Collections.Generic.List[string]
$unsupported = New-Object System.Collections.Generic.List[string]

foreach ($entry in $manifest.components) {
    $type = [string]$entry.type
    if ($type -notin @('copy', 'template')) { continue }
    if (-not $entry.source -or -not $entry.target) { throw "entry $($entry.id): copy/template needs source and target" }

    # A component the platform map marks `unsupported` for this system has no live file here,
    # so there is nothing to mirror - and asking for its source would abort the run.
    $platValue = Get-PlatformValue -Platforms $platforms -ComponentId ([string]$entry.id) -Os $exportOs
    if (Test-PlatformUnsupported $platValue) {
        $unsupported.Add([string]$entry.id)
        continue
    }

    $srcRoot = Resolve-Source ([string]$entry.source)
    Assert-SourceAllowed $srcRoot
    if (-not (Test-Path -LiteralPath $srcRoot)) { throw "entry $($entry.id): source not found: $srcRoot" }

    # the stored name (dot rule, store_as) comes from the one place that defines it
    $repoRelBase = Get-RepoFileRel -Target ([string]$entry.target) -StoreAs ([string]$entry.store_as)
    Assert-TargetAllowed $repoRelBase

    if ($entry.recursive) {
        $srcDir = $srcRoot.TrimEnd('\', '/')
        foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($srcDir.Length).TrimStart('\', '/')
            if (Test-Excluded $rel $entry.exclude) { continue }
            $ext = $f.Extension.ToLowerInvariant()
            $content = $null
            if ($binaryExtensions -contains $ext) { continue }   # never text-process binaries; none expected
            $content = Convert-File $f.FullName $entry
            $repoRel = $repoRelBase + '/' + ($rel -replace '\\', '/')
            $state = Write-RepoFile $repoRel $content $newRegistry
            $results[$state]++
            if ($state -ne 'unchanged') { $changedPaths.Add("$state  $repoRel") }
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $srcRoot -PathType Leaf)) { throw "entry $($entry.id): not a file: $srcRoot" }
        $content = Convert-File $srcRoot $entry
        $state = Write-RepoFile $repoRelBase $content $newRegistry
        $results[$state]++
        if ($state -ne 'unchanged') { $changedPaths.Add("$state  $repoRelBase") }
    }
}

# --- removals: files from the previous run that are gone now ----------------
# A doc-only component installs a REPO-AUTHORED file (requirements.txt, the gitleaks config):
# this run never writes one, and it must never remove one either - an entry that used to be a
# copy leaves its old path in the registry, and deleting it would take the installed file's
# source away.
$repoAuthored = New-Object System.Collections.Generic.List[string]
foreach ($entry in $manifest.components) {
    if ([string]$entry.type -ne 'doc-only' -or -not $entry.target) { continue }
    $repoAuthored.Add((Get-RepoFileRel -Target ([string]$entry.target) -StoreAs ([string]$entry.store_as)))
}
$removed = New-Object System.Collections.Generic.List[string]
foreach ($old in $oldRegistry) {
    if ($newRegistry -contains $old) { continue }
    if ($repoAuthored -contains $old) { continue }
    $p = Join-Path $RepoRoot $old
    if (Test-Path -LiteralPath $p) {
        if (-not $WhatIf) { Remove-Item -LiteralPath $p -Force }
        $removed.Add($old)
    }
}

if (-not $WhatIf) {
    [IO.File]::WriteAllText($registryPath, ($newRegistry | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

Write-Output ("EXPORT: " + $results.new + " new, " + $results.changed + " changed, " + $results.unchanged + " unchanged, " + $removed.Count + " removed")
foreach ($c in $changedPaths) { Write-Output ("  " + $c) }
foreach ($r in $removed) { Write-Output ("  removed  " + $r) }
foreach ($u in $unsupported) { Write-Output ("  skipped  " + $u + " (unsupported on " + $exportOs + ")") }

if (-not $SkipScan -and -not $WhatIf) {
    $scan = & pwsh -NoProfile -File (Join-Path $RepoRoot 'setup\tools\privacy-scan.ps1') -Path $RepoRoot
    $scan | ForEach-Object { Write-Output $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'EXPORT: ABORTED by privacy scan findings'
        exit 1
    }
}

Write-Output 'EXPORT-OK'
exit 0
