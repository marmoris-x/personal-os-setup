# test-block-dangerous.ps1 - prove that the delete guard blocks what it should.
#
#   pwsh -NoProfile -File setup/tests/test-block-dangerous.ps1 [-Hook <path>]
#
# The hook is a PreToolUse hook: it reads the tool call as JSON on stdin and
# exits 2 to block, 0 to allow. This script feeds it one command at a time and
# compares the answer with the expectation.
#
# Run it after every change to the hook. A hook that fails open is worse than
# no hook: it looks like protection and is not.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI
# code page).

param(
    [string]$Hook = (Join-Path $PSScriptRoot '..\..\hooks\block-dangerous.ps1')
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

# The umlauts used below are built from code points and never written into this file: a BOM-less
# .ps1 is read in the ANSI code page by Windows PowerShell 5.1, so a literal umlaut in the source
# could itself arrive wrong and the case would then test a different path than it says (measured
# 2026-10-16). $ue = u with diaeresis, $ae = a with diaeresis.
$ue = [char]0x00FC
$ae = [char]0x00E4

# expected, command
$cases = @(
    @('block', 'Remove-Item "{{DEV}}\Projects\any-project" -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Projects\one, {{DEV}}\Projects\two -Recurse'),
    @('block', 'rm -rf src'),
    @('block', 'rm -fr ./src'),
    @('block', 'rm -r docs'),
    @('block', 'rm --recursive docs'),
    @('block', 'Remove-Item -Recurse -Force node_modules, src'),
    @('block', 'Remove-Item C:\x -Recurse:$true'),
    @('block', 'cmd /c rd /s /q {{DEV}}\Projects\any-project'),
    @('block', 'rmdir {{DEV}}\Projects\old'),
    @('block', 'Get-ChildItem C:\x | Remove-Item -Recurse -Force'),
    @('block', 'Remove-Item $dir -Recurse'),
    @('block', "python -c ""import shutil; shutil.rmtree(r'C:\\vault\\x')"""),
    @('block', "node -e ""require('fs').rmSync('src',{recursive:true})"""),
    @('block', '[System.IO.Directory]::Delete("C:\x", $true)'),
    @('block', 'npx rimraf src'),
    @('block', 'rm -rf ~/.claude'),
    @('block', 'Remove-Item {{HOME_ENV}}\.claude\hooks\x.ps1'),
    @('block', 'Remove-Item "C:\Users\somebody\.claude" -Recurse'),
    @('block', 'Format-Volume -DriveLetter D'),
    @('block', 'diskpart /s script.txt'),
    @('block', 'git reset --hard'),
    @('block', 'git reset --hard origin/main'),
    @('block', 'git clean -fdx'),
    @('block', 'git checkout -- .'),
    @('block', 'git restore .'),
    @('block', 'git stash drop'),
    @('block', 'git rm -r src'),
    @('block', 'git status; rm -rf src'),
    @('block', 'Remove-Item package-lock.json'),
    @('block', 'rm package-lock.json; npm install'),
    @('block', 'del yarn.lock'),
    @('block', 'Remove-Item .\pnpm-lock.yaml -Force'),
    @('block', 'Remove-Item C:\vault\.git\index.lock'),
    @('block', 'rm .git/index.lock'),
    @('block', 'rm -rf ~/.claude #confirmed-by-user'),
    @('block', 'Format-Volume -DriveLetter D #confirmed-by-user'),

    # --- Version 10: scratch roots. Deleting INSIDE one needs no confirmation,
    # --- but the root itself, an escape out of it, and every protection above
    # --- still apply there.
    @('block', 'Remove-Item {{DEV}}\Temp -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\..\Projects\any-project -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\p\..\..\Projects\any-project -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\.claude -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\repo\.git -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\p\package-lock.json -Recurse'),
    @('block', 'Remove-Item $scratchDir -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\x*, {{DEV}}\Temp\y -Recurse -Force'),
    @('block', 'rm -rf {{DEV_BASH}}/Projects/any-project'),
    @('block', 'Remove-Item {{DEV}}\Temp\a, {{DEV}}\Projects\b -Recurse -Force'),
    # A path the tokenizer cannot judge must still ask. The first two have no
    # drive letter at all, the third escapes the temp root, the fourth pairs a
    # scratch path with a variable that points elsewhere.
    @('block', 'Remove-Item \Windows\System32 -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\safe, \Windows\System32 -Recurse -Force'),
    @('block', 'Remove-Item {{TEMP_ENV}}\..\..\evil -Recurse -Force'),
    @('block', 'Remove-Item {{DEV}}\Temp\safe, {{HOME_ENV}}\.claude\y -Recurse -Force'),

    @('allow', 'Remove-Item notes.txt -Force'),
    @('allow', 'Remove-Item .\src\old.js'),
    @('allow', 'del notes.txt'),
    @('allow', 'rm file.txt'),
    @('allow', 'rm -f file.txt'),
    @('allow', 'rm -rf node_modules'),
    @('allow', 'rm -rf node_modules dist .next'),
    @('allow', 'Remove-Item -Recurse -Force .\node_modules'),
    @('allow', 'rd build'),
    @('allow', 'Remove-Item .claude-plugin\x.json'),
    @('allow', 'git reset --soft HEAD~1'),
    @('allow', 'git clean -n -d'),
    @('allow', 'git checkout main'),
    @('allow', 'git restore src/app.js'),
    @('allow', 'git stash pop'),
    @('allow', 'git rm -r --cached node_modules'),
    @('allow', 'git push --force origin main'),
    @('allow', 'git commit -m "remove rm -rf usage"'),
    @('allow', 'npm install'),
    @('allow', 'npm ci'),
    @('allow', 'Get-ChildItem {{DEV}}\Projects -Force'),
    @('allow', 'echo done && Remove-Item build -Recurse'),
    @('allow', 'Copy-Item a b -Recurse'),
    @('allow', 'Move-Item x y -Force'),
    @('allow', 'Remove-Item "{{DEV}}\Projects\any-project" -Recurse -Force #confirmed-by-user'),
    @('allow', 'git reset --hard  # confirmed-by-user'),
    @('allow', 'Remove-Item package-lock.json #confirmed-by-user'),
    @('allow', 'Remove-Item .gitignore'),
    @('allow', 'Remove-Item .github\workflows\old.yml'),
    @('allow', 'Remove-Item package.json.bak'),
    @('allow', 'git rm --cached package-lock.json'),

    # --- Version 10: inside a scratch root, a whole-folder delete is allowed.
    @('allow', 'Remove-Item {{DEV}}\Temp\global-v12 -Recurse -Force'),
    @('allow', 'Remove-Item -Rec {{DEV}}\Temp\somewhere'),
    @('allow', 'Remove-Item {{DEV}}\Temp\a, {{DEV}}\Temp\b -Recurse -Force'),
    @('allow', 'Remove-Item {{DEV}}\Temp\p\.\sub -Recurse -Force'),
    @('allow', 'rm -rf {{DEV_BASH}}/Temp/x'),
    @('allow', 'cmd /c rd /s /q {{DEV}}\Temp\build'),
    @('allow', 'Remove-Item {{TEMP_ENV}}\claude\scratch -Recurse -Force'),
    @('allow', 'Remove-Item $env:Temp\sub -Recurse'),
    # The two ordinary spellings that the first version of the scratch rule got
    # wrong: an if-block and a trailing comment. Their words ("if", "{", "}",
    # "# tidy up") were read as paths, so the delete asked for confirmation.
    @('allow', 'if (Test-Path {{DEV}}\Temp\global-v12\p) { Remove-Item {{DEV}}\Temp\global-v12\p -Recurse -Force }'),
    @('allow', 'if ($true) { Remove-Item {{DEV}}\Temp\global-v12\p -Recurse -Force }'),
    @('allow', 'if (Test-Path {{DEV}}\Temp\p) { Remove-Item -LiteralPath {{DEV}}\Temp\p -Recurse -Force }'),
    @('allow', 'Remove-Item {{DEV}}\Temp\global-v12\p -Recurse -Force # tidy up'),
    @('allow', 'Remove-Item -Path {{DEV}}\Temp\global-v12\p -Recurse'),

    # --- Version 11: the other spellings of the same scratch root. {{DEV_FWD}}/Temp
    # --- and {{DEV_BASH}}/Temp were already judged correctly - these two are
    # --- regression guards, not new behaviour. %TEMP% and %TMP% are cmd's
    # --- spelling and are expanded ONLY in a cmd segment: in bash and in
    # --- PowerShell the same text is a folder literally named "%TEMP%", so
    # --- expanding it there would judge a different path than the one deleted.
    @('allow', 'rm -rf {{DEV_FWD}}/Temp/x'),
    @('allow', 'rm -rf {{DEV_BASH}}/Temp/x/sub'),
    @('allow', 'Remove-Item {{DEV_FWD}}/Temp/a -Recurse -Force'),
    @('allow', 'Remove-Item {{DEV_BASH}}/Temp/a -Recurse -Force'),
    @('allow', 'cmd /c rd /s /q %TEMP%\build'),
    @('allow', 'cmd /c rd /s /q "%TEMP%\claude\scratch"'),
    @('allow', 'cmd /c rd /s /q %TMP%\x'),

    @('block', 'rm -rf {{DEV_FWD}}/Temp'),
    @('block', 'rm -rf {{DEV_BASH}}/Temp'),
    @('block', 'cmd /c rd /s /q %TEMP%'),
    @('block', 'cmd /c rd /s /q %TMP%'),
    @('block', 'cmd /c rd /s /q %TEMP%\..\..\evil'),
    @('block', 'cmd /c rd /s /q %TEMP%\x, {{DEV}}\Projects\y'),
    # Not a cmd segment: the text names a literal folder, so it is an unknown
    # target and still asks.
    @('block', 'rd /s /q %TEMP%\build'),
    @('block', 'rm -rf %TEMP%\x'),
    @('block', 'Remove-Item %TEMP%\a -Recurse -Force'),

    # --- umlauts ---------------------------------------------------------------
    # The guard reads the tool call as raw UTF-8 bytes, so a path with an umlaut must land on
    # exactly the same verdict as the same path spelled in ASCII. Each pair sits next to its twin
    # here, so a difference shows up as one FAIL instead of a silently different path.
    @('block', ('Remove-Item "{{DEV}}\Projects\B' + $ue + 'cher" -Recurse -Force')),
    @('block', 'Remove-Item "{{DEV}}\Projects\Buecher" -Recurse -Force'),
    @('block', ('Remove-Item {{DEV}}\Projects\B' + $ue + 'cher\package-lock.json')),
    @('block', ('Remove-Item "{{VAULT}}\B' + $ue + 'cher M' + $ae + 'rz" -Recurse -Force')),
    @('block', ('Remove-Item "{{DEV}}\Temp\Pr' + $ue + 'fung\.claude" -Recurse -Force')),
    @('block', ('Remove-Item "{{DEV}}\Temp\Pr' + $ue + 'fung\..\..\Projects\B' + $ue + 'cher" -Recurse -Force')),
    @('allow', ('Remove-Item "{{DEV}}\Temp\Pr' + $ue + 'fung\notes.txt"')),
    @('allow', 'Remove-Item "{{DEV}}\Temp\Pruefung\notes.txt"'),
    @('allow', ('Remove-Item {{DEV}}\Temp\Pr' + $ue + 'fung -Recurse -Force')),
    @('allow', ('git commit -m "fix: B' + $ue + 'cher sortiert"'))
)

$errors = 0
foreach ($case in $cases) {
    $expected = $case[0]
    $command = $case[1]
    $payload = (@{ tool_name = 'Bash'; tool_input = @{ command = $command } } | ConvertTo-Json -Compress -Depth 5)

    # The hook writes its block message to stderr on purpose, and Windows
    # PowerShell 5.1 turns a native command's stderr into a *terminating* error
    # when the preference is 'Stop' - the suite would abort on the first blocked
    # case with no verdict at all. So the call runs with the preference relaxed
    # and the verdict comes from the exit code, never from the output.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $payload | & pwsh -NoProfile -File $hookPath 2>$null | Out-Null
        $hookExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }

    $got = if ($hookExit -eq 2) { 'block' } else { 'allow' }

    $ok = $got -eq $expected
    if (-not $ok) { $errors++ }
    $tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} expected {1,-5} | result {2,-5} | {3}" -f $tag, $expected, $got, $command)
}

# --- Input the guard cannot take for granted (version 12: fail closed) ----------
# These feed raw BYTES, because the point is what arrives on stdin: a UTF-8 byte
# order mark, garbage, nothing at all. Expected: 'allow' (exit 0), 'block' (exit 2).
# The message on stderr is checked too, so a block for the wrong reason does not pass.
$engine = (Get-Process -Id $PID).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bom = [byte[]](0xEF, 0xBB, 0xBF)
function New-Payload([string]$command) {
    return (@{ tool_name = 'Bash'; tool_input = @{ command = $command } } | ConvertTo-Json -Compress -Depth 5)
}
function Invoke-HookBytes([byte[]]$bytes) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $engine
    $psi.Arguments = '-NoProfile -File "' + $hookPath + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    # The block message is read as UTF-8 on purpose: the guard writes it as UTF-8 bytes, and
    # before 2026-10-16 the same text went out through [Console]::Error.WriteLine in the console's
    # OEM code page, so an umlaut in a quoted path arrived as mojibake. The cases below match the
    # umlaut itself, so the old bytes would decode to replacement characters and fail here.
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    $err = $proc.StandardError.ReadToEnd()
    $null = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    return @{ Exit = $proc.ExitCode; Err = $err }
}
$safeJson = $utf8.GetBytes((New-Payload 'git status'))
$deleteJson = $utf8.GetBytes((New-Payload 'rm -rf src'))
$rawCases = @(
    @{ Name = 'BOM + harmless command is read and allowed';        Bytes = ($bom + $safeJson);   Want = 'allow'; Text = '' },
    @{ Name = 'BOM + folder delete is read and asks for a yes';    Bytes = ($bom + $deleteJson); Want = 'block'; Text = 'NEEDS CONFIRMATION' },
    @{ Name = 'two BOMs + folder delete still asks for a yes';     Bytes = ($bom + $bom + $deleteJson); Want = 'block'; Text = 'NEEDS CONFIRMATION' },
    @{ Name = 'no BOM + folder delete asks for a yes (control)';   Bytes = $deleteJson;          Want = 'block'; Text = 'NEEDS CONFIRMATION' },
    @{ Name = 'garbage instead of JSON is refused';                Bytes = $utf8.GetBytes('this is not json'); Want = 'block'; Text = 'cannot read' },
    @{ Name = 'BOM + garbage is refused';                          Bytes = ($bom + $utf8.GetBytes('{{{')); Want = 'block'; Text = 'cannot read' },
    @{ Name = 'truncated JSON is refused';                         Bytes = $utf8.GetBytes('{"tool_name":"Bash","tool_input":{"command":"rm -rf sr'); Want = 'block'; Text = 'cannot read' },
    @{ Name = 'empty input is refused';                            Bytes = [byte[]]@();          Want = 'block'; Text = 'cannot read' },
    @{ Name = 'valid JSON without a command is allowed';           Bytes = $utf8.GetBytes('{"tool_name":"Read","tool_input":{"file_path":"x"}}'); Want = 'allow'; Text = '' },
    # The quoted path comes back in the message: this is the umlaut half of the delete case above,
    # read as raw bytes from the same UTF-8 stream the guard writes.
    @{ Name = 'BOM + a delete with an umlaut is read and answered in UTF-8'; Bytes = ($bom + $utf8.GetBytes((New-Payload ('Remove-Item "{{DEV}}\Projects\B' + $ue + 'cher" -Recurse -Force')))); Want = 'block'; Text = ('B' + $ue + 'cher') }
)
$rawTotal = 0
foreach ($rc in $rawCases) {
    $rawTotal++
    $r = Invoke-HookBytes $rc.Bytes
    $got = if ($r.Exit -eq 2) { 'block' } else { 'allow' }
    $ok = ($got -eq $rc.Want) -and ($rc.Text -eq '' -or $r.Err -like ('*' + $rc.Text + '*'))
    if (-not $ok) { $errors++ }
    $tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} expected {1,-5} | result {2,-5} | exit {3} | {4}" -f $tag, $rc.Want, $got, $r.Exit, $rc.Name)
}

Write-Output ''
Write-Output ("Errors: {0} of {1}" -f $errors, ($cases.Count + $rawTotal))
if ($errors -gt 0) { exit 1 }
exit 0
