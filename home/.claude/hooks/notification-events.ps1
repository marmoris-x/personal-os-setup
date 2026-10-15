# notification-events.ps1
#
# WHAT THIS FILE IS:
#   A Notification hook, scoped to matcher "permission_prompt|agent_needs_input
#   |agent_completed" (see settings.json). Complements notification-idle.ps1,
#   which only covers "idle_prompt". Together the two cover every Notification
#   type documented in the official hooks reference except the MCP
#   elicitation ones (elicitation_dialog/complete/response) and auth_success,
#   which aren't relevant to this setup (no MCP servers configured; auth
#   already handled by the DeepSeek API key, not /login).
#
# WHY THIS WAS ADDED (added later, alongside the tools.md currency pass):
#   1. Claude Code's own built-in Auto Mode classifier can still hard-block a
#      small set of destructive operations regardless of this setup's own
#      hooks (see TROUBLESHOOTING.md, "Version 4 change" section). That shows
#      up as a permission_prompt notification -- without this hook, the only
#      way to notice is to be looking at the terminal at that exact moment.
#   2. Subagents run in the background by default as of Claude Code v2.1.198
#      (see rules/tools.md, "Reliability & fallback settings"). With
#      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 also on, background work is now
#      the common case, not the exception -- agent_needs_input/agent_completed
#      are how you find out a background subagent or teammate needs you or
#      has finished, without watching the terminal for it.
#
# WHERE THIS FILE LIVES:
#   {{HOME}}\.claude\hooks\notification-events.ps1
#
# DESIGN NOTE -- why this reads "message"/"title" from stdin instead of
# hardcoding text per event type, unlike notification-idle.ps1:
#   The idle case is always the same situation, so a fixed message
#   ("Waiting for your input.") makes sense there. These three notification
#   types describe genuinely different situations, and Claude Code already
#   sends the right text for each one in the "message" and (optionally)
#   "title" JSON fields -- see the official hooks reference, "Notification
#   input". Reusing that instead of hardcoding per-type text here means this
#   script keeps working correctly even if Anthropic adds another
#   notification type to this matcher later, with zero changes needed here.
#
# WHY "async": true IN settings.json MATTERS HERE:
#   Same reasoning as notification-idle.ps1 and stop-notify.ps1 -- see
#   TROUBLESHOOTING.md Bug 9 for the fuller writeup. This script sleeps
#   briefly so the balloon is visible before it's cleaned up; without
#   "async": true, Claude Code would wait for that sleep to finish before
#   continuing.

$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
try {
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

# Fall back to sensible generic text if Claude Code didn't send a message for
# some reason -- this hook should never fail loudly just because a field was
# empty.
$msg = $data.message
if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'Claude Code has an update for you.' }
$title = $data.title
if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Claude Code' }

try {
    # System.Windows.Forms / System.Drawing give us access to the classic
    # Windows "balloon tip" notification via a NotifyIcon in the system tray
    # -- same mechanism as notification-idle.ps1, for a consistent look.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $notify = New-Object System.Windows.Forms.NotifyIcon
    # Deliberately a DIFFERENT icon than notification-idle.ps1 (Question) --
    # these are informational/action-needed events, not "waiting idle", so
    # they should look distinguishable at a glance, not just by reading text.
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.Visible = $true
    $notify.ShowBalloonTip(0, $title, $msg, [System.Windows.Forms.ToolTipIcon]::Info)

    Start-Sleep -Seconds 5
    $notify.Dispose()
} catch {
    # Fallback if the GUI notification APIs are unavailable for some reason
    # (e.g. running in a context without a desktop session): three short
    # beeps -- a distinct pattern from notification-idle.ps1's two beeps and
    # stop-notify.ps1's one beep, so all three stay distinguishable by ear
    # alone even without a screen.
    for ($i = 0; $i -lt 3; $i++) {
        [System.Console]::Beep(1200, 150)
        Start-Sleep -Milliseconds 80
    }
}

exit 0
