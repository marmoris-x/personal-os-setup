# test-trifecta-guard.ps1 - prove that outside web content and 600-archive
# content can never meet in one session.
#
#   powershell -NoProfile -File setup/tests/test-trifecta-guard.ps1 [-Hook <path>]
#
# The hook is a PreToolUse hook: it reads the tool call as JSON on stdin and
# exits 2 to block, 0 to allow. The tests feed whole call sequences, because
# the hook's verdict depends on what the session did before.
#
# The hook keeps its state per session in ~/.claude/state. The tests use
# session ids that start with "tgtest-" and remove those state files before
# and after the run; real sessions are never touched.
#
# A hook that fails open is worse than no hook: it looks like protection and
# is not. Run this after every change to the hook.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI
# code page).

param(
    [string]$Hook = (Join-Path $PSScriptRoot '..\..\hooks\trifecta-guard.ps1')
)

$ErrorActionPreference = 'Stop'
# The tool call travels to the hook through a PowerShell pipe, and Windows PowerShell 5.1 encodes
# such a pipe with $OutputEncoding, which is us-ascii there: an umlaut in a path reached the hook
# as '?', the guard read a wildcard where the case meant a letter, and the umlaut cases tested
# nothing - two suites even went red under 5.1 because of it (measured 2026-10-16). UTF-8 for the
# pipe on both hosts, so the bytes that arrive are the bytes the case wrote.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)


if (-not (Test-Path $Hook)) { Write-Error "hook not found: $Hook"; exit 2 }
$hookPath = (Resolve-Path $Hook).Path

$stateDir = Join-Path {{HOME_ENV}} '.claude\state'
function Clear-TestState {
    Get-ChildItem -LiteralPath $stateDir -Filter 'trifecta-tgtest-*.json' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
Clear-TestState

function Invoke-Guard([string]$Tool, [hashtable]$ToolInput, [string]$Session) {
    $payload = (@{ tool_name = $Tool; session_id = $Session; tool_input = $ToolInput } |
        ConvertTo-Json -Compress -Depth 6)
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

$read600 = @{ file_path = '{{VAULT}}\600-archive\01_Example\Bankvertrag.md' }

# The umlaut used below is built from a code point and never written into this file: a BOM-less
# .ps1 is read in the ANSI code page by Windows PowerShell 5.1, so a literal umlaut in the source
# could itself arrive wrong (measured 2026-10-16). $ue = u with diaeresis.
$ue = [char]0x00FC
$grep600 = @{ pattern = 'IBAN'; path = '{{VAULT}}\600-archive'; head_limit = 50 }
$web = @{ url = 'https://example.com'; prompt = 'x' }
$mcp = @{ query = 'x' }

# --- sequences: expected, tool, input, session (order matters) --------------
$cases = @(
    # web-only sessions stay open
    @{ E = 'allow'; T = 'WebFetch';  S = 'tgtest-web';   I = $web },
    @{ E = 'allow'; T = 'WebSearch'; S = 'tgtest-web';   I = @{ query = 'x' } },
    @{ E = 'allow'; T = 'mcp__exa__web_search_exa'; S = 'tgtest-web'; I = $mcp },

    # archive-only sessions stay open
    @{ E = 'allow'; T = 'Read';  S = 'tgtest-arch'; I = $read600 },
    @{ E = 'allow'; T = 'Read';  S = 'tgtest-arch'; I = $read600 },
    @{ E = 'allow'; T = 'Grep';  S = 'tgtest-arch'; I = $grep600 },
    @{ E = 'allow'; T = 'Bash';  S = 'tgtest-arch'; I = @{ command = 'Get-ChildItem {{VAULT}}\600-archive' } },

    # foreign first, then every kind of archive access is blocked
    @{ E = 'allow'; T = 'WebSearch'; S = 'tgtest-f2a'; I = @{ query = 'x' } },
    @{ E = 'block'; T = 'Read';      S = 'tgtest-f2a'; I = $read600 },
    @{ E = 'block'; T = 'Grep';      S = 'tgtest-f2a'; I = $grep600 },
    @{ E = 'block'; T = 'Bash';      S = 'tgtest-f2a'; I = @{ command = 'Get-ChildItem {{VAULT}}\600-archive' } },
    @{ E = 'block'; T = 'Bash';      S = 'tgtest-f2a'; I = @{ command = 'Get-Content "{{VAULT}}\600-archive\01_Example\Gehalt.md"' } },
    @{ E = 'block'; T = 'Bash';      S = 'tgtest-f2a'; I = @{ command = 'Get-ChildItem {{VAULT}}\600-archive #approved-by-user' } },

    # archive first, then every kind of outside content is blocked
    @{ E = 'allow'; T = 'Read';      S = 'tgtest-a2f'; I = $read600 },
    @{ E = 'block'; T = 'WebFetch';  S = 'tgtest-a2f'; I = $web },
    @{ E = 'block'; T = 'WebSearch'; S = 'tgtest-a2f'; I = @{ query = 'x' } },
    @{ E = 'block'; T = 'mcp__exa__web_search_exa'; S = 'tgtest-a2f'; I = $mcp },
    @{ E = 'block'; T = 'Bash';      S = 'tgtest-a2f'; I = @{ command = 'curl.exe https://example.com -o page.html' } },
    @{ E = 'block'; T = 'Bash';      S = 'tgtest-a2f'; I = @{ command = 'python {{HOME}}\.claude\skills\research\scripts\save_pages.py work' } },

    # the network command itself opens the foreign side
    @{ E = 'allow'; T = 'Bash'; S = 'tgtest-curl'; I = @{ command = 'curl.exe https://example.com -o page.html' } },
    @{ E = 'block'; T = 'Read'; S = 'tgtest-curl'; I = $read600 },
    @{ E = 'allow'; T = 'Bash'; S = 'tgtest-iwr';  I = @{ command = 'Invoke-WebRequest https://example.com -OutFile page.html' } },
    @{ E = 'block'; T = 'Read'; S = 'tgtest-iwr';  I = $read600 },
    @{ E = 'allow'; T = 'Bash'; S = 'tgtest-research'; I = @{ command = 'python {{HOME}}\.claude\skills\research\scripts\save_pages.py work' } },
    @{ E = 'block'; T = 'Read'; S = 'tgtest-research'; I = $read600 },

    # ... but a research script is itself outside content: in an open web
    # session it is fine (only the OTHER side, the archive, gets blocked).
    @{ E = 'allow'; T = 'WebFetch'; S = 'tgtest-script2'; I = $web },
    @{ E = 'allow'; T = 'Bash'; S = 'tgtest-script2'; I = @{ command = 'python {{HOME}}\.claude\skills\research\scripts\verify_evidence.py w' } },

    # text-only mentions are not archive access, and 300-areas is not the archive
    @{ E = 'allow'; T = 'Bash';     S = 'tgtest-text'; I = @{ command = 'git commit -m "docs: drop 600-archive from git"' } },
    @{ E = 'allow'; T = 'WebFetch'; S = 'tgtest-text'; I = $web },
    @{ E = 'allow'; T = 'Bash';     S = 'tgtest-text'; I = @{ command = 'echo 600-archive' } },
    @{ E = 'allow'; T = 'WebFetch'; S = 'tgtest-text'; I = $web },
    # A commit message with a semicolon and the -C form: quotes hold the
    # segment together and the text exemption knows git -C ... commit. The
    # following WebFetch proves the commit did NOT mark the session.
    @{ E = 'allow'; T = 'Bash';     S = 'tgtest-text'; I = @{ command = 'git -C {{VAULT}} commit -m "cleanup first; note about 600-archive"' } },
    @{ E = 'allow'; T = 'WebFetch'; S = 'tgtest-text'; I = $web },
    @{ E = 'allow'; T = 'Read';     S = 'tgtest-300'; I = @{ file_path = '{{VAULT}}\300-areas\Amt_Beispiel.md' } },
    @{ E = 'allow'; T = 'WebFetch'; S = 'tgtest-300'; I = $web },
    @{ E = 'allow'; T = 'Read';     S = 'tgtest-400'; I = @{ file_path = '{{VAULT}}\400-knowledge\x.md' } },
    @{ E = 'allow'; T = 'WebFetch'; S = 'tgtest-400'; I = $web },

    # --- umlauts: the folder the rule looks at is ASCII, the decision must not change ---
    # The guard reads the tool call as raw UTF-8 bytes, so a note whose PATH carries an umlaut is
    # archive access exactly like its ASCII twin - before the umlaut note and after it, and in a
    # web-first session too. Each pair stands next to its twin, so a difference is one FAIL. The
    # umlauts are built from code points: a BOM-less .ps1 is read in the ANSI code page by Windows
    # PowerShell 5.1, so a literal umlaut here could arrive wrong and test another path (measured
    # 2026-10-16). The messages of this guard are fixed text and carry no path, so there is no
    # message byte case to measure here.
    @{ E = 'allow'; T = 'Read';      S = 'tgtest-uml';  I = @{ file_path = ('{{VAULT}}\600-archive\B' + $ue + 'cher\Bankvertrag.md') } },
    @{ E = 'allow'; T = 'Read';      S = 'tgtest-uml';  I = @{ file_path = '{{VAULT}}\600-archive\Buecher\Bankvertrag.md' } },
    @{ E = 'block'; T = 'WebSearch'; S = 'tgtest-uml';  I = @{ query = 'x' } },
    @{ E = 'allow'; T = 'WebSearch'; S = 'tgtest-uml2'; I = @{ query = 'x' } },
    @{ E = 'block'; T = 'Read';      S = 'tgtest-uml2'; I = @{ file_path = ('{{VAULT}}\600-archive\B' + $ue + 'cher\Bankvertrag.md') } },
    @{ E = 'block'; T = 'Read';      S = 'tgtest-uml2'; I = @{ file_path = '{{VAULT}}\600-archive\Buecher\Bankvertrag.md' } },
    @{ E = 'allow'; T = 'Read';      S = 'tgtest-uml3'; I = @{ file_path = ('{{VAULT}}\400-knowledge\Notizen B' + $ue + 'cher.md') } },
    @{ E = 'allow'; T = 'WebFetch';  S = 'tgtest-uml3'; I = $web }
)

foreach ($case in $cases) {
    $exit = Invoke-Guard $case.T $case.I $case.S
    Judge ("[{0}] {1}" -f $case.S, $case.T) $case.E $exit
}

# --- fail closed, and the message the user should see -----------------------
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
function New-PayloadJson([string]$tool, [hashtable]$ToolInput, [string]$session) {
    return (@{ tool_name = $tool; session_id = $session; tool_input = $ToolInput } |
        ConvertTo-Json -Compress -Depth 5)
}

$rawCases = @(
    @{ Name = 'BOM + harmless web call is allowed'; Bytes = ($bom + $utf8.GetBytes((New-PayloadJson 'WebFetch' $web 'tgtest-raw'))); Want = 'allow'; Text = '' },
    @{ Name = 'garbage instead of JSON is refused'; Bytes = $utf8.GetBytes('this is not json'); Want = 'block'; Text = 'cannot read' },
    @{ Name = 'empty input is refused';             Bytes = [byte[]]@(); Want = 'block'; Text = 'cannot read' }
)
foreach ($rc in $rawCases) {
    $total++
    $r = Invoke-HookBytes $rc.Bytes
    $got = if ($r.Exit -eq 2) { 'block' } else { 'allow' }
    $ok = ($got -eq $rc.Want) -and ($rc.Text -eq '' -or $r.Err -like ('*' + $rc.Text + '*'))
    if (-not $ok) { $errors++ }
    $tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} expected {1,-5} | result {2,-5} | exit {3} | {4}" -f $tag, $rc.Want, $got, $r.Exit, $rc.Name)
}

# The user-facing sentence must survive into the message.
$total++
$session = 'tgtest-msg'
$null = Invoke-HookBytes $utf8.GetBytes((New-PayloadJson 'WebFetch' $web $session))
$r = Invoke-HookBytes $utf8.GetBytes((New-PayloadJson 'Read' $read600 $session))
$ok = ($r.Exit -eq 2) -and ($r.Err -like '*Fuer das andere bitte eine neue Sitzung starten*') -and ($r.Err -like '*new session*')
if (-not $ok) { $errors++ }
$tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
Write-Output ("{0} expected block | result {1} | the block message tells the user to start a new session" -f $tag, $(if ($r.Exit -eq 2) { 'block' } else { 'allow' }))

# --- a held state file must not crash the guard (1.1, 2026-10-08) -----------
# Another process holding the state file used to make the write throw and the
# call get blocked (fail-closed crash, measured 1 of 40 concurrent calls). The
# write now retries; this case holds the file for 400 ms and expects the call
# to stay allowed and the mark to arrive. The unfixed version fails here.
$total++
$session = 'tgtest-lock'
$stateFile = Join-Path {{HOME_ENV}} ('.claude\state\trifecta-' + $session + '.json')
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
$payload = $utf8.GetBytes((New-PayloadJson 'mcp__exa__web_search_exa' @{ query = 'x' } $session))
$proc.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
$proc.StandardInput.Close()
Start-Sleep -Milliseconds 400
$lock.Close()
$null = $proc.StandardError.ReadToEnd()
$null = $proc.StandardOutput.ReadToEnd()
$proc.WaitForExit()
$stateText = Get-Content -LiteralPath $stateFile -Raw
$ok = ($proc.ExitCode -eq 0) -and ($stateText -like '*"foreign":true*')
if (-not $ok) { $errors++ }
$tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
Write-Output ("{0} expected allow | result {1,-5} | held state file: call stays allowed, mark written" -f $tag, $(if ($proc.ExitCode -eq 2) { 'block' } else { 'allow' }))

# --- the other side: locked for the whole run means fail closed, not crash --
# Deterministic (no timing): the lock is held until the process has exited,
# so the write keeps colliding and the call must be BLOCKED through the trap.
$total++
$session = 'tgtest-nolock'
$stateFile = Join-Path {{HOME_ENV}} ('.claude\state\trifecta-' + $session + '.json')
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
$payload = $utf8.GetBytes((New-PayloadJson 'mcp__exa__web_search_exa' @{ query = 'x' } $session))
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
Write-Output ("Errors: {0} of {1}" -f $errors, $total)
if ($errors -gt 0) { exit 1 }
exit 0
