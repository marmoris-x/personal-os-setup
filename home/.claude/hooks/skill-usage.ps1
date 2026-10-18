# skill-usage.ps1 - one CSV line per Skill call, for the monthly /insights review.
#
#   PostToolUse hook, matcher "Skill". Input is the hook JSON on stdin. Output is one line
#   "date,skill name,session id" appended to {{HOME_CMD}}/.personal-os/state/skill-usage.csv.
#   No arguments and no prompt text are written: the log counts usage, it does not archive it.
#
#   LOGGING MUST NEVER BLOCK: every failure (unreadable input, missing fields, a locked file)
#   exits 0 and writes nothing. The registration has no onFailure on purpose.
#
#   -StateFile exists for the test suite only; the registration passes no argument.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [string]$StateFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = @($Input) -join "`n"
    if (-not $raw.Trim()) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    if (-not $payload) { exit 0 }
    if ($payload.tool_name -and [string]$payload.tool_name -ne 'Skill') { exit 0 }

    $skill = ''
    if ($payload.tool_input -and $payload.tool_input.skill) { $skill = [string]$payload.tool_input.skill }
    if (-not $skill.Trim()) { exit 0 }

    $session = ''
    if ($payload.session_id) { $session = [string]$payload.session_id }

    if (-not $StateFile) {
        $homePath = [Environment]::GetFolderPath('UserProfile')
        $StateFile = Join-Path $homePath '.personal-os/state/skill-usage.csv'
    }
    $dir = Split-Path -Parent $StateFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    function Format-Csv([string]$value) {
        if ($value -match '[",\r\n]') { return '"' + ($value -replace '"', '""') + '"' }
        return $value
    }

    $line = (Get-Date).ToString('s') + ',' + (Format-Csv $skill.Trim()) + ',' + (Format-Csv $session) + "`n"
    [IO.File]::AppendAllText($StateFile, $line, (New-Object Text.UTF8Encoding($false)))
}
catch { }

exit 0
