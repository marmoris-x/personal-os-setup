<#
tests/sandbox/smoke-install.ps1 - runs inside Windows Sandbox (see personal-os.wsb).

The repository is mapped read-only at C:\personal-os-setup. This script
  1. copies the repo to C:\setup (writable),
  2. creates %USERPROFILE%\.personal-os\personal.yaml with example values,
  3. runs install.ps1 (full install into the sandbox's own profile) and setup/verify.ps1,
  4. keeps the window open with the result.

Nothing here touches the host: the sandbox is throwaway by design.
ASCII only (runs under Windows PowerShell 5.1 in the sandbox).
#>
$ErrorActionPreference = 'Continue'

$src = 'C:\personal-os-setup'
$dst = 'C:\setup'

Write-Host '== personal-os-setup sandbox smoke test ==' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "ERROR: repo mapping not found at $src" -ForegroundColor Red
    exit 1
}

if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
Write-Host "Copying repository to $dst ..."
Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force

$personalDir = Join-Path $env:USERPROFILE '.personal-os'
New-Item -ItemType Directory -Force -Path $personalDir | Out-Null
$personalYaml = @(
    "# sandbox example values (Vera Beispiel); never real data",
    "user_name: 'Vera Beispiel'",
    "user_given: 'Vera'",
    "user_family: 'Beispiel'",
    "github_account: 'example-user'",
    "b2_bucket: 'example-kopia-backup'",
    "vault_path: 'C:\vault'",
    "dev_root: 'C:\Dev'",
    "archive_dir_name: 'Dokumentenarchiv'",
    "morning_time: '07:00'",
    "backup_time: '12:30'"
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $personalDir 'personal.yaml'), $personalYaml + "`r`n", (New-Object Text.UTF8Encoding($false)))

Set-Location $dst
Write-Host ''
Write-Host '== install.ps1 -NonInteractive ==' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'install.ps1') -NonInteractive
Write-Host ("install exit code: " + $LASTEXITCODE)

Write-Host ''
Write-Host '== setup/verify.ps1 ==' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'setup\verify.ps1')
Write-Host ("verify exit code: " + $LASTEXITCODE)

Write-Host ''
Write-Host '== done. window stays open for inspection. ==' -ForegroundColor Green
