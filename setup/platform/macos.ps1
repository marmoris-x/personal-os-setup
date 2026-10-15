<#
setup/platform/macos.ps1 - everything the engine does that only macOS can do.

Loaded on demand through Import-PlatformModule (setup/lib/platform.ps1). Same stage names as
windows.ps1 and linux.ps1.

  packages    Homebrew: `brew bundle --file macos/Brewfile` (formulae and casks together)
  task        launchd: macos/launchagents/*.plist.tmpl -> ~/Library/LaunchAgents/, then
              `launchctl bootstrap gui/<uid>`. RunAtLoad starts it at login, and launchd runs
              a StartCalendarInterval job it missed while the Mac was asleep when it wakes.
  os-extras   not applicable - macOS has no registry and no Windows firewall rules
  sync        `brew services start syncthing` (a launchd agent Homebrew writes itself)
  backup      Kopia and KopiaUI come from the Brewfile; connecting the repository is typed
              by the person (decision D8)

ASCII-only on purpose (Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page).
#>

function Get-MacosBrewFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return (Join-Path ([string]$Context['RepoRoot']) 'macos/Brewfile')
}

function Get-PlatformPwshPath {
    # PowerShell 7 for install.ps1 itself. bootstrap.sh installs it (Homebrew) before
    # install.ps1 is ever started, so a missing pwsh here is a message, not an installer -
    # the caller already looked for pwsh on PATH before asking.
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Path = $null; Manual = 'start this repository with ./bootstrap.sh - it installs PowerShell 7 (brew install powershell) first' }
}

function Get-MacosBrew {
    [CmdletBinding()]
    param()
    foreach ($p in @('/opt/homebrew/bin/brew', '/usr/local/bin/brew')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $c = Get-Command brew -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Get-MacosLaunchAgentLabel {
    # The label launchd knows the job by, and the name of its plist. ONE place, because
    # install and verify both need it: verify asks launchctl for the job, and a verify that
    # looks for a different label than the install writes can never be green. (Measured on the
    # first full-setup run on macOS: verify asked launchctl for the manifest's `name`
    # ("Life OS Morning") while the plist is stored under the label below.)
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $label = ''
    if ($Context['TaskEntry']) { $label = [string](Get-ManifestField $Context['TaskEntry'] 'label') }
    if (-not $label) { $label = 'com.personal-os.life-os-morning' }
    return $label
}

function Invoke-PackageStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context['SkipPackages']) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'per -SkipWinget'; Manual = @() } }
    $brewfile = Get-MacosBrewFile -Context $Context
    if (-not (Test-Path -LiteralPath $brewfile)) {
        return [pscustomobject]@{ Status = 'ERROR'; Detail = ('Brewfile missing: ' + $brewfile); Manual = @() }
    }
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'brew-bundle.txt' ('brew bundle --file ' + $brewfile + "`r`n")
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/brew-bundle.txt'; Manual = @() }
    }
    $brew = Get-MacosBrew
    if (-not $brew) {
        return [pscustomobject]@{ Status = 'WARN'; Detail = 'Homebrew is missing'; Manual = @('install Homebrew (https://brew.sh), then run install.ps1 -Resume') }
    }
    if ($Context['DryRun']) { return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'DryRun: brew bundle'; Manual = @() } }
    if (-not (& $Context['ShouldProcess'] 'brew bundle' 'install the formulae and casks of macos/Brewfile')) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not executed (ShouldProcess declined)'; Manual = @() }
    }
    # `brew bundle` is idempotent: a second run installs nothing and says so.
    $out = (& $brew bundle --file $brewfile 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $installed = @($out -split "`r?`n" | Where-Object { $_ -match '^(Installing|Upgrading) ' }).Count
    if ($code -ne 0) {
        # The transcript lives on the machine that ran it, and on a CI machine nobody can read
        # that file afterwards. The first full-setup run (2026-10-14) reported only "brew bundle
        # exit 1 - see the transcript", which named no reason at all; the second run showed the
        # last three lines ("Installing obsidian | Installing kopiaui | `brew bundle` failed! 1
        # Brewfile dependency failed to install") - which still did not say WHICH entry failed
        # or why. brew marks both with an "Error:" line, so those lines come first now.
        $tail = Get-MacosBrewFailureDetail -Output $out
        return [pscustomobject]@{ Status = 'WARN'; Detail = ('brew bundle exit ' + $code + ': ' + $tail); Manual = @('run `brew bundle --file macos/Brewfile` by hand and read the output') }
    }
    return [pscustomobject]@{ Status = 'OK'; Detail = ('macos/Brewfile (' + $installed + ' change(s) this run)'); Manual = @() }
}

function Invoke-SchedulerStage {
    # launchd reads one plist per job from ~/Library/LaunchAgents. The template carries the
    # label, the program and both triggers (RunAtLoad = at login, StartCalendarInterval =
    # daily at {{MORNING_TIME}}).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $repo = [string]$Context['RepoRoot']
    $entry = $Context['TaskEntry']
    if (-not $entry) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'no task component in the manifest'; Manual = @() } }
    $label = Get-MacosLaunchAgentLabel -Context $Context
    $tmpl = Join-Path $repo 'macos/launchagents/com.personal-os.life-os-morning.plist.tmpl'
    if (-not (Test-Path -LiteralPath $tmpl)) { return [pscustomobject]@{ Status = 'ERROR'; Detail = ('template missing: ' + $tmpl); Manual = @() } }
    $xml = Expand-Placeholders ([IO.File]::ReadAllText($tmpl)) $Context['Placeholders']
    $dest = Join-Path (Get-PlatformHome) ('Library/LaunchAgents/' + $label + '.plist')
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'launchagent.plist' $xml
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/launchagent.plist'; Manual = @() }
    }
    if ($Context['DryRun']) { return [pscustomobject]@{ Status = 'PREVIEW'; Detail = ('DryRun: ' + $dest + ' would be written and loaded'); Manual = @() } }
    if (-not (& $Context['ShouldProcess'] $dest 'write and load the launch agent')) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not loaded (ShouldProcess declined)'; Manual = @() }
    }
    $changed = $true
    if (Test-Path -LiteralPath $dest) {
        $old = [IO.File]::ReadAllText($dest)
        if ($old -ceq $xml) { $changed = $false }
        & $Context['BackupFile'] $dest
    }
    if ($changed) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        [IO.File]::WriteAllText($dest, $xml, (New-Object Text.UTF8Encoding($false)))
    }
    $uid = (& id -u | Out-String).Trim()
    # bootstrap is idempotent only after a bootout: loading a label that is already loaded
    # fails with "service already loaded" (exit 5), which is not an error here.
    $null = (& launchctl bootout ('gui/' + $uid + '/' + $label) 2>&1)
    $loadOut = (& launchctl bootstrap ('gui/' + $uid) $dest 2>&1 | Out-String)
    $loadCode = $LASTEXITCODE
    $listed = (& launchctl list 2>&1 | Out-String)
    if ($loadCode -ne 0 -or ($listed -notmatch [regex]::Escape($label))) {
        return [pscustomobject]@{ Status = 'WARN'; Detail = ('launchctl bootstrap exit ' + $loadCode + ': ' + $loadOut.Trim()); Manual = @('load the launch agent by hand: launchctl bootstrap gui/$(id -u) ' + $dest) }
    }
    return [pscustomobject]@{ Status = 'OK'; Detail = ($(if ($changed) { 'written and loaded' } else { 'already identical, reloaded' }) + ': ' + $dest); Manual = @() }
}

function Invoke-OsExtrasStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not applicable on macOS (no registry, no Windows firewall rules)'; Manual = @() }
}

function Invoke-SyncStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'brew-services.txt' "brew services start syncthing`r`n"
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/brew-services.txt'; Manual = @() }
    }
    $brew = Get-MacosBrew
    if (-not $brew) {
        return [pscustomobject]@{ Status = 'WARN'; Detail = 'Homebrew is missing'; Manual = @('install Homebrew, then `brew services start syncthing`') }
    }
    if ($Context['DryRun']) { return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'DryRun: brew services start syncthing'; Manual = @() } }
    if (-not (& $Context['ShouldProcess'] 'brew services start syncthing' 'start the Syncthing service')) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not started (ShouldProcess declined)'; Manual = @() }
    }
    $out = (& $brew services start syncthing 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Status = 'WARN'; Detail = $out.Trim(); Manual = @('start Syncthing by hand: brew services start syncthing') } }
    return [pscustomobject]@{ Status = 'OK'; Detail = 'brew services start syncthing (a launchd agent)'; Manual = @('open the Syncthing web UI once and pair the devices') }
}

function Get-BackupStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [pscustomobject]@{
        Status = 'OK'
        Detail = 'Kopia and KopiaUI come from macos/Brewfile'
        Manual = @('start KopiaUI once and connect the backup repository - type the password there, it never goes into a file')
    }
}

function Get-PlatformPackagePreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return ('brew bundle --file ' + (Get-MacosBrewFile -Context $Context))
}

function Invoke-OwnToolsStage {
    # No separate step: uv, gh and trufflehog are formulae of macos/Brewfile, and brew keeps
    # them current. The stage exists so install.ps1 can run the same list on every system.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'own-tools.txt' "uv, gh and trufflehog come from macos/Brewfile`n"
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/own-tools.txt'; Manual = @() }
    }
    return [pscustomobject]@{ Status = 'OK'; Detail = 'uv, gh and trufflehog come from macos/Brewfile (brew keeps them current)'; Manual = @() }
}

function Get-MacosBrewFailureDetail {
    # The decisive lines of a failed `brew bundle`: every line brew marks as an error or a
    # warning, and - when it marks none - the last three lines as before. Measured in the second
    # full-setup run (2026-10-14): the last three lines said "1 Brewfile dependency failed to
    # install" and named neither the entry nor the reason, while brew's own "Error:" line (if
    # there is one) names both. The result is one line, cut at 300 characters so the stage table
    # stays readable.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    $lines = @($Output -split "`r?`n" | Where-Object { $_.Trim() })
    $marked = @($lines | Where-Object { $_ -match '^\s*(Error|Warning):' })
    $picked = if ($marked.Count -gt 0) { @($marked | Select-Object -Last 3) } else { @($lines | Select-Object -Last 3) }
    $text = ($picked -join ' | ')
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    return $text
}

function Test-PackageStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $brew = Get-MacosBrew
    if (-not $brew) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'Homebrew is not installed'; Missing = @() } }
    $file = Get-MacosBrewFile -Context $Context
    $leaves = @(& $brew leaves 2>$null)
    # A tap is not a formula: `brew leaves` can never list one. The first full-setup run
    # (2026-10-14) reported "missing: homebrew/bundle, homebrew/cask" on macOS for exactly that
    # reason - the two `tap` lines of the Brewfile sat in the formula list. `brew tap` answers
    # for taps, and it does so on a real Mac as well, so the check was wrong there too.
    $taps = @(& $brew tap 2>$null)
    $missing = New-Object System.Collections.Generic.List[string]
    $wanted = 0
    foreach ($line in @(Get-Content -LiteralPath $file)) {
        $m = [regex]::Match($line, '^\s*(brew|tap|cask|mas)\s+"([^"]+)"')
        if (-not $m.Success) { continue }
        $wanted++
        $kind = $m.Groups[1].Value
        $name = $m.Groups[2].Value
        if ($kind -eq 'cask') { continue }   # casks are checked below
        if ($kind -eq 'tap') {
            if ($taps -notcontains $name) { $missing.Add('tap ' + $name) }
            continue
        }
        if ($leaves -notcontains $name) { $missing.Add($name) }
    }
    $casks = @(& $brew list --cask 2>$null)
    foreach ($line in @(Get-Content -LiteralPath $file)) {
        $m = [regex]::Match($line, '^\s*cask\s+"([^"]+)"')
        if ($m.Success -and ($casks -notcontains $m.Groups[1].Value)) { $missing.Add($m.Groups[1].Value) }
    }
    if ($missing.Count -eq 0) { return [pscustomobject]@{ Status = 'OK'; Detail = ($wanted.ToString() + ' entries of macos/Brewfile present'); Missing = @() } }
    return [pscustomobject]@{ Status = 'FAIL'; Detail = ('missing: ' + ($missing -join ', ')); Missing = $missing }
}

function Test-SchedulerStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $label = Get-MacosLaunchAgentLabel -Context $Context
    $uid = (& id -u | Out-String).Trim()
    $out = (& launchctl print ('gui/' + $uid + '/' + $label) 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ Status = 'OK'; Detail = 'loaded'; Missing = @() } }
    return [pscustomobject]@{ Status = 'FAIL'; Detail = ('launch agent ' + $label + ' is not loaded'); Missing = @() }
}
