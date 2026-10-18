# session-check.ps1  --  Version 1 (2026-09-29)
#
# SessionStart hook. Warns, loudly, when a protection would silently do nothing:
#
#   - a hook script named in settings.json does not exist or does not parse
#     (a PreToolUse hook whose file is missing exits with a code other than 2,
#     and only exit 2 blocks - so the command would simply go through),
#   - the delete guard (block-dangerous.ps1) is not registered as a PreToolUse hook,
#   - gitleaks is not installed (the global pre-commit hook then lets every commit
#     through unchecked).
#
# Silent when everything is in place. On a problem it prints one JSON object:
# "systemMessage" is shown to the user, "additionalContext" tells the agent to say so.
# It never blocks a session start (always exit 0).
#
# ASCII ONLY: Windows PowerShell 5.1 reads BOM-less .ps1 files in the ANSI codepage.

param(
    [string]$ClaudeDir = (Join-Path $PSScriptRoot '..'),
    [switch]$SkipGitleaks
)

$ErrorActionPreference = 'SilentlyContinue'
$problems = New-Object System.Collections.Generic.List[string]

$settingsFile = Join-Path $ClaudeDir 'settings.json'
$settings = $null
try { $settings = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
catch { $problems.Add("settings.json cannot be read ($settingsFile): no hook is guaranteed to be active.") }

$guardRegistered = $false
if ($settings -and $settings.hooks) {
    foreach ($event in $settings.hooks.PSObject.Properties) {
        foreach ($group in @($event.Value)) {
            foreach ($h in @($group.hooks)) {
                $scripts = @()
                # A hook may be a bare argument (-File <path>) or a script path inside a
                # -Command string (the fail-closed wrapper). Both forms must be seen, or a
                # missing guard goes unreported.
                # Windows (C:/...) and Unix (/home/...) paths: CI runs this check on Linux too.
                $pathPattern = '(?:[A-Za-z]:[/\\]|/)[^''"\s]*?\.ps1'
                foreach ($a in @($h.args)) {
                    if ("$a" -match '\.ps1$') { $scripts += "$a" }
                    else { foreach ($m in [regex]::Matches("$a", $pathPattern)) { $scripts += $m.Value } }
                }
                foreach ($m in [regex]::Matches("$($h.command)", $pathPattern)) { $scripts += $m.Value }
                foreach ($script in $scripts) {
                    if ($event.Name -eq 'PreToolUse' -and $script -match 'block-dangerous\.ps1$') { $guardRegistered = $true }
                    if (-not (Test-Path -LiteralPath $script)) {
                        $problems.Add("The $($event.Name) hook file is MISSING: $script")
                        continue
                    }
                    $tokens = $null; $errs = $null
                    [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errs)
                    if ($errs -and $errs.Count -gt 0) { $problems.Add("The $($event.Name) hook file does not parse: $script ($($errs[0].Message))") }
                }
            }
        }
    }
}
if ($settings -and -not $guardRegistered) {
    $problems.Add('The delete guard (block-dangerous.ps1) is not registered as a PreToolUse hook in settings.json.')
}
if (-not $SkipGitleaks -and -not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    $problems.Add('gitleaks is not installed: the pre-commit hook lets every commit through unchecked.')
}

if ($problems.Count -gt 0) {
    $text = 'SECURITY WARNING at session start - a protection is NOT working: ' + ($problems -join ' | ') +
            ' Fix this before doing anything else (setup/restore-tools.ps1 repairs tools; a missing or broken hook file must be restored from your configuration repository).'
    $out = @{
        systemMessage      = $text
        hookSpecificOutput = @{
            hookEventName     = 'SessionStart'
            additionalContext = $text + ' Tell the user about this in your first reply.'
        }
    }
    Write-Output ($out | ConvertTo-Json -Compress -Depth 5)
}
exit 0
