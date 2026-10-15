# register-tasks.ps1 - registers the two Windows scheduled tasks for the Life OS morning run.
#
# Both tasks run morning.ps1 as the current user, only while the user is logged on (no stored
# Windows password). Triggers: at logon with a 2-minute delay, and daily at {{MORNING_TIME}}. A missed
# start runs as soon as possible; battery is no obstacle; a second instance never starts.
# Running it again replaces the tasks (idempotent). Run it as the normal user, not elevated.

param(
    [string]$TaskName = 'Life OS Morning',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'morning.ps1'),
    [string]$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\{{PWSH_HOST}}"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "morning.ps1 not found at $ScriptPath" }

$action = New-ScheduledTaskAction -Execute $PowerShellExe `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"')

$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
$triggerLogon.Delay = 'PT2M'
$triggerDaily = New-ScheduledTaskTrigger -Daily -At '{{MORNING_TIME}}'

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 45)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($triggerLogon, $triggerDaily) `
    -Settings $settings -Description 'Life OS morning run: transcription (faster-whisper), life log (claude-ds), cleanup' | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ('registered: ' + $task.TaskName + ' (' + $task.State + ')')
foreach ($t in $task.Triggers) {
    if ($t.Delay) { Write-Host ('  trigger: logon + ' + $t.Delay) } else { Write-Host ('  trigger: daily ' + $t.StartBoundary) }
}
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ('  next run: ' + $info.NextRunTime)
