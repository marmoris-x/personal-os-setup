# stop-notify.ps1
#
# WHAT THIS FILE IS:
#   A Stop hook -- it fires every time Claude Code is about to end its turn.
#   Two jobs: (1) show a Windows balloon notification so the user knows a
#   task finished, and (2) implement the standard "stop_hook_active" loop
#   guard so this hook does not fire a SECOND notification if some OTHER
#   Stop hook (or a prompt-type Stop hook) has already forced Claude to
#   keep going instead of actually stopping.
#
# WHERE THIS FILE LIVES:
#   {{HOME}}\.claude\hooks\stop-notify.ps1
#
# CHANGELOG -- July 2026 audit (see TROUBLESHOOTING.md Bug 9 for the full
# writeup):
#   This file's balloon-notification block used to be described as
#   "non-blocking" in a comment, which was NOT accurate: Start-Sleep is an
#   inherently blocking call, and the settings.json hook entry for "Stop"
#   did not have "async": true set. Since a Stop hook fires at the end of
#   EVERY single turn, that meant every turn paid an extra ~5 real seconds
#   of wall-clock delay waiting for this script to finish sleeping and
#   disposing its notification icon, even though the notification itself has
#   no influence at all on whether/how Claude actually stops (this script
#   never exits with code 2). The fix was NOT made in this script -- it was
#   made in settings.json, by adding "async": true to the Stop hook entry.
#   That is safe specifically because this script always exits 0; it never
#   uses the "block the stop and keep going" exit-2 mechanism, so there is no
#   risk of an async hook's exit code being checked too late to matter.

$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Read stdin and check "stop_hook_active". If Claude Code set this to true,
# it means a Stop hook (possibly this very hook on this exact turn, possibly
# a different one) has already forced a continuation -- i.e. this is not a
# "real" stop yet. In that case, exit immediately WITHOUT showing another
# notification, so the user doesn't get a misleading "done!" balloon while
# the agent is actually still working.
# ---------------------------------------------------------------------------
$raw = [Console]::In.ReadToEnd()
try {
    $data = $raw | ConvertFrom-Json
    if ($data.stop_hook_active -eq $true) {
        exit 0
    }
} catch {
    exit 0
}

# ---------------------------------------------------------------------------
# Show a Windows balloon notification announcing the turn/task is complete.
# ---------------------------------------------------------------------------
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.Visible = $true
    $notify.ShowBalloonTip(
        0,
        'Claude Code',
        'Task completed.',
        [System.Windows.Forms.ToolTipIcon]::Info
    )

    # Keep the balloon visible for 5 seconds before disposing the icon. This
    # blocks THIS SCRIPT for 5 seconds (see the changelog note above for why
    # that's fine now that settings.json marks this hook as async).
    Start-Sleep -Seconds 5
    $notify.Dispose()
} catch {
    # Fallback if the GUI notification APIs are unavailable: a single beep.
    [System.Console]::Beep(800, 300)
}

exit 0
