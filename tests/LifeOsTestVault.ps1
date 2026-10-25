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