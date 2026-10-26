# crawl4ai-repair.ps1 - the one command that repairs Crawl4AI. Prints exactly one line and exits 0 or 1:
#   crawl4ai-repair=ok
#   crawl4ai-repair=fail: <reason>
#
# What it does, in order:
#   1. asks crawl4ai_fetch.py for Crawl4AI's own browser folder (--print-browsers-path), so the folder
#      rule lives in one place
#   2. runs crawl4ai-setup with PLAYWRIGHT_BROWSERS_PATH set to that folder, for this one process only
#      (a bare crawl4ai-setup would fill Playwright's shared ms-playwright folder, which another
#      Playwright installation can empty again - the likely cause of the 2026-10-23/25 outage)
#   3. runs crawl4ai-selftest.ps1; exit 0 only when that prints crawl4ai=ok
# Callers: the person at a prompt, and morning.ps1 (once, when its self-test fails). TimeoutSeconds is the
# budget of the whole repair (the self-test takes up to 60 s of it, the setup the rest).
# It starts no language model and deletes nothing. The only process it may kill is the setup it started
# itself, when that runs past the limit.
# ASCII only (Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page).

param(
    [string]$SetupExe = '',
    [string]$VenvPython = '',
    [string]$FetchScript = '',
    [string]$SelfTestScript = '',
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

function Write-Result([bool]$ok, [string]$reason) {
    if ($ok) { Write-Output 'crawl4ai-repair=ok'; exit 0 }
    # one line, at most 300 characters
    $line = (($reason -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1))
    if (-not $line) { $line = 'no reason given' }
    $line = $line.Trim()
    if ($line.Length -gt 300) { $line = $line.Substring(0, 300) }
    Write-Output ('crawl4ai-repair=fail: ' + $line)
    exit 1
}

function Find-Crawl4AiPython {
    # The same places as crawl4ai-selftest.ps1 and save_pages.find_crawl4ai_python: the uv tool venv.
    $roots = @()
    if ($env:UV_TOOL_DIR) { $roots += $env:UV_TOOL_DIR }
    if ($env:XDG_DATA_HOME) { $roots += (Join-Path $env:XDG_DATA_HOME 'uv/tools') }
    $roots += (Join-Path $HOME '.local/share/uv/tools')
    if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'uv/tools') }
    foreach ($root in $roots) {
        foreach ($rel in @('crawl4ai/Scripts/python.exe', 'crawl4ai/bin/python')) {
            $candidate = Join-Path $root $rel
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return ''
}

function Find-SetupExe {
    $c = Get-Command 'crawl4ai-setup' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($name in @('crawl4ai-setup.exe', 'crawl4ai-setup')) {
        $candidate = Join-Path $HOME ('.local/bin/' + $name)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

try {
    if (-not $VenvPython -and $env:CRAWL4AI_SELFTEST_PYTHON) { $VenvPython = $env:CRAWL4AI_SELFTEST_PYTHON }
    if (-not $VenvPython) { $VenvPython = Find-Crawl4AiPython }
    if (-not $VenvPython -or -not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        Write-Result $false 'the Crawl4AI venv python was not found (uv tool install crawl4ai)'
    }
    if (-not $FetchScript) { $FetchScript = Join-Path $HOME '.claude/skills/research/scripts/crawl4ai_fetch.py' }
    if (-not (Test-Path -LiteralPath $FetchScript -PathType Leaf)) {
        Write-Result $false ('crawl4ai_fetch.py was not found at ' + $FetchScript)
    }
    if (-not $SelfTestScript) { $SelfTestScript = Join-Path $PSScriptRoot 'crawl4ai-selftest.ps1' }
    if (-not (Test-Path -LiteralPath $SelfTestScript -PathType Leaf)) {
        Write-Result $false ('crawl4ai-selftest.ps1 was not found at ' + $SelfTestScript)
    }
    if (-not $SetupExe) { $SetupExe = Find-SetupExe }
    if (-not $SetupExe -or -not (Test-Path -LiteralPath $SetupExe -PathType Leaf)) {
        Write-Result $false 'crawl4ai-setup was not found (uv tool install crawl4ai)'
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('crawl4ai-repair-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        # 1. the folder, from the one place that knows it. Python writes it as UTF-8 (PYTHONUTF8) into a
        # file that is read back as UTF-8: through a pipe, Windows PowerShell 5.1 would decode it with
        # the OEM code page and a profile folder with an umlaut would come out wrong.
        $env:PYTHONUTF8 = '1'
        $env:PYTHONIOENCODING = 'utf-8'
        $dirOut = Join-Path $tmp 'dir-out.txt'
        $dirArgs = @{ FilePath = $VenvPython; PassThru = $true
                      ArgumentList = ('"' + $FetchScript + '" --print-browsers-path')
                      RedirectStandardOutput = $dirOut; RedirectStandardError = (Join-Path $tmp 'dir-err.txt') }
        if ($env:OS -eq 'Windows_NT') { $dirArgs.WindowStyle = 'Hidden' }
        $dir = ''
        try {
            $dirProc = Start-Process @dirArgs
            $null = $dirProc.Handle
            $null = Wait-Process -Id $dirProc.Id -Timeout 60 -ErrorAction SilentlyContinue
            $dirProc.Refresh()
            if ($dirProc.HasExited) {
                $dir = [string](@([IO.File]::ReadAllLines($dirOut, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() }) | Select-Object -First 1)
            } else {
                # our own child only
                if ($env:OS -eq 'Windows_NT') { & taskkill.exe /PID $dirProc.Id /T /F 2>&1 | Out-Null }
                else { Stop-Process -Id $dirProc.Id -Force -ErrorAction SilentlyContinue }
            }
        } catch { $dir = '' }
        $dir = $dir.Trim()
        if (-not $dir -or -not [IO.Path]::IsPathRooted($dir)) {
            Write-Result $false 'crawl4ai_fetch.py did not name a browser folder'
        }

        # 2. crawl4ai-setup, with the variable for this process (the child inherits it)
        $setupOut = Join-Path $tmp 'setup-out.txt'
        $setupErr = Join-Path $tmp 'setup-err.txt'
        $setupLimit = [Math]::Max(1, $TimeoutSeconds - 60)
        $env:PLAYWRIGHT_BROWSERS_PATH = $dir
        $startArgs = @{ FilePath = $SetupExe; PassThru = $true
                        RedirectStandardOutput = $setupOut; RedirectStandardError = $setupErr }
        if ($env:OS -eq 'Windows_NT') { $startArgs.WindowStyle = 'Hidden' }
        $proc = Start-Process @startArgs
        # Windows PowerShell 5.1 loses ExitCode of a redirected process unless its handle is held
        $null = $proc.Handle
        $null = Wait-Process -Id $proc.Id -Timeout $setupLimit -ErrorAction SilentlyContinue
        $proc.Refresh()
        if (-not $proc.HasExited) {
            # our own child only; /T takes the downloads it started along
            if ($env:OS -eq 'Windows_NT') { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null }
            else { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            Write-Result $false ('the browser setup timed out after ' + $setupLimit + ' s')
        }
        $exit = $null
        try { $exit = $proc.ExitCode } catch { $exit = $null }
        if ($exit -ne 0) {
            $last = ''
            foreach ($f in @($setupErr, $setupOut)) {
                if (-not $last -and (Test-Path -LiteralPath $f)) {
                    $last = [string](Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -Last 1)
                }
            }
            $why = 'the browser setup failed (exit ' + $exit + ')'
            if ($last) { $why += ': ' + $last.Trim() }
            Write-Result $false $why
        }

        # 3. the self-test decides
        $shell = (Get-Process -Id $PID).Path
        $shellArgs = @('-NoProfile')
        if ($env:OS -eq 'Windows_NT') { $shellArgs += @('-ExecutionPolicy', 'Bypass') }
        $stOut = @(& $shell @shellArgs -File $SelfTestScript -VenvPython $VenvPython -FetchScript $FetchScript -TimeoutSeconds 60 2>&1 | ForEach-Object { [string]$_ })
        $stExit = $LASTEXITCODE
        $stLine = [string](@($stOut | Where-Object { $_ -match '^crawl4ai=' }) | Select-Object -Last 1)
        if ($stExit -eq 0 -and $stLine -eq 'crawl4ai=ok') { Write-Result $true '' }
        if ($stLine -match '^crawl4ai=fail: (.*)$') { Write-Result $false $Matches[1] }
        Write-Result $false ('the self-test gave no result after the setup (exit ' + $stExit + ')')
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Result $false ('repair crashed: ' + $_.Exception.Message)
}
