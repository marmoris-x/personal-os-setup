# test-skill-usage.ps1 - prove the Skill PostToolUse logger.
#
#   pwsh -NoProfile -File setup/tests/test-skill-usage.ps1 [-Hook <path>]
#
# The hook appends "date,skill name,session id" to a CSV. It must never block:
# invalid input exits 0, no skill name means no line, and no prompt text or argument
# reaches the log. -StateFile exists for this suite only; the registration passes none.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [string]$Hook = (Join-Path $PSScriptRoot '..\..\hooks\skill-usage.ps1')
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$workRoot = if ($env:POS_BATCH_TEST_DIR) { $env:POS_BATCH_TEST_DIR } else { [IO.Path]::GetTempPath() }
$work = Join-Path $workRoot ('skill-usage-test-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$state = Join-Path $work 'skill-usage.csv'

$errors = 0
$total = 0
function Judge([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:total++
    if (-not $Ok) { $script:errors++ }
    $tag = if ($Ok) { 'OK   ' } else { 'FAIL ' }
    # Detail only on a failure: check.ps1 scans every line for "N failed/errors" and a passing
    # line carrying such a number would turn a green suite red (measured in CI).
    if ($Detail -and -not $Ok) { $Detail = '  ' + $Detail } else { $Detail = '' }
    Write-Output ((("{0} {1}" -f $tag, $Name)) + $Detail)
}

function Invoke-Hook([string]$Payload) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $Payload | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Hook -StateFile $state 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ Output = $out; Code = $code }
}

if (-not (Test-Path -LiteralPath $Hook)) {
    Write-Output ('FAIL  skill-usage hook not found: ' + $Hook)
    Write-Output ''
    Write-Output ('0 of 1 cases as expected, 1 errors')
    exit 1
}

# --- 1. a valid Skill call is logged, without the argument text -------------
$payload = @{
    session_id = 'sess-123'
    tool_name  = 'Skill'
    tool_input = @{ skill = 'research'; args = 'SECRET-ARGUMENT-TEXT' }
    prompt     = 'SECRET-PROMPT-TEXT'
} | ConvertTo-Json -Compress -Depth 5
$r = Invoke-Hook $payload
$lines = @()
if (Test-Path -LiteralPath $state) { $lines = @(Get-Content -LiteralPath $state -Encoding utf8 | Where-Object { $_.Trim() }) }
Judge 'valid call: exit 0' ($r.Code -eq 0) ('exit=' + $r.Code)
Judge 'valid call: exactly one line' ($lines.Count -eq 1) ('lines=' + $lines.Count)
Judge 'valid call: date, skill, session' (($lines.Count -eq 1) -and ($lines[0] -match '^\d{4}-\d{2}-\d{2}T[0-9:]{8},research,sess-123$')) ('line=' + $lines[0])
Judge 'valid call: no argument or prompt text' (($lines -join "`n") -notmatch 'SECRET') ''

# --- 2. a second call appends ----------------------------------------------
$payload2 = @{ session_id = 'sess-456'; tool_name = 'Skill'; tool_input = @{ skill = 'quick-research' } } | ConvertTo-Json -Compress -Depth 5
$null = Invoke-Hook $payload2
$lines = @(Get-Content -LiteralPath $state -Encoding utf8 | Where-Object { $_.Trim() })
Judge 'second call: two lines' ($lines.Count -eq 2) ('lines=' + $lines.Count)
Judge 'second call: second skill named' ($lines[1] -match ',quick-research,sess-456$') ('line=' + $lines[1])

# --- 3. no skill name: no line, still no block ------------------------------
$payload3 = @{ session_id = 'sess-789'; tool_name = 'Skill'; tool_input = @{ args = 'x' } } | ConvertTo-Json -Compress -Depth 5
$r3 = Invoke-Hook $payload3
$lines = @(Get-Content -LiteralPath $state -Encoding utf8 | Where-Object { $_.Trim() })
Judge 'missing skill: exit 0' ($r3.Code -eq 0) ('exit=' + $r3.Code)
Judge 'missing skill: no new line' ($lines.Count -eq 2) ('lines=' + $lines.Count)

# --- 4. invalid JSON: no crash, no line, exit 0 ----------------------------
$r4 = Invoke-Hook 'this is not json'
$lines = @(Get-Content -LiteralPath $state -Encoding utf8 | Where-Object { $_.Trim() })
Judge 'invalid JSON: exit 0' ($r4.Code -eq 0) ('exit=' + $r4.Code)
Judge 'invalid JSON: no new line' ($lines.Count -eq 2) ('lines=' + $lines.Count)

# --- 5. a skill name with a comma is quoted, not split ---------------------
$payload5 = @{ session_id = 'sess-999'; tool_name = 'Skill'; tool_input = @{ skill = 'a,b' } } | ConvertTo-Json -Compress -Depth 5
$null = Invoke-Hook $payload5
$last = @(Get-Content -LiteralPath $state -Encoding utf8 | Where-Object { $_.Trim() }) | Select-Object -Last 1
Judge 'comma in skill: quoted field' ($last -match ',"a,b",sess-999$') ('line=' + $last)

Write-Output ''
Write-Output ("{0} of {1} cases as expected, {2} errors" -f ($total - $errors), $total, $errors)
if ($errors -gt 0) { exit 1 } else { exit 0 }
