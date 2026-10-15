<#
install.ps1 - repo -> machine. Renders the mirror folders (home/, vault/, dev/) and runs the
fixed stages (docs/decisions/0013-install-stages.md). This is the only entry point for humans;
everything it needs lives in setup/.

It runs on Windows, macOS and Linux under PowerShell 7 (decision D2). Which system it is on is
asked once, in setup/lib/platform.ps1, and everything that differs per system - the package
source, the scheduler, the per-user state folder - lives in setup/platform/<os>.ps1. This file
itself contains no operating system of its own.

Usage (run on the target machine):
  pwsh -File install.ps1 -NonInteractive
  pwsh -File install.ps1 -TargetRoot <empty dir> -NonInteractive   # test install, no OS changes
  pwsh -File install.ps1 -Resume            # skip stages already done (journal)
  pwsh -File install.ps1 -WhatIf            # show; writes only its own log/previews (-DryRun works the same)
  pwsh -File install.ps1 -Profile minimal   # only the core components (order item 5.4)
  pwsh -File install.ps1 -Components claude-md,vault-dirs   # only these ids
  switches: -SkipWinget (skip the package stage), -WithOptional, -WithWhisperModel,
            -Profile full|minimal, -Components <ids>, -Force (replace an existing differing
            file; without it the difference is shown and the file stays), -DryRun

Rules: idempotent; nothing is ever deleted; every file about to be replaced is backed up
first (restore.ps1 brings it back). An existing file that differs is replaced only with
-Force - otherwise install shows it and keeps it (ADR 0006). A run with -Components or
-Profile minimal records its stages in the journal like any other run; combine such a run
with -Resume only for the same selection. A copy-typed repo file that carries known
{{PLACEHOLDER}} tokens is rendered like a template (detected by content, the export replaces
paths even in copy-classified files); everything else is copied byte-exact.
In -TargetRoot mode the OS stages only render preview files under .install-state/preview.
A -WhatIf/-DryRun run writes nothing outside its own .install-state folder (transcript +
previews) and reports PREVIEW instead of acting.

A component the platform map marks `unsupported` for this system is skipped and listed at the
end - never silently (red line 5 of the cross-platform task).

ASCII-only on purpose: Windows PowerShell 5.1 must be able to PARSE this file (it reads
BOM-less files in the ANSI code page); the bootstrap then relaunches under PowerShell 7.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$RepoRoot,
    [string]$ConfigPath,
    [string]$TargetRoot,
    [switch]$NonInteractive,
    [switch]$Resume,
    [string]$JournalPath,
    [string]$TranscriptPath,
    [switch]$SkipWinget,
    [switch]$WithOptional,
    [switch]$WithWhisperModel,
    [ValidateSet('full', 'minimal')][string]$Profile = 'full',
    [string[]]$Components,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = $PSScriptRoot }
# The version has one source: the newest git tag (that is why there is no VERSION file any more).
# A copy of the repo without git still works - then the newest "## x.y.z" heading of CHANGELOG.md
# answers. A hard-coded string here would be a second source of truth that goes stale silently.
function Get-RepoVersion([string]$root) {
    try {
        $tag = (& git -C $root describe --tags --abbrev=0 2>$null | Out-String).Trim()
        if ($tag) { return $tag.TrimStart('v') }
    }
    catch { }
    $changelog = Join-Path $root 'CHANGELOG.md'
    if (Test-Path -LiteralPath $changelog) {
        $m = [regex]::Match([IO.File]::ReadAllText($changelog), '(?m)^##\s+(\d+\.\d+\.\d+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return 'unknown'
}
$InstallVersion = Get-RepoVersion $RepoRoot
$TestMode = [bool]$TargetRoot
if ($DryRun) { $WhatIfPreference = $true }               # order item 5.4: -WhatIf / -DryRun
if ($Profile -eq 'minimal') { $WithOptional = $false }   # minimal = core only, never optional

# --- bootstrap: PowerShell 7 -------------------------------------------------
# HOW PowerShell 7 gets onto the machine is a platform question, so its answer lives in the
# platform module (setup/platform/<os>.ps1) like every other platform question - this script
# stays free of operating-system literals.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) { $pwshExe = $pwshCmd.Source }
    else {
        . (Join-Path $RepoRoot 'setup/lib/platform.ps1')
        $null = Import-PlatformModule -RepoRoot $RepoRoot
        $host7 = Get-PlatformPwshPath
        if (-not $host7.Path) {
            Write-Host ('ERROR: PowerShell 7 (pwsh) is missing - ' + $host7.Manual)
            exit 1
        }
        $pwshExe = $host7.Path
    }
    Write-Host ('Restarting under PowerShell 7 (' + $pwshExe + ') ...')
    $argList = @()
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += ('-' + $k) } }
        else { $argList += @(('-' + $k), [string]$v) }
    }
    & $pwshExe -NoProfile -File $PSCommandPath @argList
    exit $LASTEXITCODE
}

# --- module for YAML ---------------------------------------------------------
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Write-Host 'Installing module powershell-yaml (CurrentUser) ...'
    Install-Module powershell-yaml -Scope CurrentUser -Force -Repository PSGallery
}
Import-Module powershell-yaml -ErrorAction Stop

. (Join-Path $RepoRoot 'setup/lib/manifest.ps1')
. (Join-Path $RepoRoot 'setup/lib/platform.ps1')
. (Join-Path $RepoRoot 'setup/lib/placeholders.ps1')
# how a GitHub release names its asset and its checksum - the platform modules call this when a
# program has no package at all (setup/lib/releases.ps1, tested in tests/Releases.Tests.ps1)
. (Join-Path $RepoRoot 'setup/lib/releases.ps1')

$platformOs = Get-PlatformId
$platforms = Get-PlatformData -RepoRoot $RepoRoot
$sep = Get-PlatformPathSeparator -Os $platformOs

# --- personal values ---------------------------------------------------------
if (-not $ConfigPath) { $ConfigPath = Join-Path (Get-PlatformHome) '.personal-os/personal.yaml' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    if ($NonInteractive -or -not [Environment]::UserInteractive) {
        throw ('personal.yaml is missing: ' + $ConfigPath + '  (template: setup/config/personal.example.yaml)')
    }
    Write-Host 'No personal values yet - please fill them in once (Enter accepts the default):' -ForegroundColor Yellow
    function Ask-Value([string]$key, [string]$question, [string]$default) {
        while ($true) {
            $q = if ($default) { $question + ' [' + $default + ']: ' } else { $question + ': ' }
            $a = Read-Host $q
            if (-not $a) { $a = $default }
            if ($a) { return $a }
            Write-Host '  (must not be empty)'
        }
    }
    # D4/red line 4: the vault and Dev locations are the person's decision, on every system.
    # The suggestions come from the platform map, never from a literal in this script.
    $suggestVault = Resolve-PlatformToken -Value (Get-PlatformSetting -Platforms $platforms -Os $platformOs -Key 'default_vault') -Roots @{ HOME = (Get-PlatformHome) }
    $suggestDev = Resolve-PlatformToken -Value (Get-PlatformSetting -Platforms $platforms -Os $platformOs -Key 'default_dev') -Roots @{ HOME = (Get-PlatformHome) }
    $newValues = [ordered]@{}
    $newValues['user_name']        = Ask-Value 'user_name' 'Full name (for file names)' ''
    $newValues['user_given']       = Ask-Value 'user_given' 'Given name' ''
    $newValues['user_family']      = Ask-Value 'user_family' 'Family name' ''
    $newValues['github_account']   = Ask-Value 'github_account' 'GitHub account' ''
    $newValues['b2_bucket']        = Ask-Value 'b2_bucket' 'Backup bucket name (the name only, never the key)' ''
    $newValues['vault_path']       = Ask-Value 'vault_path' 'Path of the Obsidian vault' $suggestVault
    $newValues['dev_root']         = Ask-Value 'dev_root' 'Folder for your own projects' $suggestDev
    $newValues['archive_dir_name'] = 'Dokumentenarchiv'
    $newValues['morning_time']     = Ask-Value 'morning_time' 'Time of the morning routine' '07:00'
    $newValues['backup_time']      = Ask-Value 'backup_time' 'Time of the backup' '12:30'
    $yamlLines = foreach ($k in $newValues.Keys) { $k + ": '" + ([string]$newValues[$k]).Replace("'", "''") + "'" }
    # The folder names of the document archive. They belong in the personal layer and nowhere
    # else (ADR 0004), and add-to-archive.ps1 reads them from here - without the block it refuses
    # every call, which is why this question exists (review 22, F6). An empty list is written as
    # an empty block: the refusal then names what is missing instead of hiding it.
    Write-Host 'The folder names of your document archive, one per line (empty ends the list):' -ForegroundColor Yellow
    $categories = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $a = Read-Host ('  folder name ' + ($categories.Count + 1))
        if (-not $a) { break }
        $categories.Add($a.Trim())
    }
    $archiveBlock = 'archive_categories:' + "`r`n"
    foreach ($c in $categories) {
        if ($c.Contains('"') -or $c.Contains(' #')) {
            Write-Host ('  skipped "' + $c + '": a name with a quote or " #" in it cannot be written here - add it to ' + $ConfigPath + ' by hand') -ForegroundColor Yellow
            continue
        }
        $archiveBlock += '  - ' + $c + "`r`n"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $ConfigPath -Parent) | Out-Null
    [IO.File]::WriteAllText($ConfigPath, ((($yamlLines -join "`r`n") + "`r`n") + $archiveBlock), (New-Object Text.UTF8Encoding($false)))
    Write-Host ('written: ' + $ConfigPath + ' (archive categories: ' + $categories.Count + ')') -ForegroundColor Green
}
$cfg = @{}
$loaded = ConvertFrom-Yaml (Get-Content -LiteralPath $ConfigPath -Raw)
if ($loaded -is [System.Collections.IDictionary]) {
    foreach ($key in $loaded.Keys) { $cfg[[string]$key] = $loaded[$key] }
}
else {
    foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
}

# --- manifest ----------------------------------------------------------------
$manifest = Get-Manifest -Path (Join-Path $RepoRoot 'setup/manifest.yaml')
$schemaErrors = @(Test-ManifestSchema -Manifest $manifest -RepoRoot $RepoRoot)
if ($schemaErrors.Count -gt 0) { throw ('manifest.yaml invalid: ' + ($schemaErrors -join '; ')) }

# --- roots -------------------------------------------------------------------
if ($TestMode) {
    $tr = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetRoot)
    if (-not (Test-Path -LiteralPath $tr)) { New-Item -ItemType Directory -Force -Path $tr | Out-Null }
    # first run: the target must be empty (protects against pointing at a real folder).
    # a later run is allowed when the folder carries OUR journal marker from before.
    $journalMarker = Join-Path $tr '.install-state/install-journal.json'
    if (-not (Test-Path -LiteralPath $journalMarker)) {
        $unexpected = @(Get-ChildItem -LiteralPath $tr -Force | Where-Object { $_.Name -ne '.install-state' })
        if ($unexpected.Count -gt 0) { throw ('TargetRoot is not empty: ' + $tr + ' (only empty folders allowed)') }
    }
    $roots = @{
        HOME      = Join-Path $tr 'HOME'
        DOCUMENTS = Join-Path $tr 'DOCUMENTS'
        VAULT     = Join-Path $tr 'VAULT'
        DEV       = Join-Path $tr 'DEV'
    }
    $stateDir = Join-Path $tr '.install-state'
}
else {
    $roots = Get-PlatformRoots -ConfigValues $cfg -Os $platformOs
    if ([string]::IsNullOrWhiteSpace($roots.VAULT)) { throw 'personal.yaml: vault_path is missing' }
    if ([string]::IsNullOrWhiteSpace($roots.DEV)) { throw 'personal.yaml: dev_root is missing' }
    $stateDir = Get-PlatformStateDir -Os $platformOs
    Write-Host ('LIVE install on this ' + $platformOs + ' machine. Dry run: -TargetRoot <empty folder>') -ForegroundColor Yellow
}
# .NET call on purpose: a -WhatIf/-DryRun run must still get its state folder (transcript,
# previews); -WhatIf would gut New-Item here (found by review-2, finding M1).
$null = [IO.Directory]::CreateDirectory($stateDir)

# --- placeholders ------------------------------------------------------------
$placeholders = Get-PlaceholderMap -Roots $roots -ConfigValues $cfg -Os $platformOs
$placeholders['{{INSTALL_DATE}}'] = (Get-Date -Format 'yyyy-MM-dd')
$placeholders['{{USER_SID}}'] = Get-PlatformUserSid -Os $platformOs
$morning = if ($cfg['morning_time']) { [string]$cfg['morning_time'] } else { '07:00' }
$placeholders['{{START_BOUNDARY}}'] = (Get-Date).ToString('yyyy-MM-dd') + 'T' + $morning + ':00' + (Get-Date -Format 'zzz')

# --- journal, transcript, backup ---------------------------------------------
if (-not $JournalPath) { $JournalPath = Join-Path $stateDir 'install-journal.json' }
if (-not $TranscriptPath) { $TranscriptPath = Join-Path $stateDir ('install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
$backupRoot = Join-Path $stateDir ('backup/' + (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
$script:backupEntries = New-Object System.Collections.Generic.List[hashtable]
$script:filesCreated = 0; $script:filesReplaced = 0; $script:filesSame = 0; $script:filesKept = 0
$script:filesForceSkipped = 0
$results = New-Object System.Collections.Generic.List[object]
$manualSteps = New-Object System.Collections.Generic.List[string]
$completedStages = New-Object System.Collections.Generic.List[string]
$script:installDateValue = (Get-Date -Format 'yyyy-MM-dd')
$script:selectedIds = New-Object System.Collections.Generic.List[string]
if ($Resume -and (Test-Path -LiteralPath $JournalPath)) {
    $old = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
    foreach ($c in $old.completed) { $completedStages.Add([string]$c.id) }
    if ($old.installDate) { $script:installDateValue = [string]$old.installDate }
}

function Add-Result([string]$stage, [string]$status, [string]$detail) {
    $results.Add([pscustomobject]@{ Stage = $stage; Status = $status; Detail = $detail })
    $line = '  {0,-18} {1,-6} {2}' -f $stage, $status, $detail
    Write-Host $line
}
# One line in the "Manual steps" list at the end. Missing until the layout task: the summary
# in a LIVE run threw CommandNotFoundException and cut the run short (found by the live dry run).
function Add-Manual([string]$text) { $manualSteps.Add($text) }
function Test-StageDone([string]$stage) { return ($completedStages -contains $stage) }
function Save-Journal([string]$stage) {
    if ($WhatIfPreference) { return }
    if (-not (Test-StageDone $stage)) { $completedStages.Add($stage) }
    $doc = [ordered]@{
        version     = $InstallVersion
        installDate = $script:installDateValue
        updatedAt   = (Get-Date).ToString('s')
        completed   = @($completedStages | ForEach-Object { [ordered]@{ id = $_ } })
    }
    [IO.File]::WriteAllText($JournalPath, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}
function Backup-File([string]$absPath) {
    if ($WhatIfPreference) { return }
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $sha = [Security.Cryptography.SHA1]::Create()
    $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($absPath.ToLowerInvariant())))).Replace('-', '')
    $stored = $id + '_' + (Split-Path $absPath -Leaf)
    Copy-Item -LiteralPath $absPath -Destination (Join-Path $backupRoot $stored) -Force
    $script:backupEntries.Add(@{
        path    = $absPath
        stored  = $stored
        sha256  = (Get-FileHash -LiteralPath $absPath -Algorithm SHA256).Hash
    })
}
function Save-BackupIndex {
    if ($WhatIfPreference -or $script:backupEntries.Count -eq 0) { return }
    $index = @{ created = (Get-Date).ToString('s'); root = $backupRoot; entries = @($script:backupEntries) }
    [IO.File]::WriteAllText((Join-Path $stateDir 'restore-index.json'), ($index | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}
function Save-Preview([string]$name, [string]$content) {
    $dir = Join-Path $stateDir 'preview'
    # .NET call on purpose: preview files are the dry run's output product, so folder
    # creation must survive -WhatIf (review-2 M1: New-Item was gutted, WriteAllText threw).
    $null = [IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir $name), $content, (New-Object Text.UTF8Encoding($false)))
}
function Get-RepoFileFor([string]$targetRel, $entry) {
    # stored name (dot rule, store_as) and repo folder come from setup/lib/manifest.ps1
    $rel = Get-RepoFileRel -Target $targetRel -StoreAs ([string](Get-ManifestField $entry 'store_as'))
    return (Join-Path $RepoRoot $rel)
}
function Get-TargetPathFor([string]$targetRel) {
    $parts = $targetRel -split '/', 2
    # a root token without a path ("DEV") is the root itself - dirs entries may name it
    if ($parts.Count -lt 2 -or -not $parts[1]) { return $roots[$parts[0]] }
    return (Join-Path $roots[$parts[0]] ($parts[1] -replace '/', $sep))
}
function Get-ComponentPlatformValue($e) {
    return (Get-PlatformValue -Platforms $platforms -ComponentId ([string](Get-ManifestField $e 'id')) -Os $platformOs)
}
function Test-EntrySelected($e) {
    # order item 5.4: -Components <ids> and -Profile minimal narrow what gets installed.
    $id = [string](Get-ManifestField $e 'id')
    if ($Components -and ($Components -notcontains $id)) { return $false }
    if ($Profile -eq 'minimal' -and ((Get-ManifestField $e 'core') -ne $true)) { return $false }
    return $true
}
function Test-StageSelected([string]$id) {
    # Fixed stages that carry a manifest id (packages, task, venv, ...); without -Components
    # everything runs, git-config has no id and always runs.
    if ($Components -and ($Components -notcontains $id)) { return $false }
    return $true
}
function Test-HasKnownPlaceholder([string]$text) {
    foreach ($k in $placeholders.Keys) { if ($text.Contains($k)) { return $true } }
    return $false
}
function Confirm-ReplacePath([string]$Abs) {
    # order item 5.4 / ADR 0006: an existing file that differs is replaced only with -Force;
    # without it the difference is shown and the file stays.
    if ($Force) { return $true }
    $script:filesForceSkipped++
    Write-Host ('  different (left in place, replaced only with -Force): ' + $Abs) -ForegroundColor Yellow
    return $false
}
function Write-OneFile([string]$Abs, [string]$RepoFile, [string]$EntryType) {
    $bytesToCopy = $null
    if ($EntryType -eq 'copy') {
        # The content decides, not the type: the export replaces personal paths with known
        # tokens even in copy-classified files, so a copy file carrying known tokens is
        # rendered like a template (ADR 0001/0003). Everything else stays byte-exact.
        $bytes = [IO.File]::ReadAllBytes($RepoFile)
        $asText = [Text.Encoding]::UTF8.GetString($bytes)
        if ($asText.Contains([char]0xFFFD) -or -not (Test-HasKnownPlaceholder $asText)) { $bytesToCopy = $bytes }
    }
    if ($null -ne $bytesToCopy) {
        if (Test-Path -LiteralPath $Abs) {
            if ((Get-FileHash -LiteralPath $Abs -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $RepoFile -Algorithm SHA256).Hash) { $script:filesSame++; return }
            if (-not (Confirm-ReplacePath $Abs)) { return }
            Backup-File $Abs
            if ($PSCmdlet.ShouldProcess($Abs, 'replace')) {
                [IO.File]::WriteAllBytes($Abs, $bytesToCopy)
                $script:filesReplaced++
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($Abs, 'create')) {
                New-Item -ItemType Directory -Force -Path (Split-Path $Abs -Parent) | Out-Null
                [IO.File]::WriteAllBytes($Abs, $bytesToCopy)
                $script:filesCreated++
            }
        }
        return
    }
    $text = Expand-Placeholders ([IO.File]::ReadAllText($RepoFile)) $placeholders
    $createOnly = ($EntryType -eq 'doc-only')
    if (Test-Path -LiteralPath $Abs) {
        if ($createOnly) { $script:filesKept++; return }
        if ([IO.File]::ReadAllText($Abs) -ceq $text) { $script:filesSame++; return }
        if (-not (Confirm-ReplacePath $Abs)) { return }
        Backup-File $Abs
        if ($PSCmdlet.ShouldProcess($Abs, 'replace')) {
            [IO.File]::WriteAllText($Abs, $text, (New-Object Text.UTF8Encoding($false)))
            $script:filesReplaced++
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($Abs, 'create')) {
            New-Item -ItemType Directory -Force -Path (Split-Path $Abs -Parent) | Out-Null
            [IO.File]::WriteAllText($Abs, $text, (New-Object Text.UTF8Encoding($false)))
            $script:filesCreated++
        }
    }
}

# --- the platform stages -----------------------------------------------------
# install.ps1 asks the module of THIS system for each stage; the module knows the commands.
# The contract (setup/platform/<os>.ps1): every verb takes one hashtable and answers with
# { Status; Detail; Manual } - Status is OK, PREVIEW, WARN, SKIP or ERROR.
$taskEntry = $manifest.components | Where-Object { [string](Get-ManifestField $_ 'type') -eq 'task' } | Select-Object -First 1
$taskName = if ($taskEntry) { [string](Get-ManifestField $taskEntry 'name') } else { '' }
$script:platformCtx = @{
    RepoRoot      = $RepoRoot
    Platforms     = $platforms
    Manifest      = $manifest
    Os            = $platformOs
    TestMode      = $TestMode
    DryRun        = [bool]$WhatIfPreference
    WithOptional  = [bool]$WithOptional
    SkipPackages  = [bool]$SkipWinget
    StateDir      = $stateDir
    Placeholders  = $placeholders
    TaskEntry     = $taskEntry
    TaskName      = $taskName
    SavePreview   = { param($n, $c) Save-Preview $n $c }
    ShouldProcess = { param($t, $a) $PSCmdlet.ShouldProcess($t, $a) }
    BackupFile    = { param($p) Backup-File $p }
}
. (Join-Path $RepoRoot ('setup/platform/' + $platformOs + '.ps1'))

function Invoke-PlatformStage([string]$stage, [string]$verb, [string]$label, [string]$id) {
    if ($id -and (-not (Test-StageSelected $id))) { Add-Result $label 'SKIP' 'not selected (-Components)'; return }
    if (Test-StageDone $stage) { Add-Result $label 'SKIP' 'from journal'; return }
    # Measured on ubuntu-latest (2026-10-14): a stage that THREW - a parameter binding error in
    # the release install - ended the whole install. The stages after it never ran, and the live
    # verify then reported only the consequences ("not in PATH: uv, trufflehog") instead of the
    # one real reason. One stage failing is one ERROR line; the rest of the run still happens.
    # The stage is NOT journaled as done in that case, so -Resume tries it again.
    try {
        $r = & $verb -Context $script:platformCtx
        Add-Result $label $r.Status $r.Detail
        foreach ($m in @($r.Manual)) { if ($m) { Add-Manual $m } }
        Save-Journal $stage
    }
    catch {
        Add-Result $label 'ERROR' ('the stage threw: ' + $_.Exception.Message)
    }
}

# -WhatIf:$false on purpose: the transcript lives inside our own .install-state folder,
# so a dry run may (and should) record itself; otherwise -WhatIf would gut it (review-2 M1).
Start-Transcript -Path $TranscriptPath -WhatIf:$false | Out-Null
try {
    Write-Host ''
    Write-Host ('== personal-os-setup install ' + $InstallVersion + ' ==') -ForegroundColor Cyan
    Write-Host ('   Mode:    ' + $(if ($TestMode) { 'TEST (files in the target only, OS stages as preview)' } else { 'LIVE' }))
    Write-Host ('   System:  ' + $platformOs)
    Write-Host ('   Target:  ' + $roots.HOME)
    Write-Host ('   Journal:' + $JournalPath)
    if ($Components -or $Profile -ne 'full') { Write-Host ('   Selection: profile ' + $Profile + $(if ($Components) { '; components: ' + ($Components -join ', ') })) }
    Write-Host ''

    # ---------------------------------------------------------------- files --
    if (Test-StageDone 'files') { Add-Result 'files' 'SKIP' 'from journal (completed)' }
    else {
        $stageErrors = 0
        foreach ($e in @($manifest.components)) {
            $type = [string](Get-ManifestField $e 'type')
            if ($type -notin @('copy', 'template', 'doc-only')) { continue }
            if (-not (Test-EntrySelected $e)) { continue }
            $id = [string](Get-ManifestField $e 'id')
            # a component this system cannot use is reported, never copied half-way
            $platValue = Get-ComponentPlatformValue $e
            if (Test-PlatformUnsupported $platValue) {
                $script:selectedIds.Add($id)
                Add-Result $id 'SKIP' ('unsupported on ' + $platformOs + ': ' + (Get-UnsupportedReason $platValue))
                continue
            }
            $targetRel = [string](Get-ManifestField $e 'target')
            $repoFile = Get-RepoFileFor $targetRel $e
            $abs = Get-TargetPathFor $targetRel
            try {
                if (($type -in @('copy', 'template')) -and (Get-ManifestField $e 'recursive')) {
                    if (-not (Test-Path -LiteralPath $repoFile -PathType Container)) { throw ('repo folder missing: ' + $repoFile) }
                    foreach ($rf in (Get-ChildItem -LiteralPath $repoFile -Recurse -File -Force)) {
                        $childRel = $rf.FullName.Substring($repoFile.Length).TrimStart('\', '/')
                        Write-OneFile -Abs (Join-Path $abs $childRel) -RepoFile $rf.FullName -EntryType $type
                    }
                }
                else {
                    if (-not (Test-Path -LiteralPath $repoFile -PathType Leaf)) { throw ('repo file missing: ' + $repoFile) }
                    Write-OneFile -Abs $abs -RepoFile $repoFile -EntryType $type
                }
            }
            catch {
                $stageErrors++
                Add-Result $id 'ERROR' $_.Exception.Message
            }
        }
        if ($script:filesForceSkipped -gt 0) { $manualSteps.Add($script:filesForceSkipped.ToString() + ' different file(s) were left in place - rerun with -Force to replace them (ADR 0006).') }
        $forceText = if ($script:filesForceSkipped -gt 0) { ', different-without-Force ' + $script:filesForceSkipped } else { '' }
        $detail = 'new ' + $script:filesCreated + ', replaced ' + $script:filesReplaced + ', same ' + $script:filesSame + ', kept ' + $script:filesKept + $forceText
        if ($stageErrors -gt 0) { Add-Result 'files' 'ERROR' $detail } else { Add-Result 'files' 'OK' $detail; Save-Journal 'files' }
    }

    # ----------------------------------------------------------------- dirs --
    if (Test-StageDone 'dirs') { Add-Result 'dirs' 'SKIP' 'from journal' }
    else {
        $made = 0
        foreach ($e in @($manifest.components)) {
            if ([string](Get-ManifestField $e 'type') -ne 'dir') { continue }
            if (-not (Test-EntrySelected $e)) { continue }
            if (Test-PlatformUnsupported (Get-ComponentPlatformValue $e)) { continue }
            foreach ($d in @(Get-ManifestField $e 'dirs')) {
                $abs = Get-TargetPathFor ([string]$d)
                if (-not (Test-Path -LiteralPath $abs)) {
                    if ($PSCmdlet.ShouldProcess($abs, 'create folder')) {
                        New-Item -ItemType Directory -Force -Path $abs | Out-Null
                        $made++
                    }
                }
            }
        }
        Add-Result 'dirs' 'OK' ($made.ToString() + ' folders created')
        Save-Journal 'dirs'
    }

    # ----------------------------------------------------------- git-config --
    if (Test-StageDone 'git-config') { Add-Result 'git-config' 'SKIP' 'from journal' }
    elseif ($TestMode) {
        Save-Preview 'git-config.txt' ("git config --global core.hooksPath <HOME_FWD>/.githooks`r`ngit config --global init.defaultBranch main`r`n")
        Add-Result 'git-config' 'PREVIEW' 'preview/git-config.txt'
        Save-Journal 'git-config'
    }
    else {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) { Add-Result 'git-config' 'WARN' 'git not found - wait for the package stage, then retry'; Add-Manual 'install git (package stage), then run install.ps1 -Resume' }
        else {
            $wanted = [ordered]@{
                'core.hooksPath'     = ((Convert-PathStyle $roots.HOME 'fwd') + '/.githooks')
                'init.defaultBranch' = 'main'
            }
            # core.longpaths is a Windows-only setting (the 260-character limit)
            if ($platformOs -eq 'windows') { $wanted['core.longpaths'] = 'true' }
            $changes = New-Object System.Collections.Generic.List[string]
            $wouldChange = New-Object System.Collections.Generic.List[string]
            foreach ($key in $wanted.Keys) {
                $cur = (& git config --global --get $key 2>$null)
                if ($cur -ne $wanted[$key]) {
                    if ($WhatIfPreference) {
                        $wouldChange.Add($key)
                    }
                    elseif ($PSCmdlet.ShouldProcess(('git config --global ' + $key), 'set')) {
                        & git config --global $key $wanted[$key]
                        $changes.Add($key)
                    }
                }
            }
            if ($WhatIfPreference) {
                Add-Result 'git-config' 'PREVIEW' ('DryRun: ' + $(if ($wouldChange.Count -gt 0) { 'set: ' + ($wouldChange -join ', ') } else { 'nothing to set' }))
            }
            elseif ($changes.Count -gt 0) {
                $gitconfig = Join-Path (Get-PlatformHome) '.gitconfig'
                if (Test-Path -LiteralPath $gitconfig) { Backup-File $gitconfig }
                Save-BackupIndex
                Add-Result 'git-config' 'OK' ('set: ' + ($changes -join ', '))
            }
            else { Add-Result 'git-config' 'OK' 'already set' }
            Add-Manual 'Set the Git identity yourself: git config --global user.name / user.email'
            Save-Journal 'git-config'
        }
    }

    # ------------------------------------------------------------- packages --
    Invoke-PlatformStage 'packages' 'Invoke-PackageStage' 'packages' 'winget-core'

    # ----------------------------------------------------------------- task --
    if ($taskEntry) { Invoke-PlatformStage 'task' 'Invoke-SchedulerStage' 'task' 'task-life-os-morning' }

    # ----------------------------------------------------------- sync / backup --
    Invoke-PlatformStage 'sync' 'Invoke-SyncStage' 'sync' ''
    Invoke-PlatformStage 'backup' 'Get-BackupStage' 'backup' ''

    # ------------------------------------------------------------------ mcp --
    if (-not (Test-StageSelected 'mcp-exa') -and -not (Test-StageSelected 'mcp-parallel')) { Add-Result 'mcp' 'SKIP' 'not selected (-Components)' }
    elseif (Test-StageDone 'mcp') { Add-Result 'mcp' 'SKIP' 'from journal' }
    else {
        $mcpEntries = @($manifest.components | Where-Object { [string](Get-ManifestField $_ 'type') -eq 'mcp' -and (Test-EntrySelected $_) })
        if ($TestMode) {
            $lines = @()
            foreach ($e in $mcpEntries) { $lines += ('claude mcp add-json --scope user ' + [string](Get-ManifestField $e 'name') + ' ''' + [string](Get-ManifestField $e 'json') + '''') }
            Save-Preview 'mcp-add.txt' (($lines -join "`r`n") + "`r`n")
            Add-Result 'mcp' 'PREVIEW' 'preview/mcp-add.txt'
            Save-Journal 'mcp'
        }
        else {
            $claude = Get-Command claude -ErrorAction SilentlyContinue
            if (-not $claude) { Add-Result 'mcp' 'WARN' 'claude not found'; Add-Manual 'install Claude Code (see docs/platforms.md), then -Resume' }
            else {
                $registered = ''
                try { $registered = (& claude mcp list 2>$null | Out-String) } catch { }
                $added = New-Object System.Collections.Generic.List[string]
                $wouldAdd = New-Object System.Collections.Generic.List[string]
                foreach ($e in $mcpEntries) {
                    $name = [string](Get-ManifestField $e 'name')
                    $json = [string](Get-ManifestField $e 'json')
                    if ($registered -match [regex]::Escape($name)) { continue }
                    if ($WhatIfPreference) { $wouldAdd.Add($name); continue }
                    if ($PSCmdlet.ShouldProcess(('mcp ' + $name), 'register')) {
                        & claude mcp add-json --scope user $name $json | Out-Null
                        $added.Add($name)
                    }
                }
                if ($WhatIfPreference) {
                    Add-Result 'mcp' 'PREVIEW' ('DryRun: ' + $(if ($wouldAdd.Count -gt 0) { 'register: ' + ($wouldAdd -join ', ') } else { 'nothing to register' }))
                }
                elseif ($added.Count -gt 0) { Add-Result 'mcp' 'OK' ('registered: ' + ($added -join ', ')) } else { Add-Result 'mcp' 'OK' 'already registered' }
                Save-Journal 'mcp'
            }
        }
    }

    # ------------------------------------------------------ obsidian plugins --
    if (-not (Test-StageSelected 'obsidian-plugin-obsidian-git') -and -not (Test-StageSelected 'obsidian-plugin-tasks')) { Add-Result 'obsidian-plugins' 'SKIP' 'not selected (-Components)' }
    elseif (Test-StageDone 'obsidian-plugins') { Add-Result 'obsidian-plugins' 'SKIP' 'from journal' }
    else {
        $entries = @($manifest.components | Where-Object { [string](Get-ManifestField $_ 'type') -eq 'obsidian-plugin' -and (Test-EntrySelected $_) })
        $downloaded = New-Object System.Collections.Generic.List[string]
        $skipped = New-Object System.Collections.Generic.List[string]
        foreach ($e in $entries) {
            $name = [string](Get-ManifestField $e 'name')
            $repo = [string](Get-ManifestField $e 'repo')
            $version = [string](Get-ManifestField $e 'version')
            $dir = Join-Path $roots.VAULT ('.obsidian' + $sep + 'plugins' + $sep + $name)
            $mf = Join-Path $dir 'manifest.json'
            if ((Test-Path -LiteralPath $mf)) {
                $have = (Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).version
                if ($have -eq $version) { $skipped.Add($name); continue }
            }
            if ($TestMode) { $downloaded.Add($name + '@' + $version + ' (preview)'); continue }
            if ($WhatIfPreference) { $downloaded.Add($name + '@' + $version + ' (DryRun)'); continue }
            if ($PSCmdlet.ShouldProcess($name, ('download plugin ' + $version))) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $base = 'https://github.com/' + $repo + '/releases/download/' + $version + '/'
                foreach ($asset in @('main.js', 'manifest.json', 'styles.css')) {
                    $tmp = Join-Path $stateDir ($name + '-' + $asset + '.tmp')
                    try {
                        Invoke-WebRequest -Uri ($base + $asset) -OutFile $tmp -UseBasicParsing
                        Move-Item -LiteralPath $tmp -Destination (Join-Path $dir $asset) -Force
                    }
                    catch { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
                }
                $downloaded.Add($name + '@' + $version)
            }
        }
        Add-Result 'obsidian-plugins' $(if ($WhatIfPreference -and -not $TestMode) { 'PREVIEW' } else { 'OK' }) (($downloaded + $skipped) -join ', ')
        Save-Journal 'obsidian-plugins'
    }

    # ------------------------------------------------------------ life-os venv --
    if (-not (Test-StageSelected 'life-os-venv')) { Add-Result 'life-os-venv' 'SKIP' 'not selected (-Components)' }
    elseif (Test-StageDone 'life-os-venv') { Add-Result 'life-os-venv' 'SKIP' 'from journal' }
    else {
        $req = Join-Path $RepoRoot 'home/.claude/life-os/requirements.txt'
        $venv = Get-PlatformVenvDir -Os $platformOs
        $venvPy = Get-PlatformVenvPython -Os $platformOs
        if ($TestMode) {
            Save-Preview 'life-os-venv.txt' ('python3 -m venv ' + $venv + "`n" + $venvPy + ' -m pip install -r ' + $req + "`n")
            Add-Result 'life-os-venv' 'PREVIEW' 'preview/life-os-venv.txt'
            Save-Journal 'life-os-venv'
        }
        else {
            $python = Get-PlatformPythonCommand
            if (-not $python) { Add-Result 'life-os-venv' 'WARN' 'python3 not found'; Add-Manual 'install Python (package stage), then -Resume' }
            elseif ($WhatIfPreference) {
                Add-Result 'life-os-venv' 'PREVIEW' ('DryRun: venv ' + $venv)
            }
            else {
                if ($PSCmdlet.ShouldProcess($venv, 'create/update venv')) {
                    # Review 18 (2026-10-14) measured three things about this block, all fixed
                    # here: a throw ended the whole run (the venv stage is inline, so no
                    # Invoke-PlatformStage catch reaches it); a failed pip was journalled as done,
                    # so the "-Resume" in its own manual step printed "SKIP from journal" and
                    # never retried; and the model download was reported as OK when it failed.
                    try {
                        if (-not (Test-Path -LiteralPath $venvPy)) {
                            & $python -m venv $venv
                        }
                        # Measured in the first full-setup CI run (2026-10-14): on macos-latest the
                        # pip install failed ("No matching distribution found for nvidia-cublas-cu12")
                        # and this stage still reported OK - nobody asked pip how it ended. Two things
                        # came out of that: the CUDA-only pins carry a marker now, and pip's exit code
                        # is read here like any other program's.
                        $pipOut = (& $venvPy -m pip install --quiet --disable-pip-version-check -r $req 2>&1 | Out-String)
                        if ($LASTEXITCODE -ne 0) {
                            $tail = (@($pipOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
                            if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
                            Write-Host ('  pip install failed (exit ' + $LASTEXITCODE + '): ' + $tail)
                            Add-Result 'life-os-venv' 'WARN' ('pip install failed: ' + $tail)
                            Add-Manual 'check home/.claude/life-os/requirements.txt for this system, then run install.ps1 -Resume (the venv is incomplete)'
                        }
                        else {
                            $modelOk = $true
                            if ($WithWhisperModel) {
                                Write-Host '  downloading the faster-whisper model large-v3-turbo (one-time, large) ...'
                                $modelOut = (& $venvPy -c "from faster_whisper import WhisperModel; WhisperModel('large-v3-turbo', device='cpu'); print('model ok')" 2>&1 | Out-String)
                                if ($LASTEXITCODE -ne 0) {
                                    $tail = (@($modelOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
                                    if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
                                    Write-Host ('  the whisper model could not be loaded (exit ' + $LASTEXITCODE + '): ' + $tail)
                                    Add-Result 'life-os-venv' 'WARN' ('the model could not be loaded: ' + $tail)
                                    Add-Manual 'run install.ps1 -Resume -WithWhisperModel once the download works (the venv itself is complete)'
                                    $modelOk = $false
                                }
                            }
                            if ($modelOk) {
                                Add-Result 'life-os-venv' 'OK' $venv
                                # only a complete venv counts as done: the WARN above sends the
                                # person to -Resume, and that must really run pip again
                                Save-Journal 'life-os-venv'
                            }
                        }
                    }
                    catch {
                        Add-Result 'life-os-venv' 'ERROR' ('the stage threw: ' + $_.Exception.Message)
                    }
                }
                else {
                    Add-Result 'life-os-venv' 'SKIP' 'not executed (ShouldProcess declined)'
                    Save-Journal 'life-os-venv'
                }
            }
        }
    }

    # ------------------------------------------------------------- own-tools --
    Invoke-PlatformStage 'own-tools' 'Invoke-OwnToolsStage' 'own-tools' 'own-tools'

    # --------------------------------------------------- os-extras --
    Invoke-PlatformStage 'os-extras' 'Invoke-OsExtrasStage' 'os-extras' 'os-extras'

    # -------------------------------------------------------------- summary --
    Save-BackupIndex
    if (-not $TestMode) {
        Add-Manual 'gh auth login'
        Add-Manual 'sign in to Claude Code (claude) and set the profile keys (setup/powershell/set-research-keys.ps1)'
        Add-Manual 'install Obsidian, open the vault; the community plugins are already in the vault (obsidian-git, tasks)'
    }
    Write-Host ''
    Write-Host '== Result ==' -ForegroundColor Cyan
    foreach ($r in $results) { Write-Host ('  {0,-18} {1,-6} {2}' -f $r.Stage, $r.Status, $r.Detail) }
    if ($manualSteps.Count -gt 0) {
        Write-Host ''
        Write-Host 'Manual steps:' -ForegroundColor Yellow
        foreach ($m in $manualSteps) { Write-Host ('  - ' + $m) }
    }
    $failed = @($results | Where-Object { $_.Status -eq 'ERROR'})
    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host ('INSTALL: ' + $failed.Count + ' stage(s) with errors') -ForegroundColor Red
        $exitCode = 1
    }
    else {
        Write-Host ''
        Write-Host 'INSTALL-OK' -ForegroundColor Green
        $exitCode = 0
    }
}
finally {
    # -WhatIf:$false: the transcript is ours and must be closed even in a dry run
    Stop-Transcript -WhatIf:$false | Out-Null
}
exit $exitCode
