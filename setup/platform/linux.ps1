<#
setup/platform/linux.ps1 - everything the engine does that only Linux can do.

Loaded on demand through Import-PlatformModule (setup/lib/platform.ps1). Same stage names as
windows.ps1 and macos.ps1.

  packages    The distribution decides: apt on Debian/Ubuntu, dnf on Fedora/RHEL. The names
              live in linux/packages.yaml, the file is read, never guessed. A distribution
              that is neither prints its package list and stops that step with a clear message
              (decision D5). Obsidian comes from Flatpak, because that is the publisher's own
              channel for Linux.
  task        systemd user service + timer (linux/systemd/*.tmpl): OnCalendar daily at
              {{MORNING_TIME}} with Persistent=true, so a run missed while the machine was off
              happens at the next start; OnStartupSec gives the "at login" run.
  os-extras   not applicable - no registry, no Windows firewall rules
  sync        `systemctl --user enable --now syncthing.service`
  backup      Kopia comes from the package source (its own apt/rpm repository, see
              linux/packages.yaml); connecting the repository is typed by the person

ASCII-only on purpose (Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page).
#>

function Get-LinuxOsRelease {
    # /etc/os-release is the documented interface (os-release(5)). ID is the distribution,
    # ID_LIKE the family it belongs to - Ubuntu says ID_LIKE=debian, Rocky says ID_LIKE="rhel".
    [CmdletBinding()]
    param([string]$Path = '/etc/os-release')
    $info = @{ ID = ''; ID_LIKE = ''; PRETTY_NAME = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $info }
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        $m = [regex]::Match($line, '^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$')
        if (-not $m.Success) { continue }
        if ($info.ContainsKey($m.Groups[1].Value)) { $info[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    return $info
}

function Get-LinuxPackageManager {
    # apt | dnf | unknown - decided from /etc/os-release, never from which binary happens to
    # be installed: a Fedora machine with apt installed by hand is still a dnf machine.
    [CmdletBinding()]
    param([hashtable]$OsRelease)
    if (-not $OsRelease) { $OsRelease = Get-LinuxOsRelease }
    $words = @()
    foreach ($k in @('ID', 'ID_LIKE')) {
        foreach ($w in ([string]$OsRelease[$k] -split '\s+')) { if ($w) { $words += $w.ToLowerInvariant() } }
    }
    foreach ($w in $words) {
        if (@('debian', 'ubuntu', 'linuxmint', 'pop', 'elementary', 'zorin', 'kali', 'raspbian', 'devuan') -contains $w) { return 'apt' }
        if (@('fedora', 'rhel', 'centos', 'rocky', 'almalinux', 'ol', 'amzn') -contains $w) { return 'dnf' }
    }
    return 'unknown'
}

function Get-LinuxPackagesFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    Import-Module powershell-yaml -ErrorAction Stop
    $f = Join-Path ([string]$Context['RepoRoot']) 'linux/packages.yaml'
    if (-not (Test-Path -LiteralPath $f)) { throw ('package list missing: ' + $f) }
    return (ConvertFrom-Yaml (Get-Content -LiteralPath $f -Raw))
}

function Get-LinuxPackageNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Manager)
    $block = Get-ManifestField $Data $Manager
    if (-not $block) { return @() }
    $pkgs = Get-ManifestField $block 'packages'
    if (-not $pkgs) { return @() }
    return @($pkgs | ForEach-Object { [string]$_ })
}

function Get-LinuxRepositories {
    # repository setup lines (Kopia keeps its own apt/rpm repository - see linux/packages.yaml)
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Manager)
    $block = Get-ManifestField $Data $Manager
    if (-not $block) { return @() }
    $repos = Get-ManifestField $block 'repositories'
    if (-not $repos) { return @() }
    return @($repos)
}

function Get-LinuxArchitecture {
    # the asset names of a GitHub release use uname's spelling
    [CmdletBinding()]
    param()
    $m = (& uname -m | Out-String).Trim()
    switch ($m) {
        'x86_64' { return 'x86_64' }
        'amd64' { return 'x86_64' }
        'aarch64' { return 'arm64' }
        'arm64' { return 'arm64' }
    }
    return $m
}

function Install-LinuxRelease {
    # A program with no package at all: the official GitHub release, SHA256 checked against the
    # checksum file of the same release, unpacked into ~/.local/bin. How a release names its
    # files is answered in setup/lib/releases.ps1 (one place, two measured shapes) - the asset
    # name in linux/packages.yaml is the END of the file name, because the version sits inside
    # it. A release without a checksum is not installed.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][hashtable]$Context)
    $name = [string](Get-ManifestField $Release 'name')
    $repo = [string](Get-ManifestField $Release 'repo')
    $arch = Get-LinuxArchitecture
    $assetName = [string](Get-ManifestField $Release ('asset_linux_' + $arch))
    if (-not $assetName) { return [pscustomobject]@{ Ok = $false; Detail = ($name + ': no release asset for ' + $arch + ' in linux/packages.yaml') } }
    $binDir = Join-Path (Get-PlatformHome) '.local/bin'
    $target = Join-Path $binDir ([string](Get-ManifestField $Release 'binary'))
    if (Test-Path -LiteralPath $target) { return [pscustomobject]@{ Ok = $true; Detail = ($name + ' already present') } }
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $api = 'https://api.github.com/repos/' + $repo + '/releases/latest'
    $rel = Invoke-RestMethod -Uri $api -Headers (Get-GitHubApiHeaders)
    $asset = Select-ReleaseAsset -Assets $rel.assets -Suffix $assetName
    if (-not $asset) { return [pscustomobject]@{ Ok = $false; Detail = ($name + ': no asset whose name ends in "' + $assetName + '" in release ' + $rel.tag_name) } }
    $sumAsset = Get-ReleaseChecksumAsset -Assets $rel.assets -AssetName $asset.name
    if (-not $sumAsset) {
        return [pscustomobject]@{ Ok = $false; Detail = ($name + ': release ' + $rel.tag_name + ' carries no checksum for ' + $asset.name + ' - not installed unverified') }
    }
    $tmp = Join-Path ([string]$Context['StateDir']) ('release-' + $name + '-' + $asset.name)
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
    # the checksum file arrives as bytes on this platform (see Convert-ReleaseText)
    $sumText = Convert-ReleaseText ((Invoke-WebRequest -Uri $sumAsset.browser_download_url -UseBasicParsing).Content)
    $expected = Find-ReleaseChecksum -Text $sumText -AssetName $asset.name
    if (-not $expected) {
        Remove-Item -LiteralPath $tmp -Force
        return [pscustomobject]@{ Ok = $false; Detail = ($name + ': ' + $sumAsset.name + ' carries no line for ' + $asset.name) }
    }
    $actual = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        Remove-Item -LiteralPath $tmp -Force
        return [pscustomobject]@{ Ok = $false; Detail = ($name + ': SHA256 mismatch (expected ' + $expected + ', got ' + $actual + ')') }
    }
    # an archive that carries its own top-level folder names how many parts to drop (uv does;
    # trufflehog puts its binary at the top level and carries no such field)
    $strip = [string](Get-ManifestField $Release 'strip_components')
    $tarArgs = @('-xzf', $tmp, '-C', $binDir)
    if ($strip) { $tarArgs += ('--strip-components=' + $strip) }
    $null = (& tar @tarArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $tmp -Force
        return [pscustomobject]@{ Ok = $false; Detail = ($name + ': unpacking failed') }
    }
    $null = (& chmod +x $target 2>&1)
    Remove-Item -LiteralPath $tmp -Force
    return [pscustomobject]@{ Ok = $true; Detail = ($name + ' ' + $rel.tag_name + ' (SHA256 checked)') }
}

function Get-PlatformPwshPath {
    # PowerShell 7 for install.ps1 itself. bootstrap.sh installs it (the Microsoft package
    # repository for apt/dnf) before install.ps1 is ever started, so a missing pwsh here is a
    # message, not an installer - the caller already looked for pwsh on PATH.
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Path = $null; Manual = 'start this repository with ./bootstrap.sh - it installs PowerShell 7 from the Microsoft package repository first' }
}

function Invoke-PackageStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context['SkipPackages']) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'per -SkipWinget'; Manual = @() } }
    $os = Get-LinuxOsRelease
    $manager = Get-LinuxPackageManager -OsRelease $os
    $data = Get-LinuxPackagesFile -Context $Context

    if ($manager -eq 'unknown') {
        # Decision D5: an unknown distribution gets its list and a clear stop, not a guess.
        $all = @()
        foreach ($m in @('apt', 'dnf')) { $all += @(Get-LinuxPackageNames -Data $data -Manager $m) }
        $flatpak = Get-ManifestField $data 'flatpak'
        if ($flatpak) { $all += @((Get-ManifestField $flatpak 'apps')) }
        return [pscustomobject]@{
            Status = 'WARN'
            Detail = ('unknown distribution "' + [string]$os['ID'] + '" - no package manager was guessed')
            Manual = (@('install these packages with your distribution''s own tool: ' + (($all | Sort-Object -Unique) -join ', ')) +
                      @('then run install.ps1 -Resume -SkipWinget'))
        }
    }

    $names = @(Get-LinuxPackageNames -Data $data -Manager $manager)
    $repos = Get-LinuxRepositories -Data $data -Manager $manager
    $flatpakBlock = Get-ManifestField $data 'flatpak'
    $flatpakApps = @()
    $flatpakRemote = ''
    if ($flatpakBlock) {
        $flatpakApps = @((Get-ManifestField $flatpakBlock 'apps') | ForEach-Object { [string]$_ })
        $flatpakRemote = [string](Get-ManifestField $flatpakBlock 'remote')
    }

    if ($Context['TestMode']) {
        $lines = @()
        foreach ($r in $repos) {
            foreach ($line in @((Get-ManifestField $r 'setup'))) { $lines += [string]$line }
        }
        if ($manager -eq 'apt') { $lines += ('apt-get install -y ' + ($names -join ' ')) }
        else { $lines += ('dnf install -y ' + ($names -join ' ')) }
        if ($flatpakApps.Count -gt 0) {
            $lines += ('flatpak remote-add --if-not-exists ' + $flatpakRemote + ' https://dl.flathub.org/repo/flathub.flatpakrepo')
            $lines += ('flatpak install -y ' + $flatpakRemote + ' ' + ($flatpakApps -join ' '))
        }
        foreach ($rel in @((Get-ManifestField $data 'releases'))) {
            $lines += ('github release: ' + [string](Get-ManifestField $rel 'name') + ' (' + [string](Get-ManifestField $rel 'repo') + ', checksums.txt SHA256-verified) -> ~/.local/bin')
        }
        & $Context['SavePreview'] 'linux-packages.txt' (($lines -join "`n") + "`n")
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/linux-packages.txt'; Manual = @() }
    }
    if ($Context['DryRun']) {
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = ('DryRun: ' + $manager + ' install of ' + $names.Count + ' package(s), ' + $flatpakApps.Count + ' flatpak app(s)'); Manual = @() }
    }
    $manual = New-Object System.Collections.Generic.List[string]
    $did = New-Object System.Collections.Generic.List[string]
    if (-not (& $Context['ShouldProcess'] ($manager + ' install') ('install ' + $names.Count + ' package(s)'))) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not executed (ShouldProcess declined)'; Manual = @() }
    }
    # The repositories come first: kopia is not in any distribution's own archive.
    foreach ($r in $repos) {
        $name = [string](Get-ManifestField $r 'name')
        $marker = [string](Get-ManifestField $r 'marker')
        foreach ($p in @((Get-ManifestField $r 'packages'))) { if ($p) { $names += [string]$p } }
        if ($marker -and (Test-Path -LiteralPath $marker)) { $did.Add($name + ' repository already present'); continue }
        $lines = @((Get-ManifestField $r 'setup'))
        # a repository setup writes under /etc and downloads a key: that needs root
        $script = ($lines | ForEach-Object { [string]$_ }) -join "`n"
        $out = (& sudo sh -c $script 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { $manual.Add('set up the ' + $name + ' repository by hand (see linux/packages.yaml): ' + $out.Trim()) }
        else { $did.Add($name + ' repository'); $null = (& sudo $manager update 2>&1) }
    }
    # One call for the whole list; if a single name is unknown the package manager refuses the
    # batch, so the second attempt asks name by name and each failure is reported instead of
    # being hidden behind one error. (Debian bookworm has no gitleaks, for example.)
    $installed = 0
    $batchOut = (& sudo $manager -y install @names 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { $installed = $names.Count }
    else {
        foreach ($n in $names) {
            $null = (& sudo $manager -y install $n 2>&1)
            if ($LASTEXITCODE -eq 0) { $installed++ } else { $manual.Add('not in the ' + $manager + ' archive: ' + $n) }
        }
    }
    if ($installed -gt 0) { $did.Add($installed.ToString() + ' packages') }
    foreach ($rel in @((Get-ManifestField $data 'releases'))) {
        $r = Install-LinuxRelease -Release $rel -Context $Context
        if ($r.Ok) { $did.Add($r.Detail) } else { $manual.Add($r.Detail) }
    }
    if ($flatpakApps.Count -gt 0) {
        $fp = Get-Command flatpak -ErrorAction SilentlyContinue
        if (-not $fp) { $manual.Add('install Flatpak, then: flatpak install ' + $flatpakRemote + ' ' + ($flatpakApps -join ' ')) }
        else {
            $null = (& flatpak remote-add --if-not-exists $flatpakRemote 'https://dl.flathub.org/repo/flathub.flatpakrepo' 2>&1)
            $out = (& flatpak install -y $flatpakRemote @flatpakApps 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) {
                # the reason goes into the report, not only into a transcript nobody can read
                # on a CI machine (same rule as the brew stage on macOS)
                $tail = (@($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
                if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
                $manual.Add('install the Flatpak apps by hand: flatpak install ' + $flatpakRemote + ' ' + ($flatpakApps -join ' ') + ' - it said: ' + $tail)
            }
            else { $did.Add($flatpakApps.Count.ToString() + ' flatpak app(s)') }
        }
    }
    $status = if ($manual.Count -gt 0) { 'WARN' } else { 'OK' }
    return [pscustomobject]@{ Status = $status; Detail = (($manager + ': ') + ($did -join ', ')); Manual = $manual }
}

function Invoke-SchedulerStage {
    # A systemd USER service plus a timer. The timer is Persistent=true, so a run that was
    # missed while the machine was off happens at the next start (systemd.timer(5)).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $repo = [string]$Context['RepoRoot']
    $entry = $Context['TaskEntry']
    if (-not $entry) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'no task component in the manifest'; Manual = @() } }
    $unit = 'personal-os-morning'
    $pairs = @(
        @((Join-Path $repo ('linux/systemd/' + $unit + '.service.tmpl')), 'personal-os-morning.service'),
        @((Join-Path $repo ('linux/systemd/' + $unit + '.timer.tmpl')), 'personal-os-morning.timer')
    )
    $dir = Join-Path (Get-PlatformHome) '.config/systemd/user'
    if ($Context['TestMode']) {
        $lines = @()
        foreach ($p in $pairs) {
            $lines += ('# ' + $p[1])
            $lines += (Expand-Placeholders ([IO.File]::ReadAllText($p[0])) $Context['Placeholders'])
        }
        & $Context['SavePreview'] 'systemd-units.txt' (($lines -join "`n") + "`n")
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/systemd-units.txt'; Manual = @() }
    }
    foreach ($p in $pairs) {
        if (-not (Test-Path -LiteralPath $p[0])) { return [pscustomobject]@{ Status = 'ERROR'; Detail = ('template missing: ' + $p[0]); Manual = @() } }
    }
    if ($Context['DryRun']) { return [pscustomobject]@{ Status = 'PREVIEW'; Detail = ('DryRun: ' + $dir + ' would be written and the timer enabled'); Manual = @() } }
    if (-not (& $Context['ShouldProcess'] $dir 'write and enable the systemd user units')) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not enabled (ShouldProcess declined)'; Manual = @() }
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $changed = $false
    foreach ($p in $pairs) {
        $text = Expand-Placeholders ([IO.File]::ReadAllText($p[0])) $Context['Placeholders']
        if ($text -notmatch "`n$") { $text += "`n" }
        $dest = Join-Path $dir $p[1]
        if (Test-Path -LiteralPath $dest) {
            if ([IO.File]::ReadAllText($dest) -ceq $text) { continue }
            & $Context['BackupFile'] $dest
        }
        [IO.File]::WriteAllText($dest, $text, (New-Object Text.UTF8Encoding($false)))
        $changed = $true
    }
    $null = (& systemctl --user daemon-reload 2>&1)
    $out = (& systemctl --user enable --now ($unit + '.timer') 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Status = 'WARN'; Detail = ('systemctl --user exit ' + $LASTEXITCODE + ': ' + $out.Trim()); Manual = @('enable the timer by hand: systemctl --user enable --now personal-os-morning.timer') }
    }
    return [pscustomobject]@{ Status = 'OK'; Detail = ($(if ($changed) { 'written and enabled' } else { 'already identical, re-enabled' }) + ': ' + $unit + '.timer'); Manual = @() }
}

function Invoke-OsExtrasStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not applicable on Linux (no registry, no Windows firewall rules)'; Manual = @() }
}

function Invoke-SyncStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'systemctl-syncthing.txt' "systemctl --user enable --now syncthing.service`n"
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/systemctl-syncthing.txt'; Manual = @() }
    }
    if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'no systemd on this machine'; Manual = @('start Syncthing the way your init system does it') }
    }
    if ($Context['DryRun']) { return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'DryRun: systemctl --user enable --now syncthing.service'; Manual = @() } }
    if (-not (& $Context['ShouldProcess'] 'syncthing.service' 'enable and start the user service')) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not started (ShouldProcess declined)'; Manual = @() }
    }
    $out = (& systemctl --user enable --now syncthing.service 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Status = 'WARN'; Detail = $out.Trim(); Manual = @('start Syncthing by hand: systemctl --user enable --now syncthing.service') }
    }
    return [pscustomobject]@{ Status = 'OK'; Detail = 'systemctl --user enable --now syncthing.service'; Manual = @('open the Syncthing web UI once (http://127.0.0.1:8384) and pair the devices') }
}

function Get-BackupStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [pscustomobject]@{
        Status = 'OK'
        Detail = 'Kopia comes from linux/packages.yaml (its own repository, set up by the package stage)'
        Manual = @('run `kopia repository connect ...` once and type the password - it never goes into a file')
    }
}

function Get-PlatformPackagePreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $os = Get-LinuxOsRelease
    $manager = Get-LinuxPackageManager -OsRelease $os
    return ('distribution ' + [string]$os['PRETTY_NAME'] + ' -> ' + $manager + ' names from linux/packages.yaml')
}

function Invoke-OwnToolsStage {
    # No separate step: gh comes from the distribution, uv and trufflehog from the GitHub
    # releases named in linux/packages.yaml (checksum checked). Same list on every system.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'own-tools.txt' "gh comes from linux/packages.yaml; uv and trufflehog from the GitHub releases in the same file (checksum checked)`n"
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/own-tools.txt'; Manual = @() }
    }
    return [pscustomobject]@{ Status = 'OK'; Detail = 'gh from linux/packages.yaml; uv and trufflehog from its releases'; Manual = @() }
}

function Test-PackageStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $os = Get-LinuxOsRelease
    $manager = Get-LinuxPackageManager -OsRelease $os
    if ($manager -eq 'unknown') { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'unknown distribution'; Missing = @() } }
    $data = Get-LinuxPackagesFile -Context $Context
    $names = @(Get-LinuxPackageNames -Data $data -Manager $manager)
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($n in $names) {
        $probe = if ($manager -eq 'apt') { 'dpkg-query' } else { 'rpm' }
        if (-not (Get-Command $probe -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Status = 'SKIP'; Detail = ($probe + ' is not on PATH'); Missing = @() } }
        if ($manager -eq 'apt') { $out = (& dpkg-query -W -f='${Status}' $n 2>&1 | Out-String) }
        else { $out = (& rpm -q $n 2>&1 | Out-String) }
        if ($out -notmatch 'install ok installed|^' + [regex]::Escape($n) + '-') {
            if ($LASTEXITCODE -ne 0) { $missing.Add($n) }
        }
    }
    if ($missing.Count -eq 0) { return [pscustomobject]@{ Status = 'OK'; Detail = ($names.Count.ToString() + ' packages present'); Missing = @() } }
    return [pscustomobject]@{ Status = 'FAIL'; Detail = ('missing: ' + ($missing -join ', ')); Missing = $missing }
}

function Test-SchedulerStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'no systemd'; Missing = @() } }
    $out = (& systemctl --user is-enabled personal-os-morning.timer 2>&1 | Out-String).Trim()
    if ($out -eq 'enabled') { return [pscustomobject]@{ Status = 'OK'; Detail = 'timer enabled'; Missing = @() } }
    return [pscustomobject]@{ Status = 'FAIL'; Detail = ('personal-os-morning.timer is ' + $out); Missing = @() }
}
