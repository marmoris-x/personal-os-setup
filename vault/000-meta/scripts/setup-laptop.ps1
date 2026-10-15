<#
    setup-laptop.ps1 - run this once, on the laptop, from PowerShell.

    It checks what is installed, sets the one setting that Windows gets
    wrong on its own, and prints the couple of clicks that cannot be
    automated. It installs nothing.

    What it changes: if {{HOME_CMD}}\.claude\settings.json has no
    CLAUDE_CODE_GIT_BASH_PATH entry, it adds one, with a .bak copy next to
    it. Without that line Claude Code picks the wrong bash on Windows.
    The build guide requires it (rule 7).

    ASCII only on purpose: this file has to print the same on any console
    codepage, including a fresh Windows install.

    Usage:
        pwsh -File setup-laptop.ps1
#>

$ErrorActionPreference = 'Continue'
$problems = @()

function Check-Tool {
    param([string]$Name, [string]$Exe, [string]$Why)
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = (& $Exe --version 2>&1 | Select-Object -First 1)
        Write-Output "  OK      $Name - $version"
    }
    else {
        Write-Output "  MISSING $Name - $Why"
        $script:problems += $Name
    }
}

Write-Output "=== What is installed ==="
Check-Tool -Name 'Git' -Exe 'git' -Why 'install Git for Windows, https://git-scm.com/download/win'
Check-Tool -Name 'Claude Code' -Exe 'claude' -Why 'install Claude Code, then always start it from PowerShell'

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) { Write-Output "  OK      Python - $(& python --version 2>&1)" }
else { Write-Output "  note    Python is missing - only needed to rebuild document sidecars" }

$obsidian = @(
    "{{OBSIDIAN_APP}}",
    "$env:LOCALAPPDATA\Obsidian\Obsidian.exe",
    "$env:ProgramFiles\Obsidian\Obsidian.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($obsidian) {
    $v = (Get-Item $obsidian).VersionInfo.ProductVersion
    Write-Output "  OK      Obsidian - $v"
    $cli = Join-Path (Split-Path $obsidian) 'Obsidian.com'
    if (Test-Path $cli) {
        $cliAnswer = & $cli help 2>&1 | Out-String
        if ($cliAnswer -match 'not enabled') {
            Write-Output "  TODO    The Obsidian CLI is not enabled yet. In Obsidian:"
            Write-Output "          Settings > General > Advanced > Command line interface > on"
            Write-Output "          Then restart the terminal. No PATH entry is needed."
        }
        else {
            Write-Output "  OK      Obsidian CLI answers"
        }
    }
}
else {
    Write-Output "  MISSING Obsidian - install 1.13.7 or newer"
    $problems += 'Obsidian'
}

Write-Output ""
Write-Output "=== Git Bash for Claude Code ==="
$bashPath = 'C:\Program Files\Git\bin\bash.exe'
$settingsPath = Join-Path {{HOME_ENV}} '.claude\settings.json'
if (Test-Path $bashPath) {
    if (Test-Path $settingsPath) {
        $raw = [System.IO.File]::ReadAllText($settingsPath)
        if ($raw -match 'CLAUDE_CODE_GIT_BASH_PATH') {
            Write-Output "  OK      already set in settings.json"
        }
        else {
            Copy-Item $settingsPath "$settingsPath.bak" -Force
            $json = $raw | ConvertFrom-Json
            if (-not $json.env) {
                $json | Add-Member -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $json.env | Add-Member -NotePropertyName 'CLAUDE_CODE_GIT_BASH_PATH' -NotePropertyValue $bashPath -Force
            [IO.File]::WriteAllText($settingsPath, ($json | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
            Write-Output "  FIXED   added CLAUDE_CODE_GIT_BASH_PATH (backup: settings.json.bak)"
        }
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
        @{ env = @{ CLAUDE_CODE_GIT_BASH_PATH = $bashPath } } |
            ConvertTo-Json -Depth 5 |
            ForEach-Object { [IO.File]::WriteAllText($settingsPath, $_, (New-Object Text.UTF8Encoding($false))) }
        Write-Output "  FIXED   created settings.json with CLAUDE_CODE_GIT_BASH_PATH"
    }
}
else {
    Write-Output "  MISSING C:\Program Files\Git\bin\bash.exe - Git is not installed"
    $problems += 'Git Bash'
}

Write-Output ""
Write-Output "=== Git identity (needed for commits) ==="
$name = git config --global user.name
$mail = git config --global user.email
if ($name -and $mail) { Write-Output "  OK      $name <$mail>" }
else {
    Write-Output "  TODO    set it:"
    Write-Output '          git config --global user.name "your name"'
    Write-Output '          git config --global user.email "you@example.com"'
}

Write-Output ""
Write-Output "=== The vault ==="
if (Test-Path '{{VAULT}}\.git') {
    Write-Output "  OK      {{VAULT}} is a git repository"
    git -C {{VAULT}} pull 2>&1 | ForEach-Object { "          $_" }
}
else {
    Write-Output "  TODO    clone it:"
    Write-Output "          git clone https://github.com/{{GITHUB_ACCOUNT}}/personal-os.git {{VAULT}}"
}

Write-Output ""
Write-Output "=== Still manual, in this order ==="
Write-Output "  1. Obsidian: open {{VAULT}} as a vault"
Write-Output "  2. Obsidian: Settings > General > Advanced > Command line interface > on"
Write-Output "  3. Obsidian: Settings > Community plugins > turn community plugins on"
Write-Output "     (the Git plugin is already in the repository)"
Write-Output "  4. Obsidian: Git plugin settings - set the interval to 0"
Write-Output "     Only the main PC commits automatically. Two automatic writers"
Write-Output "     create conflicts nobody caused."

Write-Output ""
if ($problems.Count -gt 0) {
    Write-Output "Open: $($problems -join ', ')"
}
else {
    Write-Output "No blockers found on this machine."
}
