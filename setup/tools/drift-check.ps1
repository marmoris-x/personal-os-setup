<#
drift-check.ps1 - Does the live system still match this repo?

Runs setup/export.ps1 in -WhatIf mode (nothing is written) and reads its report:
0 new, 0 changed, 0 removed means no drift. Anything else is listed and the
exit code is 1, so the command can gate a release or a session end.

Usage: pwsh setup/tools/drift-check.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$setupDir = Split-Path -Parent $PSScriptRoot
$export = Join-Path $setupDir 'export.ps1'
if (-not (Test-Path -LiteralPath $export)) {
    Write-Output "DRIFT: export.ps1 missing ($export)"
    exit 2
}

$output = & pwsh -NoProfile -File $export -WhatIf 2>&1 | Out-String
$m = [regex]::Match($output, 'EXPORT:\s*(\d+)\s*new,\s*(\d+)\s*changed,\s*(\d+)\s*unchanged,\s*(\d+)\s*removed')
if (-not $m.Success) {
    Write-Output 'DRIFT: export report not readable:'
    Write-Output $output
    exit 2
}
$new = [int]$m.Groups[1].Value
$changed = [int]$m.Groups[2].Value
$removed = [int]$m.Groups[4].Value

foreach ($line in ($output -split "`n")) {
    if ($line -match '^\s{2}(new|changed|removed)\s') { Write-Output $line.TrimEnd() }
}
if ($new + $changed + $removed -eq 0) {
    Write-Output 'DRIFT: none - live system and repo match.'
    exit 0
}
Write-Output ("DRIFT: {0} new, {1} changed, {2} removed - run export.ps1 first." -f $new, $changed, $removed)
exit 1
