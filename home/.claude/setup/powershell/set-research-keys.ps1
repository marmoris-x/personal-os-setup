# Set the keys for the free research services (version 11, 2026-10-17)
# Run it YOURSELF, not through the agent: right-click the file -> "Run with PowerShell",
# or in PowerShell:  & "$HOME/.claude/setup/powershell/set-research-keys.ps1"
# Windows: the keys are stored as Windows user environment variables.
# macOS/Linux: they are stored in ~/.config/personal-os/research-keys.env (mode 600) and the
# shell profiles source that file; no value is ever printed or written anywhere else.
# Empty input = skip this service. Afterwards restart all terminals and Claude Code.

$services = [ordered]@{
    'YDC_API_KEY'       = 'You.com       -> you.com/platform  (API Keys)'
    'TAVILY_API_KEY'    = 'Tavily        -> app.tavily.com   (API Keys)'
    'FIRECRAWL_API_KEY' = 'Firecrawl     -> firecrawl.dev/app/api-keys'
    'EXA_API_KEY'       = 'Exa           -> dashboard.exa.ai/api-keys'
    'TINYFISH_API_KEY'  = 'TinyFish      -> agent.tinyfish.ai/api-keys'
    'SERPER_API_KEY'    = 'Serper/Google -> serper.dev (Dashboard, API Key)'
}

function ConvertTo-EnvFileValue {
    # single quotes in a POSIX shell, the quote itself escaped as '\''
    param([string]$Value)
    return $Value.Replace("'", "'\''")
}

function Read-ResearchKeyEnvFile {
    # name -> value. The file is ours; anything that does not parse is ignored, never echoed.
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $m = [regex]::Match($line, '^\s*export\s+([A-Z0-9_]+)=(.+)$')
        if (-not $m.Success) { continue }
        $value = $m.Groups[2].Value
        if ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2).Replace("'\''", "'")
        }
        $values[$m.Groups[1].Value] = $value
    }
    return $values
}

function Write-ResearchKeyEnvFile {
    param([string]$Path, [hashtable]$Values)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# personal-os-setup research keys - written by set-research-keys.ps1')
    $lines.Add('# Mode 600. This file holds secrets: never commit it, never print it.')
    foreach ($name in $services.Keys) {
        if (-not $Values.ContainsKey($name)) { continue }
        $lines.Add('export ' + $name + "='" + (ConvertTo-EnvFileValue $Values[$name]) + "'")
    }
    $content = (($lines -join "`n") + "`n")
    if ($IsLinux -or $IsMacOS) {
        # Create EMPTY, set 0600, then write the secrets and move the file into place. A
        # failed chmod must never leave a key file behind at the default umask.
        $tmp = $Path + '.tmp'
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $stream = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Close()
        $null = (& chmod 600 $tmp 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $tmp -Force
            throw ('chmod 600 failed for ' + $Path + ' - the keys were not written')
        }
        [IO.File]::WriteAllText($tmp, $content, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    else {
        [IO.File]::WriteAllText($Path, $content, (New-Object Text.UTF8Encoding($false)))
    }
}

function Test-ResearchKeyEnvFile {
    # The names whose value did NOT come back from the file unchanged. "saved" is reported
    # only when this returns none: a write that silently dropped a key must not look like one.
    param([string]$Path, [hashtable]$Values)
    $read = Read-ResearchKeyEnvFile -Path $Path
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Values.Keys) {
        if ($read[$name] -ne $Values[$name]) { $missing.Add($name) }
    }
    return $missing
}

function Add-ResearchKeyProfileSource {
    # Adds the guarded source block to a profile once. Returns $true when it wrote.
    param([string]$ProfilePath)
    $marker = '# personal-os-setup: research keys'
    $existing = ''
    if (Test-Path -LiteralPath $ProfilePath) { $existing = [IO.File]::ReadAllText($ProfilePath) }
    if ($existing.Contains($marker)) { return $false }
    $block = @(
        '',
        $marker,
        'if [ -f "$HOME/.config/personal-os/research-keys.env" ]; then',
        '    . "$HOME/.config/personal-os/research-keys.env"',
        'fi'
    ) -join "`n"
    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $block = "`n" + $block }
    $dir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::AppendAllText($ProfilePath, $block + "`n", (New-Object Text.UTF8Encoding($false)))
    return $true
}

function Get-ResearchKeyProfilePaths {
    # .profile always; .bashrc only when it exists; .zshrc when it exists or zsh is the shell.
    param([string]$HomeDir, [string]$Shell)
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add((Join-Path $HomeDir '.profile'))
    $bashrc = Join-Path $HomeDir '.bashrc'
    if (Test-Path -LiteralPath $bashrc) { $paths.Add($bashrc) }
    $zshrc = Join-Path $HomeDir '.zshrc'
    if ((Test-Path -LiteralPath $zshrc) -or ($Shell -match 'zsh')) { $paths.Add($zshrc) }
    return $paths
}

# Dot-sourced by tests: define the functions, do not prompt.
if ($MyInvocation.InvocationName -eq '.') { return }

$onWindows = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSVersion.Major -lt 6)
$homeDir = [string]$HOME
$entered = @{}
foreach ($name in $services.Keys) {
    Write-Host ''
    Write-Host $services[$name]
    $sec = Read-Host -AsSecureString "Key for $name (Enter = skip)"
    $plain = [System.Net.NetworkCredential]::new('', $sec).Password
    if ([string]::IsNullOrWhiteSpace($plain)) { Write-Host '  skipped'; continue }
    if ($onWindows) {
        [Environment]::SetEnvironmentVariable($name, $plain.Trim(), 'User')
        Write-Host '  saved'
    }
    else {
        $entered[$name] = $plain.Trim()
        Write-Host '  taken'
    }
}

if (-not $onWindows) {
    $envFile = Join-Path $homeDir '.config/personal-os/research-keys.env'
    $values = Read-ResearchKeyEnvFile -Path $envFile
    foreach ($name in $entered.Keys) { $values[$name] = $entered[$name] }
    if ($values.Count -gt 0) {
        Write-ResearchKeyEnvFile -Path $envFile -Values $values
        $bad = @(Test-ResearchKeyEnvFile -Path $envFile -Values $entered)
        if ($bad.Count -gt 0) {
            Write-Host ('  ERROR: the read-back did not match for ' + ($bad -join ', ') + ' - the keys are NOT confirmed') -ForegroundColor Red
            exit 1
        }
        Write-Host ('  saved: ' + $envFile + ' (' + $values.Count + ' key(s), mode 600, read back)')
    }
    else { Write-Host '  no key entered and no key on disk - nothing written' }
    foreach ($profile in (Get-ResearchKeyProfilePaths -HomeDir $homeDir -Shell ([string]$env:SHELL))) {
        if (Add-ResearchKeyProfileSource -ProfilePath $profile) { Write-Host ('  profile updated: ' + $profile) }
    }
}

Write-Host ''
Write-Host 'Done. Please restart all terminals and Claude Code.'
