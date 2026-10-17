<#
verify.ps1 - checks every manifest component against an installed target.
Lives in setup/; the repo root is its parent folder. Runs on Windows, macOS and Linux under
PowerShell 7; which system it is on is asked once (setup/lib/platform.ps1) and the checks that
depend on it are answered by setup/platform/<os>.ps1.

  pwsh -File setup/verify.ps1                    # this machine (live)
  pwsh -File setup/verify.ps1 -TargetRoot <dir>  # a test install
  pwsh -File setup/verify.ps1 -SkipSystemChecks  # only file checks

What it checks: copy files byte-equal to the repo - except a copy file that carries known
{{PLACEHOLDER}} tokens, which must equal the rendered text like a template; template files
equal to the rendered text; doc-only files present; dirs present; no {{PLACEHOLDER}}
leftovers (only the runtime token {{N_SOURCES}} is allowed); and in live mode the system
pieces (packages, scheduled job, MCP servers, Obsidian plugins, venv, tools).
-Profile full|minimal and -Components <ids> mirror install.ps1 and report the rest as SKIP.
A component the platform map marks `unsupported` for this system is reported as SKIP with the
reason from the map - the same wording install.ps1 uses.
The install date for rendering comes from the journal when present, else from today. Since
2.1.1 only the install-once skeletons carry {{INSTALL_DATE}}; no file this script compares
does - a mirrored file with a render-time value would break the export round trip, and the
round trip test forbids it.

Output: one line per component, then a summary. Exit 0 = all green, 1 = at least one FAIL.
ASCII-only on purpose (same reason as install.ps1).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$ConfigPath,
    [string]$TargetRoot,
    [switch]$SkipSystemChecks,
    [ValidateSet('full', 'minimal')][string]$Profile = 'full',
    [string[]]$Components
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }   # this script lives in setup/
$TestMode = [bool]$TargetRoot
$placeholderWhitelist = @('{{N_SOURCES}}')   # runtime token of the research skill, never ours

Import-Module powershell-yaml -ErrorAction Stop
. (Join-Path $PSScriptRoot 'lib/manifest.ps1')
. (Join-Path $PSScriptRoot 'lib/platform.ps1')
. (Join-Path $PSScriptRoot 'lib/placeholders.ps1')
. (Join-Path $PSScriptRoot 'lib/harness.ps1')

$platformOs = Get-PlatformId
$platforms = Get-PlatformData -RepoRoot $RepoRoot
$sep = Get-PlatformPathSeparator -Os $platformOs

if (-not $ConfigPath) { $ConfigPath = Join-Path (Get-PlatformHome) '.personal-os/personal.yaml' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw ('personal.yaml is missing: ' + $ConfigPath) }
$cfg = @{}
$loaded = ConvertFrom-Yaml (Get-Content -LiteralPath $ConfigPath -Raw)
if ($loaded -is [System.Collections.IDictionary]) {
    foreach ($key in $loaded.Keys) { $cfg[[string]$key] = $loaded[$key] }
}
else {
    foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
}
$manifest = Get-Manifest -Path (Join-Path $PSScriptRoot 'manifest.yaml')

function Test-EntrySelected($e) {
    # mirrors install.ps1: -Components <ids> and -Profile minimal narrow what was installed
    $id = [string](Get-ManifestField $e 'id')
    if ($Components -and ($Components -notcontains $id)) { return $false }
    if ($Profile -eq 'minimal' -and ((Get-ManifestField $e 'core') -ne $true)) { return $false }
    return $true
}
function Get-ComponentPlatformValue($e) {
    return (Get-PlatformValue -Platforms $platforms -ComponentId ([string](Get-ManifestField $e 'id')) -Os $platformOs)
}

if ($TestMode) {
    $tr = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetRoot)
    if (-not (Test-Path -LiteralPath $tr)) { throw ('TargetRoot is missing: ' + $tr) }
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
    $stateDir = Get-PlatformStateDir -Os $platformOs
}
$placeholders = Get-PlaceholderMap -Roots $roots -ConfigValues $cfg -Os $platformOs
$installDate = (Get-Date -Format 'yyyy-MM-dd')
$journalPath = Join-Path $stateDir 'install-journal.json'
if (Test-Path -LiteralPath $journalPath) {
    $j = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    if ($j.installDate) { $installDate = [string]$j.installDate }
}
$placeholders['{{INSTALL_DATE}}'] = $installDate
$placeholders['{{USER_SID}}'] = Get-PlatformUserSid -Os $platformOs
$morning = if ($cfg['morning_time']) { [string]$cfg['morning_time'] } else { '07:00' }
$placeholders['{{START_BOUNDARY}}'] = (Get-Date).ToString('yyyy-MM-dd') + 'T' + $morning + ':00' + (Get-Date -Format 'zzz')

$okCount = 0; $failCount = 0; $skipCount = 0
function Add-Check([string]$id, [string]$status, [string]$detail) {
    if ($status -eq 'OK') { $script:okCount++ }
    elseif ($status -eq 'FAIL') { $script:failCount++ }
    else { $script:skipCount++ }
    $color = switch ($status) { 'OK' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host ('  {0,-7} {1,-30} {2}' -f $status, $id, $detail) -ForegroundColor $color
}
function Get-RepoFileFor([string]$targetRel, $entry) {
    # stored name (dot rule, store_as) and repo folder come from lib/manifest.ps1
    $rel = Get-RepoFileRel -Target $targetRel -StoreAs ([string](Get-ManifestField $entry 'store_as'))
    return (Join-Path $RepoRoot $rel)
}
function Get-TargetPathFor([string]$targetRel) {
    $parts = $targetRel -split '/', 2
    # a root token without a path ("DEV") is the root itself - dirs entries may name it
    if ($parts.Count -lt 2 -or -not $parts[1]) { return $roots[$parts[0]] }
    return (Join-Path $roots[$parts[0]] ($parts[1] -replace '/', $sep))
}
function Get-UnknownTokens([string]$text) {
    $tokens = @()
    foreach ($m in [regex]::Matches($text, '\{\{[A-Z0-9_]+\}\}')) {
        if ($placeholderWhitelist -notcontains $m.Value) { $tokens += $m.Value }
    }
    return ($tokens | Select-Object -Unique)
}

Write-Host ''
Write-Host ('== verify personal-os-setup ' + $(if ($TestMode) { '(test target ' + $tr + ')' } else { '(this ' + $platformOs + ' machine)' }) + ' ==') -ForegroundColor Cyan

# the platform module answers the checks that need the operating system
$script:platformCtx = @{
    RepoRoot     = $RepoRoot
    Platforms    = $platforms
    Manifest     = $manifest
    Os           = $platformOs
    TestMode     = $TestMode
    StateDir     = $stateDir
    Placeholders = $placeholders
    TaskEntry    = ($manifest.components | Where-Object { [string](Get-ManifestField $_ 'type') -eq 'task' } | Select-Object -First 1)
    TaskName     = ''
}
if ($script:platformCtx.TaskEntry) { $script:platformCtx.TaskName = [string](Get-ManifestField $script:platformCtx.TaskEntry 'name') }
if (-not $TestMode -and -not $SkipSystemChecks) { . (Join-Path $RepoRoot ('setup/platform/' + $platformOs + '.ps1')) }
$systemSkipReason = if ($TestMode) { 'test install: only files are checked' } else { 'system check not executed' }

foreach ($e in @($manifest.components)) {
    $type = [string](Get-ManifestField $e 'type')
    $id = [string](Get-ManifestField $e 'id')
    if (-not (Test-EntrySelected $e)) { Add-Check $id 'SKIP' 'not selected (-Profile/-Components)'; continue }
    $platValue = Get-ComponentPlatformValue $e
    if (Test-PlatformUnsupported $platValue) {
        Add-Check $id 'SKIP' ('unsupported on ' + $platformOs + ': ' + (Get-UnsupportedReason $platValue))
        continue
    }
    switch ($type) {
        { $_ -in @('copy', 'template', 'doc-only') } {
            $targetRel = [string](Get-ManifestField $e 'target')
            $repoFile = Get-RepoFileFor $targetRel $e
            $abs = Get-TargetPathFor $targetRel
            if (($type -in @('copy', 'template')) -and (Get-ManifestField $e 'recursive')) {
                if (-not (Test-Path -LiteralPath $repoFile -PathType Container)) { Add-Check $id 'FAIL' ('repo folder missing: ' + $repoFile); break }
                $bad = New-Object System.Collections.Generic.List[string]
                $count = 0
                # install, export and the roundtrip all honor the manifest's exclude list; a
                # verify that counted an excluded __pycache__ as missing would call a correct
                # install broken (found by the install e2e test, 2026-10-17).
                $excludes = @(Get-ManifestField $e 'exclude') | Where-Object { $_ }
                foreach ($rf in (Get-ChildItem -LiteralPath $repoFile -Recurse -File -Force)) {
                    $childRel = $rf.FullName.Substring($repoFile.Length).TrimStart('\', '/')
                    if ($childRel -and (Test-Excluded -RelPath $childRel -Patterns $excludes)) { continue }
                    $absChild = Join-Path $abs $childRel
                    $count++
                    if (-not (Test-Path -LiteralPath $absChild)) { $bad.Add('missing: ' + $childRel); continue }
                    $effType = $type
                    # the repo text is read for every child (review-2 LOW: the rendered
                    # comparison below used $repoText, which only type copy used to set)
                    $repoText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($rf.FullName))
                    if ($type -eq 'copy') {
                        # a copy file carrying known tokens is rendered at install; it must
                        # equal the rendered text and hold no leftover placeholder
                        foreach ($k in $placeholders.Keys) { if ($repoText.Contains($k)) { $effType = 'template'; break } }
                    }
                    if ($effType -eq 'copy') {
                        if ((Get-FileHash -LiteralPath $absChild -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $rf.FullName -Algorithm SHA256).Hash) { $bad.Add('differs: ' + $childRel) }
                    }
                    else {
                        $targetText = [IO.File]::ReadAllText($absChild)
                        $expected = Expand-Placeholders $repoText $placeholders
                        if ($targetText -cne $expected) { $bad.Add('differs: ' + $childRel) }
                        else {
                            $unknown = @(Get-UnknownTokens $targetText)
                            if ($unknown.Count -gt 0) { $bad.Add('placeholders left: ' + $childRel + ' ' + ($unknown -join ' ')) }
                        }
                    }
                }
                if ($bad.Count -eq 0) { Add-Check $id 'OK' ($count.ToString() + ' files') }
                else { Add-Check $id 'FAIL' ($bad.Count.ToString() + ' of ' + $count + ': ' + (($bad | Select-Object -First 3) -join '; ')) }
                break
            }
            if (-not (Test-Path -LiteralPath $abs)) { Add-Check $id 'FAIL' ('missing: ' + $abs); break }
            $effType = $type
            if ($type -eq 'copy') {
                $repoText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($repoFile))
                foreach ($k in $placeholders.Keys) { if ($repoText.Contains($k)) { $effType = 'template'; break } }
            }
            if ($effType -eq 'copy') {
                # An entry with drop_lines is stored in the repo WITHOUT the lines the export
                # removes (personal notes that stay on the owner's machine). Comparing hashes
                # would call that normal state a difference on every live run, so the comparison
                # drops the same lines. Line endings are ignored: the export writes CRLF, git may
                # check out LF.
                $drop = @((Get-ManifestField $e 'drop_lines') | Where-Object { $_ })
                if ($drop.Count -gt 0) {
                    $kept = New-Object System.Collections.Generic.List[string]
                    foreach ($line in ([IO.File]::ReadAllText($abs) -split "`r?`n")) {
                        $isDropped = $false
                        foreach ($p in $drop) { if ($line -match $p) { $isDropped = $true; break } }
                        if (-not $isDropped) { $kept.Add($line) }
                    }
                    $repoLines = @([IO.File]::ReadAllText($repoFile) -split "`r?`n")
                    if (($kept -join "`n") -ceq ($repoLines -join "`n")) {
                        Add-Check $id 'OK' ('identical after the ' + $drop.Count + ' dropped line pattern(s)')
                    }
                    else { Add-Check $id 'FAIL' 'content differs from the repo, even after the dropped lines' }
                }
                else {
                    $h1 = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash
                    $h2 = (Get-FileHash -LiteralPath $repoFile -Algorithm SHA256).Hash
                    if ($h1 -eq $h2) { Add-Check $id 'OK' 'identical' } else { Add-Check $id 'FAIL' 'content differs from the repo' }
                }
            }
            else {
                $text = [IO.File]::ReadAllText($abs)
                $unknown = @(Get-UnknownTokens $text)
                if ($type -eq 'doc-only') {
                    if ($text.Length -gt 0) { Add-Check $id 'OK' 'present' } else { Add-Check $id 'FAIL' 'empty' }
                    break
                }
                $expected = Expand-Placeholders ([IO.File]::ReadAllText($repoFile)) $placeholders
                if ($text -ceq $expected) {
                    if ($unknown.Count -gt 0) { Add-Check $id 'FAIL' ('unknown placeholders: ' + ($unknown -join ' ')) }
                    else { Add-Check $id 'OK' 'rendered' }
                }
                else { Add-Check $id 'FAIL' 'rendered content differs' }
            }
        }
        'dir' {
            $missing = @()
            foreach ($d in @(Get-ManifestField $e 'dirs')) {
                if (-not (Test-Path -LiteralPath (Get-TargetPathFor ([string]$d)))) { $missing += [string]$d }
            }
            if ($missing.Count -eq 0) { Add-Check $id 'OK' 'all folders present' } else { Add-Check $id 'FAIL' ('missing: ' + ($missing -join ', ')) }
        }
        'winget' {
            if ([bool](Get-ManifestField $e 'core') -eq $false) { Add-Check $id 'SKIP' 'optional (only installed with -WithOptional)'; break }
            if ($TestMode) {
                # One name per system, same shape as the task branch below: the package stage
                # writes preview/winget-packages.txt on Windows, preview/brew-bundle.txt on
                # macOS and preview/linux-packages.txt on Linux. Measured 2026-10-14 in the
                # linux job: the hard-coded Windows name made this check report
                # `preview missing` for a preview that was there.
                $names = @('winget-packages.txt', 'brew-bundle.txt', 'linux-packages.txt')
                $found = @($names | Where-Object { Test-Path -LiteralPath (Join-Path $stateDir ('preview/' + $_)) })
                if ($found.Count -eq 0) { Add-Check $id 'FAIL' 'preview missing' } else { Add-Check $id 'OK' 'preview present' }
            }
            elseif ($SkipSystemChecks) { Add-Check $id 'SKIP' $systemSkipReason }
            else {
                $r = Test-PackageStage -Context $script:platformCtx
                Add-Check $id $r.Status $r.Detail
            }
        }
        'task' {
            if ($TestMode) {
                $names = @('scheduled-task.xml', 'launchagent.plist', 'systemd-units.txt')
                $found = @($names | Where-Object { Test-Path -LiteralPath (Join-Path $stateDir ('preview/' + $_)) })
                if ($found.Count -eq 0) { Add-Check $id 'FAIL' 'preview missing'; break }
                $p = Join-Path $stateDir ('preview/' + $found[0])
                if ($found[0] -eq 'systemd-units.txt') {
                    $text = [IO.File]::ReadAllText($p)
                    if ($text -match '\{\{') { Add-Check $id 'FAIL' 'unit not rendered' } else { Add-Check $id 'OK' 'preview rendered' }
                    break
                }
                try {
                    if ($found[0] -eq 'launchagent.plist') {
                        $x = [xml](Get-Content -LiteralPath $p -Raw)
                        if ($x.plist.dict) { Add-Check $id 'OK' 'preview rendered' } else { Add-Check $id 'FAIL' 'plist has no dict' }
                        break
                    }
                    $x = [xml](Get-Content -LiteralPath $p -Raw)
                    $uid = $x.Task.Principals.Principal.UserId
                    if ($platformOs -ne 'windows') { Add-Check $id 'OK' 'preview rendered'; break }
                    if ($uid -and $uid -notmatch '\{\{') { Add-Check $id 'OK' 'preview rendered' } else { Add-Check $id 'FAIL' 'UserId not rendered' }
                }
                catch { Add-Check $id 'FAIL' ('XML invalid: ' + $_.Exception.Message) }
            }
            elseif ($SkipSystemChecks) { Add-Check $id 'SKIP' $systemSkipReason }
            else {
                $r = Test-SchedulerStage -Context $script:platformCtx
                Add-Check $id $r.Status $r.Detail
            }
        }
        'mcp' {
            $name = [string](Get-ManifestField $e 'name')
            if ($TestMode) {
                if (Test-Path -LiteralPath (Join-Path $stateDir 'preview/mcp-add.txt')) { Add-Check $id 'OK' 'preview present' } else { Add-Check $id 'FAIL' 'preview missing' }
            }
            elseif ($SkipSystemChecks) { Add-Check $id 'SKIP' $systemSkipReason }
            else {
                $claude = Get-Command claude -ErrorAction SilentlyContinue
                if (-not $claude) { Add-Check $id 'FAIL' 'claude is not on PATH'; break }
                $mcpList = $null
                try { $mcpList = (& claude mcp list 2>$null | Out-String) } catch { $mcpList = $null }
                if (-not $mcpList) { Add-Check $id 'FAIL' 'claude mcp list not readable' }
                elseif ($mcpList -match [regex]::Escape($name)) { Add-Check $id 'OK' 'registered' }
                else { Add-Check $id 'FAIL' 'not registered' }
            }
        }
        'obsidian-plugin' {
            $name = [string](Get-ManifestField $e 'name')
            $version = [string](Get-ManifestField $e 'version')
            if ($TestMode) { Add-Check $id 'SKIP' 'plugin download only in a live run' }
            else {
                $mf = Join-Path $roots.VAULT ('.obsidian' + $sep + 'plugins' + $sep + $name + $sep + 'manifest.json')
                if (-not (Test-Path -LiteralPath $mf)) { Add-Check $id 'FAIL' 'plugin missing in the vault' }
                else {
                    $have = (Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).version
                    if ($have -eq $version) { Add-Check $id 'OK' ('v' + $have) } else { Add-Check $id 'FAIL' ('Version ' + $have + ' instead of ' + $version) }
                }
            }
        }
        'generated' {
            switch ($id) {
                'life-os-venv' {
                    $venvPy = Get-PlatformVenvPython -Os $platformOs
                    if ($TestMode) {
                        if (Test-Path -LiteralPath (Join-Path $stateDir 'preview/life-os-venv.txt')) { Add-Check $id 'OK' 'preview present' } else { Add-Check $id 'FAIL' 'preview missing' }
                    }
                    elseif (-not (Test-Path -LiteralPath $venvPy)) { Add-Check $id 'FAIL' ('venv missing: ' + $venvPy) }
                    else {
                        # Review 18 measured the gap: a venv whose pip install failed still has its
                        # python, so a run that ended INSTALL-OK could carry a green verify and an
                        # EMPTY venv. The file alone therefore proves nothing; one pinned package
                        # of the file is asked for by name. faster-whisper is the reason this venv
                        # exists at all, and `pip show` answers in well under a second.
                        $probe = (& $venvPy -m pip show faster-whisper 2>&1 | Out-String)
                        if ($LASTEXITCODE -eq 0) { Add-Check $id 'OK' ('venv present with its packages (' + $venvPy + ')') }
                        else { Add-Check $id 'FAIL' ('venv present but incomplete: faster-whisper is not installed - run install.ps1 -Resume') }
                    }
                }
                'other-harness-configs' {
                    if (-not $TestMode -and $SkipSystemChecks) { Add-Check $id 'SKIP' $systemSkipReason }
                    else {
                        try {
                            $updates = @(Get-HarnessConfigUpdates -HomeDir $roots.HOME -RepoRoot $RepoRoot)
                            $todo = @($updates | Where-Object { $_.Changed })
                            $names = @($updates | ForEach-Object { $_.Name })
                            if ($todo.Count -gt 0) { Add-Check $id 'FAIL' ('not merged: ' + (($todo | ForEach-Object { $_.Name }) -join ', ')) }
                            elseif ($names.Count -eq 0) { Add-Check $id 'OK' 'no OpenCode or Codex folder - nothing to merge' }
                            else { Add-Check $id 'OK' ('current: ' + ($names -join ', ')) }
                        }
                        catch { Add-Check $id 'FAIL' $_.Exception.Message }
                    }
                }
                'crawl4ai' {
                    if ($TestMode) {
                        if (Test-Path -LiteralPath (Join-Path $stateDir 'preview/crawl4ai.txt')) { Add-Check $id 'OK' 'preview present' } else { Add-Check $id 'FAIL' 'preview missing' }
                    }
                    elseif ($SkipSystemChecks) { Add-Check $id 'SKIP' $systemSkipReason }
                    else {
                        # the browser is not launched here (a crawl takes seconds and needs a
                        # network); the entry point proves the tool completed its setup.
                        # The same two places install.ps1 resolves it from: a login shell may
                        # not have ~/.local/bin on PATH (macOS), but the tool is still there.
                        $crwlPath = $null
                        $crwl = Get-Command crwl -ErrorAction SilentlyContinue
                        if ($crwl) { $crwlPath = $crwl.Source }
                        else {
                            # BaseName, not a host-specific file name: Windows has crwl.exe,
                            # the other systems have crwl; the platform module owns the folder.
                            foreach ($d in @(Get-PlatformToolDirs -Os $platformOs)) {
                                $found = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                                    Where-Object { $_.BaseName -eq 'crwl' } | Select-Object -First 1
                                if ($found) { $crwlPath = $found.FullName; break }
                            }
                        }
                        if ($crwlPath) { Add-Check $id 'OK' ('crwl ready (' + $crwlPath + ')') }
                        else { Add-Check $id 'FAIL' 'crwl not found - run install.ps1 -Resume (the crawler is the first page fetcher)' }
                    }
                }
                'own-tools' {
                    if ($TestMode) {
                        if (Test-Path -LiteralPath (Join-Path $stateDir 'preview/own-tools.txt')) { Add-Check $id 'OK' 'preview present' } else { Add-Check $id 'FAIL' 'preview missing' }
                    }
                    elseif ($SkipSystemChecks) { Add-Check $id 'SKIP' $systemSkipReason }
                    else {
                        $missing = @()
                        foreach ($tool in @('uv', 'gh', 'trufflehog')) {
                            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += $tool }
                        }
                        if ($missing.Count -eq 0) { Add-Check $id 'OK' 'uv, gh, trufflehog in PATH' } else { Add-Check $id 'FAIL' ('not in PATH: ' + ($missing -join ', ')) }
                    }
                }
                'os-sync' {
                    if ($TestMode) { Add-Check $id 'SKIP' 'OS stage: only files are checked in a test install' }
                    else { Add-Check $id 'OK' ('handled by install.ps1: ' + (Get-PlatformSetting -Platforms $platforms -Os $platformOs -Key 'scheduler')) }
                }
                'os-backup' {
                    if ($TestMode) { Add-Check $id 'SKIP' 'OS stage: only files are checked in a test install' }
                    else {
                        $kopia = Get-Command kopia -ErrorAction SilentlyContinue
                        if ($kopia) { Add-Check $id 'OK' ('kopia in PATH (' + $kopia.Source + ')') }
                        else { Add-Check $id 'OK' 'Kopia/KopiaUI are installed by the package stage; the repository is connected by hand once' }
                    }
                }
                'os-onedrive' {
                    # D9: there is no official OneDrive client for Linux. The guard stays
                    # installed there and enforces any archive path that is configured.
                    if (Test-PlatformUnsupported (Get-ComponentPlatformValue $e)) { Add-Check $id 'SKIP' 'unsupported here - see the platform map' }
                    else { Add-Check $id 'OK' 'the person signs in to the OneDrive client once (manual step)' }
                }
                'plugins-claude-code' {
                    $settings = Get-TargetPathFor 'HOME/.claude/settings.json'
                    if (Test-Path -LiteralPath $settings) {
                        $s = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
                        if ($s.enabledPlugins) { Add-Check $id 'OK' 'enabledPlugins set (install via claude CLI)' } else { Add-Check $id 'FAIL' 'enabledPlugins missing' }
                    }
                    else { Add-Check $id 'FAIL' 'settings.json missing' }
                }
                default { Add-Check $id 'SKIP' 'no check' }
            }
        }
        default { Add-Check $id 'SKIP' ('Type ' + $type) }
    }
}

Write-Host ''
if ($failCount -gt 0) {
    Write-Host ('VERIFY: ' + $okCount + ' ok, ' + $failCount + ' errors, ' + $skipCount + ' skipped') -ForegroundColor Red
    exit 1
}
Write-Host ('VERIFY-OK: ' + $okCount + ' ok, 0 errors, ' + $skipCount + ' skipped') -ForegroundColor Green
exit 0
