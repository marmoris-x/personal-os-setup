<#
restore.ps1 - puts back the files that the last install.ps1 run replaced.

  pwsh -File setup/restore.ps1 -ListOnly            # show what the last run would restore
  pwsh -File setup/restore.ps1                      # restore, verifying every file's SHA256
  pwsh -File setup/restore.ps1 -TargetRoot <dir>    # restore a test install
  pwsh -File setup/restore.ps1 -WhatIf              # show, write nothing

Only files that install.ps1 replaced are restored (its journal of replaced files lives in
restore-index.json next to the install journal). Files that were newly created are NOT
deleted - nothing is ever deleted, that is the rule. Exit 0 = all restored or already
original, 1 = errors.
ASCII-only on purpose (same reason as install.ps1).
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$StateDir,
    [string]$TargetRoot,
    [string]$RestoreIndex,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$TestMode = [bool]$TargetRoot
if (-not $StateDir) {
    if ($TestMode) {
        $tr = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetRoot)
        $StateDir = Join-Path $tr '.install-state'
    }
    else {
        . (Join-Path $PSScriptRoot 'lib/manifest.ps1')
        . (Join-Path $PSScriptRoot 'lib/platform.ps1')
        $StateDir = Get-PlatformStateDir
    }
}
if (-not $RestoreIndex) { $RestoreIndex = Join-Path $StateDir 'restore-index.json' }
if (-not (Test-Path -LiteralPath $RestoreIndex)) { throw ('No restore-index.json found: ' + $RestoreIndex + ' (install.ps1 has not replaced anything yet)') }

$index = Get-Content -LiteralPath $RestoreIndex -Raw | ConvertFrom-Json
$restored = 0; $already = 0; $errors = 0
Write-Host ''
Write-Host ('== restore (index from ' + $index.created + ') ==') -ForegroundColor Cyan
foreach ($entry in $index.entries) {
    $backupFile = Join-Path ([string]$index.root) ([string]$entry.stored)
    $path = [string]$entry.path
    if (-not (Test-Path -LiteralPath $backupFile)) { Write-Host ('  ERROR   backup missing: ' + $backupFile) -ForegroundColor Red; $errors++; continue }
    if (-not (Test-Path -LiteralPath $path)) { Write-Host ('  NOTE file no longer exists, it will be created: ' + $path) -ForegroundColor Yellow }
    if ($ListOnly) { Write-Host ('  WOULD   ' + $path); continue }
    if ((Test-Path -LiteralPath $path) -and ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq [string]$entry.sha256)) {
        Write-Host ('  already original  ' + $path) -ForegroundColor DarkGray
        $already++
        continue
    }
    if ($PSCmdlet.ShouldProcess($path, 'restore')) {
        Copy-Item -LiteralPath $backupFile -Destination $path -Force
        $now = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($now -eq [string]$entry.sha256) {
            Write-Host ('  restored        ' + $path) -ForegroundColor Green
            $restored++
        }
        else {
            Write-Host ('  ERROR  hash after restoring differs: ' + $path) -ForegroundColor Red
            $errors++
        }
    }
}
Write-Host ''
if ($ListOnly) { Write-Host ('RESTORE-LIST: ' + $index.entries.Count + ' entries'); exit 0 }
if ($errors -gt 0) { Write-Host ('RESTORE: ' + $restored + ' restored, ' + $already + ' were already original, ' + $errors + ' errors') -ForegroundColor Red; exit 1 }
Write-Host ('RESTORE-OK: ' + $restored + ' restored, ' + $already + ' were already original') -ForegroundColor Green
exit 0
