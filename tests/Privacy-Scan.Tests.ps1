<#
tests/Privacy-Scan.Tests.ps1 - pins the worktree scope of setup/tools/privacy-scan.ps1.

Scope rule (2026-10-11, after the export gate tripped over test scratch): the worktree mode
scans what git would hand over - tracked plus untracked-not-ignored files. Ignored scratch
(tests/_tmp, *.log) may hold real values on purpose - the guard suites render with the real
HOME - and it can never reach the repo, so it is skipped. Outside a git checkout the
scanner falls back to walking every file.

Pester 5 pitfalls (see tests/README.md): top-level code runs at discovery only; -Skip: is
evaluated at discovery. Both are respected below.
#>
$script:hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)

BeforeAll {
    $script:scan = Join-Path (Split-Path -Parent $PSScriptRoot) 'setup\tools\privacy-scan.ps1'
    # its own scratch folder per run - see tests/Install.Tests.ps1 and review 5, finding 7
    $script:scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $script:fixtureRoot = Join-Path $script:scratchRoot 'privacy-scan'
    if (Test-Path -LiteralPath $script:fixtureRoot) { Remove-Item -LiteralPath $script:fixtureRoot -Recurse -Force }
    $utf8 = New-Object Text.UTF8Encoding($false)
    # Built at runtime so this source file itself does not carry a key-shaped string
    # (the worktree scan is allowed to abort the export on one).
    $probe = 'aws key AKIA' + 'QWERTYUIOPASDFGH' + "`n"

    # [IO.Path]::GetTempPath() and not $env:TEMP: TEMP and TMP are Windows names, and on
    # macOS/Linux they are unset - Join-Path with a null path throws (measured in CI, 2026-10-14)
    $script:plain = Join-Path ([IO.Path]::GetTempPath()) 'personal-os-setup-scan-plain'
    if (Test-Path -LiteralPath $script:plain) { Remove-Item -LiteralPath $script:plain -Recurse -Force }
    $script:gitA = Join-Path $script:fixtureRoot 'git-untracked'
    $script:gitB = Join-Path $script:fixtureRoot 'git-ignored'
    New-Item -ItemType Directory -Force -Path $script:plain, $script:gitA, $script:gitB | Out-Null

    [IO.File]::WriteAllText((Join-Path $script:plain 'leak.txt'), $probe, $utf8)
    [IO.File]::WriteAllText((Join-Path $script:gitA 'leak.txt'), $probe, $utf8)
    & git -C $script:gitA init --quiet 2>$null | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:gitB '.gitignore'), "ignored.txt`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:gitB 'ignored.txt'), $probe, $utf8)
    & git -C $script:gitB init --quiet 2>$null | Out-Null

    function Invoke-PrivateScan([string]$Path) {
        $out = & pwsh -NoProfile -File $script:scan -Path $Path 2>&1 | Out-String
        return @{ Output = $out; Exit = $LASTEXITCODE }
    }
}

Describe 'privacy-scan worktree scope' {
    It 'plain folder: the fallback walk finds a leak' {
        $r = Invoke-PrivateScan $script:plain
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'api-key-aws'
    }
    It 'git checkout: an untracked, not-ignored file is found' -Skip:(-not $script:hasGit) {
        $r = Invoke-PrivateScan $script:gitA
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'leak\.txt'
    }
    It 'git checkout: an ignored file is skipped' -Skip:(-not $script:hasGit) {
        $r = Invoke-PrivateScan $script:gitB
        $r.Exit | Should -Be 0
        $r.Output | Should -Match 'clean'
    }
}

# The DeepSeek orientation file is public in this repository once the owner has written it
# (ADR 0020). Two things must hold: the scan reads that path, and no ignore rule hides it.
Describe 'privacy-scan covers the DeepSeek orientation file' {
    It 'a planted leak in home/.claude/orientation/deepseek.md is found' -Skip:(-not $script:hasGit) {
        $dir = Join-Path $script:fixtureRoot 'git-orientation'
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'home/.claude/orientation') | Out-Null
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $dir 'home/.claude/orientation/deepseek.md'), ('## Notes' + "`n" + 'aws key AKIA' + 'QWERTYUIOPASDFGH' + "`n"), $utf8)
        & git -C $dir init --quiet 2>$null | Out-Null
        $r = Invoke-PrivateScan $dir
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'orientation.deepseek\.md'
    }
    It 'no .gitignore rule of this repository hides the file' -Skip:(-not $script:hasGit) {
        $repo = Split-Path -Parent $PSScriptRoot
        & git -C $repo check-ignore -q 'home/.claude/orientation/deepseek.md' 2>$null
        $LASTEXITCODE | Should -Be 1 -Because 'check-ignore exits 1 when the path is not ignored'
    }
}
