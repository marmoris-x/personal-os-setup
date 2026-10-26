# crawl4ai-selftest.ps1 - token-free self-test of Crawl4AI, the first and free page reader of every
# research run. Prints exactly one line and exits 0 or 1:
#   crawl4ai=ok
#   crawl4ai=fail: <reason>
#
# It reads one small, stable page through crawl4ai_fetch.py (the same helper save_pages.py uses),
# in the Crawl4AI venv, with a hard time limit. Why it exists: on 2026-10-25 the Playwright browser
# folder (ms-playwright) was found empty, Crawl4AI had not worked for two days, and every research
# page had silently gone to the paid fallback services. Callers: morning.ps1 (daily), install.ps1
# (right after installing or upgrading Crawl4AI) and setup/tools/verify-all.ps1.
# It starts no language model and deletes nothing. The only process it may kill is the helper it
# started itself, when that runs past the limit.
# ASCII only (Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page).

param(
    [string]$Url = 'https://example.com/',
    [int]$TimeoutSeconds = 60,
    [string]$VenvPython = '',
    [string]$FetchScript = ''
)

$ErrorActionPreference = 'Stop'

function Write-Result([bool]$ok, [string]$reason) {
    if ($ok) { Write-Output 'crawl4ai=ok'; exit 0 }
    # one line, no box drawing, at most 200 characters
    $line = (($reason -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1))
    if (-not $line) { $line = 'no reason given' }
    $line = $line.Trim()
    if ($line.Length -gt 200) { $line = $line.Substring(0, 200) }
    Write-Output ('crawl4ai=fail: ' + $line)
    exit 1
}

function Find-Crawl4AiPython {
    # The same places as save_pages.find_crawl4ai_python: the uv tool venv of crawl4ai.
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

try {
    # CRAWL4AI_SELFTEST_PYTHON replaces the search; a path that does not exist simulates a
    # broken install without touching anything real (verify and the acceptance run use it).
    if (-not $VenvPython -and $env:CRAWL4AI_SELFTEST_PYTHON) { $VenvPython = $env:CRAWL4AI_SELFTEST_PYTHON }
    if (-not $VenvPython) { $VenvPython = Find-Crawl4AiPython }
    if (-not $VenvPython -or -not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        Write-Result $false 'the Crawl4AI venv python was not found'
    }
    if (-not $FetchScript) { $FetchScript = Join-Path $HOME '.claude/skills/research/scripts/crawl4ai_fetch.py' }
    if (-not (Test-Path -LiteralPath $FetchScript -PathType Leaf)) {
        Write-Result $false ('crawl4ai_fetch.py was not found at ' + $FetchScript)
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('crawl4ai-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $urlsFile = Join-Path $tmp 'urls.json'
        $outFile = Join-Path $tmp 'pages.jsonl'
        $stdoutFile = Join-Path $tmp 'stdout.txt'
        $stderrFile = Join-Path $tmp 'stderr.txt'
        [IO.File]::WriteAllText($urlsFile, ('["' + $Url + '"]'), (New-Object Text.UTF8Encoding($false)))

        # The helper's own per-page limit stays below ours, so a slow page is its error, not a kill.
        $pageTimeout = [Math]::Max(5, $TimeoutSeconds - 15)
        $env:PYTHONUTF8 = '1'
        $env:PYTHONIOENCODING = 'utf-8'
        $arguments = '"' + $FetchScript + '" "' + $urlsFile + '" "' + $outFile + '" --timeout ' + $pageTimeout + ' --concurrency 1'
        $startArgs = @{ FilePath = $VenvPython; ArgumentList = $arguments; PassThru = $true
                        RedirectStandardOutput = $stdoutFile; RedirectStandardError = $stderrFile }
        if ($env:OS -eq 'Windows_NT') { $startArgs.WindowStyle = 'Hidden' }
        $proc = Start-Process @startArgs
        # Windows PowerShell 5.1 loses ExitCode of a redirected process unless its handle is held
        $null = $proc.Handle
        $null = Wait-Process -Id $proc.Id -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue
        $proc.Refresh()
        if (-not $proc.HasExited) {
            # our own child only; /T takes the browser it started along
            if ($env:OS -eq 'Windows_NT') { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null }
            else { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            Write-Result $false ('timeout after ' + $TimeoutSeconds + ' s')
        }
        $exit = $null
        try { $exit = $proc.ExitCode } catch { $exit = $null }

        $first = $null
        if (Test-Path -LiteralPath $outFile) {
            $first = Get-Content -LiteralPath $outFile -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -First 1
        }
        if (-not $first) {
            $err = ''
            if (Test-Path -LiteralPath $stderrFile) {
                $err = (Get-Content -LiteralPath $stderrFile -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -Last 1)
            }
            if ($err) { Write-Result $false $err }
            Write-Result $false ('the helper wrote no result (exit ' + $exit + ')')
        }
        $record = $null
        try { $record = $first | ConvertFrom-Json } catch { Write-Result $false 'the helper wrote an unreadable result' }
        if ($record.ok -eq $true) { Write-Result $true '' }
        $reason = [string]$record.error
        if (-not $reason) { $reason = 'HTTP ' + [string]$record.status }
        Write-Result $false $reason
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Result $false ('self-test crashed: ' + $_.Exception.Message)
}
