<#
ci-gitleaks.ps1 - download gitleaks (checksum-verified) and hand it to the FOLLOWING CI steps.

Why a script instead of the inline download it replaces: two jobs need the binary now. The
secret scan of this repository, and the installed-hook test in tests/Hooks.Tests.ps1, which
commits into a scratch repository and needs the real gitleaks on PATH - the installed hook
execs `gitleaks`, and without the tool that test could not prove anything. Version and checksum
check live in one place so the two jobs cannot drift apart.

  pwsh -File setup/tools/ci-gitleaks.ps1

Exit 0 with "GITLEAKS-ON-PATH <version>" as the last line. ASCII-only on purpose.
#>
[CmdletBinding()]
param([string]$Version = '8.30.1')

$ErrorActionPreference = 'Stop'
$osName = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
# macos-latest is arm64, ubuntu-latest and windows-latest are x64; uname answers for the two
# Unix runners, and the release names the architecture in the asset.
$arch = 'x64'
if (-not $IsWindows -and ((& uname -m) -like 'arm64*')) { $arch = 'arm64' }
$asset = 'gitleaks_' + $Version + '_' + $osName + '_' + $arch + $(if ($IsWindows) { '.zip' } else { '.tar.gz' })
$base = 'https://github.com/gitleaks/gitleaks/releases/download/v' + $Version

$work = Join-Path ([IO.Path]::GetTempPath()) ('gitleaks-' + $Version)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$pkg = Join-Path $work $asset
Invoke-WebRequest -Uri ($base + '/' + $asset) -OutFile $pkg
$sumFile = Join-Path $work 'checksums.txt'
Invoke-WebRequest -Uri ($base + '/gitleaks_' + $Version + '_checksums.txt') -OutFile $sumFile

$expected = ((Get-Content -LiteralPath $sumFile | Select-String ([regex]::Escape($asset))) -split '\s+')[0]
if (-not $expected) { throw ('the checksum file carries no line for ' + $asset) }
$actual = (Get-FileHash -LiteralPath $pkg -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) { throw ('gitleaks checksum mismatch for ' + $asset) }

$bin = Join-Path $work 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
if ($IsWindows) { Expand-Archive -LiteralPath $pkg -DestinationPath $bin -Force }
else {
    $null = (& tar -xzf $pkg -C $bin 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'unpacking gitleaks failed' }
    $null = (& chmod +x (Join-Path $bin 'gitleaks') 2>&1)
}

$exe = Join-Path $bin $(if ($IsWindows) { 'gitleaks.exe' } else { 'gitleaks' })
$out = (& $exe version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw ('the downloaded gitleaks does not run: ' + $out) }

# GITHUB_PATH hands the folder to every step AFTER this one; this step already uses the real path.
if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin }
Write-Host ('gitleaks: ' + $out.Trim())
Write-Host ('GITLEAKS-ON-PATH ' + $Version)
