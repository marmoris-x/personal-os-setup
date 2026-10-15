<#
ci-full-setup.ps1 - the real setup on a throw-away machine: the OS stages that ci-smoke.ps1
cannot reach.

  pwsh -File setup/tools/ci-full-setup.ps1 -WorkDir <scratch>

ci-smoke.ps1 installs into an empty -TargetRoot, and a target install only renders PREVIEW
files for the OS stages (install.ps1, line 29). This script runs the same installer WITHOUT
-TargetRoot on a GitHub runner, so packages, the scheduled job, the sync service and the backup
tool are really touched - on a machine nobody has logged into and no person owns.

The order is the one a person would use: install, verify, install a second time (which must
change nothing). Every step is reported even when an earlier one failed, so one CI run shows
everything that is wrong instead of only the first thing.

What such a machine cannot do is printed as a named SKIP with its reason, never left out
silently:

  * the sign-in steps need a person: gh auth login, the Claude Code login, connecting the Kopia
    repository, pairing Syncthing;
  * `winget configure` (the declarative route, windows/configuration.winget) failed on the
    windows-latest runner in the first run of 2026-10-14; the JSON import lists installed all
    12 programs and the verify check `winget-core` was green. The stage now reports winget's
    own words for it and names the manual step (install.ps1 once from an elevated PowerShell);
  * no runner has Claude Code installed, so the two MCP checks cannot pass there.

The Life OS venv on macos-latest is NOT on that list, and it never belonged there. An entry once
stood for it that blamed a missing macOS arm64 wheel for ctranslate2==4.8.2; measured 2026-10-15,
that wheel exists for every Python from 3.9 to 3.14. What the failing runs saw was pip answering
"from versions: none" - the index returned nothing - while the same commit built the venv on the
macos-latest runner of run 38721167335. Three runs, fail, pass, fail. That is a flaky index
lookup, so the install stage retries pip a bounded number of times instead and the verify stays
strict.

Measured in that first run, and not on any expectation list: the task checks PASSED on all
three runners - windows-latest registers the scheduled task with its logon trigger (the runner
session is elevated), ubuntu-latest runs `systemctl --user enable --now personal-os-morning.timer`,
macOS `launchctl bootstrap gui/<uid>`. An entry that passes prints STALE and is removed.

The list below ($script:expectedFails) names each such check with the reason AND with the text
its detail must match. A check that fails for a different reason is NOT waved through - the job
goes red. A listed check that passes is printed as STALE, so a list that has drifted apart from
the machine is visible instead of quietly swallowing a real failure.

Exit 0 = the live install, both verifies and the idempotent second run did what they promise,
and no failure was unexpected. The last line FULL-SETUP-OK is what a human reads in the log.

Refuses to run outside CI: on a real machine this would change live files, and that is exactly
what the acceptance run forbids. ASCII-only on purpose.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'
if (-not $env:CI) { throw 'refusing to run: this script does a LIVE install and only belongs on a throw-away CI machine (set CI=1 to override deliberately)' }
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) 'personal-os-ci-full' }
$fixture = Join-Path $RepoRoot 'tests/fixtures/personal.dummy.yaml'
if (-not (Test-Path -LiteralPath $fixture)) { throw ('test fixture missing: ' + $fixture) }
$null = New-Item -ItemType Directory -Force -Path $WorkDir

. (Join-Path $RepoRoot 'setup/lib/manifest.ps1')
. (Join-Path $RepoRoot 'setup/lib/platform.ps1')
$os = Get-PlatformId
$homeDir = Get-PlatformHome
$cfgPath = Join-Path $WorkDir 'personal.yaml'

# The vault and the Dev folder are the person's decision (D4, red line 4). On a runner there is
# no person, so the script puts both INSIDE the runner's own home folder - never on a real path
# a machine would care about, and never outside the throw-away account.
$sep = Get-PlatformPathSeparator -Os $os
$vault = Join-Path $homeDir ('personal-os-ci' + $sep + 'vault')
$dev = Join-Path $homeDir ('personal-os-ci' + $sep + 'dev')
if (-not (Test-Path -LiteralPath $cfgPath)) {
    $yaml = @(
        '# Written by setup/tools/ci-full-setup.ps1 for ONE throw-away run. Never real data.'
        "user_name: 'Vera Beispiel'"
        "user_given: 'Vera'"
        "user_family: 'Beispiel'"
        "github_account: 'example-user'"
        "b2_bucket: 'example-kopia-backup'"
        "vault_path: '$vault'"
        "dev_root: '$dev'"
        "archive_dir_name: 'Dokumentenarchiv'"
        "morning_time: '07:00'"
        "backup_time: '12:30'"
    ) -join "`n"
    [IO.File]::WriteAllText($cfgPath, ($yaml + "`n"), (New-Object Text.UTF8Encoding($false)))
}

# Checks a machine nobody has logged into cannot satisfy. `detail` must match the text of the
# check, so a failure with a different cause does not slip through the same entry.
#
# Measured 2026-10-14 in the first CI run: the task checks PASSED on all three runners (see the
# header). Their entries printed STALE - which is exactly what that word is for - and are gone.
# Only the MCP checks are left: no runner has Claude Code, and installing and signing in needs a
# person.
$script:expectedFails = @{
    windows = @(
        @{ Id = 'mcp-exa'; Detail = 'claude is not on PATH'; Why = 'no Claude Code on a CI machine; installing and signing in needs a person' }
        @{ Id = 'mcp-parallel'; Detail = 'claude is not on PATH'; Why = 'same machine, same reason as mcp-exa' }
    )
    macos = @(
        # The life-os-venv entry that stood here until 2026-10-15 is gone, and the reason it gave
        # was wrong. It said ctranslate2==4.8.2 publishes no macOS arm64 wheel. Measured against
        # PyPI: it publishes one for every Python from 3.9 to 3.14, cp313-macosx_11_0_arm64
        # included. What the failing runs actually saw was pip answering "from versions: none" -
        # the index returned nothing at all - and the same commit built the same venv on the
        # macos-latest runner of run 38721167335. Three macos runs, fail, pass, fail: that is a
        # flaky index lookup, not a machine limit, and this check even said so itself ("STALE: it
        # passed this time - take it out of the list"). The remedy is a bounded retry in the
        # install stage, not an entry that hides the failure. Keeping it would not have helped
        # anyway: the files-only verify below exits non-zero on the same failure and is not
        # covered by this list.
        @{ Id = 'mcp-exa'; Detail = 'claude is not on PATH'; Why = 'no Claude Code on a CI machine; installing and signing in needs a person' }
        @{ Id = 'mcp-parallel'; Detail = 'claude is not on PATH'; Why = 'same machine, same reason as mcp-exa' }
    )
    linux = @(
        @{ Id = 'mcp-exa'; Detail = 'claude is not on PATH'; Why = 'no Claude Code on a CI machine; installing and signing in needs a person' }
        @{ Id = 'mcp-parallel'; Detail = 'claude is not on PATH'; Why = 'same machine, same reason as mcp-exa' }
    )
}

function Invoke-Step([string]$name, [string[]]$arguments) {
    # Write-Host, not Write-Output: output written to the stream of a function is collected by
    # the caller, and a failing step's own output then never reaches the job log.
    $out = & pwsh -NoProfile -File (Join-Path $RepoRoot $arguments[0]) @($arguments[1..($arguments.Count - 1)]) 2>&1 | Out-String
    $code = $LASTEXITCODE
    $out = $out -replace "`e\[[0-9;]*m", ''      # colours off: the parsing below reads plain text
    Write-Host ''
    Write-Host ('--- ' + $name + ' (exit ' + $code + ') ---')
    Write-Host $out
    return @{ Out = $out; Code = $code }
}

$script:problems = New-Object System.Collections.Generic.List[string]
function Add-Problem([string]$text) { $script:problems.Add($text); Write-Host ('PROBLEM: ' + $text) }

Write-Host ('== ci-full-setup  platform=' + $os + '  pwsh=' + $PSVersionTable.PSVersion.ToString() + ' ==')
Write-Host ('Repo: ' + $RepoRoot)
Write-Host ('Work: ' + $WorkDir)
Write-Host ('Config: ' + $cfgPath + ' (vault and dev inside ' + $homeDir + ', one throw-away run)')

# --- winget: checked before anything else, because the whole package stage rests on it --------
if ($os -eq 'windows') {
    Write-Host ''
    Write-Host '--- winget (the Windows package source) ---'
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $w) {
        Write-Host 'winget is not on PATH; trying the documented repair route (Microsoft.WinGet.Client)...'
        try {
            Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Force -ErrorAction Stop
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            Repair-WinGetPackageManager -Force -Latest | Out-Null
        }
        catch { Write-Host ('the repair route failed: ' + $_.Exception.Message) }
        $w = Get-Command winget -ErrorAction SilentlyContinue
    }
    if ($w) { Write-Host ('winget: ' + ((& winget --version 2>&1 | Out-String).Trim()) + '  ' + $w.Source) }
    else {
        Add-Problem 'winget is missing on this runner and could not be installed - the package stage and its verify check cannot run here'
    }
}

# --- the prerequisites bootstrap would install ------------------------------------------------
# bootstrap.ps1 / bootstrap.sh install these, then sign in, clone and hand over. On a runner
# they are already there (actions/checkout put the repository here), and the two steps that
# need a person are named instead of imitated.
Write-Host ''
Write-Host '--- prerequisites (what bootstrap.sh / bootstrap.ps1 would install) ---'
foreach ($tool in @('git', 'pwsh', 'gh')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host ('  present  ' + $tool + '  ' + $cmd.Source) } else { Add-Problem ('bootstrap would have to install: ' + $tool) }
}
Write-Host '  SKIPPED  bootstrap sign-in (gh auth login) - it asks a person for a one-time code'
Write-Host '  SKIPPED  bootstrap clone - actions/checkout already put the repository here'

# --- 1. the live install ----------------------------------------------------------------------
$first = Invoke-Step 'install (LIVE, without -TargetRoot)' @('install.ps1', '-ConfigPath', $cfgPath, '-NonInteractive')
if ($first.Code -ne 0) { Add-Problem ('the live install exited ' + $first.Code) }
elseif ($first.Out -notmatch 'INSTALL-OK') { Add-Problem 'the live install did not reach INSTALL-OK' }

$firstStages = @{}
foreach ($m in [regex]::Matches($first.Out, '(?m)^\s{2}(\S+)\s+(OK|PREVIEW|WARN|SKIP|ERROR)\s+(.*)$')) {
    $firstStages[$m.Groups[1].Value] = @{ Status = $m.Groups[2].Value; Detail = $m.Groups[3].Value.Trim() }
}
Write-Host ''
Write-Host ('--- stages of the live install (' + $firstStages.Count + ') ---')
foreach ($k in ($firstStages.Keys | Sort-Object)) {
    $s = $firstStages[$k]
    Write-Host ('  {0,-16} {1,-7} {2}' -f $k, $s.Status, $s.Detail)
}

# Where an install puts programs OUTSIDE the package manager, and where a real session has them
# on PATH but a CI step does not. The list (and the Windows-only winget Links folder among it)
# comes from setup/lib/platform.ps1 - Get-PlatformToolDirs: a folder name of one system belongs
# in the platform module, and acceptance check I reads this file as part of the engine.
# The fact is printed either way, and a folder that exists but is not on PATH is added for the
# verify steps below - otherwise the verify would report "not in PATH" for a program the install
# just wrote, which says nothing about the install.
$pathDirs = @(Get-PlatformToolDirs -Os $os)
foreach ($dir in $pathDirs) {
    $onPath = @($env:PATH -split [IO.Path]::PathSeparator) -contains $dir
    $exists = Test-Path -LiteralPath $dir
    Write-Host ('PATH carries ' + $dir + ': ' + $onPath + ' (exists: ' + $exists + ')')
    if (-not $onPath -and $exists) {
        $env:PATH = $dir + [IO.Path]::PathSeparator + $env:PATH
        Write-Host '  added it for the verify steps - a login session takes it from the shell profile'
    }
}

# --- 2. verify the files (strict, nothing expected to fail) -------------------------------------
$fileV = Invoke-Step 'verify (files only: -SkipSystemChecks)' @('setup/verify.ps1', '-ConfigPath', $cfgPath, '-SkipSystemChecks')
if ($fileV.Code -ne 0) { Add-Problem ('the file verify exited ' + $fileV.Code) }
elseif ($fileV.Out -notmatch 'VERIFY-OK') { Add-Problem 'the file verify did not reach VERIFY-OK' }

# --- 3. verify the whole machine ----------------------------------------------------------------
$sysV = Invoke-Step 'verify (LIVE: files and the system pieces)' @('setup/verify.ps1', '-ConfigPath', $cfgPath)
$verifyLines = @()
foreach ($m in [regex]::Matches($sysV.Out, '(?m)^\s{2}(OK|FAIL|SKIP)\s+(\S+)\s+(.*)$')) {
    $verifyLines += [pscustomobject]@{ Status = $m.Groups[1].Value; Id = $m.Groups[2].Value; Detail = $m.Groups[3].Value.Trim() }
}
$script:filled = @{}
foreach ($l in $verifyLines) {
    if ($l.Status -ne 'FAIL') { continue }
    $hit = $null
    foreach ($e in @($script:expectedFails[$os])) { if ($e.Id -eq $l.Id -and $l.Detail -match $e.Detail) { $hit = $e; break } }
    if ($hit) { $script:filled[$hit.Id] = $l }
    else { Add-Problem ('the live verify reports an unexpected failure: ' + $l.Id + ' - ' + $l.Detail) }
}
if ($sysV.Code -ne 0 -and $script:filled.Count -eq 0) { Add-Problem ('the live verify exited ' + $sysV.Code + ' and none of its failures is on the list') }

# --- 4. a second live install changes nothing ----------------------------------------------------
$second = Invoke-Step 'install (second run, LIVE)' @('install.ps1', '-ConfigPath', $cfgPath, '-NonInteractive')
if ($second.Code -ne 0) { Add-Problem ('the second live install exited ' + $second.Code) }
$m = [regex]::Match($second.Out, 'files\s+OK\s+new (\d+), replaced (\d+)')
if (-not $m.Success) { Add-Problem 'the second install did not report a files stage result' }
elseif (([int]$m.Groups[1].Value -ne 0) -or ([int]$m.Groups[2].Value -ne 0)) {
    Add-Problem ('the second install was not idempotent: new ' + $m.Groups[1].Value + ', replaced ' + $m.Groups[2].Value)
}

# --- the table a reader wants, and the honest accounting of what did not run ---------------------
Write-Host ''
Write-Host '== what ran, per step =='
Write-Host ('  {0,-44} {1}' -f 'step', 'result')
Write-Host ('  {0,-44} {1}' -f 'install (live)', $(if ($first.Out -match 'INSTALL-OK') { 'OK (INSTALL-OK, exit ' + $first.Code + ')' } else { 'FAILED (exit ' + $first.Code + ')' }))
Write-Host ('  {0,-44} {1}' -f 'verify (files only)', $(if ($fileV.Out -match 'VERIFY-OK') { ([regex]::Match($fileV.Out, 'VERIFY-OK:.*')).Value } else { 'FAILED (exit ' + $fileV.Code + ')' }))
Write-Host ('  {0,-44} {1}' -f 'verify (live)', $(if ($sysV.Out -match 'VERIFY-OK') { ([regex]::Match($sysV.Out, 'VERIFY-OK:.*')).Value } elseif ($sysV.Out -match 'VERIFY:.*') { ([regex]::Match($sysV.Out, 'VERIFY:.*')).Value } else { 'no result line (exit ' + $sysV.Code + ')' }))
Write-Host ('  {0,-44} {1}' -f 'install (second run)', $(if ($m.Success) { 'files new ' + $m.Groups[1].Value + ', replaced ' + $m.Groups[2].Value } else { 'no files line' }))

Write-Host ''
Write-Host '== what a machine nobody has logged into cannot do (named, with its reason) =='
$printed = New-Object System.Collections.Generic.List[string]
foreach ($k in ($firstStages.Keys | Sort-Object)) {
    $s = $firstStages[$k]
    if ($s.Status -in @('SKIP', 'WARN')) {
        Write-Host ('  install  ' + $k + '  ' + $s.Status + '  ' + $s.Detail)
        $printed.Add($k)
    }
}
foreach ($e in @($script:expectedFails[$os])) {
    if ($script:filled.ContainsKey($e.Id)) {
        Write-Host ('  verify   ' + $e.Id + '  ' + $script:filled[$e.Id].Status + ' (expected)  ' + $e.Why)
        Write-Host ('           what it said: ' + $script:filled[$e.Id].Detail)
    }
    else { Write-Host ('  verify   ' + $e.Id + '  STALE: it passed this time - take it out of the list  (' + $e.Why + ')') }
}
Write-Host ('  manual steps the installer named: ' + (($first.Out -split "`r?`n" | Where-Object { $_ -match '^\s{2}- ' }) -join ' | '))

Write-Host ''
if ($script:problems.Count -gt 0) {
    Write-Host ('FULL-SETUP: ' + $script:problems.Count + ' problem(s) on ' + $os) -ForegroundColor Red
    foreach ($p in $script:problems) { Write-Host ('  - ' + $p) -ForegroundColor Red }
    exit 1
}
Write-Host ('FULL-SETUP-OK: ' + $os + ' live install, verify and a second install without changes') -ForegroundColor Green
exit 0
