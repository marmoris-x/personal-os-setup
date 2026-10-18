# Pester 5.9.1 (pinned). End-to-end on a test target under tests/_tmp:
# install -> verify -> second run is a no-op -> -Force gate -> restore; plus: no {{...}}
# leftovers in a fresh target, verify catches an unrendered copy file, -Components and
# -Profile minimal narrow the install (order item 5.4), and the Life OS venv stage keeps
# reading pip's exit code (the silent OK the first full-setup run found).
# Runs everywhere (CI included); the target is our own scratch folder.
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $fixture = Join-Path $PSScriptRoot 'fixtures\personal.dummy.yaml'
    # check.ps1 hands its own work folder over: two runs at the same time must not delete each
    # other's target (review 5, finding 7). Without it, the folder below tests\_tmp is used.
    $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $tmpRoot = Join-Path $scratchRoot 'install-e2e'
    $target = Join-Path $tmpRoot 'target'
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    function Invoke-Install {
        param([switch]$Force, [string]$Dir = $target, [string[]]$Extra)
        $a = @('-TargetRoot', $Dir, '-ConfigPath', $fixture, '-NonInteractive')
        if ($Force) { $a += '-Force' }
        if ($Extra) { $a += $Extra }
        $out = & pwsh -NoProfile -File (Join-Path $repoRoot 'install.ps1') @a 2>&1 | Out-String
        return @{ out = $out; code = $LASTEXITCODE }
    }
}

Describe 'the Life OS venv stage' {
    # Measured in the first full-setup CI run (2026-10-14): on macos-latest the pip install
    # failed ("No matching distribution found for nvidia-cublas-cu12") and the stage still
    # reported OK - it never asked pip how it ended. The behaviour itself needs a live machine
    # (the stage installs into the real venv), so this suite holds the two shapes that made it
    # silent: pip's exit code is read, and the CUDA-only pins stay off macOS.
    It 'reads pip exit code and names the failure instead of reporting OK' {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.ps1'))
        $block = [regex]::Match($text, "pipOut.*?Add-Result 'life-os-venv'.*?\n", 'Singleline').Value
        $block | Should -Not -BeNullOrEmpty -Because 'the venv stage must capture what pip said'
        $block | Should -Match '\$LASTEXITCODE -ne 0' -Because 'a native program reports failure through its exit code, not through an exception'
        $block | Should -Match "Add-Result 'life-os-venv' 'WARN'" -Because 'a failed pip install must not come back as OK'
    }

    It 'keeps the CUDA-only pins off macOS, where no such wheel exists' {
        $req = Join-Path $repoRoot 'home/.claude/life-os/requirements.txt'
        foreach ($pin in @('nvidia-cublas-cu12', 'nvidia-cuda-nvrtc-cu12', 'nvidia-cudnn-cu12')) {
            $line = @(Get-Content -LiteralPath $req | Where-Object { $_ -match ('^' + [regex]::Escape($pin) + '==') })
            $line.Count | Should -Be 1 -Because ($pin + ' must appear exactly once')
            $line[0] | Should -Match 'sys_platform != "darwin"' -Because 'pip stops at the first wheel it cannot find, and that stopped the whole venv'
        }
    }

    It 'aborts with a named cause when the found python is newer than the wheels' {
        # Measured 2026-10-16: the stage called `python3` from PATH, and a fresh Mac resolves
        # that to 3.15 while ctranslate2 ships wheels up to cp314 only - pip then failed the
        # whole venv on a message that names no cause. The stage must resolve through
        # Get-PlatformLifeOsPython and turn TooNew into a clear abort with a manual step.
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.ps1'))
        $text | Should -Not -Match 'Get-PlatformPythonCommand' -Because 'the bare PATH python is exactly what resolved to 3.15'
        $block = [regex]::Match($text, "Get-PlatformLifeOsPython.*?Add-Result 'life-os-venv' 'WARN'", 'Singleline').Value
        $block | Should -Not -BeNullOrEmpty -Because 'the venv stage must ask the resolver'
        $block | Should -Match "ContainsKey\('TooNew'\)"
        $block | Should -Match "Add-Result 'life-os-venv' 'ERROR'" -Because 'a python that cannot build the venv is an error, not a warning'
        $block | Should -Match 'Add-Manual' -Because 'the abort must tell the person what to install'
    }

    It 'reports a stage that throws as an ERROR line and keeps going (behaviour, not text)' {
        # Measured on ubuntu-latest (2026-10-14, run 38584744785): the release install threw a
        # parameter binding error and the whole run ended there - the install printed 6 of its 15
        # stage lines (review 18 counted them). And review 18 measured that a witness test only
        # grepping for the word "catch" stayed GREEN on a copy where the try/catch was replaced by
        # a comment and dead code. So the function is lifted out of install.ps1 and really called
        # here, with stubs standing in for its neighbours.
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.ps1'))
        $fnText = [regex]::Match($text, '(?s)function Invoke-PlatformStage.*?\r?\n\}').Value
        $fnText | Should -Not -BeNullOrEmpty
        $script:seen = New-Object System.Collections.Generic.List[string]
        function Add-Result { param($l, $s, $d) $script:seen.Add($l + ' ' + $s) }
        function Add-Manual { param($m) }
        function Test-StageSelected { param($id) return $true }
        function Test-StageDone { param($s) return $false }
        function Save-Journal { param($s) $script:seen.Add('journal ' + $s) }
        $script:platformCtx = @{}
        . ([scriptblock]::Create($fnText))
        function Invoke-BrokenStage { param([hashtable]$Context) throw 'the stage blew up' }
        function Invoke-FineStage { param([hashtable]$Context) return [pscustomobject]@{ Status = 'OK'; Detail = 'done'; Manual = @() } }
        { Invoke-PlatformStage 'x' 'Invoke-BrokenStage' 'packages' 'packages' } | Should -Not -Throw -Because 'one stage throwing must not end the run'
        ($script:seen -join '; ') | Should -Match 'packages ERROR' -Because 'the reason belongs in the stage table'
        ($script:seen -join '; ') | Should -Not -Match 'journal' -Because 'a stage that threw must not look done to -Resume'
        { Invoke-PlatformStage 'y' 'Invoke-FineStage' 'files' 'files' } | Should -Not -Throw
        ($script:seen -join '; ') | Should -Match 'files OK' -Because 'the stages after a broken one still run'
        ($script:seen -join '; ') | Should -Match 'journal y'
    }

    # NOT here on purpose: a test for "the venv stage journals only on success". The defect
    # review 18 found was a REACHABILITY one - the single Save-Journal sat after the if/else, so
    # it ran on the WARN path too - and no reading of the text can see that; a text witness would
    # stay green on the broken code, which review 18 measured about the old "catch" witness. The
    # fix is therefore guarded by the reviewer's own re-measurement (and by the code comment).
}

Describe 'install -> verify -> reinstall -> restore (test target)' {
    # The files of the target tree are counted without the installer's own state folder. The
    # filter is a regex over both separators: "-notlike '*\.install-state\*'" only matched on
    # Windows, so on Linux the journal and the previews counted as installed files and two
    # cases here failed in the ubuntu job (measured 2026-10-14: "Expected 1, but got 5" and
    # "a dry run must not write the target tree, but got 8").
    It 'installs into an empty target' {
        $r = Invoke-Install
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'INSTALL-OK'
        $files = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.install-state[\\/]' })
        # a floor, not the exact number: the three systems install slightly different trees
        # (measured 2026-10-14: 132 files on Windows, 130 on Linux). The exact count per system
        # is the platform map's and acceptance check J's business, not this test's.
        $files.Count | Should -BeGreaterThan 125
    }

    It 'leaves no install placeholder anywhere in the target (copy files are rendered too)' {
        # Only the install vocabulary counts: Obsidian templates legitimately carry tokens
        # like {{DATE}}. The keys come from the same builder install.ps1 uses.
        . (Join-Path $repoRoot 'setup\lib\placeholders.ps1')
        . (Join-Path $repoRoot 'setup\lib\manifest.ps1')
        # platform.ps1 answers Get-PlatformId, which Get-PlaceholderMap asks for the platform
        # half of the vocabulary. check.ps1 has it loaded already; a run of this file alone
        # does not, and that must not decide whether the test passes.
        . (Join-Path $repoRoot 'setup\lib\platform.ps1')
        Import-Module powershell-yaml -ErrorAction Stop
        $loaded = ConvertFrom-Yaml (Get-Content -LiteralPath $fixture -Raw)
        $cfg = @{}
        if ($loaded -is [System.Collections.IDictionary]) { foreach ($k in $loaded.Keys) { $cfg[[string]$k] = $loaded[$k] } }
        else { foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
        # The dummy roots carry the shape of the system this test runs on: Get-PlaceholderMap
        # asks Split-Path for the folder above DOCUMENTS, and on macOS/Linux a "C:" drive does
        # not exist (measured in CI, 2026-10-14). The values themselves do not matter here -
        # only that the keys of the vocabulary are the ones install.ps1 would use.
        $dummyHome = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'C:\dummy-home' } else { '/home/dummy' }
        $dummyDocs = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'C:\dummy-docs' } else { '/home/dummy/Documents' }
        $roots = @{ HOME = $dummyHome; DOCUMENTS = $dummyDocs; VAULT = [string]$cfg['vault_path']; DEV = [string]$cfg['dev_root'] }
        $keys = @((Get-PlaceholderMap -Roots $roots -ConfigValues $cfg).Keys) + @('{{INSTALL_DATE}}', '{{USER_SID}}', '{{START_BOUNDARY}}')
        $hits = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.install-state[\\/]' } |
            Select-String -Pattern '\{\{[A-Z0-9_]+\}\}' -ErrorAction SilentlyContinue |
            Where-Object { $keys -contains $_.Matches[0].Value })
        $hits.Count | Should -Be 0 -Because (($hits | Select-Object -First 5 | ForEach-Object { $_.Path + ':' + $_.LineNumber + ' ' + $_.Matches[0].Value }) -join '; ')
    }

    It 'verifies green against the same target' {
        $out = & pwsh -NoProfile -File (Join-Path $repoRoot 'setup\verify.ps1') -TargetRoot $target -ConfigPath $fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'VERIFY-OK'
    }

    It 'verify catches a copy file that was installed unrendered (placeholder left)' {
        $f = Join-Path $target 'HOME\.claude\life-os\morning.ps1'
        $repoFile = Join-Path $repoRoot 'home\.claude\life-os\morning.ps1'
        $good = [IO.File]::ReadAllText($f)
        try {
            [IO.File]::WriteAllBytes($f, [IO.File]::ReadAllBytes($repoFile))   # what the old bug produced
            $out = & pwsh -NoProfile -File (Join-Path $repoRoot 'setup\verify.ps1') -TargetRoot $target -ConfigPath $fixture 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 1 -Because $out
            $out | Should -Match 'FAIL'
        }
        finally { [IO.File]::WriteAllText($f, $good, (New-Object Text.UTF8Encoding($false))) }
    }

    It 'changes nothing on the second run (idempotent)' {
        $r = Invoke-Install
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'new 0, replaced 0'
    }

    It 'keeps a differing file without -Force, replaces with -Force, restore brings it back' {
        $f = Join-Path $target 'HOME\.claude\CLAUDE.md'
        Test-Path -LiteralPath $f | Should -BeTrue
        [IO.File]::WriteAllText($f, "# local test change`r`n", (New-Object Text.UTF8Encoding($false)))
        $hEdit = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash

        $r = Invoke-Install
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'different-without-Force 1'
        (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash | Should -Be $hEdit

        $r = Invoke-Install -Force
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'replaced 1'
        (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash | Should -Not -Be $hEdit

        $out = & pwsh -NoProfile -File (Join-Path $repoRoot 'setup\restore.ps1') -TargetRoot $target 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'RESTORE-OK'
        (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash | Should -Be $hEdit
    }

    It 'installs only the requested components with -Components' {
        $t2 = Join-Path $tmpRoot 'target-components'
        New-Item -ItemType Directory -Force -Path $t2 | Out-Null
        $r = Invoke-Install -Dir $t2 -Extra @('-Components', 'claude-md')
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'INSTALL-OK'
        $files = @(Get-ChildItem -LiteralPath $t2 -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.install-state[\\/]' })
        $files.Count | Should -Be 1
        $files[0].Name | Should -Be 'CLAUDE.md'
    }

    It 'accepts -Components as one comma-separated string, the way -File passes it' {
        # Measured 2026-10-18: `pwsh -File install.ps1 -Components a,b` binds "a,b" as ONE
        # string and the old code selected nothing, silently. Both forms must select the same.
        $t2b = Join-Path $tmpRoot 'target-components-string'
        New-Item -ItemType Directory -Force -Path $t2b | Out-Null
        $r = Invoke-Install -Dir $t2b -Extra @('-Components', 'claude-md,vault-readme')
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'INSTALL-OK'
        $r.out | Should -Match 'components: claude-md, vault-readme'
        $files = @(Get-ChildItem -LiteralPath $t2b -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.install-state[\\/]' })
        @($files.Name | Sort-Object) -join ',' | Should -Be 'CLAUDE.md,README.md'
    }

    It 'accepts -Components as a real array through -Command' {
        # The other binding of the same parameter: `-Command` parses the comma as the array
        # operator, so [string[]]$Components receives two elements. Both forms must select
        # the same files, or a regression in only one of them stays invisible.
        $t2d = Join-Path $tmpRoot 'target-components-array'
        New-Item -ItemType Directory -Force -Path $t2d | Out-Null
        $command = "& '" + (Join-Path $repoRoot 'install.ps1') + "' -TargetRoot '" + $t2d +
            "' -ConfigPath '" + $fixture + "' -NonInteractive -Components claude-md,vault-readme"
        $out = & pwsh -NoProfile -Command $command 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'INSTALL-OK'
        $out | Should -Match 'components: claude-md, vault-readme'
        $files = @(Get-ChildItem -LiteralPath $t2d -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.install-state[\\/]' })
        @($files.Name | Sort-Object) -join ',' | Should -Be 'CLAUDE.md,README.md'
    }

    It 'fails with a clear message on an unknown component name' {
        $t2c = Join-Path $tmpRoot 'target-components-bad'
        New-Item -ItemType Directory -Force -Path $t2c | Out-Null
        $r = Invoke-Install -Dir $t2c -Extra @('-Components', 'claude-md,does-not-exist')
        $r.code | Should -Not -Be 0
        $r.out | Should -Match 'unknown component'
        $r.out | Should -Match 'does-not-exist'
    }

    It 'installs only core components with -Profile minimal' {
        $t3 = Join-Path $tmpRoot 'target-minimal'
        New-Item -ItemType Directory -Force -Path $t3 | Out-Null
        $r = Invoke-Install -Dir $t3 -Extra @('-Profile', 'minimal')
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'INSTALL-OK'
        $r.out | Should -Match 'crawl4ai\s+SKIP' -Because 'an optional OS stage must not run in a minimal install'
        $r.out | Should -Match 'other-harness-configs\s+SKIP' -Because 'an optional generated stage must not run in a minimal install'
        Test-Path -LiteralPath (Join-Path $t3 'HOME\.claude\CLAUDE.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $t3 'VAULT\README.md') | Should -BeFalse
        $files = @(Get-ChildItem -LiteralPath $t3 -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.install-state[\\/]' })
        $files.Count | Should -BeGreaterThan 90
        $files.Count | Should -BeLessThan 131
    }

    It '-DryRun on a fresh target exits 0, writes no tree file, keeps previews in .install-state' {
        $t4 = Join-Path $tmpRoot 'target-dryrun'
        New-Item -ItemType Directory -Force -Path $t4 | Out-Null
        $r = Invoke-Install -Dir $t4 -Extra @('-DryRun')
        $r.code | Should -Be 0 -Because $r.out
        $r.out | Should -Match 'INSTALL-OK'
        $r.out | Should -Match 'PREVIEW'
        $files = @(Get-ChildItem -LiteralPath $t4 -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.install-state[\\/]' })
        $files.Count | Should -Be 0 -Because 'a dry run must not write the target tree'
        Test-Path -LiteralPath (Join-Path $t4 '.install-state\preview\git-config.txt') | Should -BeTrue
    }
}
