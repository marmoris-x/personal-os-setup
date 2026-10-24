# deepseek-orientation.ps1 -Part <1|2|3> - hands the owner's orientation file to a DeepSeek session.
#
#   SessionStart and SubagentStart hook, registered in the DeepSeek profile file only (three
#   handlers per event, -Part 1, 2 and 3). It reads ~/.claude/orientation/deepseek.md and prints
#   part N as hookSpecificOutput.additionalContext for the event named in the hook input.
#
#   Why parts: Claude Code caps one hook's additionalContext at 10,000 characters and measures
#   each hook on its own, so the file goes in up to three parts of at most 9,500 characters
#   (28,500 in total). The three calls run in parallel and compute the same split independently.
#
#   The split is deterministic and never cuts inside a line:
#     1. at lines that start with "## ", parts are filled greedily in file order;
#     2. a section longer than one part is cut at blank lines;
#     3. a paragraph still longer is cut at the last line break before the limit.
#   Each part starts with "[Orientation part N of M - the owner's own instructions, injected by
#   his SessionStart hook from ~/.claude/orientation/deepseek.md; same standing as CLAUDE.md]";
#   the label counts toward the 9,500. The global CLAUDE.md (Safety) grants that standing by
#   origin only, and names this label. Joining the parts without their labels gives back the file.
#
#   Nothing to say -> prints nothing: a missing file, an empty one, one that holds only the
#   placeholder comment, or a part number that does not exist. A file that needs more than three
#   parts (or holds a single line longer than a part) injects nothing; -Part 1 on SessionStart
#   prints a German systemMessage so the owner sees it.
#
#   INJECTING MUST NEVER BLOCK A SESSION: every failure exits 0 (the same rule as skill-usage.ps1).
#
#   -OrientationFile is for the tests; the environment variable PERSONAL_OS_ORIENTATION_FILE
#   overrides the default path for the live proof. The output is pure ASCII (non-ASCII characters
#   become \uXXXX escapes), so it survives any console code page.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [int]$Part = 1,
    [string]$OrientationFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'

$limit = 9500
$maxParts = 3

function ConvertTo-AsciiJson($obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 5
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function Get-Lines([string]$text) {
    # every line keeps its own line ending, so joining the lines gives the text back
    return @([regex]::Matches($text, '[^\n]*\n|[^\n]+$') | ForEach-Object { $_.Value })
}

# Cut one over-long block (a list of lines) into chunks of at most $budget characters at line
# breaks. Returns $null when a single line is longer than the budget (never cut inside a line).
function Split-AtLines($lines, [int]$budget) {
    $chunks = New-Object System.Collections.ArrayList
    $cur = ''
    foreach ($l in $lines) {
        if ($l.Length -gt $budget) { return $null }
        if (($cur.Length + $l.Length) -gt $budget) { [void]$chunks.Add($cur); $cur = '' }
        $cur += $l
    }
    if ($cur.Length -gt 0) { [void]$chunks.Add($cur) }
    return , $chunks
}

# Cut an over-long section at blank lines; a paragraph that is still too long goes to Split-AtLines.
function Split-Section([string]$section, [int]$budget) {
    $lines = Get-Lines $section
    $paras = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        [void]$cur.Add($l)
        if ($l.Trim().Length -eq 0) { [void]$paras.Add(-join $cur.ToArray()); $cur = New-Object System.Collections.ArrayList }
    }
    if ($cur.Count -gt 0) { [void]$paras.Add(-join $cur.ToArray()) }
    $units = New-Object System.Collections.ArrayList
    foreach ($p in $paras) {
        if ($p.Length -le $budget) { [void]$units.Add($p); continue }
        $sub = Split-AtLines (Get-Lines $p) $budget
        if ($null -eq $sub) { return $null }
        foreach ($s in $sub) { [void]$units.Add($s) }
    }
    return , $units
}

function Get-Pieces([string]$text, [int]$budget) {
    # sections: text before the first "## " heading is its own section
    $lines = Get-Lines $text
    $sections = New-Object System.Collections.ArrayList
    $cur = ''
    foreach ($l in $lines) {
        if ($l.StartsWith('## ') -and $cur.Length -gt 0) { [void]$sections.Add($cur); $cur = '' }
        $cur += $l
    }
    if ($cur.Length -gt 0) { [void]$sections.Add($cur) }
    # units: a section that fits stays whole, a longer one is cut as described above
    $units = New-Object System.Collections.ArrayList
    foreach ($s in $sections) {
        if ($s.Length -le $budget) { [void]$units.Add($s); continue }
        $sub = Split-Section $s $budget
        if ($null -eq $sub) { return $null }
        foreach ($u in $sub) { [void]$units.Add($u) }
    }
    # greedy fill in file order
    $parts = New-Object System.Collections.ArrayList
    $cur = ''
    foreach ($u in $units) {
        if (($cur.Length + $u.Length) -gt $budget -and $cur.Length -gt 0) { [void]$parts.Add($cur); $cur = '' }
        $cur += $u
    }
    if ($cur.Length -gt 0) { [void]$parts.Add($cur) }
    return , $parts
}

try {
    # the hook input names the event; anything unreadable falls back to SessionStart
    $event = 'SessionStart'
    if ([Console]::IsInputRedirected) {
        $raw = @($Input) -join "`n"
        if ($raw.Trim()) {
            $payload = $raw | ConvertFrom-Json
            if ($payload -and ($payload.hook_event_name -is [string]) -and $payload.hook_event_name) { $event = [string]$payload.hook_event_name }
        }
    }
    if ($event -ne 'SessionStart' -and $event -ne 'SubagentStart') { exit 0 }

    $path = $OrientationFile
    if (-not $path) { $path = $env:PERSONAL_OS_ORIENTATION_FILE }
    if (-not $path) { $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'orientation/deepseek.md' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 0 }

    $text = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false)))
    $trim = $text.Trim()
    if (-not $trim) { exit 0 }
    if ($trim -match '^<!--\s*PLACEHOLDER:[^\r\n]*-->$') { exit 0 }

    $labelFor = { param($n, $m) "[Orientation part $n of $m - the owner's own instructions, injected by his SessionStart hook from ~/.claude/orientation/deepseek.md; same standing as CLAUDE.md]`n" }
    $budget = $limit - (& $labelFor 1 1).Length     # the label has the same length for every n, m up to 9
    $parts = Get-Pieces $text $budget

    if ($null -eq $parts -or $parts.Count -gt $maxParts) {
        if ($Part -eq 1 -and $event -eq 'SessionStart') {
            $n = $text.Length.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('de-DE'))
            $msg = 'Orientierungsdatei zu lang: ' + $n + ' Zeichen, h' + [char]0x00F6 + 'chstens 28.500'
            if ($null -eq $parts) { $msg = 'Orientierungsdatei nicht teilbar: eine Zeile ist l' + [char]0x00E4 + 'nger als 9.500 Zeichen' }
            elseif ($text.Length -le 28500) { $msg = 'Orientierungsdatei passt nicht in drei Teile (' + $n + ' Zeichen): zwei Abschnitte mit ## ergeben zusammen mehr als 9.500 Zeichen. Abschnitte k' + [char]0x00FC + 'rzer machen oder teilen' }
            Write-Output (ConvertTo-AsciiJson @{ systemMessage = $msg })
        }
        exit 0
    }
    if ($Part -lt 1 -or $Part -gt $parts.Count) { exit 0 }

    $body = (& $labelFor $Part $parts.Count) + $parts[$Part - 1]
    $out = @{ hookSpecificOutput = @{ hookEventName = $event; additionalContext = $body } }
    Write-Output (ConvertTo-AsciiJson $out)
}
catch { }

exit 0
