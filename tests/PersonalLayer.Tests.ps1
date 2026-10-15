<#
tests/PersonalLayer.Tests.ps1 - the personal layer and the two readers of its category list.

Why this file exists (release task, 2026-10-15): the archive category list left the repository.
It lives in the personal values file now, and TWO things read it there -
setup/lib/personal.ps1 for the repository tools, and the reader built into
home/.claude/setup/powershell/add-to-archive.ps1, which must run in Windows PowerShell 5.1
where powershell-yaml is not installed. Two readers that must agree are one reader too many
unless something measures it: the cases below feed both the same files and require the same
answer, so they cannot drift apart.

The second half pins setup/tools/archive-name-scan.ps1: a seeded hit must be found (the red
half) and a clean tree must report hits: 0 (the green half). Every fixture is invented and
lives in the check work folder - the real vault is never touched, and the stand-in vault uses
an invented archive folder name so this file names no folder of this machine.
#>
BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $script:work = Join-Path $script:scratchRoot 'personal-layer'
    if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $script:work | Out-Null
    $script:utf8 = New-Object Text.UTF8Encoding($false)
    # the stand-in archive folder of this suite, assembled from two halves: the real one is a
    # personal value and a hook refuses to write it into a file
    $script:standInArchive = 'Example' + 'Archiv'

    # forward slashes: this suite runs on all three systems in CI
    . (Join-Path $script:repoRoot 'setup/lib/personal.ps1')

    # --- the reader built into the live script, taken from its source ---------
    # Not dot-sourced: that file runs on load and would try to archive a file. The function is
    # lifted out of the syntax tree and given a name of its own.
    $script:liveScript = Join-Path $script:repoRoot 'home/.claude/setup/powershell/add-to-archive.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:liveScript, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ArchiveCategories' }, $true))
    if ($fn.Count -ne 1) { throw ('expected exactly one Get-ArchiveCategories in ' + $script:liveScript + ', found ' + $fn.Count) }
    $script:liveReaderPath = Join-Path $script:work 'live-reader.ps1'
    [IO.File]::WriteAllText($script:liveReaderPath, $fn[0].Extent.Text + "`r`n", $script:utf8)
    . $script:liveReaderPath

    function Write-Fixture([string]$name, [string]$text) {
        $p = Join-Path $script:work $name
        [IO.File]::WriteAllText($p, $text, $script:utf8)
        return $p
    }

    # Every fixture in one table: the repo reader and the live reader must answer each of them
    # the same way - the same values, or both an error.
    $script:minimal = Write-Fixture 'minimal.yaml' "archive_categories:`n  - `"01_Example`"`n  - `"02_Example`"`n"
    $script:withComments = Write-Fixture 'comments.yaml' "# a comment`narchive_categories:`n  # another`n  - `"01_Example`"`n`n  - '02_Example'`n  - 03_Example`n"
    $script:badLine = Write-Fixture 'bad-line.yaml' "archive_categories:`n  - `"01_Example`"`n  oops: not a list item`n"
    $script:noBlock = Write-Fixture 'no-block.yaml' "user_name: `"Vera Beispiel`"`narchive_dir_name: `"$($script:standInArchive)`"`n"
    $script:emptyBlock = Write-Fixture 'empty-block.yaml' "archive_categories:`nuser_name: `"Vera Beispiel`"`n"
    $script:afterBlock = Write-Fixture 'after-block.yaml' "archive_categories:`n  - `"01_Example`"`nuser_name: `"Vera Beispiel`"`n"
    # Review 22 (F4): the earlier reader handed back the quotes AND the comment as part of the
    # name, so both scans looked for a term that does not exist and the archive script refused
    # the real category. These three shapes are what a person writing the file produces.
    $script:inlineComment = Write-Fixture 'inline-comment.yaml' "archive_categories: # the list`n  - `"01_Example`"  # invoices`n  - 02_Example # letters`n"
    $script:noValue = Write-Fixture 'no-value.yaml' "archive_categories:`n  - `"`"`n  - `"01_Example`"`n"
    $script:afterQuote = Write-Fixture 'after-quote.yaml' "archive_categories:`n  - `"01_Example`" oops`n"

    $script:result = @{}
    foreach ($case in @('minimal', 'withComments', 'badLine', 'noBlock', 'emptyBlock', 'afterBlock', 'inlineComment', 'noValue', 'afterQuote')) {
        foreach ($reader in @('repo', 'live')) {
            $path = (Get-Variable -Name $case -ValueOnly)
            try {
                $v = if ($reader -eq 'repo') { @(Get-PersonalCategoryList -ConfigPath $path) } else { @(Get-ArchiveCategories $path) }
                $script:result[$case + '/' + $reader] = @{ Values = $v; Error = $null }
            }
            catch { $script:result[$case + '/' + $reader] = @{ Values = @(); Error = $_.Exception.Message } }
        }
    }
}

Describe 'the personal layer reader' {
    It 'reads the documented block' {
        $script:result['minimal/repo'].Error | Should -BeNullOrEmpty
        $script:result['minimal/repo'].Values.Count | Should -Be 2
        $script:result['minimal/repo'].Values[0] | Should -Be '01_Example'
    }
    It 'skips comments and blank lines and accepts bare, single- and double-quoted values' {
        $script:result['withComments/repo'].Error | Should -BeNullOrEmpty
        ($script:result['withComments/repo'].Values -join '|') | Should -Be '01_Example|02_Example|03_Example'
    }
    It 'refuses a line inside the block that is not a list item instead of guessing' {
        $script:result['badLine/repo'].Error | Should -Match 'neither a comment nor'
    }
    It 'refuses a file without the block' {
        $script:result['noBlock/repo'].Error | Should -Match 'no archive_categories block'
    }
    It 'reads an empty block as an empty list, not as an error' {
        $script:result['emptyBlock/repo'].Error | Should -BeNullOrEmpty
        $script:result['emptyBlock/repo'].Values.Count | Should -Be 0
    }
    It 'ends the block at the next key and keeps what it read' {
        $script:result['afterBlock/repo'].Error | Should -BeNullOrEmpty
        ($script:result['afterBlock/repo'].Values -join '|') | Should -Be '01_Example'
    }
    It 'strips an inline comment after a value, and a comment on the key line, the way YAML means it' {
        $script:result['inlineComment/repo'].Error | Should -BeNullOrEmpty
        ($script:result['inlineComment/repo'].Values -join '|') | Should -Be '01_Example|02_Example'
    }
    It 'refuses an entry without a value instead of reading a space as a name' {
        $script:result['noValue/repo'].Error | Should -Match 'entry without a value'
    }
    It 'refuses text after a quoted value that is not a comment' {
        $script:result['afterQuote/repo'].Error | Should -Match 'after a quoted value'
    }
}

Describe 'the two readers agree' {
    # The one measurement that keeps the copy in the live script honest: same file in, same
    # answer out - the same values, or both of them an error.
    It 'answers every fixture the same way as the reader in add-to-archive.ps1' -ForEach @('minimal', 'withComments', 'badLine', 'noBlock', 'emptyBlock', 'afterBlock', 'inlineComment', 'noValue', 'afterQuote') {
        $repo = $script:result[$_ + '/repo']
        $live = $script:result[$_ + '/live']
        ($null -ne $repo.Error) | Should -Be ($null -ne $live.Error)
        ($repo.Values -join '|') | Should -Be ($live.Values -join '|')
    }
}

Describe 'the scalar reader' {
    BeforeAll {
        # Two backslashes in the file, which is what YAML means by an escaped one: the reader
        # must hand back `C:\Vault`. Four of them would ask for `C:\\Vault` and measure nothing.
        $script:scalars = Write-Fixture 'scalars.yaml' "vault_path: `"C:\\Vault`"`nquoted: 'a b'`nbare: plain`n"
    }
    It 'unquotes a double-quoted path the way YAML means it' {
        Get-ConfigScalar -ConfigPath $script:scalars -Key 'vault_path' | Should -Be 'C:\Vault'
    }
    It 'reads a single-quoted and a bare value' {
        Get-ConfigScalar -ConfigPath $script:scalars -Key 'quoted' | Should -Be 'a b'
        Get-ConfigScalar -ConfigPath $script:scalars -Key 'bare' | Should -Be 'plain'
    }
    It 'returns nothing for a key that is absent' {
        Get-ConfigScalar -ConfigPath $script:scalars -Key 'nope' | Should -BeNullOrEmpty
    }
    It 'reads the key of repo.yaml that decides which state is demanded' {
        # The value belongs to repo.yaml and flips when a release happens. Pinning the literal
        # 'false' here made this test red the moment the release was recorded - on ubuntu and on
        # macOS in CI run 38710712333, while it had been green a minute earlier. What the test is
        # about is the READER, so it takes the value from the file and demands two things: that
        # the file carries the key at all, and that the reader hands back exactly that value.
        $yaml = [IO.File]::ReadAllText((Join-Path $script:repoRoot 'setup/config/repo.yaml'))
        $inFile = [regex]::Match($yaml, '(?m)^\s*published:\s*(\S+)\s*$').Groups[1].Value
        $inFile | Should -BeIn @('true', 'false') -Because 'repo.yaml carries the key this test is about, and check S accepts only these two states'
        Get-ConfigScalar -ConfigPath (Join-Path $script:repoRoot 'setup/config/repo.yaml') -Key 'published' | Should -Be $inFile
    }
}

Describe 'archive-name-scan' {
    BeforeAll {
        $script:scan = Join-Path $script:repoRoot 'setup/tools/archive-name-scan.ps1'
        # a stand-in vault: two invented folder names, one of them in a sub-folder
        $script:vault = Join-Path $script:work 'vault'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:vault "$($script:standInArchive)\01_Example\Unterordner") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:vault '300-areas\Lebensbereich') | Out-Null
        $script:scanConfig = Write-Fixture 'scan-personal.yaml' ("vault_path: `"" + ($script:vault.Replace('\', '\\')) + "`"`narchive_dir_name: `"$($script:standInArchive)`"`n")
        $script:candidate = Join-Path $script:work 'candidate'
        New-Item -ItemType Directory -Force -Path $script:candidate | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:candidate 'clean.txt'), "nothing personal in here`n", $script:utf8)

        function Invoke-NameScan([string]$Tree) {
            $out = & pwsh -NoProfile -File $script:scan -Path $Tree -ConfigPath $script:scanConfig 2>&1 | Out-String
            return @{ Output = $out; Exit = $LASTEXITCODE }
        }
    }
    It 'reports hits: 0 on a clean tree' {
        $r = Invoke-NameScan $script:candidate
        $r.Exit | Should -Be 0
        $r.Output | Should -Match 'hits: 0'
    }
    It 'finds a seeded name in a file without printing the name' {
        $seeded = Join-Path $script:candidate 'seeded.txt'
        [IO.File]::WriteAllText($seeded, "a line mentioning Lebensbereich and nothing else`n", $script:utf8)
        $r = Invoke-NameScan $script:candidate
        Remove-Item -LiteralPath $seeded -Force
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'hits: [1-9]'
        $r.Output | Should -Not -Match 'Lebensbereich'
        $r.Output | Should -Match 'seeded\.txt:1'
    }
    It 'finds a seeded name in a directory name without printing it' {
        $dir = Join-Path $script:candidate 'Unterordner'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $r = Invoke-NameScan $script:candidate
        Remove-Item -LiteralPath $dir -Recurse -Force
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'directory name matches'
    }
    It 'finds a seeded name in a commit message without printing it' {
        $repo = Join-Path $script:work 'candidate-repo'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'file.txt'), "clean`n", $script:utf8)
        & git -C $repo init --quiet 2>$null | Out-Null
        & git -C $repo -c user.email=t@example.com -c user.name=t add -A 2>$null | Out-Null
        & git -C $repo -c user.email=t@example.com -c user.name=t commit -q -m "mentions Lebensbereich" 2>$null | Out-Null
        $out = & pwsh -NoProfile -File $script:scan -Path $repo -Repo $repo -ConfigPath $script:scanConfig 2>&1 | Out-String
        $code = $LASTEXITCODE
        $code | Should -Be 1
        $out | Should -Match 'commit [0-9a-f]+: message'
    }
    It 'counts one commit message, not one line of it' {
        $repo = Join-Path $script:work 'candidate-repo-multiline'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'file.txt'), "clean`n", $script:utf8)
        & git -C $repo init --quiet 2>$null | Out-Null
        & git -C $repo -c user.email=t@example.com -c user.name=t add -A 2>$null | Out-Null
        $msg = Join-Path $script:work 'multiline-msg.txt'
        [IO.File]::WriteAllText($msg, "a subject line`n`nfirst paragraph`nsecond paragraph`n", $script:utf8)
        & git -C $repo -c user.email=t@example.com -c user.name=t commit -q -F $msg 2>$null | Out-Null
        $out = & pwsh -NoProfile -File $script:scan -Path $repo -Repo $repo -ConfigPath $script:scanConfig 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match '1 commit message\(s\) scanned'
    }
}
