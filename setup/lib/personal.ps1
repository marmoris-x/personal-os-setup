<#
setup/lib/personal.ps1 - read a list out of the personal layer, and turn one of its terms
into a search rule.

The archive category list lives in the personal values file
(<home>/.personal-os/personal.yaml, see docs/decisions/0004-personal-layer.md): the folder
names the owner keeps his documents in. They are personal, so they stand in no repository,
and the tools that must know them read them here. ConvertTo-TermRule is the second half:
both scans that look for such a term build their pattern with it, so "a hit" means the same
thing in privacy-scan.ps1 and in archive-name-scan.ps1.

TWO READERS, ONE SHAPE. The second reader is built into
home/.claude/setup/powershell/add-to-archive.ps1, which has to run in Windows PowerShell 5.1,
where powershell-yaml is not installed (measured 2026-10-15) - so it cannot use a YAML module
either. Both read the same block by hand, and tests/PersonalLayer.Tests.ps1 feeds both the
same files and requires the same answer, so they cannot drift apart.

The shape both accept is the one setup/config/personal.example.yaml shows:

    archive_categories:
      - "01_Example"
      - "02_Example"

A line inside the block that is neither a comment nor a "- value" entry is an error, and so
is a missing block or an empty list - never a guess.

ASCII-only: Windows PowerShell 5.1 reads BOM-less files in the ANSI code page.
#>

function ConvertTo-TermRule {
    <#
    One personal term -> one regex that matches that term and nothing longer.

    The boundary markers are the point: without them a three-letter folder name matches the
    same three letters inside an ordinary word and the scan reports hits in eighty files that
    have nothing to do with the personal material. privacy-scan.ps1 and archive-name-scan.ps1
    both build their rules here, so the two scans cannot disagree about what a hit is.
    A '*' inside the term stays a wildcard; every other character is literal text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Term)
    $esc = [regex]::Escape($Term)
    $esc = $esc -replace '\\\*', '[A-Za-z0-9_-]*'          # wildcard support
    $rx = $esc
    if ($rx.StartsWith('*')) { $rx = $rx.Substring(1) }     # leading wildcard: no left boundary
    else { $rx = '(?<![A-Za-z0-9])' + $rx }
    if ($rx.EndsWith('*')) { $rx = $rx.Substring(0, $rx.Length - 1) }
    else { $rx = $rx + '(?![A-Za-z0-9])' }
    return $rx
}

function Get-ConfigScalar {
    <#
    One scalar value of a `key: value` file, without a YAML module. Used for the personal
    values file and for setup/config/repo.yaml, which have this shape in common. Handles the
    three spellings both use: bare, single-quoted and double-quoted. A double-quoted scalar is
    unescaped (\\ and \"), because that is what YAML means by it and what the paths in
    personal.yaml are written as. Returns $null when the key is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Key
    )
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -notmatch ('^' + [regex]::Escape($Key) + '\s*:\s*(?<v>.*)$')) { continue }
        $v = $Matches['v'].Trim()
        if ($v.Length -ge 2) {
            $q = $v.Substring(0, 1)
            if ($q -eq '"' -and $v.EndsWith('"')) {
                $v = $v.Substring(1, $v.Length - 2)
                $v = $v.Replace('\\', '\').Replace('\"', '"')
            }
            elseif ($q -eq "'" -and $v.EndsWith("'")) { $v = $v.Substring(1, $v.Length - 2).Replace("''", "'") }
        }
        return $v
    }
    return $null
}

function Get-PersonalCategoryList {
    <#
    The archive_categories block of a personal values file, as a string array.
    Throws when the file has no such block or when the block cannot be read as a list.

    The three spellings of the example file are read - bare, single-quoted and double-quoted -
    and an inline comment after a value is stripped, because that is what YAML means by it and
    what a person writing the file expects. Review 22 (F4) measured what the earlier reader did
    with `- "01_Example" # note`: it handed back the quotes AND the comment as part of the name.
    That name matches nothing, so both scans would have looked for a term that does not exist
    and the archive script would have refused the real category - a silent hole in the guard
    this reader feeds. A comment on the key line is accepted the same way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $cats = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $seen = $false
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if (-not $inBlock) {
            if ($line -match '^archive_categories\s*:(?:\s*#.*)?$') { $inBlock = $true; $seen = $true }
            continue
        }
        if ($line.Trim() -eq '' -or $line -match '^\s*#') { continue }
        if ($line -match '^\s*-\s*(?<v>.+?)\s*$') {
            $v = $Matches['v']
            $q = if ($v.Length -ge 1) { $v.Substring(0, 1) } else { '' }
            if ($q -eq '"' -or $q -eq "'") {
                $close = $v.IndexOf($q, 1)
                if ($close -lt 1) { throw ('the archive_categories block of ' + $ConfigPath + ' holds a quoted value that never closes') }
                $rest = $v.Substring($close + 1).Trim()
                if ($rest -ne '' -and -not $rest.StartsWith('#')) { throw ('the archive_categories block of ' + $ConfigPath + ' holds text after a quoted value that is not a comment') }
                $v = $v.Substring(1, $close - 1)
            }
            else {
                # A bare value ends where a comment starts: YAML begins one at ' #'.
                $h = $v.IndexOf(' #')
                if ($h -ge 0) { $v = $v.Substring(0, $h).Trim() }
            }
            if ($v.Trim() -eq '') { throw ('the archive_categories block of ' + $ConfigPath + ' holds an entry without a value') }
            $cats.Add($v)
            continue
        }
        if ($line -match '^\S') { break }        # the next key at column 0 ends the block
        throw ('the archive_categories block of ' + $ConfigPath + ' holds a line that is neither a comment nor a "- value" entry')
    }
    if (-not $seen) { throw ('no archive_categories block in ' + $ConfigPath) }
    # No unary comma: the caller wraps the call in @(...), and `return , $x` would hand that
    # one element - the array - instead of its values (measured 2026-10-15 in the live script).
    return $cats.ToArray()
}
