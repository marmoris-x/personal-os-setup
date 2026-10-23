# Pester 5.9.1 (pinned). The DeepSeek orientation hook: hooks/deepseek-orientation.ps1 -Part N.
#
# The owner's orientation file (about 12,000-14,000 characters) must reach every DeepSeek session
# and subagent by itself. Claude Code caps one hook's additionalContext at 10,000 characters, so
# the script cuts the file into up to three labelled parts of at most 9,500 characters, one hook
# call per part. What is measured here: a missing, empty or placeholder-only file adds nothing;
# a 14,000-character file gives exactly two parts that join back to the original text; a file
# over 28,500 characters injects nothing and shows a German warning; the split never cuts inside
# a line; the script never blocks a session and stays ASCII-only.
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:hook = Join-Path $repoRoot 'home/.claude/hooks/deepseek-orientation.ps1'
    $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $script:work = Join-Path $scratchRoot 'orientation'
    if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $script:work | Out-Null

    $script:placeholder = '<!-- PLACEHOLDER: the owner writes this file. Loaded by the DeepSeek profile only, in up to 3 parts of 9,500 characters each (28,500 in total). Split points: lines starting with "## ". -->'

    function Write-Text([string]$Name, [string]$Text) {
        $p = Join-Path $script:work $Name
        [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
        return $p
    }
    # Filler with "## " sections: each section is a heading plus paragraphs of 79-character lines.
    function New-Doc([int]$Sections, [int]$LinesPerSection, [string]$First = '', [string]$Last = '') {
        $sb = [Text.StringBuilder]::new()
        for ($s = 1; $s -le $Sections; $s++) {
            [void]$sb.Append("## Section $s`n")
            if ($s -eq 1 -and $First) { [void]$sb.Append("$First`n") }
            for ($l = 1; $l -le $LinesPerSection; $l++) {
                [void]$sb.Append(('Filler line {0}.{1} ' -f $s, $l).PadRight(78, 'x') + "`n")
                if ($l % 5 -eq 0) { [void]$sb.Append("`n") }
            }
            if ($s -eq $Sections -and $Last) { [void]$sb.Append("$Last`n") }
        }
        return $sb.ToString()
    }
    # One hook call. Returns text, exit code and the parsed JSON (or $null).
    function Invoke-Hook {
        param([int]$Part, [string]$File = '', [string]$Event = 'SessionStart', [string]$EnvFile = '', [string]$Stdin = '__default__')
        if ($Stdin -eq '__default__') { $Stdin = '{"hook_event_name":"' + $Event + '","session_id":"t"}' }
        $a = @('-NoProfile', '-File', $script:hook, '-Part', $Part)
        if ($File) { $a += @('-OrientationFile', $File) }
        $env:PERSONAL_OS_ORIENTATION_FILE = $EnvFile
        $text = ($Stdin | & pwsh @a 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $env:PERSONAL_OS_ORIENTATION_FILE = $null
        $json = $null
        if ($text.Trim()) { try { $json = $text | ConvertFrom-Json } catch { $json = $null } }
        return @{ text = $text; code = $code; json = $json }
    }
    function Get-Parts([string]$File, [string]$Event = 'SessionStart') {
        $parts = @()
        foreach ($n in 1..3) {
            $r = Invoke-Hook -Part $n -File $File -Event $Event
            if ($r.json -and $r.json.hookSpecificOutput) { $parts += $r.json.hookSpecificOutput.additionalContext }
        }
        return , $parts
    }
    function Remove-Label([string]$Part) { return $Part.Substring($Part.IndexOf("`n") + 1) }
}

Describe 'deepseek-orientation.ps1' {
    It 'exists and is ASCII-only' {
        $script:hook | Should -Exist
        $bytes = [IO.File]::ReadAllBytes($script:hook)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'prints nothing for a missing, an empty and a placeholder-only file' {
        $missing = Join-Path $script:work 'does-not-exist.md'
        $empty = Write-Text 'empty.md' ''
        $blank = Write-Text 'blank.md' "  `n`n"
        $ph = Write-Text 'placeholder.md' ($script:placeholder + "`n")
        foreach ($f in $missing, $empty, $blank, $ph) {
            $r = Invoke-Hook -Part 1 -File $f
            $r.code | Should -Be 0
            $r.text.Trim() | Should -BeNullOrEmpty -Because $f
        }
    }

    It 'gives exactly two parts for a 14,000-character file, each at most 9,500 characters' {
        $doc = New-Doc -Sections 7 -LinesPerSection 24
        $doc.Length | Should -BeGreaterThan 13000
        $doc.Length | Should -BeLessThan 15000
        $f = Write-Text 'f14k.md' $doc
        $parts = Get-Parts $f
        $parts.Count | Should -Be 2
        foreach ($p in $parts) { $p.Length | Should -BeLessOrEqual 9500 }
        $parts[0] | Should -Match '^\[Orientation part 1 of 2 - all parts together form one document\]'
        $parts[1] | Should -Match '^\[Orientation part 2 of 2 - all parts together form one document\]'
        (Invoke-Hook -Part 3 -File $f).text.Trim() | Should -BeNullOrEmpty
    }

    It 'joins back to the original text exactly once the labels are taken off' {
        $doc = New-Doc -Sections 7 -LinesPerSection 24 -First 'The first marker word is BLUEFINCH.' -Last 'The second marker word is REDKITE.'
        $f = Write-Text 'join.md' $doc
        $parts = Get-Parts $f
        (($parts | ForEach-Object { Remove-Label $_ }) -join '') | Should -BeExactly $doc
    }

    It 'splits at "## " headings: a part ends before a heading, never inside a section that fits' {
        $doc = New-Doc -Sections 7 -LinesPerSection 24
        $f = Write-Text 'headings.md' $doc
        $parts = Get-Parts $f
        (Remove-Label $parts[1]) | Should -Match '^## Section \d'
    }

    It 'splits an over-long section at blank lines, and an over-long paragraph at a line break' {
        $one = New-Doc -Sections 1 -LinesPerSection 140          # one section of about 11,000 characters
        $f1 = Write-Text 'bigsection.md' $one
        $p1 = Get-Parts $f1
        $p1.Count | Should -Be 2
        (($p1 | ForEach-Object { Remove-Label $_ }) -join '') | Should -BeExactly $one
        (Remove-Label $p1[0]) | Should -Match "`n`n$"            # cut right after a blank line

        $para = "## Only`n" + ((1..130 | ForEach-Object { ('Line {0} ' -f $_).PadRight(78, 'y') + "`n" }) -join '')   # no blank lines
        $f2 = Write-Text 'bigparagraph.md' $para
        $p2 = Get-Parts $f2
        $p2.Count | Should -Be 2
        (($p2 | ForEach-Object { Remove-Label $_ }) -join '') | Should -BeExactly $para
        foreach ($p in $p2) { $p.Length | Should -BeLessOrEqual 9500; (Remove-Label $p) | Should -Match "`n$" }
    }

    It 'keeps CRLF line endings and German text intact' {
        $text = "## " + [char]0x00DC + "berblick`r`n" + ((1..30 | ForEach-Object { "Zeile $_ mit Umlauten " + [char]0x00E4 + [char]0x00F6 + [char]0x00FC + "`r`n" }) -join '')
        $f = Write-Text 'crlf.md' $text
        $parts = Get-Parts $f
        $parts.Count | Should -Be 1
        (Remove-Label $parts[0]) | Should -BeExactly $text
    }

    It 'injects nothing and shows a German warning for a 30,000-character file' {
        $doc = New-Doc -Sections 15 -LinesPerSection 24
        $doc.Length | Should -BeGreaterThan 28500
        $f = Write-Text 'f30k.md' $doc
        $r1 = Invoke-Hook -Part 1 -File $f
        $r1.code | Should -Be 0
        $r1.json.hookSpecificOutput | Should -BeNullOrEmpty
        $r1.json.systemMessage | Should -Match 'Orientierungsdatei zu lang'
        $r1.json.systemMessage | Should -Match '28\.500'
        $r1.json.systemMessage | Should -Match ([regex]::Escape($doc.Length.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('de-DE'))))
        foreach ($n in 2, 3) { (Invoke-Hook -Part $n -File $f).text.Trim() | Should -BeNullOrEmpty }
    }

    # Found by the review of 2026-10-23: five sections of about 4,900 characters (24,500 in total) do
    # not pack into three parts, because two of them together exceed one part. The hook used to
    # call that "too long, maximum 28,500", which contradicts itself.
    It 'gives its own warning when the file is short enough but its sections do not pack into three parts' {
        $doc = New-Doc -Sections 5 -LinesPerSection 61
        $doc.Length | Should -BeLessThan 28500
        $doc.Length | Should -BeGreaterThan 20000
        $f = Write-Text 'fpack.md' $doc
        $r1 = Invoke-Hook -Part 1 -File $f
        $r1.code | Should -Be 0
        $r1.json.hookSpecificOutput | Should -BeNullOrEmpty
        $r1.json.systemMessage | Should -Not -Match 'zu lang'
        $r1.json.systemMessage | Should -Match 'drei Teile'
        foreach ($n in 2, 3) { (Invoke-Hook -Part $n -File $f).text.Trim() | Should -BeNullOrEmpty }
    }

    It 'names the event it was called for, and also serves a subagent start' {
        $f = Write-Text 'event.md' (New-Doc -Sections 2 -LinesPerSection 5)
        (Invoke-Hook -Part 1 -File $f -Event 'SessionStart').json.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
        (Invoke-Hook -Part 1 -File $f -Event 'SubagentStart').json.hookSpecificOutput.hookEventName | Should -Be 'SubagentStart'
    }

    It 'reads PERSONAL_OS_ORIENTATION_FILE when no -OrientationFile is given' {
        $f = Write-Text 'envfile.md' "## A`nThe marker is GREENHERON.`n"
        $r = Invoke-Hook -Part 1 -EnvFile $f
        $r.json.hookSpecificOutput.additionalContext | Should -Match 'GREENHERON'
    }

    It 'never blocks: garbage or no input still exits 0, and the output stays ASCII' {
        $f = Write-Text 'garbage.md' ("## " + [char]0x00DC + "ber`nText " + [char]0x00E4 + "`n")
        foreach ($stdin in 'not json at all', '', '{"hook_event_name":42}') {
            $r = Invoke-Hook -Part 1 -File $f -Stdin $stdin
            $r.code | Should -Be 0
            @([Text.Encoding]::UTF8.GetBytes($r.text) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
        (Invoke-Hook -Part 9 -File $f).code | Should -Be 0
    }
}
