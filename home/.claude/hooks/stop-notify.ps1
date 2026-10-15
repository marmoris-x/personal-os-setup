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
#   With the toast below there is no sleep left at all - the shell owns the
#   notification the moment Show() returns.

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
# Show a Windows notification announcing the turn/task is complete.
#
# Since 2026-10-16 this is a real WINDOWS TOAST (WinRT), not the old
# NotifyIcon "balloon tip". Measured on Windows 11 build 26300: a balloon tip
# from this hook reaches the notification platform NEVER (no entry in
# %LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db for any of the
# 14 NotifyIcon handlers on this machine, while the same process's toast does),
# so the owner saw nothing. The toast is sent under the AUMID of Windows
# PowerShell, whose notifications Windows shows; the owner confirmed both test
# toasts on screen.
#
# The process does NOT have to stay alive any more: Show() hands the toast to
# the shell, which replaces the old Start-Sleep 5 + Dispose() dance. The
# "async": true in settings.json still applies and still costs nothing.
# ---------------------------------------------------------------------------
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml('<toast duration="long"><visual><binding template="ToastText02">' +
        '<text id="1">' + [System.Security.SecurityElement]::Escape('Claude Code') + '</text>' +
        '<text id="2">' + [System.Security.SecurityElement]::Escape('Task completed.') + '</text>' +
        '</binding></visual></toast>')
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\{{PWSH_HOST}}'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
} catch {
    # Fallback if the toast APIs are unavailable: a single beep.
    [System.Console]::Beep(800, 300)
}

exit 0
