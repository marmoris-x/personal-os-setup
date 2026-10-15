# test-archive-guard.ps1 - prove that the archive guard blocks what it should.
#
#   powershell -NoProfile -File setup/tests/test-archive-guard.ps1 [-Hook <path>]
#
# The hook is a PreToolUse hook: it reads the tool call as JSON on stdin and
# exits 2 to block, 0 to allow. This script feeds it one tool call at a time
# and compares the answer with the expectation. It runs the hook under
# {{PWSH_HOST}} - the same engine the registration in settings.json uses.
#
# The hook keeps a read counter per session in ~/.claude/state. The tests use
# session ids that start with "agtest-" and remove those state files before
# and after the run; real sessions are never touched.
#
# A hook that fails open is worse than no hook: it looks like protection and
# is not. Run this after every change to the hook.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI
# code page).

param(
    [string]$Hook = (Join-Path $PSScriptRoot '..\..\hooks\archive-guard.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Hook)) { Write-Error "hook not found: $Hook"; exit 2 }
$hookPath = (Resolve-Path $Hook).Path
$stateGlob = 'archive-guard-agtest-*.json'

$stateDir = Join-Path {{HOME_ENV}} '.claude\state'
function Clear-TestState {
    Get-ChildItem -LiteralPath $stateDir -Filter $stateGlob -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
Clear-TestState

function Invoke-Guard([string]$Tool, [hashtable]$ToolInput, [string]$Session) {
    $payload = (@{ tool_name = $Tool; session_id = $Session; tool_input = $ToolInput } |
        ConvertTo-Json -Compress -Depth 6)
    # The hook writes its block message to stderr on purpose; a native
    # command's stderr must not abort the suite, so the preference is relaxed
    # and the verdict comes from the exit code only.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $payload | & {{PWSH_HOST}} -NoProfile -File $hookPath 2>$null | Out-Null
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
}

$errors = 0
$total = 0
function Judge([string]$Name, [string]$Expect, [int]$Exit) {
    $script:total++
    $got = if ($Exit -eq 2) { 'block' } else { 'allow' }
    $ok = $got -eq $Expect
    if (-not $ok) { $script:errors++ }
    $tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} expected {1,-5} | result {2,-5} | {3}" -f $tag, $Expect, $got, $Name)
}

$sMain = 'agtest-main'
$f600 = '{{VAULT}}\600-archive\01_Example\Bankvertrag.md'

# --- the table: expected, tool, input, session ------------------------------
$cases = @(
    @{ E = 'allow'; T = 'Read';        S = $sMain; I = @{ file_path = $f600 } },
    @{ E = 'allow'; T = 'Read';        S = $sMain; I = @{ file_path = $f600 } },                       # re-read never counts twice
    @{ E = 'allow'; T = 'Read';        S = $sMain; I = @{ file_path = '{{VAULT}}\300-areas\Beispielbereich.md' } },
    @{ E = 'allow'; T = 'Read';        S = $sMain; I = @{ file_path = '{{VAULT}}\400-knowledge\x.md' } },
    @{ E = 'allow'; T = 'Edit';        S = $sMain; I = @{ file_path = '{{VAULT}}\600-archive\Ordner_Gamma\neu.md' } },
    @{ E = 'allow'; T = 'Write';       S = $sMain; I = @{ file_path = '{{VAULT}}\300-areas\Beispielbereich_Zwei.md' } },
    @{ E = 'allow'; T = 'Grep';        S = $sMain; I = @{ pattern = 'IBAN'; path = '{{VAULT}}\600-archive'; head_limit = 50 } },
    @{ E = 'allow'; T = 'Grep';        S = $sMain; I = @{ pattern = 'IBAN'; path = '{{VAULT}}\600-archive'; head_limit = 10 } },
    @{ E = 'allow'; T = 'Grep';        S = $sMain; I = @{ pattern = 'x'; path = '{{VAULT}}\400-knowledge' } },
    @{ E = 'allow'; T = 'Bash';        S = $sMain; I = @{ command = 'Get-Content "{{VAULT}}\600-archive\01_Example\Gehalt.md"' } },
    @{ E = 'allow'; T = 'Bash';        S = $sMain; I = @{ command = 'git -C {{VAULT}} status -sb' } },
    @{ E = 'allow'; T = 'Bash';        S = $sMain; I = @{ command = 'git commit -m "docs: drop 600-archive from git"' } },
    @{ E = 'allow'; T = 'Bash';        S = $sMain; I = @{ command = 'git -C {{VAULT}} commit -m "cleanup; drop 600-archive"' } },
    @{ E = 'allow'; T = 'Bash';        S = $sMain; I = @{ command = 'Get-ChildItem {{VAULT}}\600-archive -Recurse #approved-by-user' } },
    @{ E = 'allow'; T = 'Bash';        S = $sMain; I = @{ command = 'Select-String -Path {{VAULT}}\300-areas\Amt_Beispiel.md -Pattern Amt_Beispiel_Zwei' } },
    @{ E = 'allow'; T = 'Glob';        S = $sMain; I = @{ pattern = '{{VAULT}}\600-archive\01_Example\Bankvertrag.md' } },

    @{ E = 'block'; T = 'Glob';        S = $sMain; I = @{ pattern = '600-archive/**' } },
    @{ E = 'block'; T = 'Glob';        S = $sMain; I = @{ pattern = '*.md'; path = '{{VAULT}}\600-archive' } },
    @{ E = 'block'; T = 'Glob';        S = $sMain; I = @{ pattern = '**/*.md'; path = '{{VAULT}}\300-areas' } },
    @{ E = 'block'; T = 'Grep';        S = $sMain; I = @{ pattern = 'IBAN'; path = '{{VAULT}}\600-archive' } },
    @{ E = 'block'; T = 'Grep';        S = $sMain; I = @{ pattern = 'IBAN'; path = '{{VAULT}}\600-archive'; head_limit = 100 } },
    @{ E = 'block'; T = 'Bash';        S = $sMain; I = @{ command = 'Get-ChildItem {{VAULT}}\600-archive -Recurse' } },
    @{ E = 'block'; T = 'Bash';        S = $sMain; I = @{ command = 'python scan.py {{VAULT}}\600-archive' } },
    @{ E = 'block'; T = 'Bash';        S = $sMain; I = @{ command = 'Select-String -Path {{VAULT}}\600-archive\*\*.md -Pattern IBAN' } },
    @{ E = 'block'; T = 'Bash';        S = $sMain; I = @{ command = 'git -C {{VAULT}} add 600-archive' } },
    @{ E = 'block'; T = 'Read';        S = $sMain; I = @{ file_path = '{{VAULT}}\600-archive\05_Example\Rechnung.pdf' } },
    @{ E = 'block'; T = 'Read';        S = $sMain; I = @{ file_path = '{{VAULT}}\600-archive\archive.base' } },
    @{ E = 'block'; T = 'Edit';        S = $sMain; I = @{ file_path = '{{VAULT}}\600-archive\02_Example\Ausweis.jpg' } },
    @{ E = 'block'; T = 'Bash';        S = $sMain; I = @{ command = 'Copy-Item "{{VAULT}}\600-archive\x\scan.pdf" {{DEV}}\Temp\' } }
)

foreach ($case in $cases) {
    $exit = Invoke-Guard $case.T $case.I $case.S
    Judge (("$($case.T) {0}" -f (($case.I.Values | Select-Object -First 1)))) $case.E $exit
}

# --- the counter: the 11th distinct document asks ---------------------------
$sCount = 'agtest-count'
for ($i = 1; $i -le 10; $i++) {
    $exit = Invoke-Guard 'Read' @{ file_path = ("{{VAULT}}\600-archive\d{0:d2}.md" -f $i) } $sCount
    Judge ("Read d{0:d2} (under the limit)" -f $i) 'allow' $exit
}
$exit = Invoke-Guard 'Read' @{ file_path = '{{VAULT}}\600-archive\d01.md' } $sCount
Judge 're-read d01 does not count again' 'allow' $exit
$exit = Invoke-Guard 'Read' @{ file_path = '{{VAULT}}\600-archive\d11.md' } $sCount
Judge 'the 11th distinct document asks' 'block' $exit

# The same counter is fed by explicit files named in a shell command.
$sCount2 = 'agtest-count2'
$files10 = (1..10 | ForEach-Object { '"{{VAULT}}\600-archive\b{0:d2}.md"' -f $_ }) -join ', '
$cmd10 = 'Get-Content ' + $files10
$exit = Invoke-Guard 'Bash' @{ command = $cmd10 } $sCount2
Judge 'shell command with 10 explicit files is allowed' 'allow' $exit
$exit = Invoke-Guard 'Bash' @{ command = 'Get-Content "{{VAULT}}\600-archive\b11.md"' } $sCount2
Judge 'shell read of the 11th distinct file asks' 'block' $exit

# --- input the guard cannot take for granted (fail closed) ------------------
$engine = (Get-Process -Id $PID).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bom = [byte[]](0xEF, 0xBB, 0xBF)
function Invoke-HookBytes([byte[]]$bytes) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $engine
    $psi.Arguments = '-NoProfile -File "' + $hookPath + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    $err = $proc.StandardError.ReadToEnd()
    $null = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    return @{ Exit = $proc.ExitCode; Err = $err }
}
function New-ReadPayload([string]$path, [string]$session) {
    return (@{ tool_name = 'Read'; session_id = $session; tool_input = @{ file_path = $path } } |
        ConvertTo-Json -Compress -Depth 5)
}
$rawCases = @(
    @{ Name = 'BOM + harmless read is read and allowed'; Bytes = ($bom + $utf8.GetBytes((New-ReadPayload '{{VAULT}}\400-knowledge\x.md' 'agtest-raw'))); Want = 'allow'; Text = '' },
    @{ Name = 'garbage instead of JSON is refused';      Bytes = $utf8.GetBytes('this is not json'); Want = 'block'; Text = 'cannot read' },
    @{ Name = 'empty input is refused';                  Bytes = [byte[]]@(); Want = 'block'; Text = 'cannot read' },
    @{ Name = 'valid JSON without tool_input is allowed'; Bytes = $utf8.GetBytes('{"tool_name":"TodoWrite","session_id":"agtest-raw"}'); Want = 'allow'; Text = '' },
    @{ Name = 'the 11th document message names the limit'; Bytes = $null; Want = 'block'; Text = 'document number 11' }
)
$rawTotal = 0
foreach ($rc in $rawCases) {
    $rawTotal++
    if ($rc.Name -eq 'the 11th document message names the limit') {
        $session = 'agtest-msg'
        foreach ($i in 1..10) {
            $null = Invoke-HookBytes $utf8.GetBytes((New-ReadPayload ("{{VAULT}}\600-archive\m{0:d2}.md" -f $i) $session))
        }
        $r = Invoke-HookBytes $utf8.GetBytes((New-ReadPayload '{{VAULT}}\600-archive\m11.md' $session))
    } else {
        $r = Invoke-HookBytes $rc.Bytes
    }
    $got = if ($r.Exit -eq 2) { 'block' } else { 'allow' }
    $ok = ($got -eq $rc.Want) -and ($rc.Text -eq '' -or $r.Err -like ('*' + $rc.Text + '*'))
    if (-not $ok) { $errors++ }
    $tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} expected {1,-5} | result {2,-5} | exit {3} | {4}" -f $tag, $rc.Want, $got, $r.Exit, $rc.Name)
}

# --- a held state file must not crash the guard (1.1, 2026-10-08) -----------
# Same race as in trifecta-guard 1.1 (see there): another process holding the
# state file used to make the write throw and the call get blocked. This case
# holds the file for 400 ms while the hook records a document read and expects
# the call to stay allowed and the mark to arrive. The unfixed version fails here.
$session = 'agtest-lock'
$stateFile = Join-Path {{HOME_ENV}} ('.claude\state\archive-guard-' + $session + '.json')
$null = New-Item -ItemType File -Path $stateFile -Force
$lock = [IO.File]::Open($stateFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $engine
$psi.Arguments = '-NoProfile -File "' + $hookPath + '"'
$psi.RedirectStandardInput = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$payload = $utf8.GetBytes((New-ReadPayload '{{VAULT}}\600-archive\lock1.md' $session))
$proc.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
$proc.StandardInput.Close()
Start-Sleep -Milliseconds 400
$lock.Close()
$null = $proc.StandardError.ReadToEnd()
$null = $proc.StandardOutput.ReadToEnd()
$proc.WaitForExit()
$stateText = Get-Content -LiteralPath $stateFile -Raw
$ok = ($proc.ExitCode -eq 0) -and ($stateText -like '*lock1.md*')
if (-not $ok) { $errors++ }
$tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
Write-Output ("{0} expected allow | result {1,-5} | held state file: call stays allowed, mark written" -f $tag, $(if ($proc.ExitCode -eq 2) { 'block' } else { 'allow' }))

# --- the other side: locked for the whole run means fail closed, not crash --
# Deterministic (no timing): the lock is held until the process has exited,
# so the write keeps colliding and the call must be BLOCKED through the trap.
$session = 'agtest-nolock'
$stateFile = Join-Path {{HOME_ENV}} ('.claude\state\archive-guard-' + $session + '.json')
$null = New-Item -ItemType File -Path $stateFile -Force
$lock = [IO.File]::Open($stateFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $engine
$psi.Arguments = '-NoProfile -File "' + $hookPath + '"'
$psi.RedirectStandardInput = $true
$psi.RedirectStandardError = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$payload = $utf8.GetBytes((New-ReadPayload '{{VAULT}}\600-archive\lock2.md' $session))
$proc.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
$proc.StandardInput.Close()
$err = $proc.StandardError.ReadToEnd()
$null = $proc.StandardOutput.ReadToEnd()
$proc.WaitForExit()
$lock.Close()
$ok = ($proc.ExitCode -eq 2) -and ($err -like '*unexpected error*')
if (-not $ok) { $errors++ }
$tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
Write-Output ("{0} expected block | result {1,-5} | state file locked for the whole run: blocked (fail closed)" -f $tag, $(if ($proc.ExitCode -eq 2) { 'block' } else { 'allow' }))

Clear-TestState
Write-Output ''
Write-Output ("Errors: {0} of {1}" -f $errors, ($cases.Count + 16 + $rawCases.Count))
if ($errors -gt 0) { exit 1 }
exit 0
