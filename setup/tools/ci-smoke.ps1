<#
ci-smoke.ps1 - the proof every CI job prints: install into an empty target, verify it, install
a second time and show that nothing changed.

That is check O of the acceptance run ("second install run reports 0 changes"). Check O reads
the conclusion of the step that runs this file out of the run's JSON, so a job that did not run
it cannot be mistaken for one that did; the fixed marker on the last line is what a human reads
in the job log.

  pwsh -File setup/tools/ci-smoke.ps1 -WorkDir <scratch>

Exit 0 = all three steps passed. ASCII-only on purpose.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) 'personal-os-ci-smoke' }
$fixture = Join-Path $RepoRoot 'tests/fixtures/personal.dummy.yaml'
if (-not (Test-Path -LiteralPath $fixture)) { throw ('test fixture missing: ' + $fixture) }

. (Join-Path $RepoRoot 'setup/lib/manifest.ps1')
. (Join-Path $RepoRoot 'setup/lib/platform.ps1')
$os = Get-PlatformId

$target = Join-Path $WorkDir ('ci-target-' + $os)
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Force -Path $target | Out-Null

function Invoke-Step([string]$name, [string[]]$Arguments) {
    $out = & pwsh -NoProfile -File (Join-Path $RepoRoot ($Arguments[0])) @($Arguments[1..($Arguments.Count - 1)]) 2>&1 | Out-String
    $code = $LASTEXITCODE
    # Write-Host, NOT Write-Output: everything a function writes to the OUTPUT stream is
    # collected into $first/$ver/$second by the caller, so the failing step's own output never
    # reached the job log (measured 2026-10-14: the ubuntu job showed one truncated exception
    # line and nothing else). The host stream is printed where a human looks.
    Write-Host ('--- ' + $name + ' (exit ' + $code + ') ---')
    Write-Host $out
    return @{ Out = $out; Code = $code }
}

$first = Invoke-Step 'install (first run)' @('install.ps1', '-TargetRoot', $target, '-ConfigPath', $fixture, '-NonInteractive')
if (($first.Code -ne 0) -or ($first.Out -notmatch 'INSTALL-OK')) { throw 'the first install did not reach INSTALL-OK' }

$ver = Invoke-Step 'verify' @('setup/verify.ps1', '-TargetRoot', $target, '-ConfigPath', $fixture)
if (($ver.Code -ne 0) -or ($ver.Out -notmatch 'VERIFY-OK')) { throw 'verify did not report VERIFY-OK' }

$second = Invoke-Step 'install (second run)' @('install.ps1', '-TargetRoot', $target, '-ConfigPath', $fixture, '-NonInteractive')
if ($second.Code -ne 0) { throw 'the second install failed' }
$m = [regex]::Match($second.Out, 'files\s+OK\s+new (\d+), replaced (\d+)')
if (-not $m.Success) { throw 'the second install did not report a files stage result' }
if (([int]$m.Groups[1].Value -ne 0) -or ([int]$m.Groups[2].Value -ne 0)) {
    throw ('the second install was not idempotent: new ' + $m.Groups[1].Value + ', replaced ' + $m.Groups[2].Value)
}

Write-Output ''
Write-Output ('IDEMPOTENT-OK: ' + $os + ' second install changed nothing (new 0, replaced 0)')
exit 0
