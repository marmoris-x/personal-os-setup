<#
drift-check.ps1 - Does the live system still match this repo?

Two questions, one verdict:

1. Managed drift: runs setup/export.ps1 in -WhatIf mode (nothing is written) and reads its
   report. 0 new, 0 changed, 0 removed means the mirror holds what the manifest mirrors.

2. Unmanaged files: every live file under the watched roots (~/.claude,
   Documents\PowerShell, Documents\WindowsPowerShell, the vault's .obsidian, .claude and
   000-meta) that no manifest entry covers and no exclusion names - the idea of `chezmoi
   unmanaged`. The first question alone can never notice a file the manifest's list does not
   know: what is not in the list does not exist for export, so a new file in a watched place
   stayed invisible. The second question is the net for exactly that class.

   The exclusions are written down here, ONE LINE PER PATTERN WITH A ONE-WORD REASON - a
   runtime file (cache, session state), the history of the previous repository layout, the
   owner's own notes, plugin code. Nothing is excused silently.

Anything found by either half prints, and the exit code is 1, so the command can gate a
release or a session end. Both halves clean prints DRIFT: none and exits 0.

Usage: pwsh setup/tools/drift-check.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$setupDir = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $setupDir
$export = Join-Path $setupDir 'export.ps1'
if (-not (Test-Path -LiteralPath $export)) {
    Write-Output "DRIFT: export.ps1 missing ($export)"
    exit 2
}

# --- half 1: managed drift --------------------------------------------------
$output = & pwsh -NoProfile -File $export -WhatIf 2>&1 | Out-String
$m = [regex]::Match($output, 'EXPORT:\s*(\d+)\s*new,\s*(\d+)\s*changed,\s*(\d+)\s*unchanged,\s*(\d+)\s*removed')
if (-not $m.Success) {
    Write-Output 'DRIFT: export report not readable:'
    Write-Output $output
    exit 2
}
$new = [int]$m.Groups[1].Value
$changed = [int]$m.Groups[2].Value
$removed = [int]$m.Groups[4].Value

foreach ($line in ($output -split "`n")) {
    if ($line -match '^\s{2}(new|changed|removed)\s') { Write-Output $line.TrimEnd() }
}

# --- half 2: unmanaged files ------------------------------------------------
# Dot-source the two rule modules: manifest.ps1 has the naming rules and the forbidden
# patterns, platform.ps1 knows the roots an operating system has. Forward slashes in the
# child: they are the one separator that resolves on all three systems (a backslash child
# is the Windows spelling and would rely on path translation).
. (Join-Path $setupDir 'lib/manifest.ps1')
. (Join-Path $setupDir 'lib/platform.ps1')
$os = Get-PlatformId
Import-Module powershell-yaml -ErrorAction Stop

$configPath = Join-Path (Get-PlatformHome) '.personal-os/personal.yaml'
$config = @{}
if (Test-Path -LiteralPath $configPath) {
    $loaded = ConvertFrom-Yaml (Get-Content -LiteralPath $configPath -Raw)
    if ($loaded -is [System.Collections.IDictionary]) {
        foreach ($key in $loaded.Keys) { $config[[string]$key] = $loaded[$key] }
    }
    else {
        foreach ($p in $loaded.PSObject.Properties) { $config[$p.Name] = $p.Value }
    }
}
$roots = Get-PlatformRoots -ConfigValues $config -Os $os
if ([string]::IsNullOrWhiteSpace($roots.VAULT)) { throw 'personal.yaml is missing vault_path' }
$platforms = Get-PlatformData -RepoRoot $repoRoot
$manifest = Get-Manifest -Path (Join-Path $setupDir 'manifest.yaml')

# What a manifest entry owns on this machine: a recursive entry owns its whole folder, every
# other entry exactly one file. The platform map decides which entries exist here at all.
$coveredDirs = New-Object System.Collections.Generic.List[string]
$coveredFiles = New-Object System.Collections.Generic.List[string]
$tokenValues = @{ HOME = $roots.HOME; DOCUMENTS = $roots.DOCUMENTS; VAULT = $roots.VAULT; DEV = $roots.DEV }
foreach ($entry in $manifest.components) {
    $type = [string](Get-ManifestField $entry 'type')
    if ($type -notin @('copy', 'template', 'doc-only')) { continue }
    $target = [string](Get-ManifestField $entry 'target')
    if (-not $target) { continue }
    $platValue = Get-PlatformValue -Platforms $platforms -ComponentId ([string](Get-ManifestField $entry 'id')) -Os $os
    if (Test-PlatformUnsupported $platValue) { continue }
    $parts = ($target -replace '\\', '/') -split '/', 2
    $abs = $tokenValues[$parts[0]]
    if (-not $abs) { continue }
    # every comparison in this script runs on forward-slash paths: the file side below is
    # normalized the same way, so the same strings compare on Windows and on macOS/Linux
    $abs = $abs -replace '\\', '/'
    if ($parts.Count -gt 1 -and $parts[1]) { $abs = $abs.TrimEnd('/') + '/' + ($parts[1] -replace '\\', '/') }
    if (Get-ManifestField $entry 'recursive') { $coveredDirs.Add($abs.TrimEnd('/') + '/') }
    else { $coveredFiles.Add($abs) }
}

# The watched roots. Directories are pruned as a whole as soon as their relative path matches
# a forbidden pattern, so runtime folders are neither judged nor walked (the Claude plugin
# cache alone holds thousands of files nobody needs to list).
#
# Claude Code knows more folders than these roots carry today - commands/, output-styles/,
# themes/, workflows/, agent-memory/, keybindings.json. Checked 2026-10-16: none of them
# exists on this machine. They all live under HOME/.claude, so the day one appears it is a
# finding here - exactly like the vault's hotkeys.json and .obsidian/plugins/
# obsidian-tasks-plugin/data.json would be (checked the same day: neither exists yet; the
# obsidian-git data.json beside them is mirrored, which is why the plugins folder of the
# vault is NOT pruned below).
$watchedRoots = @(
    @{ Label = 'HOME/.claude';                Path = (Join-Path $roots.HOME '.claude') },
    @{ Label = 'DOCUMENTS/PowerShell';        Path = (Join-Path $roots.DOCUMENTS 'PowerShell') },
    @{ Label = 'DOCUMENTS/WindowsPowerShell'; Path = (Join-Path $roots.DOCUMENTS 'WindowsPowerShell') },
    @{ Label = 'VAULT/.obsidian';             Path = (Join-Path $roots.VAULT '.obsidian') },
    @{ Label = 'VAULT/.claude';               Path = (Join-Path $roots.VAULT '.claude') },
    @{ Label = 'VAULT/000-meta';              Path = (Join-Path $roots.VAULT '000-meta') }
)

# The files under the watched roots that do NOT belong in the repo, each with its one-word
# reason, each bound to the watched root it was written for: a note pattern for 000-meta must
# not excuse a top-level .md in HOME/.claude (measured 2026-10-16: a planted file there was
# silently excused by the 000-meta note rule while the table was one flat list). Patterns run
# on the forward-slash path relative to the watched root, the same spelling the comparisons use.
$unmanagedExclusions = @(
    # HOME/.claude
    @{ root = 'HOME/.claude';                 pattern = '^README\.md$';                reason = 'history' }        # the previous repository layout
    @{ root = 'HOME/.claude';                 pattern = '^statusline-usage-cache';     reason = 'runtime' }
    @{ root = 'HOME/.claude';                 pattern = '^mcp-needs-auth-cache\.json$'; reason = 'runtime' }
    @{ root = 'HOME/.claude';                 pattern = '^\.last-cleanup$';            reason = 'runtime' }
    @{ root = 'HOME/.claude';                 pattern = '^\.last-update-result\.json$'; reason = 'runtime' }
    @{ root = 'HOME/.claude';                 pattern = '^\.superpowers/';            reason = 'runtime' }        # the Superpowers framework's session state
    @{ root = 'HOME/.claude';                 pattern = '^docs/README\.md$';          reason = 'history' }
    @{ root = 'HOME/.claude';                 pattern = '^docs/(HANDOFF-|blueprint-sync-|report-|_removed/)'; reason = 'history' }
    @{ root = 'HOME/.claude';                 pattern = '^setup/(_removed|blueprint-checks|repo-template|vault)/'; reason = 'history' }  # the superseded old kit
    @{ root = 'HOME/.claude';                 pattern = '^setup/(SETUP-GUIDE\.md|installed-tools\.md|restore-tools\.ps1)$'; reason = 'history' }
    # DOCUMENTS/PowerShell
    @{ root = 'DOCUMENTS/PowerShell';         pattern = '^Modules/';                   reason = 'runtime' }        # reinstalled programs, not the person's profile
    # VAULT/.obsidian
    @{ root = 'VAULT/.obsidian';              pattern = '^workspace.*\.json$';         reason = 'runtime' }        # Obsidian window state
    @{ root = 'VAULT/.obsidian';              pattern = '^plugins/[^/]+/(main\.js|styles\.css|manifest\.json|[^/]+\.sh)$'; reason = 'plugin-code' }
    # VAULT/000-meta
    @{ root = 'VAULT/000-meta';               pattern = '^[^/]+\.md$';                 reason = 'note' }           # the owner's own notes (todo.md, log.md, index.md, ...)
    @{ root = 'VAULT/000-meta';               pattern = '^auftraege/';                 reason = 'personal' }
    @{ root = 'VAULT/000-meta';               pattern = '^todo-archive/';              reason = 'archive' }
    @{ root = 'VAULT/000-meta';               pattern = '^life-os-(state|inbox|conflicts)\.json$'; reason = 'runtime' }
    @{ root = 'VAULT/000-meta';               pattern = '^life-os-runs\.log$';         reason = 'runtime' }
    @{ root = 'VAULT/000-meta';               pattern = '^scripts/build-sidecars\.py$'; reason = 'personal' }
)

# Windows and macOS fold case in a file name, Linux does not.
$cmp = if ($os -eq 'linux') { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
$unmanaged = New-Object System.Collections.Generic.List[string]
$absentRoots = New-Object System.Collections.Generic.List[string]

foreach ($spec in $watchedRoots) {
    if (-not (Test-Path -LiteralPath $spec.Path -PathType Container)) {
        $absentRoots.Add($spec.Label)
        continue
    }
    $rootFull = (Resolve-Path -LiteralPath $spec.Path).Path.TrimEnd('\', '/')
    $patterns = @(Get-ForbiddenSourcePatterns)
    if ($spec.Label -eq 'VAULT/.obsidian') {
        # The plugins pattern protects the Claude plugin CACHE. The vault's Obsidian plugin
        # folder is a different thing: one mirrored settings file (obsidian-git/data.json) and
        # any settings a plugin writes later - noticing those is what this check is for.
        $patterns = @($patterns | Where-Object { $_ -ne '\\plugins\\' })
    }
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            $drel = '\' + (($d.FullName.Substring($rootFull.Length).TrimStart('\', '/')) -replace '/', '\') + '\'
            $skip = $false
            foreach ($p in $patterns) { if ($drel -match $p) { $skip = $true; break } }
            if (-not $skip) { $stack.Push($d.FullName) }
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) {
            $fFull = $f.FullName -replace '\\', '/'
            $isCovered = $false
            foreach ($cf in $coveredFiles) { if ($fFull.Equals($cf, $cmp)) { $isCovered = $true; break } }
            if (-not $isCovered) {
                foreach ($cd in $coveredDirs) { if ($fFull.StartsWith($cd, $cmp)) { $isCovered = $true; break } }
            }
            if ($isCovered) { continue }
            $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\', '/')
            # two spellings, one per matcher: the shared forbidden patterns are backslash-
            # spelled (Get-ForbiddenSourcePatterns), the exclusion table and the report are
            # forward-slash; both are derived from the same relative path
            $relFwd = $rel -replace '\\', '/'
            $abs = '\' + ($relFwd -replace '/', '\')
            $excluded = $false
            foreach ($p in $patterns) { if (($abs -match $p) -or (($abs + '\') -match $p)) { $excluded = $true; break } }
            if (-not $excluded) {
                foreach ($e in $unmanagedExclusions) {
                    if ($e.root -ne $spec.Label) { continue }
                    if ($relFwd -match $e.pattern) { $excluded = $true; break }
                }
            }
            if (-not $excluded) { $unmanaged.Add($spec.Label + '/' + $relFwd) }
        }
    }
}

foreach ($label in $absentRoots) { Write-Output ('  note  ' + $label + ' does not exist on this system - nothing to check there') }
if ($unmanaged.Count -gt 0) {
    Write-Output ('UNMANAGED: ' + $unmanaged.Count + ' file(s) no manifest entry covers and no exclusion names:')
    foreach ($u in ($unmanaged | Sort-Object)) { Write-Output ('  ' + $u) }
}

if ($new + $changed + $removed -eq 0 -and $unmanaged.Count -eq 0) {
    Write-Output 'DRIFT: none - live system and repo match (no managed drift, no unmanaged files).'
    exit 0
}
if ($new + $changed + $removed -gt 0) {
    Write-Output ("DRIFT: {0} new, {1} changed, {2} removed - run export.ps1 first." -f $new, $changed, $removed)
}
if ($unmanaged.Count -gt 0) {
    Write-Output ('DRIFT: ' + $unmanaged.Count + ' unmanaged file(s) - add a manifest entry, or an exclusion with a reason in this script.')
}
exit 1
