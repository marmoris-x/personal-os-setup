# area-check.ps1 - the token-free safety net behind the automatic updates of 300-areas.
#
# The morning agent may append Timeline lines to an area note and replace a sentence of
# "Current truth" (skill step 3b). This check runs after the agent over every area note that
# differs from the copy taken before it (New-AreaSnapshot) and restores that copy for a note
# when anything is wrong:
#   - a Timeline line without a "([[100-daily/<date>]])" source, or whose source note does not
#     exist, or whose words (4 letters or more) are not all in the source note;
#   - a digit run of four or more outside the leading date (case numbers, ids, amounts);
#   - a change to the frontmatter, the title, or any section other than "Current truth" and
#     "Timeline"; a removed Timeline line; a new, removed or renamed section;
#   - a changed "Current truth" whose old words are not kept in a "Vorher:" Timeline line, or
#     whose new words are neither in the old sentence nor in a source note of the new lines.
# A new note in 300-areas is only named (new notes stay manual, nothing is deleted).
#
#   dot-source it for the functions, or run it:
#   powershell -File area-check.ps1 -AreaVault <vault> -AreaSnapshot <dir>
#   (the parameters are not called VaultPath/SnapshotDir on purpose: a dot-sourcing script such as
#   morning.ps1 would have its own $VaultPath overwritten by the empty default)
# ASCII only (Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page).

[CmdletBinding()]
param(
    [string]$AreaVault = '',
    [string]$AreaSnapshot = ''
)

. "$PSScriptRoot\life-os-common.ps1"

$script:EmDash = [string][char]0x2014

function ConvertTo-NoteParts([string]$text) {
    $t = $text -replace "`r`n", "`n"
    $fm = ''
    $body = $t
    $m = [regex]::Match($t, '(?s)^---\n(.*?)\n---\n?(.*)$')
    if ($m.Success) { $fm = $m.Groups[1].Value; $body = $m.Groups[2].Value }
    $names = New-Object System.Collections.ArrayList
    $texts = @{}
    $current = ''
    [void]$names.Add($current)
    $texts[$current] = New-Object System.Collections.ArrayList
    foreach ($line in ($body -split "`n")) {
        $h = [regex]::Match($line, '^## (.+?)\s*$')
        if ($h.Success) {
            $current = $h.Groups[1].Value
            [void]$names.Add($current)
            if (-not $texts.ContainsKey($current)) { $texts[$current] = New-Object System.Collections.ArrayList }
            continue
        }
        [void]$texts[$current].Add($line.TrimEnd())
    }
    $sections = @{}
    foreach ($k in $texts.Keys) { $sections[$k] = (($texts[$k] -join "`n")).Trim() }
    return [pscustomobject]@{ Frontmatter = $fm; Names = @($names); Sections = $sections }
}

function Get-NoteLines([string]$sectionText) {
    return @(($sectionText -split "`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim() })
}

function Get-LineDifference($oldLines, $newLines) {
    # multiset difference: lines only in new (added) and only in old (removed)
    $count = @{}
    foreach ($l in $oldLines) { if ($count.ContainsKey($l)) { $count[$l]++ } else { $count[$l] = 1 } }
    $added = @()
    foreach ($l in $newLines) {
        if ($count.ContainsKey($l) -and $count[$l] -gt 0) { $count[$l]-- } else { $added += $l }
    }
    $removed = @()
    foreach ($k in $count.Keys) { for ($i = 0; $i -lt $count[$k]; $i++) { $removed += $k } }
    return [pscustomobject]@{ Added = @($added); Removed = @($removed) }
}

function Get-Words([string]$text) {
    # lower-case words of four letters or more (digits and short words do not count)
    return @([regex]::Matches($text.ToLowerInvariant(), '\p{L}{4,}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
}

function Test-AreaNote {
    # Returns the list of reasons why a changed note must be restored; empty means ok.
    param([string]$OldText, [string]$NewText, [string]$VaultPath)
    $reasons = New-Object System.Collections.ArrayList
    $old = ConvertTo-NoteParts $OldText
    $new = ConvertTo-NoteParts $NewText

    if ($old.Frontmatter -ne $new.Frontmatter) { [void]$reasons.Add('frontmatter changed') }
    if (($old.Names -join '|') -ne ($new.Names -join '|')) { [void]$reasons.Add('sections added, removed or renamed') }
    foreach ($name in $old.Names) {
        if ($name -eq 'Current truth' -or $name -eq 'Timeline') { continue }
        if ($new.Sections.ContainsKey($name) -and $old.Sections[$name] -ne $new.Sections[$name]) {
            if ($name -eq '') { [void]$reasons.Add('title or text above the first section changed') }
            else { [void]$reasons.Add('section "' + $name + '" changed') }
        }
    }
    if ($reasons.Count -gt 0) { return @($reasons) }

    $tl = Get-LineDifference (Get-NoteLines $old.Sections['Timeline']) (Get-NoteLines $new.Sections['Timeline'])
    if ($tl.Removed.Count -gt 0) { [void]$reasons.Add('a Timeline line was removed') }
    $ct = Get-LineDifference (Get-NoteLines $old.Sections['Current truth']) (Get-NoteLines $new.Sections['Current truth'])

    $factRegex = '^- (\d{4}-\d{2}-\d{2}) ' + $script:EmDash + ' (.+) \(\[\[100-daily/(\d{4}-\d{2}-\d{2})\]\]\)\s*$'
    $sourceWords = @()
    $vorherWords = @()
    foreach ($line in $tl.Added) {
        $m = [regex]::Match($line, $factRegex)
        if (-not $m.Success) { [void]$reasons.Add('Timeline line without a "([[100-daily/<date>]])" source: ' + $line); continue }
        $fact = $m.Groups[2].Value
        if ($fact.StartsWith('Vorher: ')) {
            $vorherWords += Get-Words $fact.Substring(8)
            continue
        }
        if ([regex]::IsMatch($fact, '\d{4,}')) { [void]$reasons.Add('digit run of four or more in: ' + $line) }
        $src = Join-Path $VaultPath ('100-daily\' + $m.Groups[3].Value + '.md')
        if (-not (Test-Path -LiteralPath $src)) { [void]$reasons.Add('source note missing: 100-daily/' + $m.Groups[3].Value); continue }
        $srcWords = Get-Words ([IO.File]::ReadAllText($src))
        $sourceWords += $srcWords
        $missing = @(Get-Words $fact | Where-Object { $srcWords -notcontains $_ })
        if ($missing.Count -gt 0) { [void]$reasons.Add('words not in the source note (' + ($missing -join ', ') + ') in: ' + $line) }
    }

    $removedWords = @(Get-Words ($ct.Removed -join ' '))
    $addedWords = @(Get-Words ($ct.Added -join ' '))
    foreach ($line in $ct.Added) {
        if ([regex]::IsMatch($line, '\d{4,}')) { [void]$reasons.Add('digit run of four or more in Current truth: ' + $line) }
    }
    $foreign = @($addedWords | Where-Object { ($removedWords -notcontains $_) -and ($sourceWords -notcontains $_) })
    if ($foreign.Count -gt 0) { [void]$reasons.Add('Current truth words from neither the old sentence nor a source note (' + ($foreign -join ', ') + ')') }
    $newCtWords = Get-Words $new.Sections['Current truth']
    $lost = @($removedWords | Where-Object { ($newCtWords -notcontains $_) -and ($vorherWords -notcontains $_) })
    if ($lost.Count -gt 0) { [void]$reasons.Add('old Current truth words not kept in a Vorher line (' + ($lost -join ', ') + ')') }
    return @($reasons)
}

function Invoke-AreaCheck {
    param([string]$VaultPath, [string]$SnapshotDir)
    $dir = Join-Path $VaultPath '300-areas'
    $results = @()
    $seen = @{}
    if (Test-Path -LiteralPath $SnapshotDir) {
        foreach ($s in (Get-ChildItem -LiteralPath $SnapshotDir -Filter '*.md' -File -Recurse)) {
            $rel = $s.FullName.Substring($SnapshotDir.TrimEnd('\').Length + 1)
            $seen[$rel] = $true
            $live = Join-Path $dir $rel
            $name = [IO.Path]::GetFileNameWithoutExtension($s.Name)
            $oldText = [IO.File]::ReadAllText($s.FullName)
            if (-not (Test-Path -LiteralPath $live)) {
                Write-Utf8 $live $oldText
                $results += [pscustomobject]@{ file = $name; status = 'reverted'; reasons = @('note was removed') }
                continue
            }
            $newText = [IO.File]::ReadAllText($live)
            if ($newText -ceq $oldText) { $results += [pscustomobject]@{ file = $name; status = 'unchanged'; reasons = @() }; continue }
            $reasons = @(Test-AreaNote -OldText $oldText -NewText $newText -VaultPath $VaultPath)
            if ($reasons.Count -gt 0) {
                Write-Utf8 $live $oldText
                $results += [pscustomobject]@{ file = $name; status = 'reverted'; reasons = $reasons }
            } else {
                $results += [pscustomobject]@{ file = $name; status = 'ok'; reasons = @() }
            }
        }
    }
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse)) {
            $rel = $f.FullName.Substring($dir.TrimEnd('\').Length + 1)
            if (-not $seen.ContainsKey($rel)) {
                $results += [pscustomobject]@{ file = [IO.Path]::GetFileNameWithoutExtension($f.Name); status = 'new'; reasons = @() }
            }
        }
    }
    return $results
}

function Format-AreaResultLines($results) {
    $lines = @()
    foreach ($r in @($results)) {
        if ($r.status -eq 'reverted') { $lines += ('Bereich zur' + [char]0x00FC + 'ckgesetzt: ' + $r.file + ' (' + (@($r.reasons) -join '; ') + ')') }
        elseif ($r.status -eq 'new') { $lines += ('Neue Bereichsnotiz ohne Auftrag: ' + $r.file) }
    }
    return $lines
}

if ($MyInvocation.InvocationName -ne '.' -and $AreaVault -and $AreaSnapshot) {
    $res = Invoke-AreaCheck -VaultPath $AreaVault -SnapshotDir $AreaSnapshot
    foreach ($r in $res) { Write-Host ($r.status + ' ' + $r.file + ' ' + (@($r.reasons) -join '; ')) }
    $bad = @($res | Where-Object { $_.status -eq 'reverted' }).Count
    Write-Host ('area-check: ' + @($res | Where-Object { $_.status -ne 'unchanged' }).Count + ' changed, ' + $bad + ' restored')
    exit ([int]($bad -gt 0))
}
