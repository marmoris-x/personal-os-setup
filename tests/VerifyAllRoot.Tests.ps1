#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.9.1' }
# Check B of setup/tools/verify-all.ps1 (the repo root holds exactly the documented entries) against a
# throw-away repository under Temp. The repo is never touched: verify-all gets -RepoRoot and -WorkRoot.
# A partial run (-Only) never exits 0, so the verdict is read from the check's own result line.
#
# The rule being tested: PROGRESS.md is local working state, written by the agent rule in CLAUDE.md.
# It is no stray file only when git ignores it AND it is listed in $allowedLocal. Anything else
# untracked stays a finding, and a tracked PROGRESS.md is a finding.

BeforeAll {
    $script:VerifyAll = Join-Path (Split-Path -Parent $PSScriptRoot) 'setup/tools/verify-all.ps1'
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('verify-root-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Work 'log') | Out-Null
    # built from two parts so the privacy scan does not read the fixture's author as an address
    $script:GitMail = 't' + '@' + 'example.invalid'

    function New-RootFixture([string]$name, [string]$gitignore) {
        $fix = Join-Path $script:Work $name
        New-Item -ItemType Directory -Force -Path $fix | Out-Null
        foreach ($d in @('.github', 'dev', 'docs', 'home', 'linux', 'macos', 'setup', 'tests', 'vault', 'windows')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $fix $d) | Out-Null
            [IO.File]::WriteAllText((Join-Path $fix "$d/keep.txt"), 'x')
        }
        foreach ($f in @('.gitattributes', '.gitleaks.toml', 'AGENTS.md', 'bootstrap.ps1', 'bootstrap.sh', 'CHANGELOG.md', 'CLAUDE.md', 'README.md', 'SECURITY.md', 'install.ps1')) {
            [IO.File]::WriteAllText((Join-Path $fix $f), 'x')
        }
        [IO.File]::WriteAllText((Join-Path $fix '.gitignore'), $gitignore)
        & git -C $fix init -q 2>&1 | Out-Null
        & git -C $fix add -A 2>&1 | Out-Null
        & git -C $fix -c user.name=t -c user.email=$script:GitMail commit -q -m fixture 2>&1 | Out-Null
        # the fixture must be its own repository with no remote, or a commit could land elsewhere
        (& git -C $fix remote -v) | Should -BeNullOrEmpty
        return $fix
    }
    function Invoke-CheckB([string]$fix) {
        $out = & pwsh -NoProfile -File $script:VerifyAll -RepoRoot $fix -WorkRoot (Join-Path $script:Work 'log') -Only B -Verbose 4>&1 2>&1 | Out-String
        return [pscustomobject]@{ Out = $out }
    }
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'verify-all check B and the local PROGRESS.md' {
    It 'passes a clean root' {
        $fix = New-RootFixture 'clean' "/PROGRESS.md`n"
        $r = Invoke-CheckB $fix
        # the verdict of the root rule itself: no tool of the acceptance run is needed for it, so CI
        # (which lacks gh, gitleaks and trufflehog) reads the detail line, not the PASS mark
        $r.Out | Should -Match 'none untracked'
        $r.Out | Should -Not -Match 'UNTRACKED ON DISK|UNEXPECTED|MISSING:'
    }
    It 'passes a local PROGRESS.md that git ignores' {
        $fix = New-RootFixture 'local-ignored' "/PROGRESS.md`n"
        [IO.File]::WriteAllText((Join-Path $fix 'PROGRESS.md'), 'local state')
        $r = Invoke-CheckB $fix
        # the verdict of the root rule itself: no tool of the acceptance run is needed for it, so CI
        # (which lacks gh, gitleaks and trufflehog) reads the detail line, not the PASS mark
        $r.Out | Should -Match 'none untracked'
        $r.Out | Should -Not -Match 'UNTRACKED ON DISK|UNEXPECTED|MISSING:'
    }
    It 'fails a local PROGRESS.md that git does not ignore' {
        $fix = New-RootFixture 'local-not-ignored' "# nothing ignored`n"
        [IO.File]::WriteAllText((Join-Path $fix 'PROGRESS.md'), 'local state')
        $r = Invoke-CheckB $fix
        $r.Out | Should -Match 'UNTRACKED ON DISK: PROGRESS.md'
        $r.Out | Should -Match 'B\s+root holds exactly the documented entries\s+FAIL'
    }
    It 'fails a local PROGRESS.md that only .git/info/exclude hides (the repo itself does not ignore it)' {
        $fix = New-RootFixture 'local-excluded' "# nothing ignored`n"
        [IO.File]::AppendAllText((Join-Path $fix '.git/info/exclude'), "PROGRESS.md`n")
        [IO.File]::WriteAllText((Join-Path $fix 'PROGRESS.md'), 'local state')
        $r = Invoke-CheckB $fix
        $r.Out | Should -Match 'UNTRACKED ON DISK: PROGRESS.md'
    }
    It 'still fails a stray notes.txt, also when git ignores it' {
        $fix = New-RootFixture 'stray' "/PROGRESS.md`nnotes.txt`n"
        [IO.File]::WriteAllText((Join-Path $fix 'notes.txt'), 'stray')
        $r = Invoke-CheckB $fix
        $r.Out | Should -Match 'UNTRACKED ON DISK: notes.txt'
        $r.Out | Should -Match 'B\s+root holds exactly the documented entries\s+FAIL'
    }
    It 'fails a tracked PROGRESS.md' {
        $fix = New-RootFixture 'tracked' "/PROGRESS.md`n"
        [IO.File]::WriteAllText((Join-Path $fix 'PROGRESS.md'), 'tracked state')
        & git -C $fix add -f PROGRESS.md 2>&1 | Out-Null
        & git -C $fix -c user.name=t -c user.email=$script:GitMail commit -q -m tracked 2>&1 | Out-Null
        $r = Invoke-CheckB $fix
        $r.Out | Should -Match 'UNEXPECTED: PROGRESS.md'
        $r.Out | Should -Match 'B\s+root holds exactly the documented entries\s+FAIL'
    }
}
