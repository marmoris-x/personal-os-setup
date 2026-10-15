# test-no-license-files.ps1 - prove that the attribution-file guard decides the way it says.
#
#   pwsh -NoProfile -File setup/tests/test-no-license-files.ps1 [-Hook <path>]
#
# The hook is a PreToolUse hook: it reads the tool call as JSON on stdin and exits 2 to block,
# 0 to allow. Every case here is a whole tool call, judged on its own.
#
# The denied cases are built from the same three roots the hook itself carries, so the suite
# runs unchanged on Windows, macOS and Linux: on each system the render gives the hook and this
# file the same values, and the cases then carry that system's own path shapes. The allowed
# cases at the end include paths in all three styles that sit OUTSIDE the roots, plus the tool
# calls the hook must never judge.
#
# A hook that fails open is worse than no hook: it looks like protection and is not. Run this
# after every change to the hook. The -Hook switch exists so a deliberately broken copy can be
# measured (the red proof) without touching the real file.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [string]$Hook = (Join-Path $PSScriptRoot '..\..\hooks\no-license-files.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Hook)) { Write-Error "hook not found: $Hook"; exit 2 }
$hookPath = (Resolve-Path $Hook).Path

function Invoke-Guard([string]$Tool, [hashtable]$ToolInput, [string]$Cwd = '') {
    # "cwd" is a field of the tool call itself, beside tool_input - the same place
    # downloads-guard.ps1 reads it from. It is left out when no folder is given, so the case
    # "relative with no session folder given" really measures the missing field.
    $call = @{ tool_name = $Tool; session_id = 'nlftest'; tool_input = $ToolInput }
    if ($Cwd -ne '') { $call['cwd'] = $Cwd }
    $payload = ($call | ConvertTo-Json -Compress -Depth 6)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $payload | & {{PWSH_HOST}} -NoProfile -File $hookPath 2>$null | Out-Null
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
}

# The three roots, written the way the hook writes them: the render turns each of them into the
# value of the system it runs on, so both files always agree.
$devProjects = '{{DEV}}\Projects'
$vault       = '{{VAULT}}'
$claude      = {{HOME_ENV}} + '\.claude'

# A drive-rooted path in the other two styles, built without a Windows literal: on Windows the
# hook never sees them as INSIDE a root (its roots are drive paths), and on macOS and Linux the
# same holds for the drive style. They are here as the allowed half of the style question.
$posixUser = '/Users/beispiel'
$posixHome = '/home/beispiel'

$errors = 0
$total = 0

function Test-Case([string]$Expected, [string]$Tool, [hashtable]$ToolInput, [string]$What, [string]$Cwd = '') {
    $script:total++
    $code = Invoke-Guard $Tool $ToolInput $Cwd
    $got = if ($code -eq 2) { 'block' } elseif ($code -eq 0) { 'allow' } else { "exit $code" }
    $ok = ($got -eq $Expected)
    if (-not $ok) { $script:errors++ }
    $tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} {1,-6} expected {2,-5} | {3} | {4}" -f $tag, $got, $Expected, $Tool, $What)
}

Write-Output '== denied: an attribution file inside one of the three folders =='
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\LICENSE') } 'LICENSE in a project'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\LICENSE.md') } 'LICENSE.md'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\LICENSE-MIT') } 'LICENSE-MIT'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\COPYING') } 'COPYING'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\NOTICE.txt') } 'NOTICE.txt'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\THIRD-PARTY-NOTICES.md') } 'THIRD-PARTY-NOTICES.md'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\third-party.md') } 'third-party.md, lower case'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\ATTRIBUTION.md') } 'ATTRIBUTION.md'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\license') } 'LICENSE in lower case'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\a\b\c\d\LICENCE') } 'deep below the project root, LICENCE'
Test-Case 'block' 'Edit'  @{ file_path = ($devProjects + '\myrepo\LICENSE') } 'Edit, not only Write'
Test-Case 'block' 'MultiEdit' @{ file_path = ($devProjects + '\myrepo\LICENSE') } 'MultiEdit'
Test-Case 'block' 'Write' @{ file_path = ($vault + '\LICENCE') } 'at the vault root'
Test-Case 'block' 'Write' @{ file_path = ($vault + '\500-sources\docs\COPYING') } 'inside the vault, COPYING'
Test-Case 'block' 'Write' @{ file_path = ($claude + '\LICENSE') } 'at the .claude root'
Test-Case 'block' 'Write' @{ file_path = ($claude + '\skills\reuse-first\LICENSE') } 'inside a skill folder'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo/LICENSE') } 'forward slashes'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\LICENSE') + '\' } 'a trailing separator'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\NOTICE') } 'NOTICE without an extension'
# A relative path is the ordinary shape for a file in the folder the session sits in. The tool
# call carries that folder, and the hook resolves the name against it (review 1, finding 3).
Test-Case 'block' 'Write' @{ file_path = 'LICENSE' } 'relative, resolved against the session folder' ($devProjects + '\myrepo')
Test-Case 'block' 'Write' @{ file_path = 'docs/THIRD-PARTY.md' } 'relative with a subfolder' ($devProjects + '\myrepo')
Test-Case 'block' 'Write' @{ file_path = 'LICENSE' } 'relative inside .claude' ($claude + '\skills\reuse-first')
# ".." is collapsed before the comparison (review 1, finding 4): this one comes back inside.
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\..\other\LICENSE') } 'a branch that returns into the root'

Write-Output ''
Write-Output '== allowed: the same names outside the three folders =='
Test-Case 'allow' 'Write' @{ file_path = ('{{DEV}}\External' + '\some-clone\LICENSE') } 'a cloned repository keeps its files'
Test-Case 'allow' 'Write' @{ file_path = ('{{DEV}}\External' + '\some-clone\THIRD-PARTY.md') } 'the same for the .md spelling'
Test-Case 'allow' 'Write' @{ file_path = ('{{DEV}}\Temp\agent-upgrade\LICENSE') } 'a scratch folder'
Test-Case 'allow' 'Write' @{ file_path = "$posixUser\Downloads\LICENSE" } 'macOS style, outside the roots'
Test-Case 'allow' 'Write' @{ file_path = "$posixHome\Downloads\COPYING" } 'Linux style, outside the roots'
Test-Case 'allow' 'Write' @{ file_path = '/tmp/scratch/NOTICE.txt' } 'Linux style, forward slashes'
Test-Case 'allow' 'Write' @{ file_path = "$devProjects-backup\LICENSE" } 'a folder whose name merely starts with the root'
Test-Case 'allow' 'Write' @{ file_path = "$vault-old\LICENCE" } 'the vault name plus a suffix'
Test-Case 'allow' 'Write' @{ file_path = "$claude-backup\LICENSE" } 'the .claude name plus a suffix'
Test-Case 'allow' 'Write' @{ file_path = "$posixUser\dev\Projects\LICENSE" } 'macOS style project root - not this system''s root'
# The two shapes the ".." step exists for: a branch that leaves the root, and a path with no root
# at all. Both name a file outside the three folders, so both must pass.
Test-Case 'allow' 'Write' @{ file_path = ($devProjects + '\..\External\cl\LICENSE') } 'a branch out of the root lands outside it'
Test-Case 'allow' 'Write' @{ file_path = ($vault + '\..\Temp\COPYING') } 'the same for the vault'
Test-Case 'allow' 'Write' @{ file_path = 'LICENSE' } 'relative, session folder outside the roots' '/tmp/scratch'
Test-Case 'allow' 'Write' @{ file_path = 'LICENSE' } 'relative with no session folder given'

Write-Output ''
Write-Output '== allowed: names inside the folders that are not attribution files =='
Test-Case 'allow' 'Write' @{ file_path = ($devProjects + '\myrepo\README.md') } 'a README'
Test-Case 'allow' 'Write' @{ file_path = ($devProjects + '\myrepo\src\main.py') } 'a source file'
Test-Case 'allow' 'Write' @{ file_path = ($devProjects + '\myrepo\LICENSING.md') } 'LICENSING is not LICENSE - the seventh letter decides'
# The next two are the price of the prefix rule, and they are pinned here so the price stays
# visible: a name that merely BEGINS with one of the words is refused too. The rule names
# LICENSE* and NOTICE*, not "a file that carries terms", and a session that wants a note called
# licence-notes.md has to call it something else. Widening the rule to a word match would let
# LICENSE.md.old through, which is the file that matters.
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\NOTICEBOARD.md') } 'NOTICEBOARD starts with NOTICE - the prefix rule, pinned'
Test-Case 'block' 'Write' @{ file_path = ($devProjects + '\myrepo\licence-notes.md') } 'a name that begins with LICENCE - the prefix rule, pinned'
Test-Case 'allow' 'Write' @{ file_path = ($claude + '\settings.json') } 'an ordinary file in .claude'
Test-Case 'allow' 'Write' @{ file_path = ($vault + '\000-meta\todo.md') } 'an ordinary note in the vault'
Test-Case 'allow' 'Write' @{ file_path = ($devProjects + '\') } 'the project root itself'

Write-Output ''
Write-Output '== allowed: tool calls this hook must never judge =='
Test-Case 'allow' 'Bash' @{ command = 'git clone --depth 1 https://github.com/x/y {{DEV}}\External\y' } 'git clone brings its own files along'
Test-Case 'allow' 'PowerShell' @{ command = 'git clone https://github.com/x/y {{DEV_FWD}}/External/y' } 'the same, other spelling'
Test-Case 'allow' 'Read' @{ file_path = ($devProjects + '\myrepo\LICENSE') } 'reading one is not writing one'
Test-Case 'allow' 'NotebookEdit' @{ notebook_path = ($devProjects + '\myrepo\LICENSE') } 'a notebook path is not judged'
Test-Case 'allow' 'Write' @{ file_path = '' } 'no path at all'
Test-Case 'allow' 'Write' @{} 'no file_path field'

Write-Output ''
Write-Output ("Errors: {0} of {1}" -f $errors, $total)
if ($errors -gt 0) { exit 1 }
exit 0
