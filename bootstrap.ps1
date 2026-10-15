<#
bootstrap.ps1 - the Windows start command. One file, then everything else comes by itself.

  powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -RepoUrl https://github.com/<account>/personal-os-setup.git

What it does, in this order:
  1. makes sure git, gh (GitHub CLI) and PowerShell 7 are on the machine (winget, with the
     vendor download as the fallback)
  2. asks you to sign in to GitHub (gh auth login) - needed to use gh and to push
  3. clones the repository to a folder you confirm
  4. runs install.ps1 from that clone

It changes nothing outside the folder you choose and the programs it installs. Every step asks
before it acts; -Yes answers all of them. The repository URL has no default on purpose: this
file may be copied around before anyone is signed in, and an account name does not belong into
a repository (see AGENTS.md, hard rule 1).

ASCII-only on purpose (Windows PowerShell 5.1 must be able to parse it).
#>
[CmdletBinding()]
param(
    [string]$RepoUrl = $env:PERSONAL_OS_REPO,
    [string]$Destination,
    [switch]$Yes,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$text) { Write-Host ''; Write-Host ('== ' + $text + ' ==') -ForegroundColor Cyan }
function Write-Ok([string]$text) { Write-Host ('   OK   ' + $text) -ForegroundColor Green }
function Write-Note([string]$text) { Write-Host ('   ..   ' + $text) -ForegroundColor Yellow }
function Confirm-Step([string]$question) {
    if ($Yes) { return $true }
    $a = Read-Host ($question + ' [Y/n]')
    return (-not $a -or $a -match '^(?i)y')
}
function Test-Command([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Get-Winget {
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    Write-Note 'winget is missing - install "App Installer" from the Microsoft Store, then start this script again.'
    return $null
}

function Install-WithWinget([string]$id, [string]$name, [string]$command) {
    # $command is the program to look for, not something derived from the package id:
    # "Microsoft.PowerShell" installs pwsh, and no rule maps one to the other.
    if (Test-Command $command) { Write-Ok ($name + ' is already installed'); return $true }
    $winget = Get-Winget
    if (-not $winget) { return $false }
    Write-Note ('installing ' + $name + ' (winget ' + $id + ') ...')
    & $winget install --exact --id $id --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { Write-Note ($name + ' could not be installed automatically - install it by hand and start this script again.'); return $false }
    return $true
}

function Resolve-RepoUrl {
    # This file does not carry the repository's account. The order is:
    # the parameter, the environment variable, then the question. Nothing is guessed.
    param([string]$Given)
    if ($Given) { return $Given }
    if ($env:PERSONAL_OS_REPO) { return $env:PERSONAL_OS_REPO }
    Write-Host ''
    Write-Host 'This file does not carry the repository address.'
    Write-Host 'You find the address in the browser after signing in, or in the personal.yaml of a machine you already set up.'
    $a = Read-Host 'Repository URL (https://github.com/<account>/personal-os-setup.git)'
    if (-not $a) { throw 'no repository URL given' }
    return $a
}

Write-Host ''
Write-Host '== personal-os-setup bootstrap (Windows) ==' -ForegroundColor Cyan
Write-Host ('   PowerShell ' + $PSVersionTable.PSVersion)

# --- 1. the three tools ------------------------------------------------------
Write-Step 'Tools: git, gh, PowerShell 7'
# PowerShell 7 first: install.ps1 needs it, and it is the one tool that can install the others
if ($PSVersionTable.PSVersion.Major -lt 7 -and -not (Test-Command 'pwsh')) {
    $null = Install-WithWinget 'Microsoft.PowerShell' 'PowerShell 7' 'pwsh'
}
if (-not (Test-Command 'git')) { $null = Install-WithWinget 'Git.Git' 'Git' 'git' }
if (-not (Test-Command 'gh')) { $null = Install-WithWinget 'GitHub.cli' 'the GitHub CLI' 'gh' }
foreach ($t in @('git', 'gh', 'pwsh')) {
    if (Test-Command $t) { Write-Ok ($t + ' is on PATH') } else { Write-Note ($t + ' is still missing') }
}
if (-not (Test-Command 'git')) { throw 'git is missing - install it and start this script again' }

# --- 2. sign in to GitHub ----------------------------------------------------
Write-Step 'Sign in to GitHub'
if (-not (Test-Command 'gh')) {
    Write-Note 'the GitHub CLI (gh) is missing - install it, or clone the repository yourself and run install.ps1 in it'
}
else {
    $auth = (& gh auth status 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { Write-Ok 'already signed in' }
    elseif (Confirm-Step 'Sign in to GitHub now (a browser window opens)?') {
        & gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { throw 'gh auth login did not finish - start this script again when you are signed in' }
        Write-Ok 'signed in'
    }
    else { Write-Note 'skipped - the repository cannot be cloned without a sign-in' }
}

# --- 3. clone ----------------------------------------------------------------
Write-Step 'Get the repository'
$url = Resolve-RepoUrl -Given $RepoUrl
if (-not $Destination) { $Destination = Join-Path (Split-Path $PSScriptRoot -Parent) 'personal-os-setup' }
if (Test-Path -LiteralPath (Join-Path $Destination 'install.ps1')) { Write-Ok ('already there: ' + $Destination) }
else {
    Write-Host ('   target: ' + $Destination)
    if (-not (Confirm-Step 'Clone the repository there?')) { throw 'stopped by you' }
    if (Test-Command 'gh') { & gh repo clone $url $Destination }
    else { & git clone $url $Destination }
    if ($LASTEXITCODE -ne 0) { throw ('cloning failed: ' + $url + ' -> ' + $Destination) }
    Write-Ok ('cloned to ' + $Destination)
}

# --- 4. install --------------------------------------------------------------
if ($SkipInstall) { Write-Host ''; Write-Step 'Skipped install.ps1 (-SkipInstall)'; exit 0 }
Write-Step 'Install (install.ps1)'
$pwsh = if (Test-Command 'pwsh') { (Get-Command pwsh).Source } else { $null }
if (-not $pwsh) { throw 'PowerShell 7 is missing - install it and start install.ps1 in the clone yourself' }
& $pwsh -NoProfile -File (Join-Path $Destination 'install.ps1')
exit $LASTEXITCODE
