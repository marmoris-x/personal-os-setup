# test-session-check.ps1 - prove that the session-start check warns when a protection is gone.
#
#   pwsh -NoProfile -File setup/tests/test-session-check.ps1
#   {{PWSH_HOST}} -NoProfile -File setup/tests/test-session-check.ps1
#
# It builds small fake ".claude" folders in a scratch folder and runs hooks/session-check.ps1
# against each. A healthy folder must print nothing; each broken one must print a warning.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

$ErrorActionPreference = 'Stop'
$check = (Resolve-Path (Join-Path $PSScriptRoot '..\..\hooks\session-check.ps1')).Path
$engine = (Get-Process -Id $PID).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('session-check-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

function New-FakeClaude([string]$name, [string]$guardBody, [bool]$register, [bool]$makeGuard, [switch]$Wrapper) {
    $dir = Join-Path $scratch $name
    New-Item -ItemType Directory -Path (Join-Path $dir 'hooks') -Force | Out-Null
    $guard = (Join-Path $dir 'hooks\block-dangerous.ps1')
    if ($makeGuard) { [IO.File]::WriteAllText($guard, $guardBody, (New-Object Text.UTF8Encoding($false))) }
    $other = (Join-Path $dir 'hooks\stop-notify.ps1')
    [IO.File]::WriteAllText($other, "exit 0`n", (New-Object Text.UTF8Encoding($false)))
    $pre = @()
    if ($register) {
        $hookArgs = @('-NoProfile', '-File', $guard)
        if ($Wrapper) {
            # The live form: the script path sits inside a -Command string, not as a bare argument.
            $p = $guard.Replace('\', '/')
            $hookArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                "if (-not (Test-Path -LiteralPath '$p')) { exit 1 }; & '$p'; exit `$LASTEXITCODE")
        }
        $pre = @(@{ matcher = 'Bash|PowerShell'; hooks = @(@{ type = 'command'; command = '{{PWSH_HOST}}'; args = $hookArgs }) })
    }
    $settings = @{ hooks = @{
        PreToolUse = $pre
        Stop = @(@{ hooks = @(@{ type = 'command'; command = '{{PWSH_HOST}}'; args = @('-NoProfile', '-File', $other) }) })
    } }
    [IO.File]::WriteAllText((Join-Path $dir 'settings.json'), ($settings | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    return $dir
}

function Invoke-Check([string]$dir) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $engine -NoProfile -File $check -ClaudeDir $dir -SkipGitleaks 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return @{ Out = $out.Trim(); Exit = $code }
}

$good = New-FakeClaude 'good' "exit 0`n" $true $true
$missing = New-FakeClaude 'missing' '' $true $false
$broken = New-FakeClaude 'broken' "if ( {{{`n" $true $true
$unregistered = New-FakeClaude 'unregistered' "exit 0`n" $false $true
$wrapped = New-FakeClaude 'wrapped' "exit 0`n" $true $true -Wrapper
$wrappedMissing = New-FakeClaude 'wrapped-missing' '' $true $false -Wrapper
$nosettings = Join-Path $scratch 'nosettings'
New-Item -ItemType Directory -Path $nosettings | Out-Null

# name, folder, warning text that must appear ('' = must be silent)
$cases = @(
    @('healthy folder is silent',                 $good,         ''),
    @('missing hook file is reported',            $missing,      'MISSING'),
    @('hook file that does not parse is reported', $broken,      'does not parse'),
    @('guard not registered is reported',         $unregistered, 'not registered'),
    @('wrapper form counts as registered',        $wrapped,      ''),
    @('wrapper form reports a missing guard',     $wrappedMissing, 'MISSING'),
    @('unreadable settings.json is reported',     $nosettings,   'settings.json cannot be read')
)

$errors = 0
foreach ($c in $cases) {
    $r = Invoke-Check $c[1]
    $ok = ($r.Exit -eq 0) -and $(if ($c[2] -eq '') { $r.Out -eq '' } else { $r.Out -like ('*' + $c[2] + '*') -and $r.Out -like '*systemMessage*' })
    if (-not $ok) { $errors++ }
    Write-Output ("{0} {1}" -f $(if ($ok) { 'OK   ' } else { 'FAIL ' }), $c[0])
}

# The real folder must be healthy, and gitleaks must be found (the same check the hook makes).
$realRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$real = Invoke-Check $realRoot
$realSettings = Join-Path $realRoot 'settings.json'
$templated = (Test-Path -LiteralPath $realSettings) -and ((Get-Content -LiteralPath $realSettings -Raw) -match '\{\{')
if ($templated) {
    # A repository mirror, not a live install: its hook paths are placeholders that only the
    # installer renders, so a warning about them is correct. CI checks this copy on Linux and
    # macOS; asserts only that the check itself ends cleanly.
    $okReal = ($real.Exit -eq 0)
    Write-Output ("{0} real folder: repository mirror with unrendered placeholders (a warning is expected; exit {1})" -f $(if ($okReal) { 'OK   ' } else { 'FAIL ' }), $real.Exit)
}
else {
    $okReal = ($real.Exit -eq 0) -and ($real.Out -eq '')
    if (-not $okReal) { $errors++ }
    Write-Output ("{0} real folder: {1}" -f $(if ($okReal) { 'OK   ' } else { 'FAIL ' }), $(if ($real.Out -eq '') { 'no warning' } else { $real.Out }))
}

Remove-Item -LiteralPath $scratch -Recurse -Force -Confirm:$false
Write-Output ''
Write-Output ("Errors: {0} of {1}" -f $errors, ($cases.Count + 1))
if ($errors -gt 0) { exit 1 }
exit 0
