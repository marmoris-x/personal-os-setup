# start via Start-Process -Verb RunAs (one UAC prompt). Runs register-tasks.ps1 and
# writes everything to {{DEV}}\Temp\life-os-logs\register-tasks.log so the result stays
# readable after the elevated window closes.
$logFile = '{{DEV}}\Temp\life-os-logs\register-tasks.log'
if (-not (Test-Path -LiteralPath (Split-Path -Parent $logFile))) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logFile) | Out-Null
}
$stamp = (Get-Date).ToString('s')
Add-Content -LiteralPath $logFile -Value ("--- run $stamp elevated ---") -Encoding utf8
& "$PSScriptRoot\register-tasks.ps1" *>&1 | Out-File -LiteralPath $logFile -Append -Encoding utf8
Add-Content -LiteralPath $logFile -Value ("exit=" + $LASTEXITCODE) -Encoding utf8
