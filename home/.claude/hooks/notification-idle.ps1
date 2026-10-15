# notification-idle.ps1
#
# WHAT THIS FILE IS:
#   A Notification hook, scoped to the "idle_prompt" matcher (see
#   settings.json) -- it fires when Claude Code is sitting idle, waiting for
#   the user to type something. Shows a Windows balloon notification so the
#   user (who might be doing something else entirely) knows their input is
#   needed.
#
# WHERE THIS FILE LIVES:
#   {{HOME}}\.claude\hooks\notification-idle.ps1
#
# WHY "async": true IN settings.json MATTERS HERE:
#   This script intentionally sleeps for 5 seconds so the balloon stays
#   visible for a moment before it's cleaned up (Start-Sleep + Dispose()
#   below). Start-Sleep is a genuinely BLOCKING call -- the script itself
#   does not return until those 5 seconds are up. Marking this hook as
#   "async": true in settings.json tells Claude Code not to wait for the
#   hook process to finish before continuing, so this 5-second internal
#   delay does not translate into a 5-second delay for the user/agent.
#   (This mirrors the exact same reasoning as stop-notify.ps1 -- see that
#   file, and TROUBLESHOOTING.md Bug 9, for the fuller writeup.)

$ErrorActionPreference = 'SilentlyContinue'

try {
    # System.Windows.Forms / System.Drawing give us access to the classic
    # Windows "balloon tip" notification via a NotifyIcon in the system tray.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Question
    $notify.Visible = $true
    $notify.ShowBalloonTip(
        0,
        'Claude Code',
        'Waiting for your input.',
        [System.Windows.Forms.ToolTipIcon]::Warning
    )

    # Keep the balloon visible for 5 seconds before disposing the icon.
    Start-Sleep -Seconds 5
    $notify.Dispose()
} catch {
    # Fallback if the GUI notification APIs are unavailable for some reason
    # (e.g. running in a context without a desktop session): play two short
    # beeps instead. A distinct tone/pattern from stop-notify.ps1's single
    # beep, so the two events remain distinguishable by ear alone.
    [System.Console]::Beep(1000, 200)
    Start-Sleep -Milliseconds 100
    [System.Console]::Beep(1000, 200)
}

exit 0
