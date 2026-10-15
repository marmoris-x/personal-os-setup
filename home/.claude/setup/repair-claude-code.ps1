# repair-claude-code.ps1
#
# WHAT THIS FILE IS:
#   A standalone, manually-run repair script (NOT a Claude Code hook -- it is
#   never invoked automatically, you run it yourself in a terminal). It fixes
#   a known Windows-specific installation bug where "claude.exe" gets
#   replaced by an empty Bun JavaScript runtime shell, so running "claude"
#   shows Bun's own help text ("Bun is a fast JavaScript runtime...") instead
#   of the actual Claude Code interface.
#
# VERIFIED AGAINST:
#   GitHub anthropics/claude-code issues #40544, #67801, #69884, #63402 (all
#   confirmed to exist and describe this exact symptom), plus the official
#   Anthropic documentation at code.claude.com/docs/en/setup ("Advanced
#   setup" / uninstall section).
#
# IMPORTANT CORRECTION vs. guides circulating online:
#   The official path for Claude Code's program data is .local\share\claude,
#   NOT .local\state\claude. The latter path does exist (for example, it is
#   where AutoDream's .consolidate-lock file lives -- see TROUBLESHOOTING.md),
#   but it is NOT part of the official uninstall/repair procedure for THIS
#   specific bug, despite some guides online conflating the two paths.
#
# WHERE TO KEEP THIS FILE:
#   Anywhere convenient, e.g. the Desktop. It does NOT need to live inside
#   .claude\ -- it is a manual tool, not part of the automatic hook system.
#
# HOW TO USE IT:
#   Just run it in PowerShell whenever "claude" only shows the Bun help menu
#   instead of the real Claude Code interface.
#
# CHANGELOG -- July 2026 audit: added .Trim() before the two version regex
# checks. See the inline comments at each match site below for the full
# explanation of why this matters.

$ErrorActionPreference = 'Stop'

Write-Host "=== Claude Code Repair Script ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 1 of 4: Back up sessions and settings (never deletes anything here --
# this step only ever COPIES data to a timestamped folder on the Desktop, as
# a safety net in case anything later goes wrong).
# ---------------------------------------------------------------------------
$backupDir = "{{HOME_ENV}}\Desktop\ClaudeCode_Backup_$(Get-Date -Format 'yyyy-MM-dd_HHmm')"

if (Test-Path "{{HOME_ENV}}\.claude") {
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Write-Host "[1/4] Backing up sessions and settings to:" -ForegroundColor Yellow
    Write-Host "      $backupDir"
    Copy-Item -Path "{{HOME_ENV}}\.claude" -Destination "$backupDir\.claude" -Recurse -Force
    # The state file needs no separate copy: CLAUDE_CONFIG_DIR points Claude Code at
    # {{HOME_CMD}}\.claude, so the state file is {{HOME_CMD}}\.claude\.claude.json and the
    # recursive copy above already contains it. Until 2026-09-27 this block also copied
    # {{HOME_CMD}}\.claude.json -- a leftover from before the variable was set, last written
    # 2026-07-02. It was removed together with that file.
    Write-Host "      Done." -ForegroundColor Green
} else {
    Write-Host "[1/4] No .claude folder found -- skipping backup." -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 2 of 4: Check whether claude.exe is actually broken before touching
# anything. A "broken" install reports a Bun version number (which looks
# like 1.x.x) instead of a real Claude Code version number (which looks like
# 2.x.x).
#
# WHY .Trim() MATTERS HERE (added July 2026):
#   "& $claudeExe --version 2>&1 | Out-String" can, depending on the exact
#   PowerShell version and how the child process writes its output, come
#   back with a LEADING newline or leading whitespace before the actual
#   version text. The pattern '^1\.\d' uses the "^" anchor, which demands a
#   match starting at character position 0 of the string -- literally the
#   very first character. If there is so much as one leading space or blank
#   line before "1.2.3", the anchored match silently fails even though the
#   text truly does start with a Bun-style "1." version a few characters in.
#   That would make this script wrongly conclude "no problem here" for an
#   installation that actually IS broken. The display line further below
#   already used ".Trim()" (so what you SEE on screen was always clean) --
#   only the actual detection logic did not. Both are now trimmed the same
#   way, so what the script decides matches what it shows you.
# ---------------------------------------------------------------------------
Write-Host "[2/4] Checking whether claude.exe is affected..." -ForegroundColor Yellow
$claudeExe = "{{HOME_ENV}}\.local\bin\claude.exe"
$isBroken = $false

if (Test-Path $claudeExe) {
    try {
        $versionOutput = & $claudeExe --version 2>&1 | Out-String
        # Bun version numbers look like 1.x.x -- real Claude Code versions
        # look like 2.x.x. .Trim() removes any leading/trailing whitespace
        # or newlines BEFORE we anchor-match against "starts with 1.".
        if ($versionOutput.Trim() -match '^1\.\d') {
            $isBroken = $true
            Write-Host "      Confirmed: claude.exe reports a Bun version ($($versionOutput.Trim()))." -ForegroundColor Red
        } else {
            Write-Host "      claude.exe reports: $($versionOutput.Trim())" -ForegroundColor Green
            Write-Host "      Looks like a normal Claude Code version." -ForegroundColor Green
        }
    } catch {
        $isBroken = $true
        Write-Host "      claude.exe could not be executed -- treating as broken." -ForegroundColor Red
    }
} else {
    Write-Host "      claude.exe does not exist -- performing a fresh install." -ForegroundColor Gray
}
Write-Host ""

if (-not $isBroken -and (Test-Path $claudeExe)) {
    Write-Host "No problem detected. Nothing to do." -ForegroundColor Green
    Write-Host "If you still want to reinstall anyway, run steps 3+4 manually." -ForegroundColor Gray
    exit 0
}

# ---------------------------------------------------------------------------
# STEP 3 of 4: Remove the broken installation using the OFFICIAL uninstall
# paths from Anthropic's documentation (see the "VERIFIED AGAINST" note at
# the top of this file). This deliberately does NOT touch the .claude folder
# itself (sessions, settings, hooks, memory all stay untouched) -- only the
# actual program binary and its internal share directory are removed.
# ---------------------------------------------------------------------------
Write-Host "[3/4] Removing the broken installation (official path)..." -ForegroundColor Yellow

Get-Process -Name "claude*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

Remove-Item -Path "{{HOME_ENV}}\.local\bin\claude.exe" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "{{HOME_ENV}}\.local\share\claude" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "      Removed: .local\bin\claude.exe and .local\share\claude" -ForegroundColor Green
Write-Host "      (Your .claude folder with sessions and settings is untouched.)" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 4 of 4: Fresh install, using Anthropic's own official install script.
# ---------------------------------------------------------------------------
Write-Host "[4/4] Reinstalling Claude Code..." -ForegroundColor Yellow
& ([scriptblock]::Create((Invoke-RestMethod https://claude.ai/install.ps1)))

Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Cyan
Start-Sleep -Seconds 2

if (Test-Path $claudeExe) {
    $newVersion = & $claudeExe --version 2>&1 | Out-String
    Write-Host "claude.exe now reports: $($newVersion.Trim())"
    # Same .Trim()-before-match fix as in step 2 above, applied to the
    # post-install verification check as well.
    if ($newVersion.Trim() -match '^1\.\d') {
        Write-Host ""
        Write-Host "WARNING: Still a Bun version. Fallback method (Issue #69884):" -ForegroundColor Red
        Write-Host "  npm install -g @anthropic-ai/claude-code" -ForegroundColor White
        Write-Host '  Copy-Item "$env:APPDATA\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe" "{{HOME_ENV}}\.local\bin\claude.exe" -Force' -ForegroundColor White
        Write-Host "(Requires Node.js -- if you don't have it: winget install OpenJS.NodeJS)" -ForegroundColor Gray
    } else {
        Write-Host "Successfully repaired." -ForegroundColor Green
    }
} else {
    Write-Host "claude.exe was not found. The installation may not have succeeded." -ForegroundColor Red
    Write-Host "Try manually: irm https://claude.ai/install.ps1 | iex" -ForegroundColor Gray
}

Write-Host ""
Write-Host "A backup of your old sessions/settings is here (nothing was deleted, this is just for safety):" -ForegroundColor Gray
Write-Host "  $backupDir" -ForegroundColor Gray
