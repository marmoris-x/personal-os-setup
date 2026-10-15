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
#   It mattered because the old balloon needed Start-Sleep + Dispose() to stay
#   on screen: a genuinely BLOCKING call that would have delayed every idle
#   notification by 5 seconds without it. The toast below has no sleep left -
#   the shell owns the notification the moment Show() returns - so "async"
#   costs nothing either way and stays set. (Same reasoning as stop-notify.ps1;
#   see that file, and TROUBLESHOOTING.md Bug 9, for the fuller writeup.)

$ErrorActionPreference = 'SilentlyContinue'

try {
    # A real Windows TOAST (WinRT), not the old NotifyIcon "balloon tip" - see
    # stop-notify.ps1 for the measurement behind that change (2026-10-16): a
    # balloon from this hook never reaches the notification platform on this
    # Windows build, a toast under the Windows PowerShell AUMID does.
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml('<toast duration="long"><visual><binding template="ToastText02">' +
        '<text id="1">' + [System.Security.SecurityElement]::Escape('Claude Code') + '</text>' +
        '<text id="2">' + [System.Security.SecurityElement]::Escape('Waiting for your input.') + '</text>' +
        '</binding></visual></toast>')
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\{{PWSH_HOST}}'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
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
