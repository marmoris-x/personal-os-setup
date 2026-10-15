<#
setup/tools/check-structure.ps1 - does the repo tree match the block in docs/structure.md?

The block is the list of every file git tracks, one repo-relative path per line, sorted, inside
a ```text fence that follows the marker line "<!-- structure-check -->". It is the written form
of the layout: a reader sees the whole repository in one place, and this script keeps that list
and reality from drifting apart.

  pwsh setup/tools/check-structure.ps1           # report; exit 0 when they match, 1 when not
  pwsh setup/tools/check-structure.ps1 -Write    # write the current tree into the block

Only files that git tracks are compared. Untracked scratch (tests/_tmp, tests/_scratch) is not
part of the layout and is ignored by design.

ASCII-only on purpose (same reason as install.ps1).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$StructurePath,
    [switch]$Write
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not $StructurePath) { $StructurePath = Join-Path $RepoRoot 'docs\structure.md' }
$marker = '<!-- structure-check -->'

function Get-TrackedPaths {
    Push-Location $RepoRoot
    try {
        $paths = @(& git ls-files)
        if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
    }
    finally { Pop-Location }
    return @($paths | Where-Object { $_ } | Sort-Object)
}

function Get-DocumentedPaths {
    if (-not (Test-Path -LiteralPath $StructurePath)) { throw ('structure file missing: ' + $StructurePath) }
    $lines = [IO.File]::ReadAllLines($StructurePath)
    $inMarker = $false; $inFence = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if (-not $inMarker) { if ($line.Trim() -eq $marker) { $inMarker = $true }; continue }
        if (-not $inFence) {
            if ($line.Trim() -eq '```text') { $inFence = $true }
            continue
        }
        if ($line.Trim() -eq '```') { break }
        $t = $line.Trim()
        if ($t) { $out.Add($t) }
    }
    if (-not $inFence) { throw ('no ```text block after ' + $marker + ' in ' + $StructurePath) }
    return @($out)
}

$tracked = Get-TrackedPaths

if ($Write) {
    $text = [IO.File]::ReadAllText($StructurePath)
    # the block: the marker line, a ```text fence with any content, and the closing fence
    $pattern = '(?s)(' + [regex]::Escape($marker) + '\s*```text\r?\n).*?(\r?\n```)'
    if (-not [regex]::IsMatch($text, $pattern)) { throw ('no ```text block after ' + $marker + ' in ' + $StructurePath) }
    $block = ($marker + "`n" + '```text' + "`n" + (($tracked -join "`n")) + "`n" + '```')
    $new = [regex]::Replace($text, $pattern, { param($m) $block }, 1)
    [IO.File]::WriteAllText($StructurePath, $new, (New-Object Text.UTF8Encoding($false)))
    Write-Host ('STRUCTURE-WRITE: ' + $tracked.Count + ' tracked path(s) written to ' + (Split-Path $StructurePath -Leaf))
    exit 0
}

try { $documented = Get-DocumentedPaths }
catch {
    Write-Host ('STRUCTURE: cannot read the block - ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$missingInDoc = @($tracked | Where-Object { $documented -notcontains $_ })
$extraInDoc = @($documented | Where-Object { $tracked -notcontains $_ })

Write-Host ('STRUCTURE: ' + $tracked.Count + ' tracked, ' + $documented.Count + ' documented')
if ($missingInDoc.Count -eq 0 -and $extraInDoc.Count -eq 0) {
    Write-Host 'STRUCTURE-OK: the tree matches docs/structure.md' -ForegroundColor Green
    exit 0
}
foreach ($p in $missingInDoc) { Write-Host ('  in the repo, not in structure.md: ' + $p) -ForegroundColor Red }
foreach ($p in $extraInDoc) { Write-Host ('  in structure.md, not in the repo: ' + $p) -ForegroundColor Red }
Write-Host ('STRUCTURE: ' + ($missingInDoc.Count + $extraInDoc.Count) + ' difference(s) - run: pwsh setup/tools/check-structure.ps1 -Write (then read the diff!)') -ForegroundColor Red
exit 1
