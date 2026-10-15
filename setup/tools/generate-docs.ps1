<#
setup/tools/generate-docs.ps1 - writes docs/components.md from setup/manifest.yaml.

The manifest is the single source (docs/decisions/0002-manifest.md); this generator turns it
into the human-readable component list. The output is deterministic: it prints the SHA256 of
the manifest instead of a timestamp, so -Check can prove the committed file is current.

  pwsh setup/tools/generate-docs.ps1          # write docs/components.md
  pwsh setup/tools/generate-docs.ps1 -Check   # exit 1 when the committed file is outdated

ASCII-only on purpose (same reason as install.ps1).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
. (Join-Path $RepoRoot 'setup\lib\manifest.ps1')

$manifestPath = Join-Path $RepoRoot 'setup\manifest.yaml'
$manifest = Get-Manifest -Path $manifestPath
# Hash over LF-normalized text: a checkout may give CRLF, the blob keeps LF - the check
# must not depend on the machine's line endings.
$manifestText = ([IO.File]::ReadAllText($manifestPath)) -replace "`r`n", "`n"
$sha = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($manifestText))
$manifestHash = (($sha | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Components')
$lines.Add('')
$lines.Add('This file is **generated** - do not edit it by hand. The source is `setup/manifest.yaml`;')
$lines.Add('regenerate with `pwsh setup/tools/generate-docs.ps1`. `setup/tools/check.ps1` fails when this')
$lines.Add('file no longer matches the manifest (`-Check`).')
$lines.Add('')
$lines.Add(('- Manifest checksum: `' + $manifestHash + '` (SHA256, first 16 characters)'))
$lines.Add('- Manifest version: ' + [string](Get-ManifestField $manifest 'version'))

$components = @($manifest.components)
function Get-Row($e) {
    $target = [string](Get-ManifestField $e 'target')
    $detail = ''
    switch ([string](Get-ManifestField $e 'type')) {
        'copy' { $detail = 'file/folder to `' + $target + '`' }
        'template' { $detail = 'template with placeholders to `' + $target + '`' }
        'doc-only' { $detail = 'skeleton to `' + $target + '` (only when nothing is there)' }
        'dir' { $detail = 'create folders' }
        'winget' { $detail = 'programs from `' + [string](Get-ManifestField $e 'file') + '`' }
        'task' { $detail = 'scheduled task "' + [string](Get-ManifestField $e 'name') + '" from `' + [string](Get-ManifestField $e 'file') + '`' }
        'mcp' { $detail = 'MCP server "' + [string](Get-ManifestField $e 'name') + '"' }
        'obsidian-plugin' { $detail = [string](Get-ManifestField $e 'repo') + ' v' + [string](Get-ManifestField $e 'version') }
        'generated' { $detail = [string](Get-ManifestField $e 'note') }
    }
    $core = if ((Get-ManifestField $e 'core') -eq $true) { 'core' } else { 'optional' }
    return '| `' + [string](Get-ManifestField $e 'id') + '` | ' + [string](Get-ManifestField $e 'area') + ' | ' + $core + ' | ' + $detail + ' |'
}

$coreRows = @($components | Where-Object { (Get-ManifestField $_ 'core') -eq $true } | ForEach-Object { Get-Row $_ })
$optRows = @($components | Where-Object { (Get-ManifestField $_ 'core') -ne $true } | ForEach-Object { Get-Row $_ })

$lines.Add('')
$lines.Add('## Core (' + $coreRows.Count + ' of ' + $components.Count + ')')
$lines.Add('')
$lines.Add('| ID | Area | Scope | What happens |')
$lines.Add('|---|---|---|---|')
foreach ($r in $coreRows) { $lines.Add($r) }
$lines.Add('')
$lines.Add('## Optional (' + $optRows.Count + ')')
$lines.Add('')
$lines.Add('| ID | Area | Scope | What happens |')
$lines.Add('|---|---|---|---|')
foreach ($r in $optRows) { $lines.Add($r) }
$lines.Add('')
$lines.Add('## Fixed installer stages (deliberately not in the manifest, see `docs/decisions/0013-install-stages.md`)')
$lines.Add('')
$lines.Add('- git-config: `core.hooksPath`, `init.defaultBranch` (and `core.longpaths` on Windows)')
$lines.Add('- packages: from the platform map - `windows/configuration.winget` (WinGet Configuration), `macos/Brewfile` (brew bundle), `linux/packages.yaml` (apt/dnf + Flatpak)')
$lines.Add('- task, mcp, obsidian-plugins, life-os-venv, own-tools (uv/gh/trufflehog)')
$lines.Add('- sync and backup: SyncTrayzor, `brew services`, `systemctl --user`; KopiaUI / Kopia')
$lines.Add('- os-extras (Windows only): firewall rule for Syncthing, `LongPathsEnabled` (both need administrator rights)')

$content = ($lines -join "`n") + "`n"
$outPath = Join-Path $RepoRoot 'docs/components.md'

# --- docs/platforms.md: the same manifest, seen through setup/platforms.yaml --------------
# Generated for the same reason as components.md: a hand-written matrix drifts away from the
# map it describes, and a matrix that lies is worse than no matrix. Node L of the acceptance
# run compares the two.
. (Join-Path $RepoRoot 'setup\lib\platform.ps1')
$platforms = Get-PlatformData -RepoRoot $RepoRoot
$osList = @('windows', 'macos', 'linux')
$platLines = New-Object System.Collections.Generic.List[string]
$platLines.Add('# Platforms')
$platLines.Add('')
$platLines.Add('This file is **generated** - do not edit it by hand. The source is `setup/platforms.yaml`')
$platLines.Add('(which components exist where) together with `setup/manifest.yaml` (what they contain);')
$platLines.Add('regenerate with `pwsh setup/tools/generate-docs.ps1`. Acceptance check L fails when this')
$platLines.Add('file and the map disagree.')
$platLines.Add('')
$platLines.Add('- Manifest checksum: `' + $manifestHash + '`')
$platLines.Add('')
$platLines.Add('## What each system can do')
$platLines.Add('')
$platLines.Add('| | Windows | macOS | Linux |')
$platLines.Add('|---|---|---|---|')
$rows = [ordered]@{
    'package source'   = 'package_file'
    'package tool'     = 'package_tool'
    'scheduler'        = 'scheduler'
    'state folder'     = 'state_dir'
    'documents folder' = 'documents'
    'suggested vault'  = 'default_vault'
    'suggested dev'    = 'default_dev'
}
foreach ($label in $rows.Keys) {
    $cells = @()
    foreach ($os in $osList) { $cells += ('`' + (Get-PlatformSetting -Platforms $platforms -Os $os -Key $rows[$label]) + '`') }
    $platLines.Add('| ' + $label + ' | ' + ($cells -join ' | ') + ' |')
}
$platLines.Add('')
$platLines.Add('## Every component on every system')
$platLines.Add('')
$platLines.Add('`unsupported` means the component does not exist on that system, and the reason is')
$platLines.Add('written next to it. An agent that meets one of these skips the component and says so')
$platLines.Add('(AGENTS.md, "Platform first", rule 3) - it never invents a replacement.')
$platLines.Add('')
$platLines.Add('| ID | Windows | macOS | Linux |')
$platLines.Add('|---|---|---|---|')
foreach ($e in $components) {
    $id = [string](Get-ManifestField $e 'id')
    $cells = @()
    foreach ($os in $osList) {
        $v = [string](Get-PlatformValue -Platforms $platforms -ComponentId $id -Os $os)
        $cells += ('`' + ($v -replace '\|', '\\|') + '`')
    }
    $platLines.Add('| `' + $id + '` | ' + ($cells -join ' | ') + ' |')
}
$platLines.Add('')
$platLines.Add('## Where the three systems are really checked')
$platLines.Add('')
$platLines.Add('`setup/tools/check.ps1` and `setup/tools/ci-smoke.ps1` run on the system they run on; the CI')
$platLines.Add('matrix covers the others. `windows-latest` and `ubuntu-latest` run on every push, so a')
$platLines.Add('change that only works on one of them is red before it is merged. The macOS job runs on a')
$platLines.Add('release tag, once a week and on request (`gh workflow run ci`) - its minutes cost more,')
$platLines.Add('which is the rule written in the comment at the top of `.github/workflows/ci.yml`. Every')
$platLines.Add('job runs `ci-smoke.ps1` first and prints `IDEMPOTENT-OK`; acceptance check O reads')
$platLines.Add('the conclusion of that step out of the run''s JSON and check N wants the newest run to')
$platLines.Add('carry both matrix jobs and a macOS job that really ran.')
$platLines.Add('')
$platLines.Add('Three of the guard suites are Windows-only (their cases and the guards under test are')
$platLines.Add('Windows text) and the Windows row of the placeholder tests needs a Windows host. On the')
$platLines.Add('other systems `check.ps1` prints a `SKIP` line with the reason instead of leaving them')
$platLines.Add('out silently, and the macOS and Linux rows run everywhere - they are what found the')
$platLines.Add('missing `{{*_BASH}}` tokens on a Windows machine.')
$platLines.Add('')
$platContent = ($platLines -join "`n") + "`n"
$platPath = Join-Path $RepoRoot 'docs/platforms.md'

$targets = @(
    [pscustomobject]@{ Path = $outPath; Content = $content; Name = 'docs/components.md' }
    [pscustomobject]@{ Path = $platPath; Content = $platContent; Name = 'docs/platforms.md' }
)

if ($Check) {
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { $bad.Add($t.Name + ' is missing'); continue }
        $old = [IO.File]::ReadAllText($t.Path)
        if ((($old -replace "`r`n", "`n")) -cne (($t.Content -replace "`r`n", "`n"))) { $bad.Add($t.Name + ' is outdated') }
    }
    if ($bad.Count -eq 0) { Write-Host 'COMPONENTS-OK (current: components.md and platforms.md)'; exit 0 }
    Write-Host ('ERROR: ' + ($bad -join '; ') + ' - run pwsh setup/tools/generate-docs.ps1')
    exit 1
}
foreach ($t in $targets) { [IO.File]::WriteAllText($t.Path, $t.Content, (New-Object Text.UTF8Encoding($false))) }
Write-Host ('written: docs/components.md and docs/platforms.md (' + $components.Count + ' components, checksum ' + $manifestHash + ')')
exit 0
