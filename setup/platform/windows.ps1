<#
setup/platform/windows.ps1 - everything the engine does that only Windows can do.

This file is the ONE allowed home of Windows literals in the engine. Check I of the acceptance
run demands zero hits everywhere else, so a new Windows assumption cannot creep into a portable
file unnoticed; the three files where a Windows literal is inherent by their nature
(setup/lib/platform.ps1, bootstrap.ps1, setup/tools/check.ps1) are named there with their
reason and their hit count.

Loaded on demand through Import-PlatformModule (setup/lib/platform.ps1).

Stages (same names as in macos.ps1 and linux.ps1):
  pwsh        Get-PlatformPwshPath - PowerShell 7 for install.ps1 itself (MSI + msiexec)
  packages    winget: `winget configure` from windows/configuration.winget; where that cannot
              run (an older winget, no elevated process) the JSON import lists of the same
              folder install the same package ids, and the stage names the reason as WARN
  task        Task Scheduler: the scheduled-task XML template in windows/scheduled-tasks/
  os-extras   registry and firewall work that needs an administrator (LongPathsEnabled,
              the Syncthing firewall rule)
  sync        SyncTrayzor carries the Syncthing service - nothing to enable here
  backup      Kopia and KopiaUI come from the package stage; connecting the repository is
              typed by the person (decision D8)

ASCII-only on purpose (Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page).
#>

function Get-PlatformPwshPath {
    # PowerShell 7 for install.ps1 itself (the script restarts under pwsh before it does
    # anything). Windows can install it: the official MSI from the PowerShell release page,
    # started with msiexec /quiet. When that does not work either, the Manual line names the
    # one command that does.
    [CmdletBinding()]
    param()
    $installed = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $manual = 'install it once by hand:  winget install Microsoft.PowerShell'
    if (Test-Path -LiteralPath $installed) { return [pscustomobject]@{ Path = $installed; Manual = '' } }
    Write-Host 'PowerShell 7 is missing - downloading the official MSI from GitHub ...'
    $url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi'
    $msi = Join-Path $env:TEMP 'PowerShell-7.6.6-win-x64.msi'
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
        Write-Host 'Installing PowerShell 7 (msiexec /quiet) ...'
        Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/quiet', '/norestart', 'ADD_PATH=1') -Wait
    }
    catch { Write-Host ('The automatic install did not finish: ' + $_.Exception.Message) }
    if (Test-Path -LiteralPath $installed) { return [pscustomobject]@{ Path = $installed; Manual = '' } }
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return [pscustomobject]@{ Path = $c.Source; Manual = '' } }
    return [pscustomobject]@{ Path = $null; Manual = $manual }
}

function Get-WindowsPackageFiles {
    # the declarative file first, the two JSON import lists as the documented fallback
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $repo = [string]$Context['RepoRoot']
    $manifest = $Context['Manifest']
    $files = New-Object System.Collections.Generic.List[string]
    $declarative = Join-Path $repo 'windows/configuration.winget'
    if (Test-Path -LiteralPath $declarative) { $files.Add('windows/configuration.winget') }
    foreach ($e in @(Get-ManifestField $manifest 'components')) {
        if ([string](Get-ManifestField $e 'type') -ne 'winget') { continue }
        $core = [bool](Get-ManifestField $e 'core')
        if ((-not $core) -and (-not $Context['WithOptional'])) { continue }
        $f = [string](Get-ManifestField $e 'file')
        if ($f -and ($files -notcontains $f)) { $files.Add($f) }
    }
    return $files
}

function Invoke-PackageStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $repo = [string]$Context['RepoRoot']
    $context = $Context
    if ($Context['SkipPackages']) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'per -SkipWinget'; Manual = @() } }

    $files = Get-WindowsPackageFiles -Context $Context
    if ($files.Count -eq 0) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'no package file in the repo'; Manual = @() } }

    if ($Context['TestMode']) {
        $lines = @()
        foreach ($f in $files) {
            $abs = Join-Path $repo $f
            if ($f -like '*.winget') { $lines += ('winget configure --file ' + $abs + ' --accept-configuration-agreements --disable-interactivity') }
            else { $lines += ('winget import ' + $abs + ' --accept-package-agreements --accept-source-agreements --disable-interactivity --no-upgrade') }
        }
        & $Context['SavePreview'] 'winget-packages.txt' (($lines -join "`r`n") + "`r`n")
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/winget-packages.txt'; Manual = @() }
    }

    $w = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $w) {
        return [pscustomobject]@{ Status = 'WARN'; Detail = 'winget is missing on this PC'; Manual = @('install winget (App Installer / Microsoft.WinGet.Client), then run -Resume') }
    }
    if ($Context['DryRun']) {
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = ('DryRun: ' + ($files -join ', ')); Manual = @() }
    }

    # `winget configure` is the declarative route (decision D5). It needs WinGet 1.6 or newer;
    # on an older winget the command is unknown, and then the JSON import lists still work.
    $ok = $true
    $failures = New-Object System.Collections.Generic.List[string]
    $limits = New-Object System.Collections.Generic.List[string]
    $note = ''
    $declarative = 'windows/configuration.winget'
    if ($files -contains $declarative) {
        $abs = Join-Path $repo $declarative
        if (& $Context['ShouldProcess'] ('winget configure ' + $declarative) 'apply the machine configuration') {
            $cfgOut = (& winget configure --file $abs --accept-configuration-agreements --disable-interactivity 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) {
                $tail = (@($cfgOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
                if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
                Write-Host ('  winget configure failed (exit ' + $LASTEXITCODE + '): ' + $tail)
                if ($tail -match 'not a recognized command|0x8A15002B') {
                    # measured on an old winget: the command is unknown there, and the JSON import
                    # lists are the documented route for it. Nothing is missing, so nothing is
                    # reported but the note in the stage's detail.
                    $note = ' (winget configure not available - used the JSON import lists)'
                }
                else {
                    # Any other reason is a limitation of THIS run, not a missing program: the JSON
                    # lists below install the same packages, and the verify check `winget-core` says
                    # whether they arrived. Measured in the first full-setup CI run (2026-10-14):
                    # configure needs an elevated process, the runner has none, and the import lists
                    # still put all 12 programs in place. The reason and the manual step travel with
                    # the stage instead of being swallowed.
                    $limits.Add('winget configure: ' + $tail)
                }
            }
        }
        else { $limits.Add('winget configure not executed (ShouldProcess declined)') }
    }
    # windows/configuration.winget is YAML and belongs to `winget configure`; `winget import`
    # reads JSON. Handing the declarative file to the import lists - what this stage did until
    # 2026-10-14 - fails on the file type and reports nothing about the machine.
    $rest = @($files | Where-Object { $_ -ne $declarative })
    foreach ($f in $rest) {
        $abs = Join-Path $repo $f
        if (& $Context['ShouldProcess'] ('winget import ' + $f) 'install programs') {
            $out = (& winget import $abs --accept-package-agreements --accept-source-agreements --disable-interactivity --no-upgrade 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) {
                $ok = $false
                $tail = (@($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
                if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
                # the reason goes into the job log as well: the transcript lives on the machine
                # that ran it, and on a CI machine nobody reads that file afterwards
                Write-Host ('  winget import ' + $f + ' reported (exit ' + $LASTEXITCODE + '):')
                @($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) | ForEach-Object { Write-Host ('    ' + $_) }
                $failures.Add('winget import ' + $f + ': ' + $tail)
            }
        }
    }
    $detail = ($files -join ', ') + $note
    if (-not $ok) {
        # A machine-wide install needs an elevated process. Naming the exact manual step keeps
        # the failure usable instead of hiding it behind one exit code. The reason the
        # declarative route did not run belongs next to it (review 18: on an ERROR the detail
        # named only the import, so that reason was lost exactly when it mattered).
        $all = @($limits) + @($failures)
        return [pscustomobject]@{ Status = 'ERROR'; Detail = ($all -join ' ; '); Manual = @('some programs install machine-wide: run install.ps1 once from an elevated PowerShell') }
    }
    if ($limits.Count -gt 0) {
        # The manual step does NOT assume elevation: measured on windows-latest (2026-10-14), the
        # declarative route failed there with "Failed to create instance: -2147023174 | Some of the
        # configuration was not applied successfully" while the session WAS elevated (the same run
        # registered the scheduled task including its logon trigger). So the step names both what
        # to try and what it is for.
        return [pscustomobject]@{ Status = 'WARN'; Detail = ($detail + ' - ' + ($limits -join ' ; ')); Manual = @('the declarative configuration did not run: try `winget configure --file windows/configuration.winget` by hand and read winget''s error (some resources install machine-wide and need an elevated PowerShell); the JSON import lists install the same package ids') }
    }
    return [pscustomobject]@{ Status = 'OK'; Detail = $detail; Manual = @() }
}

function Invoke-SchedulerStage {
    # The scheduled task comes from the XML template in windows/scheduled-tasks/. A logon
    # trigger may only be registered by an administrator (measured on this PC: "access denied"
    # with the trigger, accepted without it), so the fallback registers the other triggers and
    # reports the difference instead of hiding it.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $repo = [string]$Context['RepoRoot']
    $entry = $Context['TaskEntry']
    if (-not $entry) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'no task component in the manifest'; Manual = @() } }
    $taskName = [string](Get-ManifestField $entry 'name')
    $tmpl = Join-Path $repo ([string](Get-ManifestField $entry 'file'))
    $xml = Expand-Placeholders ([IO.File]::ReadAllText($tmpl)) $Context['Placeholders']
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'scheduled-task.xml' $xml
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/scheduled-task.xml'; Manual = @() }
    }
    # Register-ScheduledTask takes the XML as a string, and it refuses a declaration that
    # promises UTF-8 while the string is UTF-16 ("(1,40)::ERROR: the encoding cannot be
    # changed", measured 2026-10-12). XML 1.0 makes the declaration optional, so it goes.
    $xml = [regex]::Replace($xml, '^\s*<\?xml[^>]*\?>\s*', '')
    if ($Context['DryRun']) { return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'DryRun: task would be registered'; Manual = @() } }
    try {
        $existingXml = $null
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { $existingXml = (Export-ScheduledTask -TaskName $taskName) }
        if ($existingXml -and (($existingXml -replace '\s+', ' ') -eq ($xml -replace '\s+', ' '))) {
            return [pscustomobject]@{ Status = 'OK'; Detail = 'already registered (identical)'; Manual = @() }
        }
        if (-not (& $Context['ShouldProcess'] $taskName 'register task')) {
            return [pscustomobject]@{ Status = 'SKIP'; Detail = 'not registered (ShouldProcess declined)'; Manual = @() }
        }
        $xmlNoLogon = [regex]::Replace($xml, '<LogonTrigger>.*?</LogonTrigger>', '', 'Singleline')
        $partial = $false
        try { Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null }
        catch {
            if ((Test-WindowsAdmin) -or ($xmlNoLogon -eq $xml)) { throw }
            Register-ScheduledTask -TaskName $taskName -Xml $xmlNoLogon -Force -ErrorAction Stop | Out-Null
            $partial = $true
        }
        # -ErrorAction Stop alone is not enough: the cmdlet can report a rejected XML without
        # throwing, which once printed "registered" for a task that was never created. So the
        # system is asked afterwards.
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            if ($partial) {
                return [pscustomobject]@{ Status = 'WARN'; Detail = 'registered without the logon trigger'; Manual = @('task "' + $taskName + '" has no logon trigger - run install.ps1 once from an administrator PowerShell') }
            }
            return [pscustomobject]@{ Status = 'OK'; Detail = 'registered'; Manual = @() }
        }
        return [pscustomobject]@{ Status = 'WARN'; Detail = 'the system did not keep the registration'; Manual = @('Register task "' + $taskName + '" as administrator: install.ps1 from an admin PowerShell') }
    }
    catch {
        return [pscustomobject]@{ Status = 'WARN'; Detail = ('Admin rights missing? ' + $_.Exception.Message); Manual = @('Register task "' + $taskName + '" as administrator: install.ps1 from an admin PowerShell') }
    }
}

function Test-WindowsAdmin {
    [CmdletBinding()]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-OsExtrasStage {
    # The two machine-level settings that winget configure also declares (LongPathsEnabled) and
    # the firewall rule for Syncthing. Both need an administrator; without one the run reports
    # them as a manual step instead of pretending.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $done = New-Object System.Collections.Generic.List[string]
    $manual = New-Object System.Collections.Generic.List[string]
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'os-extras.txt' ("New-NetFirewallRule -DisplayName 'Syncthing (SyncTrayzor)' -Direction Inbound -Action Allow -Profile Private -Program %APPDATA%\SyncTrayzor\syncthing.exe`r`nSet-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled -Value 1`r`n")
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/os-extras.txt'; Manual = @() }
    }
    if (-not (Test-WindowsAdmin)) {
        return [pscustomobject]@{ Status = 'OK'; Detail = 'needs an administrator'; Manual = @('run again as administrator for: the Syncthing firewall rule, LongPathsEnabled=1 (or let winget configure do it)') }
    }
    if ($Context['DryRun']) { return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'DryRun: firewall rule and LongPathsEnabled would be set'; Manual = @() } }
    try {
        if (-not (Get-NetFirewallRule -DisplayName 'Syncthing (SyncTrayzor)' -ErrorAction SilentlyContinue)) {
            if (& $Context['ShouldProcess'] 'Firewall' 'create Syncthing rule') {
                New-NetFirewallRule -DisplayName 'Syncthing (SyncTrayzor)' -Direction Inbound -Action Allow -Profile Private -Program (Join-Path $env:APPDATA 'SyncTrayzor\syncthing.exe') | Out-Null
                $done.Add('firewall rule')
            }
        }
        else { $done.Add('firewall rule already present') }
    }
    catch { $manual.Add('create the firewall rule "Syncthing (SyncTrayzor)" manually (Inbound/Allow/Private)') }
    try {
        $lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
        if ($lp -ne 1) {
            if (& $Context['ShouldProcess'] 'LongPathsEnabled' 'set to 1') {
                Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
                $done.Add('LongPathsEnabled=1 set')
            }
        }
        else { $done.Add('LongPaths already present') }
    }
    catch { $manual.Add('set LongPathsEnabled=1 manually (registry, as admin)') }
    return [pscustomobject]@{ Status = 'OK'; Detail = ($done -join ', '); Manual = $manual }
}

function Invoke-SyncStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [pscustomobject]@{
        Status = 'OK'
        Detail = 'SyncTrayzor carries the Syncthing service (installed by the package stage)'
        Manual = @('start SyncTrayzor once - it sets up its own autostart; pair the Syncthing devices')
    }
}

function Get-BackupStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    return [pscustomobject]@{
        Status = 'OK'
        Detail = 'Kopia and KopiaUI come from the package stage'
        Manual = @('start KopiaUI once and connect the backup repository - type the password there, it never goes into a file')
    }
}

function Get-PlatformPackagePreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $files = Get-WindowsPackageFiles -Context $Context
    return ('winget configure / winget import: ' + ($files -join ', '))
}

function Invoke-OwnToolsStage {
    # uv and gh come from the package source; trufflehog has no winget package that is
    # maintained, so it comes from its official GitHub release with the SHA256 checked against
    # the checksum file of the same release. Measured 2026-10-14: that release ships
    # trufflehog_<version>_windows_amd64.tar.gz (not the .zip this stage used to look for), so
    # the shape of the names is answered in setup/lib/releases.ps1 like on Linux.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $binDir = Join-Path (Get-PlatformHome) '.local\bin'
    $thPath = Join-Path $binDir 'trufflehog.exe'
    if ($Context['TestMode']) {
        & $Context['SavePreview'] 'own-tools.txt' "uv + gh come from windows/configuration.winget`ntrufflehog: latest GitHub release, checksum file SHA256-verified, unpacked into ~/.local/bin`n"
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'preview/own-tools.txt'; Manual = @() }
    }
    if (Test-Path -LiteralPath $thPath) {
        return [pscustomobject]@{ Status = 'OK'; Detail = 'trufflehog already present (uv/gh via the package stage)'; Manual = @() }
    }
    if ($Context['DryRun']) {
        return [pscustomobject]@{ Status = 'PREVIEW'; Detail = 'DryRun: trufflehog would be downloaded (GitHub, SHA256 verified)'; Manual = @() }
    }
    $manual = @('check PATH: ' + $binDir + ' must be included (uv/trufflehog)')
    try {
        if (-not (& $Context['ShouldProcess'] 'trufflehog' 'download latest release (GitHub)')) {
            return [pscustomobject]@{ Status = 'SKIP'; Detail = 'download not executed (ShouldProcess declined)'; Manual = $manual }
        }
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/trufflesecurity/trufflehog/releases/latest' -Headers (Get-GitHubApiHeaders)
        $asset = Select-ReleaseAsset -Assets $rel.assets -Suffix 'windows_amd64.tar.gz'
        if (-not $asset) { return [pscustomobject]@{ Status = 'WARN'; Detail = ('no asset whose name ends in windows_amd64.tar.gz in release ' + $rel.tag_name); Manual = $manual } }
        $sumAsset = Get-ReleaseChecksumAsset -Assets $rel.assets -AssetName $asset.name
        if (-not $sumAsset) { return [pscustomobject]@{ Status = 'WARN'; Detail = ('release ' + $rel.tag_name + ' carries no checksum for ' + $asset.name + ' - not installed unverified'); Manual = $manual } }
        $archive = Join-Path ([string]$Context['StateDir']) $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -UseBasicParsing
        # a checksum file arrives as bytes when the server types it as a binary (see
        # Convert-ReleaseText - the same defect ended the live install on ubuntu-latest)
        $sumText = Convert-ReleaseText ((Invoke-WebRequest -Uri $sumAsset.browser_download_url -UseBasicParsing).Content)
        $expected = Find-ReleaseChecksum -Text $sumText -AssetName $asset.name
        if (-not $expected) { throw ($sumAsset.name + ' carries no line for ' + $asset.name) }
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) { throw ('SHA256 mismatch: ' + $actual) }
        # Windows ships tar.exe since build 17063 (bsdtar), so the .tar.gz needs no extra tool
        $null = (& tar -xzf $archive -C $binDir 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'unpacking failed' }
        Remove-Item -LiteralPath $archive -Force
        return [pscustomobject]@{ Status = 'OK'; Detail = ('trufflehog ' + $rel.tag_name); Manual = $manual }
    }
    catch {
        return [pscustomobject]@{ Status = 'WARN'; Detail = ('download failed: ' + $_.Exception.Message); Manual = (@('download trufflehog manually (GitHub release, verify SHA256) into ' + $binDir)) }
    }
}

function Test-PackageStage {
    # verify.ps1 asks the platform how to check that the packages are there.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $repo = [string]$Context['RepoRoot']
    $manifest = $Context['Manifest']
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $w) { return [pscustomobject]@{ Status = 'SKIP'; Detail = 'winget is not on PATH'; Missing = @() } }
    $list = (& winget list --accept-source-agreements --disable-interactivity 2>$null | Out-String)
    $missing = New-Object System.Collections.Generic.List[string]
    $wanted = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(Get-ManifestField $manifest 'components')) {
        if ([string](Get-ManifestField $e 'type') -ne 'winget') { continue }
        if (((Get-ManifestField $e 'core') -ne $true)) { continue }
        $file = Join-Path $repo ([string](Get-ManifestField $e 'file'))
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $ids = @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).Sources | ForEach-Object { $_.Packages.PackageIdentifier })
        foreach ($id in $ids) {
            $wanted.Add($id)
            if ($list -notmatch ('(?m)\s' + [regex]::Escape($id) + '\s')) { $missing.Add($id) }
        }
    }
    if ($missing.Count -eq 0) { return [pscustomobject]@{ Status = 'OK'; Detail = ($wanted.Count.ToString() + ' packages present'); Missing = @() } }
    return [pscustomobject]@{ Status = 'FAIL'; Detail = ('missing: ' + ($missing -join ', ')); Missing = $missing }
}

function Test-SchedulerStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    $name = [string]$Context['TaskName']
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($t -and ((Export-ScheduledTask -TaskName $name) -match 'morning\.ps1')) {
        return [pscustomobject]@{ Status = 'OK'; Detail = 'registered'; Missing = @() }
    }
    return [pscustomobject]@{ Status = 'FAIL'; Detail = 'task missing or does not call morning.ps1'; Missing = @() }
}
