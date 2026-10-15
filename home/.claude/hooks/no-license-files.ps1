# no-license-files.ps1  --  Version 1 (2026-10-15)
#
# PreToolUse hook for the Write / Edit / MultiEdit tools. It keeps an attribution file out of
# the three folders the rule covers:
#
#   {{DEV}}\Projects            the owner's own repositories
#   {{VAULT}}              the notes vault
#   {{HOME}}\.claude     the configuration
#
#   BLOCK: creating or editing a file whose NAME is one of the attribution names -
#          LICENSE*, LICENCE*, COPYING*, NOTICE*, THIRD-PARTY*, third-party.md, ATTRIBUTION*.
#   ALLOW: everything else, including every path outside those three folders.
#
#   {{DEV}}\External is deliberately not covered: a cloned repository keeps the files it came
#   with. Only the file tools are judged, so `git clone` never meets this hook - the Bash,
#   PowerShell and Monitor calls have their own hooks and this one is not registered there.
#
#   The name decides, not the content: a file named like this exists to carry terms, and the
#   owner's rule is that the topic is not part of this setup. A session that writes one is
#   following a habit picked up somewhere else, and the habit is what gets stopped here.
#
# Output contract: exit 2 + message on stderr = blocked (the message goes to the model).
#                  exit 0 = normal permission flow.
#
# Fail closed: only exit 2 blocks and every other code lets the call through, so an unexpected
# error must end in exit 2 rather than in the default exit 1 (same rule as block-dangerous.ps1).
#
# ASCII only (Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page).

$ErrorActionPreference = 'SilentlyContinue'

$blockMsg = 'Licensing does not matter here; this file is not needed.'

function Send-Block {
    [Console]::Error.WriteLine($blockMsg)
    exit 2
}

trap { Send-Block }

# --- read the tool call ------------------------------------------------------
# A UTF-8 byte order mark in front of the JSON makes ConvertFrom-Json fail; the agent's
# PowerShell tool sends one. The bytes are read raw, the mark is cut off there, and the rest is
# decoded as UTF-8 (the same handling as block-dangerous.ps1).
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) { Send-Block }
try { $call = $raw | ConvertFrom-Json -ErrorAction Stop } catch { Send-Block }

$tool = [string]$call.tool_name
if ($tool -ne 'Write' -and $tool -ne 'Edit' -and $tool -ne 'MultiEdit') { exit 0 }
$path = [string]$call.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }

# --- the three folders -------------------------------------------------------
# Plain strings, not Join-Path: this hook is part of the portable set and runs on macOS and Linux
# too, where Join-Path with a drive-lettered first part throws "Cannot find drive" - and a hook
# that throws on every call is a hook that blocks every call. The separator does not matter here
# because both sides are compared with "/" a few lines down.
$roots = @(
    '{{DEV}}\Projects',
    '{{VAULT}}',
    ({{HOME_ENV}} + '\.claude')
)

# Both sides are compared with "/" as the separator and without case, so the spellings a session
# really writes (backslashes, forward slashes, a trailing separator) all land on one string.
# A path under no root at all is never judged, and a file that is not named like an attribution
# file is never judged either - so a false block can only come from the name rule.
function ConvertTo-Slashes([string]$value) {
    $s = $value -replace '\\', '/'
    while ($s.Length -gt 1 -and $s.EndsWith('/')) { $s = $s.Substring(0, $s.Length - 1) }
    return $s
}

$target = ConvertTo-Slashes $path
$inside = $false
foreach ($root in $roots) {
    $r = ConvertTo-Slashes ([string]$root)
    if ($r.Length -eq 0) { continue }
    if ($target.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break }
    if ($target.StartsWith($r + '/', [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break }
}
if (-not $inside) { exit 0 }

# --- the name ----------------------------------------------------------------
$name = ($target -split '/')[-1]
$upper = $name.ToUpperInvariant()
foreach ($prefix in @('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'THIRD-PARTY', 'ATTRIBUTION')) {
    if ($upper.StartsWith($prefix, [StringComparison]::Ordinal)) { Send-Block }
}
if ($upper -eq 'THIRD-PARTY.MD') { Send-Block }

exit 0
