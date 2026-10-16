<#
setup/lib/platform.ps1 - what an operating system is and what the engine may assume about it.

Decision D2 of the cross-platform task: PowerShell 7 is the one script language on Windows,
macOS and Linux. This file is the ONLY place in the engine that asks which system it runs on.
Everything that is specific to one system lives in setup/platform/<os>.ps1 (loaded on demand
through Import-PlatformModule) or in the mirror folders windows/, macos/ and linux/.

Dot-source this file, then:
  $os     = Get-PlatformId
  $plat   = Get-PlatformData -RepoRoot <repo>          # setup/platforms.yaml, parsed
  $entry  = Get-ComponentPlatform -Platforms $plat -ComponentId 'claude-md'
  $value  = $entry['macos']                            # 'files' | 'unsupported: ...' | ...
  $render = Get-PlatformPlaceholderValue -Token PWSH_HOST -Os $os

Value vocabulary of a platform entry (see the header of setup/platforms.yaml):
  files | dirs | packages:<path> | scheduler:<kind> | mcp | plugin | generated |
  homebrew-service:<name> | systemd-user:<unit> | manual:<what> | unsupported: <reason>

Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less file in the ANSI code
page, and the bootstrap parses install.ps1 with it before PowerShell 7 is installed.
#>

$script:PlatformIds = @('windows', 'macos', 'linux')

function Get-PlatformId {
    # windows | macos | linux. Throws on anything else - a system the engine was never tested
    # on must not be treated like one it was.
    [CmdletBinding()]
    param()
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # D2 names these three: they exist from PowerShell 6 on and are the clearest statement
        if ($IsWindows) { return 'windows' }
        if ($IsMacOS) { return 'macos' }
        if ($IsLinux) { return 'linux' }
    }
    # Windows PowerShell 5.1 has no $IsWindows. RuntimeInformation answers there too
    # (.NET Framework 4.7.1 and newer), which matters because bootstrap.ps1 may still be
    # running under 5.1 when it asks.
    try {
        $ri = [System.Runtime.InteropServices.RuntimeInformation]
        $op = [System.Runtime.InteropServices.OSPlatform]
        if ($ri::IsOSPlatform($op::Windows)) { return 'windows' }
        if ($ri::IsOSPlatform($op::OSX)) { return 'macos' }
        if ($ri::IsOSPlatform($op::Linux)) { return 'linux' }
    }
    catch { }
    if ($env:OS -eq 'Windows_NT') { return 'windows' }
    throw 'unknown operating system: this engine supports windows, macos and linux only'
}

function Test-PlatformId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Os)
    return ($script:PlatformIds -contains $Os)
}

function Get-PlatformData {
    # setup/platforms.yaml, read once. Always loaded through the manifest module's YAML
    # importer so there is exactly one YAML path in the engine.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    if ($script:PlatformCache -and ($script:PlatformCacheRoot -eq $RepoRoot)) { return $script:PlatformCache }
    $file = Join-Path $RepoRoot 'setup/platforms.yaml'
    if (-not (Test-Path -LiteralPath $file)) { throw ('platform map missing: ' + $file) }
    Import-Module powershell-yaml -ErrorAction Stop
    $data = ConvertFrom-Yaml (Get-Content -LiteralPath $file -Raw)
    if (-not $data) { throw ('platform map not readable: ' + $file) }
    $script:PlatformCache = $data
    $script:PlatformCacheRoot = $RepoRoot
    return $data
}

function Get-ComponentPlatform {
    # the { windows = ...; macos = ...; linux = ... } block of one manifest component
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Platforms,
        [Parameter(Mandatory)][string]$ComponentId
    )
    $components = Get-ManifestField $Platforms 'components'
    if (-not $components) { throw 'setup/platforms.yaml has no components section' }
    foreach ($c in @($components)) {
        if ([string](Get-ManifestField $c 'id') -eq $ComponentId) { return $c }
    }
    if ($components -is [System.Collections.IDictionary] -and $components.Contains($ComponentId)) {
        return $components[$ComponentId]
    }
    return $null
}

function Get-PlatformValue {
    # the value a component carries for one operating system, or $null when the map is silent.
    # An empty value is an error, not "probably files": check H exists for exactly that.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Platforms,
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Os
    )
    $block = Get-ComponentPlatform -Platforms $Platforms -ComponentId $ComponentId
    if (-not $block) { return $null }
    $v = Get-ManifestField $block $Os
    if ($null -eq $v) { return $null }
    return [string]$v
}

function Test-PlatformUnsupported {
    # "unsupported: <reason>" is the one value a component may carry instead of a real one.
    # The reason is mandatory - red line 5: report, never silently disable.
    [CmdletBinding()]
    param([string]$Value)
    if (-not $Value) { return $false }
    return ($Value -match '^\s*unsupported\s*:')
}

function Get-UnsupportedReason {
    [CmdletBinding()]
    param([string]$Value)
    if (-not (Test-PlatformUnsupported $Value)) { return '' }
    return (($Value -replace '^\s*unsupported\s*:\s*', '')).Trim()
}

function Get-PlatformSetting {
    # one key of the platforms: section, e.g. -Key state_dir
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Platforms,
        [Parameter(Mandatory)][string]$Os,
        [Parameter(Mandatory)][string]$Key
    )
    $section = Get-ManifestField $Platforms 'platforms'
    if (-not $section) { throw 'setup/platforms.yaml has no platforms section' }
    $block = Get-ManifestField $section $Os
    if (-not $block) { throw ('setup/platforms.yaml has no block for ' + $Os) }
    return [string](Get-ManifestField $block $Key)
}

function Resolve-PlatformToken {
    # "{HOME}/x" -> the real path. Only the documented tokens are replaced; anything else
    # (a literal path in the map) is handed back unchanged.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][hashtable]$Roots
    )
    $s = $Value
    foreach ($k in $Roots.Keys) { $s = $s.Replace('{' + $k + '}', [string]$Roots[$k]) }
    return $s
}

function Get-PlatformHome {
    # The user's home folder. HOME is set on every system this engine supports; on Windows it
    # is USERPROFILE, and [Environment] answers even when the variable was cleared.
    [CmdletBinding()]
    param()
    $os = Get-PlatformId
    if ($os -eq 'windows') {
        if ($env:USERPROFILE) { return $env:USERPROFILE }
        return [Environment]::GetFolderPath('UserProfile')
    }
    if ($env:HOME) { return $env:HOME }
    return [Environment]::GetFolderPath('UserProfile')
}

function Get-PlatformDocuments {
    # D4: the DOCUMENTS root the profile components install into.
    # Windows: the known Documents folder (OneDrive may redirect it).
    # macOS/Linux: where the system keeps documents - pwsh reads its profile from
    # ~/.config/powershell there, which is a HOME component, not this one.
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    if ($Os -eq 'windows') { return [Environment]::GetFolderPath('MyDocuments') }
    return (Join-Path (Get-PlatformHome) 'Documents')
}

function Get-PlatformRoots {
    # the four roots every manifest target starts with
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ConfigValues,
        [string]$Os = (Get-PlatformId)
    )
    # never $home: that name is a read-only automatic variable in PowerShell and assigning it
    # throws "cannot overwrite the variable HOME because it is read-only or constant"
    $homeDir = Get-PlatformHome
    return @{
        HOME      = $homeDir
        DOCUMENTS = Get-PlatformDocuments -Os $Os
        VAULT     = [string]$ConfigValues['vault_path']
        DEV       = [string]$ConfigValues['dev_root']
    }
}

function Get-PlatformStateDir {
    # where install.ps1 keeps journal, transcript, backups and previews. Never inside the
    # repository and never inside the vault.
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    if ($Os -eq 'windows') {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path (Get-PlatformHome) 'AppData\Local' }
        return (Join-Path $base 'personal-os-setup')
    }
    return (Join-Path (Join-Path (Get-PlatformHome) '.local/state') 'personal-os-setup')
}

function Get-PlatformVenvDir {
    # where the Life OS python environment lives. Both the installer and the installed
    # scripts ask this, so the answer sits in one place ({{LIFEOS_*}} renders to the same
    # paths - see Get-PlatformPlaceholderTable).
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    if ($Os -eq 'windows') { return (Join-Path (Join-Path $env:LOCALAPPDATA 'life-os') 'venv') }
    return (Join-Path (Join-Path (Join-Path (Get-PlatformHome) '.local/state') 'life-os') 'venv')
}

function Get-PlatformVenvPython {
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    $venv = Get-PlatformVenvDir -Os $Os
    if ($Os -eq 'windows') { return (Join-Path $venv 'Scripts\python.exe') }
    return (Join-Path $venv 'bin/python')
}

function Get-PlatformLifeOsPythonMaxMinor {
    # The newest Python MINOR version ctranslate2 ships wheels for. ctranslate2 is the engine
    # under faster-whisper and the one Life OS package that must have a prebuilt wheel; without
    # one pip stops at "No matching distribution found for ctranslate2" and the venv stays
    # empty. Measured 2026-10-16 against PyPI (pypi.org/pypi/ctranslate2/4.8.2/json): the wheel
    # tags run cp39 to cp314 and stop there, while Python 3.15.0 (released 2026-10-09) is what
    # Homebrew's `python` formula already points at. Raise this number TOGETHER with the pins
    # (macos/Brewfile, windows/winget-core.json) and the first candidate below once a newer
    # Python has wheels - tests/Platforms.Tests.ps1 holds the three in agreement.
    [CmdletBinding()]
    param()
    return 14
}

function Get-PlatformLifeOsPythonCandidates {
    # The interpreters the Life OS venv may be built with, in order of preference, each as an
    # argv array (the Windows launcher needs its version selector as a second argument, so a
    # bare name could not carry the pin). The first candidate IS the pin: 3.13, the version
    # macos/Brewfile (python@3.13) and windows/winget-core.json (Python.Python.3.13) install.
    # A bare `python3` from PATH is the last resort and only while its version is not above
    # Get-PlatformLifeOsPythonMaxMinor - the check in Get-PlatformLifeOsPython decides.
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    if ($Os -eq 'windows') {
        # `py -3.13` is the launcher python.org installs (the winget package is that installer)
        # and the only way to name a specific version on a machine carrying several. python3.exe
        # is deliberately absent: on Windows it is the App Execution Alias of the Store.
        return @(
            @('py', '-3.13'),
            @('py', '-3.14'),
            @('python')
        )
    }
    if ($Os -eq 'macos') {
        # python3.13 comes from `brew install python@3.13`; measured 2026-10-16 against the
        # Homebrew API, that formula is NOT keg-only, so Homebrew links python3.13 into its bin.
        # The two keg paths stay behind it as a fallback for a keg-only future.
        return @(
            @('python3.13'),
            @('/opt/homebrew/opt/python@3.13/bin/python3.13'),
            @('/usr/local/opt/python@3.13/bin/python3.13'),
            @('python3.14'),
            @('python3')
        )
    }
    # Linux: the distribution's own python3. linux/packages.yaml names the package without a
    # version on purpose - no supported distribution carries a python3.13 package - so the
    # version check below is what decides, and the python3.13 candidate above only wins where
    # the distribution or the person provides one.
    return @(
        @('python3.13'),
        @('python3.14'),
        @('python3'),
        @('python')
    )
}

function Get-PlatformLifeOsPython {
    # Resolves the interpreter that builds the Life OS venv and reads its version back FROM the
    # interpreter, never from its name - `python3` says nothing about what it is. Returns
    #   @{ Argv = @('python3.13'); Command = 'python3.13'; Version = '3.13' }  ready to use
    #   @{ TooNew = '3.15'; Command = 'python3' }  found, but newer than wheels exist for
    #   $null                                      nothing usable found
    # The venv must be built through this function and not with a bare `python3` from PATH:
    # measured 2026-10-16, a fresh Mac (Homebrew `python` now points at 3.15) failed the whole
    # venv on "No matching distribution found for ctranslate2" while 3.13 sat next to it.
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    $maxMinor = Get-PlatformLifeOsPythonMaxMinor
    $tooNew = $null
    foreach ($argv in @(Get-PlatformLifeOsPythonCandidates -Os $Os)) {
        $exe = $argv[0]
        if ($exe -match '[\\/]') {
            if (-not (Test-Path -LiteralPath $exe)) { continue }
        }
        elseif (-not (Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue)) { continue }
        # the probe is one line of python without a single space in it: the argument then
        # survives every quoting rule of PowerShell 5.1 and cmd alike
        $code = "import sys;print('%d.%d'%sys.version_info[:2])"
        $pre = @($argv | Select-Object -Skip 1)
        $out = ''
        try { $out = ((& $exe @pre -c $code 2>&1) | Out-String).Trim() } catch { continue }
        if ($LASTEXITCODE -ne 0) { continue }
        if ($out -notmatch '^(\d+)\.(\d+)$') { continue }
        $version = $Matches[1] + '.' + $Matches[2]
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if (($major -gt 3) -or (($major -eq 3) -and ($minor -gt $maxMinor))) {
            # remembered, not returned: an older interpreter further down the list may still
            # work, and only when none does is this the finding the caller reports
            if (-not $tooNew) { $tooNew = @{ TooNew = $version; Command = ($argv -join ' ') } }
            continue
        }
        return @{ Argv = $argv; Command = ($argv -join ' '); Version = $version }
    }
    return $tooNew
}

function Get-PlatformUserSid {
    # {{USER_SID}} is a Windows account identifier (the scheduled task needs it). Everywhere
    # else the placeholder renders to an empty string, and the files that use it are the
    # Windows-only ones.
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    if ($Os -ne 'windows') { return '' }
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return '' }
}

function Get-PlatformPathSeparator {
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    if ($Os -eq 'windows') { return '\' }
    return '/'
}

function Get-PlatformToolDirs {
    # Where an install puts programs that no package manager owns, and where a login session has
    # them on PATH while a CI step does not:
    #   * <home>/.local/bin - the release installs (uv and trufflehog on Linux, trufflehog on
    #     Windows). A login session gets it from the shell profile (Ubuntu's .profile adds
    #     $HOME/.local/bin), a CI step inherits the PATH its own process started with.
    #   * Windows only: winget's Links folder holds the shims of portable packages (uv). winget
    #     registers it in the USER PATH, which a process started afterwards sees.
    # The folder name is a Windows fact with no equivalent on the other systems, so it lives
    # here - in the platform module, the one file that may carry the answers of a single system
    # (acceptance check I forbids it in the engine and names this file as the place for it).
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add((Join-Path (Get-PlatformHome) ('.local' + (Get-PlatformPathSeparator -Os $Os) + 'bin')))
    if (($Os -eq 'windows') -and $env:LOCALAPPDATA) {
        $dirs.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'))
    }
    # No comma before the array: `return , $dirs.ToArray()` hands back ONE value (the array
    # itself), and a caller that loops over it then concatenates both paths into a single string
    # - measured on the windows-latest runner (2026-10-14, tag run v2.3.2): the PATH got
    # "C:\...\.local\bin C:\...\WinGet\Links" as ONE entry, and the live verify reported
    # "own-tools - not in PATH: uv, trufflehog". Every caller wraps the call in @(), which
    # restores the array shape for the one-element case; tests/Platforms.Tests.ps1 holds it.
    return $dirs.ToArray()
}

function Get-PlatformPackageEntries {
    # every manifest component whose value for this OS is "packages:<path>", in manifest order
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Platforms,
        [Parameter(Mandatory)]$Manifest,
        [string]$Os = (Get-PlatformId)
    )
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-ManifestField $Manifest 'components')) {
        $id = [string](Get-ManifestField $e 'id')
        $v = Get-PlatformValue -Platforms $Platforms -ComponentId $id -Os $Os
        if ($v -and ($v -match '^packages:')) {
            $list.Add([pscustomobject]@{ Id = $id; Path = ($v -replace '^packages:', '') })
        }
    }
    return $list
}

function Import-PlatformModule {
    # The one place that loads setup/platform/<os>.ps1. Every module defines the same five
    # stage verbs, so install.ps1 never branches on the OS itself:
    #   Invoke-PackageStage, Invoke-SchedulerStage, Invoke-SyncStage, Get-BackupStage,
    #   Get-PlatformPackagePreview
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Os = (Get-PlatformId)
    )
    $file = Join-Path $RepoRoot ('setup/platform/' + $Os + '.ps1')
    if (-not (Test-Path -LiteralPath $file)) { throw ('no platform module for ' + $Os + ': ' + $file) }
    . $file
    return $Os
}

function Get-PlatformPlaceholderTable {
    # D2/A6: the platform-dependent part of the placeholder vocabulary. ONE table, three
    # systems, two directions.
    #
    #   sources  the text that appears in a LIVE file of this system. export.ps1 pairs each of
    #            them with the token, so the mirror stores {{TOKEN}}.
    #   value    what install.ps1 renders the token back to on this system.
    #
    # On Windows `sources` and `value` are the same string, which makes the round trip
    # export -> repo -> install an identity - the live files never change (check 8 and check J
    # of the acceptance run).
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    $win = @(
        @{ token = 'PWSH_PATH';      value = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'; sources = @('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe') }
        @{ token = 'PWSH_EXE';       value = 'pwsh.exe';        sources = @('pwsh.exe') }
        @{ token = 'PWSH_HOST';      value = 'powershell.exe';  sources = @('powershell.exe') }
        @{ token = 'HOME_ENV';       value = '$env:USERPROFILE'; sources = @('$env:USERPROFILE') }
        @{ token = 'HOME_CMD';       value = '%USERPROFILE%';   sources = @('%USERPROFILE%') }
        @{ token = 'TEMP_ENV';       value = '$env:TEMP';       sources = @('$env:TEMP') }
        @{ token = 'TMP_ENV';        value = '$env:TMP';        sources = @('$env:TMP') }
        @{ token = 'LIFEOS_PYTHON';  value = '$env:LOCALAPPDATA\life-os\venv\Scripts\python.exe'; sources = @('$env:LOCALAPPDATA\life-os\venv\Scripts\python.exe') }
        @{ token = 'LIFEOS_LOCK';    value = '$env:LOCALAPPDATA\life-os\morning.lock'; sources = @('$env:LOCALAPPDATA\life-os\morning.lock') }
        @{ token = 'LIFEOS_STATE';   value = '$env:LOCALAPPDATA\life-os'; sources = @('$env:LOCALAPPDATA\life-os') }
        @{ token = 'KOPIA_CLI';      value = '$env:LOCALAPPDATA\Programs\KopiaUI\resources\server\kopia.exe'; sources = @('$env:LOCALAPPDATA\Programs\KopiaUI\resources\server\kopia.exe') }
        @{ token = 'KOPIA_CONFIG';   value = '$env:APPDATA\kopia\repository.config'; sources = @('$env:APPDATA\kopia\repository.config') }
        # ONE source per token: a second source that also occurs in the same live file would
        # collapse two different lines into one placeholder and the install would hand back the
        # first line's text for both (measured 2026-10-14 on vault/000-meta/scripts/
        # setup-laptop.ps1, which names two candidate Obsidian paths).
        @{ token = 'OBSIDIAN_APP';   value = '$env:LOCALAPPDATA\Programs\Obsidian\Obsidian.exe'; sources = @('$env:LOCALAPPDATA\Programs\Obsidian\Obsidian.exe') }
    )
    $mac = @(
        @{ token = 'PWSH_PATH';      value = 'pwsh'; sources = @('/usr/local/bin/pwsh') }
        @{ token = 'PWSH_EXE';       value = 'pwsh'; sources = @() }
        @{ token = 'PWSH_HOST';      value = 'pwsh'; sources = @() }
        @{ token = 'HOME_ENV';       value = '$env:HOME'; sources = @() }
        @{ token = 'HOME_CMD';       value = '$HOME'; sources = @() }
        # TMPDIR, and not a call: the Windows text this replaces is $env:TEMP, and a live file
        # ASSIGNS to it ($env:TEMP = $PSScriptRoot in home/.claude/setup/tests/
        # test-add-to-archive.ps1). A variable is the only shape that works in every position -
        # as an argument, inside a string and as the target of an assignment. Measured
        # 2026-10-14 by rendering every mirrored file for macOS and Linux and parsing it;
        # tests/Platforms.Tests.ps1 keeps that measurement.
        @{ token = 'TEMP_ENV';       value = '$env:TMPDIR'; sources = @() }
        @{ token = 'TMP_ENV';        value = '$env:TMPDIR'; sources = @() }
        @{ token = 'LIFEOS_PYTHON';  value = '$env:HOME/.local/state/life-os/venv/bin/python'; sources = @() }
        @{ token = 'LIFEOS_LOCK';    value = '$env:HOME/.local/state/life-os/morning.lock'; sources = @() }
        @{ token = 'LIFEOS_STATE';   value = '$env:HOME/.local/state/life-os'; sources = @() }
        @{ token = 'KOPIA_CLI';      value = 'kopia'; sources = @() }
        @{ token = 'KOPIA_CONFIG';   value = '$env:HOME/Library/Application Support/kopia/repository.config'; sources = @() }
        @{ token = 'OBSIDIAN_APP';   value = '/Applications/Obsidian.app'; sources = @() }
    )
    $lin = @(
        @{ token = 'PWSH_PATH';      value = 'pwsh'; sources = @('/usr/bin/pwsh') }
        @{ token = 'PWSH_EXE';       value = 'pwsh'; sources = @() }
        @{ token = 'PWSH_HOST';      value = 'pwsh'; sources = @() }
        @{ token = 'HOME_ENV';       value = '$env:HOME'; sources = @() }
        @{ token = 'HOME_CMD';       value = '$HOME'; sources = @() }
        # $env:TMPDIR for the same reason as in the macOS table above: the value of TEMP_ENV and
        # TMP_ENV has to be a variable, because a live file assigns to it. TMPDIR is the one
        # temporary-folder variable of this system, so both tokens answer with it.
        @{ token = 'TEMP_ENV';       value = '$env:TMPDIR'; sources = @() }
        @{ token = 'TMP_ENV';        value = '$env:TMPDIR'; sources = @() }
        @{ token = 'LIFEOS_PYTHON';  value = '$env:HOME/.local/state/life-os/venv/bin/python'; sources = @() }
        @{ token = 'LIFEOS_LOCK';    value = '$env:HOME/.local/state/life-os/morning.lock'; sources = @() }
        @{ token = 'LIFEOS_STATE';   value = '$env:HOME/.local/state/life-os'; sources = @() }
        @{ token = 'KOPIA_CLI';      value = 'kopia'; sources = @() }
        @{ token = 'KOPIA_CONFIG';   value = '$env:HOME/.config/kopia/repository.config'; sources = @() }
        @{ token = 'OBSIDIAN_APP';   value = '/var/lib/flatpak/exports/bin/md.obsidian.Obsidian'; sources = @() }
    )
    switch ($Os) {
        'windows' { return $win }
        'macos' { return $mac }
        'linux' { return $lin }
    }
    throw ('no placeholder table for ' + $Os)
}

function Get-PlatformPlaceholderValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [string]$Os = (Get-PlatformId)
    )
    foreach ($e in (Get-PlatformPlaceholderTable -Os $Os)) {
        if ($e.token -eq $Token) { return [string]$e.value }
    }
    return $null
}

function Get-PlatformPlaceholderNames {
    [CmdletBinding()]
    param()
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($e in (Get-PlatformPlaceholderTable -Os 'windows')) { $names.Add([string]$e.token) }
    return $names
}

function Get-PlatformPlaceholderMap {
    # the {{TOKEN}} -> value map for Get-PlaceholderMap, for one operating system
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    $map = [ordered]@{}
    foreach ($e in (Get-PlatformPlaceholderTable -Os $Os)) {
        $map['{{' + $e.token + '}}'] = [string]$e.value
    }
    return $map
}

function Get-PlatformExportPairs {
    # export.ps1: every live string of THIS system that stands for a platform token.
    # Longest source first - {{LIFEOS_STATE}} is a prefix of {{LIFEOS_PYTHON}}'s text, and a
    # short pair running first would break the long one apart.
    [CmdletBinding()]
    param([string]$Os = (Get-PlatformId))
    $pairs = New-Object System.Collections.Generic.List[hashtable]
    foreach ($e in (Get-PlatformPlaceholderTable -Os $Os)) {
        foreach ($src in @($e.sources)) {
            if ($src) { $pairs.Add(@{ from = [string]$src; to = ('{{' + $e.token + '}}') }) }
        }
    }
    return @($pairs | Sort-Object -Property { $_.from.Length } -Descending)
}
