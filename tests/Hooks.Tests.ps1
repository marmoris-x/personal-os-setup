# Pester 5.9.1 (pinned). The installed git hooks: the bit that makes git run them, and the proof
# that one really runs.
#
# Why this file exists. A hook is only a guard while git starts it, and git SKIPS a hook that is
# not executable - without a word. That happens on macOS and Linux only, which is the platform
# nobody of this project sits at: measured 2026-10-16, `git ls-files -s` answered 100644 for the
# mirrored global hook, so a clone carried no bit, and an install copies content without it -
# while the owner's Windows machine ran the hook anyway (git for Windows starts a hook that has a
# shebang, executed bit or not). Nothing looked. So install.ps1 sets the bit since then (rule 3
# in setup/lib/manifest.ps1) and this suite measures the two halves that matter: the bit is on
# the installed hook, and a commit that carries a planted hit is really refused by that hook.
#
# The planted value is assembled from parts at runtime on purpose: spelled out it would be a
# finding for this repository's own gitleaks scan and a block for its own pre-commit hook - the
# same reason the guard suites build their umlauts from code points.
#
# Top level runs during discovery: the -Skip condition below is evaluated there, so the system
# flag must live here as well as in BeforeAll (the same note stands in Roundtrip.Tests.ps1).
$script:hooksRepo = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:hooksRepo 'setup/lib/platform.ps1')
$script:onWindows = ((Get-PlatformId) -eq 'windows')

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'setup/lib/platform.ps1')
    $script:onWindows = ((Get-PlatformId) -eq 'windows')
    $fixture = Join-Path $PSScriptRoot 'fixtures/personal.dummy.yaml'
    # check.ps1 hands its own work folder over, like Install.Tests.ps1 does: two runs at the same
    # time must not delete each other's target.
    $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $work = Join-Path $scratchRoot 'hooks-e2e'
    $target = Join-Path $work 'target'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $script:installOut = & pwsh -NoProfile -File (Join-Path $repoRoot 'install.ps1') -TargetRoot $target -ConfigPath $fixture -NonInteractive 2>&1 | Out-String
    $script:installCode = $LASTEXITCODE
    # -TargetRoot puts the roots one level down: the fake home of the target is <target>/HOME.
    $script:targetHome = Join-Path $target 'HOME'
    $script:hook = Join-Path $script:targetHome '.githooks/pre-commit'

    # The hook reads its config through $HOME, and the install wrote that config into the target:
    # without HOME pointing there, gitleaks would look at the real user's config or at none.
    $script:savedHome = $env:HOME
    $env:HOME = $script:targetHome

    $script:hasGitleaks = [bool](Get-Command gitleaks -ErrorAction SilentlyContinue)
    # A commit in a throw-away repository of its own, with the INSTALLED hooks and nothing else.
    $script:scratch = Join-Path $work 'scratch-repo'
    New-Item -ItemType Directory -Force -Path $script:scratch | Out-Null
    $null = & git -C $script:scratch init -q 2>&1
    # example.com is a documented test domain AND one the privacy scan's email rule skips by
    # name; an invented domain would make this file a finding for the export's own gate.
    $null = & git -C $script:scratch config user.email 'hooks-test@example.com' 2>&1
    $null = & git -C $script:scratch config user.name 'personal-os hook test' 2>&1
    $null = & git -C $script:scratch config commit.gpgsign false 2>&1
    $null = & git -C $script:scratch config core.hooksPath (Join-Path $script:targetHome '.githooks') 2>&1

    function Invoke-ScratchCommit([string]$Message, [string]$OutputName, [string]$Content, [switch]$NoVerify) {
        [IO.File]::WriteAllText((Join-Path $script:scratch $OutputName), $Content, (New-Object Text.UTF8Encoding($false)))
        $null = & git -C $script:scratch add -A 2>&1
        $a = @('-C', $script:scratch, 'commit', '-m', $Message)
        if ($NoVerify) { $a += '--no-verify' }
        $text = & git @a 2>&1 | Out-String
        return @{ out = $text; code = $LASTEXITCODE }
    }

    # The first commit is the baseline the two cases below build on: a hook that cannot let a
    # clean commit through would make the refusal below meaningless.
    $script:cleanCommit = Invoke-ScratchCommit -Message 'test: a clean file' -OutputName 'clean.txt' -Content "nothing to see`n"
}

Describe 'the hook files in the repository' {
    It 'are executable in the index, so a clone carries the bit before any install' {
        # git stores the bit in the index; without it a Linux/macOS checkout is 644 and git
        # silently skips the hook. Windows cannot show this in the file system, so the index is
        # what gets judged - it is the same thing a clone checks out everywhere.
        $listed = @(& git -C $repoRoot ls-files -s | Where-Object { $_ -match 'githooks/' })
        $listed.Count | Should -BeGreaterThan 1 -Because 'the global hook and the two repository hooks must all be listed'
        $notExec = @($listed | Where-Object { $_ -notmatch '^100755 ' })
        ($notExec -join '; ') | Should -Be '' -Because 'a hook stored as 100644 is skipped by git on macOS and Linux without a word'
    }
}

Describe 'the installed hook' {
    It 'came out of an install that passed' {
        $script:installCode | Should -Be 0 -Because ('the install is the subject; its output ends with: ' + $script:installOut.Substring([Math]::Max(0, $script:installOut.Length - 300)))
        Test-Path -LiteralPath $script:hook | Should -BeTrue -Because 'the global hook is a core component and must land in every target'
    }

    It 'has the executable bit on macOS and Linux (skipped on Windows, which has no such bit)' -Skip:$script:onWindows {
        # POSIX `test -x` asks the kernel, not a copy of the rule: exactly what git asks before
        # it starts a hook. Every installed file under a githooks folder is judged, not only the
        # one git is pointed at - rule 3 in setup/lib/manifest.ps1 says "every file", and the
        # target carries a second copy under .claude/setup/security.
        $hooks = @(Get-ChildItem -LiteralPath $script:targetHome -Recurse -File -Force | Where-Object { $_.FullName -match '[\\/]githooks[\\/]' })
        $hooks.Count | Should -BeGreaterThan 0 -Because 'an empty list would let the rule below pass by saying nothing'
        $notExec = @()
        foreach ($h in $hooks) {
            $null = & sh -c 'test -x "$1"' sh $h.FullName 2>&1
            if ($LASTEXITCODE -ne 0) { $notExec += $h.FullName.Substring($script:targetHome.Length) }
        }
        ($notExec -join '; ') | Should -Be '' -Because 'git skips a hook that is not executable, and the whole point of this suite is that something would notice'
    }
}

Describe 'a commit through the installed hook' {
    It 'is possible at all: the clean file went through' {
        $script:cleanCommit.code | Should -Be 0 -Because ('a hook that blocks everything proves nothing; the commit said: ' + $script:cleanCommit.out)
    }

    It 'is refused when the staged file carries a secret-shaped hit' {
        if (-not $script:hasGitleaks) {
            throw 'gitleaks is not on PATH: the installed hook cannot be proven to block anything. Install gitleaks (the package stage does) or run this on CI, where the step before the checks puts it on PATH.'
        }
        # DeepSeek's key shape, which the installed config has a rule for - assembled here so this
        # file itself is not a finding.
        $hit = 'sk-' + '0123456789abcdef' + 'fedcba9876543210'
        $r = Invoke-ScratchCommit -Message 'test: this must not pass' -OutputName 'planted.txt' -Content ($hit + "`n")
        $r.code | Should -Not -Be 0 -Because 'the hook is the only thing between this commit and the repository'
        $r.out | Should -Match 'leaks found|gitleaks' -Because 'the refusal must be the hook (the hook execs gitleaks, which prints "leaks found"), not an unrelated failure'
        # ... and the hook is what refused, not something else in the way: the same commit with
        # --no-verify goes through (the hook is skipped, the repository takes it).
        $again = Invoke-ScratchCommit -Message 'test: same content, hook skipped by hand' -OutputName 'planted.txt' -Content ($hit + "`n") -NoVerify
        $again.code | Should -Be 0 -Because ('--no-verify proves the hook was the obstacle; without that, a missing git identity or an empty branch could be the reason: ' + $again.out)
    }
}

AfterAll {
    if ($null -eq $script:savedHome) { Remove-Item Env:\HOME -ErrorAction SilentlyContinue } else { $env:HOME = $script:savedHome }
}
