# test-downloads-guard.ps1 - prove that the Downloads guard blocks what it should.
#
#   powershell -NoProfile -File setup/tests/test-downloads-guard.ps1 [-Hook <path>]
#
# The hook is a PreToolUse hook: it reads the tool call as JSON on stdin and
# exits 2 to block, 0 to allow. This script feeds it one tool call at a time
# and compares the answer with the expectation, under {{PWSH_HOST}} (the
# engine the registration in settings.json uses). The hook keeps no state.
#
# A hook that fails open is worse than no hook. Run this after every change,
# and once against a deliberately broken copy (see the result file).
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI
# code page).

param(
    [string]$Hook = (Join-Path $PSScriptRoot '..\..\hooks\downloads-guard.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Hook)) { Write-Error "hook not found: $Hook"; exit 2 }
$hookPath = (Resolve-Path $Hook).Path

function Invoke-Guard([string]$Tool, [hashtable]$ToolInput, [string]$Cwd = '{{VAULT}}') {
    $payload = (@{ tool_name = $Tool; session_id = 'dgtest'; cwd = $Cwd; tool_input = $ToolInput } |
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

$d = '{{HOME}}\Downloads'

# The umlauts used below are built from code points and never written into this file: a BOM-less
# .ps1 is read in the ANSI code page by Windows PowerShell 5.1, so a literal umlaut in the source
# could itself arrive wrong and the case would then test a path other than the one it names
# (measured 2026-10-16). $ue = u with diaeresis, $ae = a with diaeresis.
$ue = [char]0x00FC
$ae = [char]0x00E4

$cases = @(
    # --- must be blocked -------------------------------------------------
    @{ E = 'block'; T = 'PowerShell'; C = "Move-Item -LiteralPath '$d\Images\a.png' -Destination {{DEV}}\Temp\" },
    @{ E = 'block'; T = 'PowerShell'; C = "Remove-Item '$d\Music\Soundboard\x.mp3'" },
    @{ E = 'block'; T = 'PowerShell'; C = "Rename-Item '$d\Documents\a.pdf' b.pdf" },
    @{ E = 'block'; T = 'PowerShell'; C = "Move-Item {{DEV}}\Temp\a.zip '$d\Compressed\'" },          # moving INTO the folder
    @{ E = 'block'; T = 'PowerShell'; C = "`$base = '$d'; Move-Item `"`$base\Videos\a.mp4`" X" },     # path in a variable
    @{ E = 'block'; T = 'PowerShell'; C = "Set-Location $d; Remove-Item Programs\setup.exe" },       # relative after cd
    @{ E = 'block'; T = 'PowerShell'; C = "[IO.File]::Delete('$d\Compressed\a.rar')" },
    @{ E = 'block'; T = 'PowerShell'; C = "Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('$d\Images\a.png','OnlyErrorDialogs','SendToRecycleBin')" },
    @{ E = 'block'; T = 'PowerShell'; C = "Get-ChildItem '$d\Images' | ForEach-Object { `$_.Delete() }" },
    @{ E = 'block'; T = 'PowerShell'; C = "robocopy '$d\Music' {{DEV}}\Temp\m /MOV" },
    @{ E = 'block'; T = 'PowerShell'; C = "ri '$d\Music\a.mp3'" },
    @{ E = 'block'; T = 'Bash';       C = 'mv {{HOME_BASH}}/Downloads/Videos/a.mp4 /tmp/' },
    @{ E = 'block'; T = 'Bash';       C = 'rm -rf ~/Downloads/Music/Soundboard' },
    @{ E = 'block'; T = 'Bash';       C = 'python -c "import shutil; shutil.move(r\"{{HOME}}\Downloads\Images\a.png\", r\"C:\x\")"' },
    @{ E = 'block'; T = 'Bash';       C = 'cd {{HOME_BASH}}/Downloads && mv Documents/a.pdf /tmp/' },
    @{ E = 'block'; T = 'PowerShell'; C = "Write-Output ok; Remove-Item '$d\Images\a.png'" },        # text segment first, action second
    # --- must be allowed -------------------------------------------------
    @{ E = 'allow'; T = 'PowerShell'; C = "Get-ChildItem -LiteralPath '$d\Images' -Recurse" },
    @{ E = 'allow'; T = 'PowerShell'; C = "Get-FileHash -LiteralPath '$d\Compressed\a.rar'" },
    @{ E = 'allow'; T = 'PowerShell'; C = "Copy-Item '$d\Images\a.png' {{DEV}}\Temp\" },
    @{ E = 'allow'; T = 'PowerShell'; C = "Remove-Item '$d\_Aufraeum-Protokoll.csv'" },               # loose file in Downloads
    @{ E = 'allow'; T = 'PowerShell'; C = "Move-Item '$d\a.pdf' '$d\_Fuer-PersonalOS\'" },           # loose file, no protected folder
    @{ E = 'allow'; T = 'PowerShell'; C = 'Move-Item {{DEV}}\Temp\a {{DEV}}\Temp\b' },
    @{ E = 'allow'; T = 'PowerShell'; C = 'Remove-Item {{HOME}}\OneDriveX\Documents\a.txt' },   # Documents elsewhere, no Downloads
    @{ E = 'allow'; T = 'PowerShell'; C = "Move-Item '$d\Images\a.png' C:\x\ #approved-by-user" },   # the owner said yes
    @{ E = 'allow'; T = 'Bash';       C = 'git commit -m "chore: move files from Downloads\Images to the archive"' },
    @{ E = 'allow'; T = 'Bash';       C = 'git -C {{VAULT}} commit -m "cleanup; rm Downloads\Music"' },
    @{ E = 'allow'; T = 'Bash';       C = 'echo "mv Downloads/Videos/a /tmp"' },
    @{ E = 'allow'; T = 'Bash';       C = 'ls {{HOME_BASH}}/Downloads/Music' },
    @{ E = 'allow'; T = 'Read';       C = $null; I = @{ file_path = "$d\Images\a.png" } },            # other tools are not this guard's job
    @{ E = 'allow'; T = 'Edit';       C = $null; I = @{ file_path = "$d\Documents\a.md" } },
    @{ E = 'allow'; T = 'PowerShell'; C = '' },

    # --- added in 1.1 after the independent review: must be blocked ------------
    @{ E = 'block'; T = 'PowerShell'; C = "Remove-Item -Recurse -Force $d\*" },                      # everything in Downloads
    @{ E = 'block'; T = 'PowerShell'; C = "Remove-Item -Recurse $d" },                                # Downloads itself
    @{ E = 'block'; T = 'PowerShell'; C = "Rename-Item $d Dl2" },
    @{ E = 'block'; T = 'PowerShell'; C = "Get-ChildItem $d -Directory | Remove-Item -Recurse" },     # pipeline = one statement
    @{ E = 'block'; T = 'PowerShell'; C = "Get-ChildItem $d -File -Recurse | Remove-Item" },          # files, but recursive into the folders
    @{ E = 'block'; T = 'PowerShell'; C = "Remove-Item '$d\I*\a.png'" },                             # glob directly under Downloads
    @{ E = 'block'; T = 'PowerShell'; C = "Write-Output `$(Remove-Item '$d\Images\a.png')" },         # substitution inside a text statement
    @{ E = 'block'; T = 'Bash';       C = 'git commit -m "$(rm ~/Downloads/Images/a.png)"' },
    @{ E = 'block'; T = 'Bash';       C = "echo don't ; rm ~/Downloads/Images/a.png" },               # unbalanced quote hides the real command
    @{ E = 'block'; T = 'Bash';       C = 'echo "\"" ; rm ~/Downloads/Images/a.png' },                # escaped quote
    @{ E = 'block'; T = 'Bash';       C = 'find ~/Downloads/Music -delete' },
    @{ E = 'block'; T = 'Bash';       C = "node -e `"require('fs').rmSync('{{HOME_FWD}}/Downloads/Music/a')`"" },
    @{ E = 'block'; T = 'PowerShell'; C = "[Microsoft.VisualBasic.FileIO.FileSystem]::RenameFile('$d\Images\a.png','b.png')" },
    @{ E = 'block'; T = 'PowerShell'; C = "Remove-Item '$d\Images\a.png'; Write-Output `"#approved-by-user`"" },   # marker inside a string, not at the end
    @{ E = 'block'; T = 'PowerShell'; C = 'Remove-Item Images\a.png'; W = $d },                       # relative path, working directory is Downloads
    # --- added in 1.1: must be allowed (false positives of 1.0) -------------------
    @{ E = 'allow'; T = 'PowerShell'; C = "Move-Item '$d\a.pdf' {{HOME}}\Documents\" },         # destination is another Documents
    @{ E = 'allow'; T = 'PowerShell'; C = "Move-Item '$d\a.mp4' {{HOME}}\Videos\" },
    @{ E = 'allow'; T = 'PowerShell'; C = "Move-Item '$d\a.png' {{DEV}}\Temp\Images\" },
    @{ E = 'allow'; T = 'PowerShell'; C = "Copy-Item '$d\Images\a.png' {{DEV}}\Temp\t\; Remove-Item {{DEV}}\Temp\t -Recurse" },   # verb and folder in different statements
    @{ E = 'allow'; T = 'PowerShell'; C = 'Move-Item {{DEV}}\External\Downloads\Images\a C:\x' },      # a different Downloads folder
    @{ E = 'allow'; T = 'PowerShell'; C = 'Remove-Item {{DEV}}\Projects\downloads-tool\docs\Images\x.png' },
    @{ E = 'allow'; T = 'PowerShell'; C = 'Get-Content {{HOME}}\.claude\hooks\downloads-guard.ps1' },
    @{ E = 'allow'; T = 'Bash';       C = "git -C {{DEV}}\Projects\foo mv a.md b.md; Get-ChildItem $d\Images" },
    @{ E = 'allow'; T = 'PowerShell'; C = "Get-ChildItem -LiteralPath '$d' -File | Remove-Item" },      # loose files only
    @{ E = 'allow'; T = 'PowerShell'; C = 'Remove-Item Images\a.png'; W = '{{VAULT}}' },          # relative path, but the working directory is elsewhere

    # --- heredoc bodies: text for cat/tee/git is not a command, for a shell it is ------
    @{ E = 'allow'; T = 'Bash';       C = "cat >> notes.md <<'EOF'`nmoved with Move-Item from Downloads\Images, then Remove-Item Downloads\Music\a`nEOF`n" },
    @{ E = 'allow'; T = 'Bash';       C = "git commit -m `"`$(cat <<'EOF'`nrm ~/Downloads/Music/a (text only)`nEOF`n)`"" },
    @{ E = 'block'; T = 'Bash';       C = "bash <<'EOF'`nrm ~/Downloads/Images/a.png`nEOF`n" },
    @{ E = 'block'; T = 'Bash';       C = "cat <<'EOF' | bash`nrm ~/Downloads/Images/a.png`nEOF`n" },
    @{ E = 'block'; T = 'Bash';       C = "python - <<'EOF'`nimport shutil; shutil.move(r'{{HOME}}\Downloads\Images\a.png', 'x')`nEOF`n" },
    @{ E = 'block'; T = 'Bash';       C = "cat <<'EOF' > x.md`ntext`nEOF`nrm ~/Downloads/Images/a.png`n" },   # a real command AFTER the heredoc

    # --- umlauts: the same path with and without must be judged the same --------
    # The guard reads the tool call as raw UTF-8 bytes, so an umlaut in the path must land on
    # exactly the same verdict as its ASCII twin. Each pair stands next to its twin, so a
    # difference shows up as a FAIL and not as a silently different path.
    @{ E = 'block'; T = 'PowerShell'; C = ('Move-Item "' + $d + '\Documents\B' + $ue + 'cher\a.pdf" {{DEV}}\Temp\') },
    @{ E = 'block'; T = 'PowerShell'; C = ('Move-Item "' + $d + '\Documents\Buecher\a.pdf" {{DEV}}\Temp\') },
    @{ E = 'block'; T = 'Bash';       C = ('rm ~/Downloads/Music/Soundboard/Sch' + $ue + 'tzen/a.mp3') },
    @{ E = 'block'; T = 'PowerShell'; C = ('Remove-Item -Recurse -Force "' + $d + '\Videos\Pr' + $ue + 'fung"') },
    @{ E = 'allow'; T = 'PowerShell'; C = ('Get-ChildItem -LiteralPath "' + $d + '\Documents\B' + $ue + 'cher" -Recurse') },
    @{ E = 'allow'; T = 'PowerShell'; C = ('Get-ChildItem -LiteralPath "' + $d + '\Documents\Buecher" -Recurse') },
    @{ E = 'allow'; T = 'PowerShell'; C = ('Remove-Item "' + $d + '\_Aufraeum-Protokoll M' + $ae + 'rz.csv"') },
    @{ E = 'allow'; T = 'Bash';       C = 'git commit -m "chore: Buecher und Notizen umsortiert"' }
)

foreach ($c in $cases) {
    $in = if ($c.ContainsKey('I')) { $c.I } else { @{ command = $c.C } }
    $label = if ($c.ContainsKey('I')) { $c.T + ': ' + $in.file_path } else { $c.T + ': ' + $c.C }
    if ($c.ContainsKey('W') -and $c.W -like '*Downloads*') { $label = $label + '  [cwd Downloads]' }
    if ($label.Length -gt 120) { $label = $label.Substring(0, 120) + '...' }
    $cwdArg = if ($c.ContainsKey('W')) { $c.W } else { '{{VAULT}}' }
    Judge $label $c.E (Invoke-Guard $c.T $in $cwdArg)
}

# --- fail closed: input that cannot be read ---------------------------------
foreach ($bad in @('', 'not json at all')) {
    $total++
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $bad | & {{PWSH_HOST}} -NoProfile -File $hookPath 2>$null | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    $ok = ($code -eq 2)
    if (-not $ok) { $errors++ }
    Write-Output ("{0} expected block | result {1,-5} | unreadable input: '{2}'" -f $(if ($ok) { 'OK   ' } else { 'FAIL ' }), $(if ($code -eq 2) { 'block' } else { 'allow' }), $bad)
}

# --- umlauts: the quoted path in the message must arrive as UTF-8 ------------
# The guard quotes the statement in its block message. Until 2026-10-16 that message went out
# through [Console]::Error.WriteLine, which writes in the console's OEM code page: the umlaut
# reached the agent as mojibake (measured bytes 81 84 instead of the UTF-8 spellings of ue and
# ae) while the verdict itself stayed right. Stderr is decoded as UTF-8 here ON PURPOSE, so those
# old bytes would come back as replacement characters and this check would fail.
function Invoke-GuardErr([string]$Payload) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = '{{PWSH_HOST}}'
    $psi.Arguments = '-NoProfile -File "' + $hookPath + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    $err = $proc.StandardError.ReadToEnd()
    $null = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    return @{ Exit = $proc.ExitCode; Err = $err }
}
$total++
$umlautCommand = 'Move-Item "' + $d + '\Documents\B' + $ue + 'cher\a.pdf" {{DEV}}\Temp\'
$umlautPayload = (@{ tool_name = 'PowerShell'; session_id = 'dlgtest'; cwd = '{{VAULT}}'; tool_input = @{ command = $umlautCommand } } | ConvertTo-Json -Compress -Depth 6)
$um = Invoke-GuardErr $umlautPayload
$ok = ($um.Exit -eq 2) -and ($um.Err -like ('*B' + $ue + 'cher*'))
if (-not $ok) { $errors++ }
Write-Output ("{0} expected block | result {1,-5} | message quotes the umlaut path as UTF-8: {2}" -f
    $(if ($ok) { 'OK   ' } else { 'FAIL ' }), $(if ($um.Exit -eq 2) { 'block' } else { 'allow' }), $(if ($um.Err -like ('*B' + $ue + 'cher*')) { 'yes' } else { 'no' }))

Write-Output ''
Write-Output ("{0} of {1} cases as expected, {2} errors" -f ($total - $errors), $total, $errors)
if ($errors -gt 0) { exit 1 } else { exit 0 }
