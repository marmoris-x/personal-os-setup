<#
install-fingerprint.ps1 - what a test install puts on a machine, as a comparable fingerprint.

Check J of the acceptance run ("Windows unchanged") compares the fingerprint of a test install
today against the one recorded at v2.1.2 (tests/fixtures/install-baseline-v2.1.2.json). Two
runs must be comparable although they land in different folders on different days, so the
fingerprint normalises the two values that change by themselves:

  - the target folder, in all four spellings a rendered file can carry
    (back slash, forward slash, JSON-escaped, git-bash form) -> <TARGET>
  - every ISO date (yyyy-MM-dd) and clock time with an offset -> <DATE> / <TIME>
    ({{INSTALL_DATE}} and {{START_BOUNDARY}} render to those)

What is fingerprinted: every file under HOME/, DOCUMENTS/, VAULT/ and DEV/ of the target,
sorted by its relative path. The installer's own state folder (.install-state) is NOT part of
it - it is the installer's record of the run, not something the machine shows, and it carries
the run's timestamps and version by design. That exclusion is printed by the check.

The tool only reads a target that install.ps1 has already filled; the caller runs the install
(it knows how to read the installer's exit code - install.ps1 opens a transcript, and a pipe
around it swallows the host output).

Usage:
  pwsh -File setup/tools/install-fingerprint.ps1 -TargetRoot <installed dir> -Out <file.json>

ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less files in the ANSI code page).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetRoot,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'
$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetRoot)
if (-not (Test-Path -LiteralPath $target)) { throw ('target not found: ' + $target) }

# The normalisation patterns. The target is replaced first, so a path inside a rendered file
# never depends on where the test ran.
$targetBack = $target.TrimEnd('\', '/')
$targetFwd = $targetBack.Replace('\', '/')
$targetJson = $targetBack.Replace('\', '\\')
$targetBash = if ($targetBack -match '^[A-Za-z]:') { '/' + $targetBack.Substring(0, 1).ToLowerInvariant() + $targetBack.Substring(2).Replace('\', '/') } else { $targetFwd }
$normalise = @(
    @($targetJson, '<TARGET>'),
    @($targetBack, '<TARGET>'),
    @($targetFwd, '<TARGET>'),
    @($targetBash, '<TARGET>')
)

function Get-NormalizedHash([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    # a text file has no NUL byte in its first 4 KB; binaries are hashed as they are
    $probe = [Math]::Min(4096, $bytes.Length)
    $isText = $true
    for ($i = 0; $i -lt $probe; $i++) { if ($bytes[$i] -eq 0) { $isText = $false; break } }
    if (-not $isText) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    foreach ($pair in $normalise) { $text = $text.Replace($pair[0], $pair[1]) }
    $text = [regex]::Replace($text, '\d{4}-\d{2}-\d{2}', '<DATE>')
    $text = [regex]::Replace($text, '\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}', '<TIME>')
    $sha = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '')
}

# A list of { path; sha256 } objects, not one object keyed by path: a key that happens to
# contain the word "keys" next to a 64-character hex value is what the default generic-api-key
# rule of gitleaks reads as an API key (measured 2026-10-14 on the v2.1.2 baseline, whose entry
# for home/.claude/setup/powershell/set-research-keys.ps1 tripped it). This shape keeps the
# secret scanner's default ruleset sharp instead of teaching it an exception.
$files = New-Object System.Collections.Generic.List[object]
$roots = @('HOME', 'DOCUMENTS', 'VAULT', 'DEV')
foreach ($root in $roots) {
    $dir = Join-Path $target $root
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($target.Length).TrimStart('\', '/') -replace '\\', '/'
        $files.Add([ordered]@{ path = $rel; sha256 = (Get-NormalizedHash $f.FullName) })
    }
}

$doc = [ordered]@{
    version    = 'v2.1.2'
    note       = 'Fingerprint of a test install (install.ps1 -TargetRoot <empty> -NonInteractive). Paths are relative to the target root; .install-state is excluded by design. Compare with setup/tools/install-fingerprint.ps1 -Compare.'
    roots      = $roots
    fileCount  = $files.Count
    files      = $files
}
[IO.File]::WriteAllText($Out, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Write-Output ('FINGERPRINT: ' + $files.Count + ' file(s) -> ' + $Out)
