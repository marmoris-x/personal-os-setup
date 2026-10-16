# Pester 5.9.1 (pinned - see docs/decisions/0010-test-strategy.md).
# The platform map: setup/platforms.yaml, its rules, and the one place where the Windows
# package inventory is written down twice (windows/configuration.winget for the declarative
# route, windows/winget-core.json for the fallback and for the live verify check).
# Setup goes in BeforeAll: top-level code here would only run during discovery (Pester 5).
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'setup/lib/manifest.ps1')
    . (Join-Path $repoRoot 'setup/lib/platform.ps1')
    . (Join-Path $repoRoot 'setup/lib/placeholders.ps1')
    $manifest = Get-Manifest -Path (Join-Path $repoRoot 'setup/manifest.yaml')
    $platforms = Get-PlatformData -RepoRoot $repoRoot
    $script:oses = @('windows', 'macos', 'linux')
}

Describe 'the platform map' {
    It 'answers for every manifest component on all three systems' {
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($manifest.components)) {
            $id = [string](Get-ManifestField $e 'id')
            foreach ($os in $script:oses) {
                $v = Get-PlatformValue -Platforms $platforms -ComponentId $id -Os $os
                if (-not $v) { $missing.Add($id + ' has no ' + $os + ' entry') }
            }
        }
        $missing.Count | Should -Be 0 -Because ($missing -join '; ')
    }

    It 'names a reason for every unsupported entry' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($manifest.components)) {
            $id = [string](Get-ManifestField $e 'id')
            foreach ($os in $script:oses) {
                $v = Get-PlatformValue -Platforms $platforms -ComponentId $id -Os $os
                if ((Test-PlatformUnsupported $v) -and ((Get-UnsupportedReason $v).Length -lt 10)) {
                    $bad.Add($id + '/' + $os + ' = "' + $v + '"')
                }
            }
        }
        $bad.Count | Should -Be 0 -Because ('an unsupported entry without a real reason: ' + ($bad -join '; '))
    }

    It 'uses a value from the documented vocabulary' {
        $allowed = @('files', 'dirs', 'mcp', 'plugin', 'generated')
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($manifest.components)) {
            $id = [string](Get-ManifestField $e 'id')
            foreach ($os in $script:oses) {
                $v = [string](Get-PlatformValue -Platforms $platforms -ComponentId $id -Os $os)
                if (Test-PlatformUnsupported $v) { continue }
                if ($allowed -contains $v) { continue }
                if ($v -match '^(packages|scheduler|homebrew-service|systemd-user|manual):.+') { continue }
                $bad.Add($id + '/' + $os + ' = "' + $v + '"')
            }
        }
        $bad.Count | Should -Be 0 -Because ($bad -join '; ')
    }

    It 'has a platform block with the settings the engine reads' {
        foreach ($os in $script:oses) {
            foreach ($key in @('id', 'os_name', 'state_dir', 'package_tool', 'package_file', 'scheduler', 'documents', 'default_vault', 'default_dev')) {
                $v = Get-PlatformSetting -Platforms $platforms -Os $os -Key $key
                $v | Should -Not -BeNullOrEmpty -Because ($os + ' needs ' + $key)
            }
        }
    }

    It 'points packages: at a file that exists' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($os in $script:oses) {
            foreach ($entry in @(Get-PlatformPackageEntries -Platforms $platforms -Manifest $manifest -Os $os)) {
                if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $entry.Path))) { $bad.Add($os + ': ' + $entry.Path) }
            }
        }
        $bad.Count | Should -Be 0 -Because ($bad -join '; ')
    }
}

Describe 'the platform placeholder vocabulary' {
    It 'is an identity on Windows and differs elsewhere' {
        # This is what keeps the live system untouched: export replaces the Windows text with
        # the token, install renders the token back to the SAME text. If one of these ever
        # differs, every mirrored file changes on the next install.
        foreach ($e in @(Get-PlatformPlaceholderTable -Os 'windows')) {
            $pairs = @(Get-PlatformExportPairs -Os 'windows' | Where-Object { $_.to -eq ('{{' + $e.token + '}}') })
            $pairs.Count | Should -BeGreaterThan 0 -Because ($e.token + ' has no live source text on Windows')
            foreach ($p in $pairs) { $p.from | Should -BeExactly $e.value -Because ($e.token + ' would not round-trip') }
        }
    }

    It 'renders every token to something non-empty on every system' {
        foreach ($os in $script:oses) {
            $map = Get-PlatformPlaceholderMap -Os $os
            $map.Count | Should -BeGreaterThan 0
            foreach ($k in $map.Keys) { $map[$k] | Should -Not -BeNullOrEmpty -Because ($os + ' ' + $k) }
        }
    }

    It 'answers the same tokens on all three systems' {
        $a = @(Get-PlatformPlaceholderNames)
        foreach ($os in @('macos', 'linux')) {
            $b = @(Get-PlatformPlaceholderMap -Os $os).Keys | ForEach-Object { $_ -replace '[{}]', '' }
            ($b | Sort-Object) -join ',' | Should -BeExactly (($a | Sort-Object) -join ',') -Because ($os + ' must know the same tokens')
        }
    }

    It 'renders every mirrored PowerShell file into something that parses' {
        # Measured 2026-10-14: "TEMP_ENV = [IO.Path]::GetTempPath()" made two files unparseable on
        # macOS and Linux - a method call is not a valid command argument, and one live file even
        # assigns to the variable the token stands for. This test renders every mirrored .ps1 of
        # every system and parses the result, so the next such value is red here and not in CI.
        Import-Module powershell-yaml -ErrorAction Stop
        $cfg = @{}
        $loaded = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/personal.dummy.yaml') -Raw)
        if ($loaded -is [System.Collections.IDictionary]) { foreach ($k in $loaded.Keys) { $cfg[[string]$k] = $loaded[$k] } }
        else { foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
        $roots = @{
            windows = @{ HOME = 'C:\Users\check'; DOCUMENTS = 'C:\Users\check\Documents'; VAULT = 'C:\PersonalOS'; DEV = 'C:\Dev' }
            macos   = @{ HOME = '/Users/check'; DOCUMENTS = '/Users/check/Documents'; VAULT = '/Users/check/PersonalOS'; DEV = '/Users/check/Dev' }
            linux   = @{ HOME = '/home/check'; DOCUMENTS = '/home/check/Documents'; VAULT = '/home/check/PersonalOS'; DEV = '/home/check/Dev' }
        }
        $mirrorRoots = @('home', 'home/Documents', 'vault', 'dev')
        $bad = New-Object System.Collections.Generic.List[string]
        $count = 0
        # A Windows-shaped root cannot even be built on another host: Get-PlaceholderMap asks
        # Split-Path for the folder above DOCUMENTS, and PowerShell on Linux reads
        # "C:\Users\check\Documents" as a drive that does not exist (DriveNotFoundException,
        # measured in the ubuntu job 2026-10-14). Those rows are checked by the job that runs on
        # that system - the same division the guard suites use, and the reason the macOS/Linux
        # rows are the valuable ones here: they are what found the missing {{*_BASH}} tokens on
        # a Windows host in the first place.
        $hostOs = Get-PlatformId
        if ($hostOs -ne 'windows') { Write-Host ('    (the windows row of this test needs a Windows host - it runs in the windows CI job)') }
        foreach ($os in @($script:oses | Where-Object { ($_ -ne 'windows') -or ($hostOs -eq 'windows') })) {
            $map = Get-PlaceholderMap -Roots $roots[$os] -ConfigValues $cfg -Os $os
            foreach ($mirror in $mirrorRoots) {
                $src = Join-Path $repoRoot $mirror
                if (-not (Test-Path -LiteralPath $src)) { continue }
                foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Filter '*.ps1')) {
                    $count++
                    $errs = $null
                    $null = [System.Management.Automation.Language.Parser]::ParseInput((Expand-Placeholders ([IO.File]::ReadAllText($f.FullName)) $map), [ref]$null, [ref]$errs)
                    foreach ($e in @($errs)) {
                        $bad.Add($os + ' ' + $f.Name + ' L' + $e.Extent.StartLineNumber + ': ' + $e.Message)
                    }
                }
            }
        }
        $count | Should -BeGreaterThan 0
        $bad.Count | Should -Be 0 -Because (($bad | Select-Object -First 5) -join ' | ')
    }

    It 'leaves no placeholder behind in the rendered mirror of any system' {
        # Measured 2026-10-14 in the ubuntu CI job: Convert-PathStyle dropped the bash spelling
        # of a path that does not start with a drive letter (/home/runner/Dev), so {{DEV_BASH}}
        # and {{HOME_BASH}} never entered the map. The mirror files carry them (the git-bash
        # spelling of the dev and home folders in settings.json and in the guard tests), and the
        # installed files kept the raw token. A local test install could not see it: in test mode
        # the roots are Windows paths, so the token existed.
        # This test renders every text file of the mirror for all three systems with the roots
        # that system really has, and fails on any token that survives.
        Import-Module powershell-yaml -ErrorAction Stop
        $cfg = @{}
        $loaded = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/personal.dummy.yaml') -Raw)
        if ($loaded -is [System.Collections.IDictionary]) { foreach ($k in $loaded.Keys) { $cfg[[string]$k] = $loaded[$k] } }
        else { foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
        $roots = @{
            windows = @{ HOME = 'C:\Users\check'; DOCUMENTS = 'C:\Users\check\Documents'; VAULT = 'C:\PersonalOS'; DEV = 'C:\Dev' }
            macos   = @{ HOME = '/Users/check'; DOCUMENTS = '/Users/check/Documents'; VAULT = '/Users/check/PersonalOS'; DEV = '/Users/check/Dev' }
            linux   = @{ HOME = '/home/check'; DOCUMENTS = '/home/check/Documents'; VAULT = '/home/check/PersonalOS'; DEV = '/home/check/Dev' }
        }
        # runtime tokens of other tools: they are none of this vocabulary's business (see
        # docs/decisions/0003 and the same list in setup/verify.ps1)
        $runtimeTokens = @('{{N_SOURCES}}')
        # render-time tokens: install.ps1 fills them from its own journal, and only the
        # install-once skeletons (*.tmpl) may carry them (ADR 0003; measured 2026-10-14: exactly
        # the three vault/000-meta/*.md.tmpl do). They are expected there and nowhere else.
        $renderTokens = @('{{INSTALL_DATE}}', '{{USER_SID}}', '{{START_BOUNDARY}}')
        $binExt = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.pyc')
        $mirrorRoots = @('home', 'home/Documents', 'vault', 'dev')
        $bad = New-Object System.Collections.Generic.List[string]
        $count = 0
        # same host rule as the parse test above: a Windows-shaped root needs a Windows host
        $hostOs = Get-PlatformId
        foreach ($os in @($script:oses | Where-Object { ($_ -ne 'windows') -or ($hostOs -eq 'windows') })) {
            $map = Get-PlaceholderMap -Roots $roots[$os] -ConfigValues $cfg -Os $os
            foreach ($mirror in $mirrorRoots) {
                $src = Join-Path $repoRoot $mirror
                if (-not (Test-Path -LiteralPath $src)) { continue }
                foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File)) {
                    if ($binExt -contains $f.Extension.ToLowerInvariant()) { continue }
                    $count++
                    $allowed = $runtimeTokens
                    if ($f.Name.EndsWith('.tmpl')) { $allowed = $allowed + $renderTokens }
                    $text = Expand-Placeholders ([IO.File]::ReadAllText($f.FullName)) $map
                    foreach ($m in [regex]::Matches($text, '\{\{[A-Z0-9_]+\}\}')) {
                        if ($allowed -notcontains $m.Value) { $bad.Add($os + ' ' + $f.FullName.Substring($repoRoot.Length + 1) + ': ' + $m.Value) }
                    }
                }
            }
        }
        $count | Should -BeGreaterThan 0
        $bad.Count | Should -Be 0 -Because (($bad | Select-Object -Unique | Select-Object -First 5) -join ' | ')
    }
}

Describe 'the Windows package inventory' {
    It 'lists the same package ids in both files' {
        # windows/configuration.winget is the declarative route install.ps1 prefers;
        # windows/winget-core.json is the fallback for an older winget AND the list the live
        # verify check reads. Two files, one inventory - this test is what keeps them equal.
        $jsonFile = Join-Path $repoRoot 'windows/winget-core.json'
        $fromJson = @((Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json).Sources | ForEach-Object { $_.Packages.PackageIdentifier } | Sort-Object)
        $lines = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/configuration.winget')
        $fromWinget = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s{8}id:\s*(\S+)\s*$') { $fromWinget += $Matches[1] }
        }
        $fromWinget = @($fromWinget | Sort-Object)
        $fromWinget.Count | Should -BeGreaterThan 0
        ($fromWinget -join ',') | Should -BeExactly (($fromJson -join ',')) -Because 'the two package files must name the same programs'
    }
}

Describe 'the Windows package stage' -Skip:(-not $IsWindows) {
    # Measured in the first full-setup CI run (2026-10-14, run 38579290413): `winget configure`
    # failed on the runner, and the fallback then handed windows/configuration.winget - a YAML
    # file - to `winget import`, which reads JSON. The stage ended as an error whose text named
    # neither the file nor a reason ("winget import exit 0"): the loop read $LASTEXITCODE long
    # after the failing command had run. This test drives the stage against a stub winget whose
    # answers are the runner's, so the shape is measured instead of read.
    BeforeAll {
        . (Join-Path $repoRoot 'setup/platform/windows.ps1')
        $script:scratch = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
        $script:stubDir = Join-Path $script:scratch 'win-packages'
        $null = New-Item -ItemType Directory -Force -Path $script:stubDir
        $script:stubLog = Join-Path $script:stubDir 'calls.txt'
        Remove-Item -LiteralPath $script:stubLog -Force -ErrorAction SilentlyContinue
        # The stub answers from little files, so one test can make configure fail with the
        # runner's words and another with "not a recognized command" (an older winget - review 18
        # measured that this branch had no test at all).
        $script:cfgText = Join-Path $script:stubDir 'configure.txt'
        $script:cfgExit = Join-Path $script:stubDir 'configure-exit.txt'
        $script:impText = Join-Path $script:stubDir 'import.txt'
        $script:impExit = Join-Path $script:stubDir 'import-exit.txt'
        function Set-StubAnswers([string]$configureText, [int]$configureExit, [string]$importText, [int]$importExit) {
            [IO.File]::WriteAllText($script:cfgText, $configureText, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($script:cfgExit, [string]$configureExit, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($script:impText, $importText, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($script:impExit, [string]$importExit, (New-Object Text.UTF8Encoding($false)))
        }
        Set-StubAnswers 'This configuration requires administrator privileges.' 1 'Successfully installed' 0
        $stub = @(
            '@echo off'
            'setlocal enabledelayedexpansion'
            'echo %1^|%2>> "' + $script:stubLog + '"'
            'if "%1"=="configure" ('
            '  type "' + $script:cfgText + '"'
            '  set /p code=<"' + $script:cfgExit + '"'
            '  exit /b !code!'
            ')'
            'type "' + $script:impText + '"'
            'set /p code=<"' + $script:impExit + '"'
            'exit /b !code!'
        ) -join "`r`n"
        [IO.File]::WriteAllText((Join-Path $script:stubDir 'winget.cmd'), $stub, (New-Object Text.UTF8Encoding($false)))
        $script:pathBefore = $env:PATH
        $env:PATH = $script:stubDir + [IO.Path]::PathSeparator + $env:PATH
        $script:ctx = @{
            RepoRoot      = $repoRoot
            Manifest      = $manifest
            SkipPackages  = $false
            TestMode      = $false
            DryRun        = $false
            WithOptional  = $false
            StateDir      = $script:stubDir
            SavePreview   = { param($n, $c) }
            ShouldProcess = { param($t, $a) $true }
        }
    }
    AfterAll {
        $env:PATH = $script:pathBefore
    }

    It 'never hands the declarative .winget file to winget import' {
        $null = Invoke-PackageStage -Context $script:ctx
        $calls = @(Get-Content -LiteralPath $script:stubLog)
        $imported = @($calls | Where-Object { $_ -like 'import|*' }) -join ' '
        $imported | Should -Not -Match 'configuration\.winget' -Because 'that file is YAML; winget import reads JSON and fails on it for a reason that has nothing to do with the machine'
        $imported | Should -Match 'winget-core\.json' -Because 'the JSON import list is the documented fallback and must still run'
    }

    It 'reports a failed configure as a named limitation with its reason' {
        $result = Invoke-PackageStage -Context $script:ctx
        $result.Status | Should -BeExactly 'WARN' -Because 'the JSON lists install the packages; the declarative route is the part this run could not do'
        $result.Detail | Should -Match 'administrator privileges' -Because 'the words winget itself used must survive into the report'
        $result.Manual.Count | Should -BeGreaterThan 0 -Because 'a limitation without the step that removes it is half a report'
    }

    It 'treats an unrecognized configure command as the documented fallback, not as a limitation' {
        # An older winget does not know the command at all; there the JSON import lists ARE the
        # route, so the stage reports OK and says which route it used.
        Set-StubAnswers "The command 'configure' is not a recognized command. 0x8A15002B" 1 'Successfully installed' 0
        try {
            $result = Invoke-PackageStage -Context $script:ctx
            $result.Status | Should -BeExactly 'OK' -Because 'nothing is missing when the fallback is the documented route for that winget'
            $result.Detail | Should -Match 'winget configure not available' -Because 'the report says which route ran'
        }
        finally { Set-StubAnswers 'This configuration requires administrator privileges.' 1 'Successfully installed' 0 }
    }

    It 'keeps the configure reason when a JSON import really fails' {
        # Review 18: on an ERROR the detail named only the import, so the reason the declarative
        # route did not run was lost exactly when the report matters most.
        Set-StubAnswers 'Failed to create instance: -2147023174' 1 'Error: no package found matching input criteria.' 1
        try {
            $result = Invoke-PackageStage -Context $script:ctx
            $result.Status | Should -BeExactly 'ERROR' -Because 'an import that failed can leave programs missing'
            $result.Detail | Should -Match 'no package found matching input criteria' -Because 'the import names its own reason'
            $result.Detail | Should -Match 'Failed to create instance' -Because 'and the configure reason belongs next to it'
        }
        finally { Set-StubAnswers 'This configuration requires administrator privileges.' 1 'Successfully installed' 0 }
    }
}

Describe 'the macOS package stage' {
    # The second full-setup run (2026-10-14, run 38584744785) reported
    # "brew bundle exit 1: Installing obsidian | Installing kopiaui | `brew bundle` failed!
    # 1 Brewfile dependency failed to install" - the last three lines, which name neither the
    # entry nor the reason. brew marks both with an "Error:" line.
    BeforeAll {
        . (Join-Path $repoRoot 'setup/platform/macos.ps1')
    }

    It 'prefers the lines brew marks as an error over the last three' {
        $recorded = @(
            'Tapping homebrew/bundle'
            'Installing obsidian'
            'Installing kopiaui'
            'Error: homebrew/bundle was not tapped: the command is built into Homebrew'
            '`brew bundle` failed! 1 Brewfile dependency failed to install'
        ) -join "`n"
        $detail = Get-MacosBrewFailureDetail -Output $recorded
        $detail | Should -Match 'Error: homebrew/bundle' -Because 'the marked line names the entry; the summary line does not'
        $detail | Should -Not -Match 'failed! 1 Brewfile dependency' -Because 'the summary is what the report already said'
    }

    It 'falls back to the last three lines when brew marks nothing' {
        $recorded = @('Installing obsidian', 'Installing kopiaui', '`brew bundle` failed! 1 Brewfile dependency failed to install') -join "`n"
        (Get-MacosBrewFailureDetail -Output $recorded) | Should -BeExactly 'Installing obsidian | Installing kopiaui | `brew bundle` failed! 1 Brewfile dependency failed to install'
    }

    It 'keeps default taps out of the Brewfile' {
        # `brew tap` never lists a default tap, so a `tap "homebrew/cask"` line would make the
        # live verify report a missing package forever (measured on macos-latest: the tap line
        # was the one entry `brew bundle` failed on, and `brew tap` listed homebrew/cask but not
        # homebrew/bundle). A third-party tap in this list would be fine.
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($line in @(Get-Content -LiteralPath (Join-Path $repoRoot 'macos/Brewfile'))) {
            $m = [regex]::Match($line, '^\s*tap\s+"([^"]+)"')
            if ($m.Success -and ($m.Groups[1].Value -in @('homebrew/core', 'homebrew/cask', 'homebrew/bundle'))) { $bad.Add($m.Groups[1].Value) }
        }
        $bad.Count | Should -Be 0 -Because ('a default tap needs no tapping and cannot be verified: ' + ($bad -join ', '))
    }
}

Describe 'the launch agent on macOS' {
    # install writes <label>.plist into ~/Library/LaunchAgents and loads it by that label, and
    # verify asks launchctl for the same label. Until the first full-setup CI run the two used
    # different sources: verify took the manifest's `name` ("Life OS Morning"), install the
    # manifest's `label` with its own default - so a live verify on macOS could never be green.
    # The label lives in ONE function now, and this suite says what it has to be.
    BeforeAll {
        . (Join-Path $repoRoot 'setup/platform/macos.ps1')
        $script:taskEntry = @($manifest.components | Where-Object { [string](Get-ManifestField $_ 'type') -eq 'task' })[0]
        $script:macCtx = @{ TaskEntry = $script:taskEntry; RepoRoot = $repoRoot }
    }

    It 'names the label the plist is stored under' {
        $label = Get-MacosLaunchAgentLabel -Context $script:macCtx
        $label | Should -BeExactly 'com.personal-os.life-os-morning'
        Test-Path -LiteralPath (Join-Path $repoRoot ('macos/launchagents/' + $label + '.plist.tmpl')) |
            Should -BeTrue -Because 'the label IS the file name of the launch agent template'
    }

    It 'has install and verify ask for it through the same function' {
        # A witness, not a behaviour test: the behaviour needs a Mac. What it guards is the
        # shape that broke - one side reading a different field than the other.
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'setup/platform/macos.ps1'))
        ([regex]::Matches($text, 'Get-MacosLaunchAgentLabel -Context')).Count |
            Should -BeGreaterOrEqual 2 -Because 'both the install stage and the verify check ask for the label'
        $text | Should -Not -Match "\`$Context\['TaskName'\]" -Because 'TaskName is the manifest name, not the launchd label'
    }
}

Describe 'the PATH folders of a machine (Get-PlatformToolDirs)' {
    # Measured on the windows-latest runner (2026-10-14, the tag run of v2.3.2):
    # the function returned its two folders as ONE value - a nested array stringifies with the
    # output field separator - so the runner's PATH got a single entry "C:\...\.local\bin
    # C:\...\WinGet\Links" instead of two, and the live verify then reported
    # "own-tools - not in PATH: uv, trufflehog" for programs the install had just written.
    # The function's own output line was the evidence: "PATH carries A B: False (exists: True True)".
    It 'hands back one folder per element, never a nested array' {
        foreach ($os in @('windows', 'linux', 'macos')) {
            $dirs = @(Get-PlatformToolDirs -Os $os)
            $dirs.Count | Should -BeGreaterOrEqual 1 -Because ($os + ' has at least the .local/bin of the release installs')
            foreach ($d in $dirs) {
                # a nested array stringifies with a space between its parts, which is exactly
                # the shape the runner printed
                $d | Should -BeOfType [string] -Because ($os + ': every entry must be one path, not a list of paths')
                $d | Should -Not -Match ' ' -Because ($os + ': a path with a space here is two paths joined by the output field separator')
            }
        }
        @(Get-PlatformToolDirs -Os 'linux').Count | Should -Be 1 -Because 'the Unix systems have no winget Links folder'
        if ($env:LOCALAPPDATA) {
            @(Get-PlatformToolDirs -Os 'windows').Count | Should -Be 2 -Because 'Windows adds winget''s Links folder for the portable-package shims'
        }
    }
}

Describe 'the Life OS python pin' {
    # Measured 2026-10-16: ctranslate2 4.8.2 ships wheels up to cp314 and stops (PyPI JSON,
    # pypi.org/pypi/ctranslate2/4.8.2/json), Python 3.15.0 came out 2026-10-09 and Homebrew's
    # `python` formula already points at it. Three places must agree or a fresh Mac fails the
    # venv on "No matching distribution found for ctranslate2": the two pins (which version is
    # INSTALLED) and the candidate list in setup/lib/platform.ps1 (which interpreter builds the
    # VENV). The wheel ceiling is the number those three have to stay under.
    It 'keeps the two pins, the resolver candidates and the wheel ceiling in agreement' {
        $max = Get-PlatformLifeOsPythonMaxMinor
        $brew = [regex]::Match([IO.File]::ReadAllText((Join-Path $repoRoot 'macos/Brewfile')), 'brew "python@3\.(\d+)"')
        $brew.Success | Should -BeTrue -Because 'macos/Brewfile must pin python@3.<minor>'
        $pinned = [int]$brew.Groups[1].Value
        $pinned | Should -BeLessOrEqual $max -Because ('the installed python must not be newer than the newest ctranslate2 wheel (3.' + $max + ')')
        $winget = [IO.File]::ReadAllText((Join-Path $repoRoot 'windows/winget-core.json'))
        @([regex]::Matches($winget, '"Python\.Python\.3\.(\d+)"')).Count | Should -Be 1 -Because 'the winget inventory pins exactly one python version'
        [int]([regex]::Match($winget, '"Python\.Python\.3\.(\d+)"').Groups[1].Value) | Should -Be $pinned -Because 'both pins name the same version'
        $dsc = [IO.File]::ReadAllText((Join-Path $repoRoot 'windows/configuration.winget'))
        [int]([regex]::Match($dsc, 'Python\.Python\.3\.(\d+)').Groups[1].Value) | Should -Be $pinned -Because 'the declarative route and the fallback inventory name the same package'
        ((Get-PlatformLifeOsPythonCandidates -Os 'macos')[0] -join ' ') | Should -BeExactly ('python3.' + $pinned) -Because 'the first macOS candidate is the pin'
        ((Get-PlatformLifeOsPythonCandidates -Os 'windows')[0] -join ' ') | Should -BeExactly ('py -3.' + $pinned) -Because 'the first Windows candidate is the pin'
    }

    It 'orders every candidate list pin first, bare PATH python last' {
        # The order IS the preference rule of Get-PlatformLifeOsPython; a reordering here
        # changes which interpreter builds the venv.
        $expected = @{
            windows = 'py -3.13 ; py -3.14 ; python'
            macos   = 'python3.13 ; /opt/homebrew/opt/python@3.13/bin/python3.13 ; /usr/local/opt/python@3.13/bin/python3.13 ; python3.14 ; python3'
            linux   = 'python3.13 ; python3.14 ; python3 ; python'
        }
        foreach ($os in $script:oses) {
            $flat = @((Get-PlatformLifeOsPythonCandidates -Os $os) | ForEach-Object { @($_) -join ' ' })
            ($flat -join ' ; ') | Should -BeExactly $expected[$os] -Because ($os + ': the list order decides which interpreter wins')
        }
    }
}

Describe 'the Life OS python resolver (Get-PlatformLifeOsPython)' {
    # The defect these cases pin: measured 2026-10-16, a fresh Mac resolves `python3` to 3.15
    # while ctranslate2 ships wheels up to cp314 only, and the old code took `python3` from
    # PATH, so the whole venv died on a package error that names no cause. The fakes below
    # stand in for interpreters of hosts that cannot be reached from here: each one ANSWERS the
    # version probe like a real python, sits in front of PATH, and is judged through
    # Get-Command exactly like production.
    BeforeAll {
        $script:hostOs = Get-PlatformId
        $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
        $script:fakeDir = Join-Path $scratchRoot 'python-fakes'
        if (Test-Path -LiteralPath $script:fakeDir) { Remove-Item -LiteralPath $script:fakeDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $script:fakeDir | Out-Null

        function New-FakePython([string]$Name, [string]$Version) {
            # Version '' writes a dead interpreter: it exists, runs, and fails - like a py
            # launcher whose requested version is not installed
            if ($script:hostOs -eq 'windows') {
                $p = Join-Path $script:fakeDir ($Name + '.cmd')
                $text = if ($Version) { '@echo ' + $Version + "`r`n" } else { "@exit /b 1`r`n" }
            }
            else {
                $p = Join-Path $script:fakeDir $Name
                $text = if ($Version) { "#!/bin/sh`necho $Version`n" } else { "#!/bin/sh`nexit 1`n" }
            }
            [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding($false)))
            if ($script:hostOs -ne 'windows') { & chmod +x $p | Out-Null }
        }

        function Invoke-Resolved([hashtable]$Fakes) {
            # one fake per candidate NAME of this host (missing entry = dead), the folder in
            # front of PATH, resolve, PATH back
            $names = @((Get-PlatformLifeOsPythonCandidates -Os $script:hostOs) | ForEach-Object { @($_)[0] } | Select-Object -Unique)
            foreach ($n in $names) { New-FakePython -Name $n -Version ([string]$Fakes[$n]) }
            $saved = $env:PATH
            try {
                $env:PATH = $script:fakeDir + [IO.Path]::PathSeparator + $saved
                return (Get-PlatformLifeOsPython -Os $script:hostOs)
            }
            finally { $env:PATH = $saved }
        }

        $script:pinName = if ($script:hostOs -eq 'windows') { 'py' } else { 'python3.13' }
        $script:pinCommand = if ($script:hostOs -eq 'windows') { 'py -3.13' } else { 'python3.13' }
        $script:fallbackName = if ($script:hostOs -eq 'windows') { 'python' } else { 'python3' }
    }

    It 'takes the pinned 3.13 when both the pin and an older fallback answer' {
        # the fallback answers too, so this fails if the resolver ever takes the PATH python
        # before the pin - the preference, not mere availability
        $fakes = @{}
        $fakes[$script:pinName] = '3.13'
        $fakes[$script:fallbackName] = '3.12'
        $py = Invoke-Resolved $fakes
        $py | Should -Not -BeNullOrEmpty
        $py.ContainsKey('TooNew') | Should -BeFalse
        $py.Version | Should -BeExactly '3.13'
        $py.Command | Should -BeExactly $script:pinCommand -Because 'the pin must win before any PATH python is asked'
    }

    It 'reports TooNew when only a python newer than the wheels answers' {
        $fakes = @{}
        $fakes[$script:pinName] = '3.15'
        $py = Invoke-Resolved $fakes
        $py | Should -Not -BeNullOrEmpty
        $py.ContainsKey('TooNew') | Should -BeTrue -Because 'a 3.15 cannot build the venv and must not be handed back as usable'
        $py.TooNew | Should -BeExactly '3.15'
        $py.Command | Should -BeExactly $script:pinCommand
        $py.ContainsKey('Argv') | Should -BeFalse -Because 'the caller aborts on TooNew; it must never find an argv to run'
    }

    It 'walks past the too-new interpreter to an older one that works' {
        $fakes = @{}
        $fakes[$script:pinName] = '3.15'
        $fakes[$script:fallbackName] = '3.12'
        $py = Invoke-Resolved $fakes
        $py | Should -Not -BeNullOrEmpty
        $py.ContainsKey('TooNew') | Should -BeFalse
        $py.Version | Should -BeExactly '3.12'
        $py.Command | Should -BeExactly $script:fallbackName -Because '3.12 still has ctranslate2 wheels, so the venv may use it'
    }

    It 'returns nothing when no candidate answers' {
        $py = Invoke-Resolved @{}
        $py | Should -BeNullOrEmpty -Because 'the caller reports a manual step on $null'
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:fakeDir) { Remove-Item -LiteralPath $script:fakeDir -Recurse -Force }
    }
}
