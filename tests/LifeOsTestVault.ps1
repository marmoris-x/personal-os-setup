# TestVault.ps1 - builds a throw-away vault and dev root for the Life OS tests. Dot-source.
# ASCII only. Nothing here touches the live vault or C:\Dev\Projects.

function Write-TestFile([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

$script:DailyTemplate = "---`ntype: daily`nstatus: active`ndate: '{{date}}'`n---`n# {{date}}`n`n## Roh`n`n## Protokoll`n`n## Aufgaben`n`n## Morgenbericht`n"

function New-TestVault([string]$root) {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    foreach ($d in '000-meta\templates', '100-daily', '200-projects', '300-areas', 'inbox\audio', 'trash') {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null
    }
    Write-TestFile (Join-Path $root '000-meta\templates\daily.md') $script:DailyTemplate
    Write-TestFile (Join-Path $root '000-meta\life-os-runs.log') ''
    Write-TestFile (Join-Path $root '000-meta\todo.md') "---`ntype: note`nstatus: active`ndate: 2026-09-20`n---`n# Todo`n`n## Now`n`n## Next`n`n## Waiting`n`n## Later`n`n## Done`n"
    return $root
}

function Set-FileAge([string]$path, [int]$minutesOld) {
    (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddMinutes(-$minutesOld)
}

function New-Daily([string]$vault, [string]$date, [string]$rohLines = '', [string]$morgen = '') {
    $roh = ''
    if ($rohLines) { $roh = $rohLines + "`n" }
    $text = "---`ntype: daily`nstatus: active`ndate: '$date'`n---`n# $date`n`n## Roh`n$roh`n## Protokoll`n`n## Aufgaben`n`n## Morgenbericht`n$morgen"
    $p = Join-Path $vault ("100-daily\$date.md")
    Write-TestFile $p $text
    return $p
}

function New-Hub([string]$vault, [string]$name, [string]$hubWritten = '') {
    $fm = "type: project`nstatus: active`ndate: 2026-09-01`nrepo: C:\Dev\Projects\$name`n"
    if ($hubWritten) { $fm += "hub_written: $hubWritten`n" }
    $text = "---`n$fm---`n# $name`n`n## Goal`nTest.`n`n## Status`nOld status.`n`n## Next step`nOld next.`n`n## Timeline`n- 2026-09-01 - created`n"
    $p = Join-Path $vault ("200-projects\$name.md")
    Write-TestFile $p $text
    return $p
}

function New-TestRepo([string]$devRoot, [string]$name, [switch]$Dirty) {
    $dir = Join-Path $devRoot $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.com'
    $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.com'
    & git -C $dir init -q 2>$null | Out-Null
    Write-TestFile (Join-Path $dir 'a.txt') "one`n"
    & git -C $dir add -A 2>$null | Out-Null
    & git -C $dir -c commit.gpgsign=false commit -q -m 'init' 2>$null | Out-Null
    if ($Dirty) { Write-TestFile (Join-Path $dir 'b.txt') "two`n" }
    return $dir
}

function New-RenderedMirror {
    # The files under home/ carry {{PLACEHOLDER}} tokens that install.ps1 fills in. The tests run
    # the scripts for real, so they work on a rendered copy in a temp folder. Only the tokens the
    # life-os scripts use are filled; every path a test cares about is passed as a parameter.
    param([string]$Source, [string]$Dest)
    $tokens = @{
        '{{PWSH_HOST}}' = 'powershell.exe'; '{{VAULT}}' = 'C:\PersonalOS'; '{{DEV}}' = 'C:\Dev'
        '{{HOME}}' = $env:USERPROFILE; '{{HOME_ENV}}' = $env:USERPROFILE
        '{{LIFEOS_PYTHON}}' = (Join-Path $env:LOCALAPPDATA 'life-os\venv\Scripts\python.exe')
        '{{LIFEOS_LOCK}}' = (Join-Path $env:LOCALAPPDATA 'life-os\morning.lock')
        '{{LIFEOS_STATE}}' = (Join-Path $env:LOCALAPPDATA 'life-os'); '{{MORNING_TIME}}' = '07:00'
    }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $files = @(Get-Item -LiteralPath $Source)
    if ((Get-Item -LiteralPath $Source).PSIsContainer) { $files = @(Get-ChildItem -LiteralPath $Source -File) }
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)
        foreach ($k in $tokens.Keys) { $text = $text.Replace($k, $tokens[$k]) }
        [IO.File]::WriteAllText((Join-Path $Dest $f.Name), $text, (New-Object Text.UTF8Encoding($false)))
    }
    return $Dest
}

# A stand-in for the Crawl4AI venv python: crawl4ai-selftest.ps1 runs it as
# "<stub> <fetch script> <urls.json> <out.jsonl> --timeout N --concurrency 1". Nothing real is
# started, nothing real is deleted (owner's rule 2026-10-26: simulate the failure).
function New-Crawl4AiStub([string]$dir, [string]$mode) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $body = switch ($mode) {
        'ok'   { "echo {`"url`":`"https://example.com/`",`"ok`":true,`"status`":200,`"markdown`":`"Example Domain`"}> %3`r`n" }
        'fail' { "echo {`"url`":`"https://example.com/`",`"ok`":false,`"status`":null,`"error`":`"Error: BrowserType.launch: Executable doesn't exist at X`"}> %3`r`n" }
        'slow' { "ping -n 40 127.0.0.1 >nul`r`n" }
        'empty' { "exit /b 3`r`n" }
        # fails until the stand-in setup program (New-Crawl4AiSetupStub, same folder) has run;
        # `--print-browsers-path` answers like crawl4ai_fetch.py does
        # answers `--print-browsers-path` with a path that holds u-umlaut, encoded like the real Python
        # does: UTF-8 when PYTHONUTF8=1 is set for it, else the ANSI code page (1252)
        'umlaut' {
            $ps = '$p = ''C:\Users\J'' + [char]0xFC + ''rgen\own''; if ($env:PYTHONUTF8 -eq ''1'') { $e = [Text.Encoding]::UTF8 } else { $e = [Text.Encoding]::GetEncoding(1252) }; $b = $e.GetBytes($p + [char]13 + [char]10); $o = [Console]::OpenStandardOutput(); $o.Write($b, 0, $b.Length)'
            ('if not "%2"=="--print-browsers-path" goto json' + "`r`n" + 'powershell.exe -NoProfile -Command "' + $ps + '"' + "`r`nexit /b 0`r`n:json`r`n" +
                "echo {`"url`":`"https://example.com/`",`"ok`":true,`"status`":200,`"markdown`":`"Example Domain`"}> %3`r`n")
        }
        'repairable' { "if `"%2`"==`"--print-browsers-path`" (echo %~dp0own& exit /b 0)`r`nif exist `"%~dp0repaired.marker`" (echo {`"url`":`"https://example.com/`",`"ok`":true,`"status`":200,`"markdown`":`"Example Domain`"}> %3) else (echo {`"url`":`"https://example.com/`",`"ok`":false,`"status`":null,`"error`":`"Error: BrowserType.launch: Executable doesn't exist at X`"}> %3)`r`n" }
    }
    $stub = Join-Path $dir ($mode + '.cmd')
    Write-TestFile $stub ("@echo off`r`n" + $body)
    $fetch = Join-Path $dir 'crawl4ai_fetch.py'
    Write-TestFile $fetch "# stand-in`n"
    return [pscustomobject]@{ Python = $stub; Fetch = $fetch }
}

# A stand-in for crawl4ai-setup. It records the PLAYWRIGHT_BROWSERS_PATH it was given in seen.txt
# and, when it works, leaves the marker that the 'repairable' python stub waits for. The real
# crawl4ai-setup must never run from a test (it would fill the owner's real browser folder).
function New-Crawl4AiSetupStub([string]$dir, [string]$mode) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $body = switch ($mode) {
        'ok'   { "echo %PLAYWRIGHT_BROWSERS_PATH%> `"%~dp0seen.txt`"`r`necho x> `"%~dp0repaired.marker`"`r`nexit /b 0`r`n" }
        'fail' { "echo %PLAYWRIGHT_BROWSERS_PATH%> `"%~dp0seen.txt`"`r`necho boom 1>&2`r`nexit /b 1`r`n" }
        # works, but fixes nothing: the self-test stays red afterwards
        'nomarker' { "echo %PLAYWRIGHT_BROWSERS_PATH%> `"%~dp0seen.txt`"`r`nexit /b 0`r`n" }
        'slow' { "ping -n 40 127.0.0.1 >nul`r`n" }
        # records the variable as UTF-8 (a cmd echo would mangle the umlaut)
        'utf8' { "powershell.exe -NoProfile -Command `"[IO.File]::WriteAllText('%~dp0seen-utf8.txt', `$env:PLAYWRIGHT_BROWSERS_PATH, (New-Object Text.UTF8Encoding(`$false)))`"`r`nexit /b 0`r`n" }
    }
    $stub = Join-Path $dir ('setup-' + $mode + '.cmd')
    Write-TestFile $stub ("@echo off`r`n" + $body)
    return $stub
}

# The three morning.ps1 parameters that keep a test away from the real Crawl4AI: a venv python
# whose self-test passes, its fetch script, and a setup program that fails. Every test that runs
# morning.ps1 merges these into its arguments (tests/LifeOsMorning.Tests.ps1 checks that it does):
# without them the real self-test runs, and when it fails the real crawl4ai-repair.ps1 runs.
function Get-HermeticCrawl4AiArgs([string]$dir) {
    $c4 = New-Crawl4AiStub $dir 'ok'
    return @{ Crawl4AiVenvPython = $c4.Python; Crawl4AiFetchScript = $c4.Fetch; Crawl4AiSetupExe = (New-Crawl4AiSetupStub $dir 'fail') }
}