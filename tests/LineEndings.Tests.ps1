# Pester 5.9.1 (pinned). Line endings: a checkout must be the working tree, byte for byte.
#
# Why this file exists. Acceptance check J installs from the repository and compares sha256 with
# the recorded v2.1.2 baseline (tests/fixtures/install-baseline-v2.1.2.json). As long as
# .gitattributes asked git to convert line endings (`* text=auto`, `*.ps1 text eol=crlf` while the
# working tree carries LF for 113 of the 132 mirrored files), a `git clone` or `git archive`
# produced other bytes than this tree and check J called 113 files changed that differed in line
# endings alone - measured 2026-10-14 on a clone (review 17, finding F5). The fix is one line,
# `* -text`; this test is its witness, because a `text=auto` added back would only show up in a
# clone - and no check looks at what a clone looks like.
#
# The test asks git itself which attributes it would apply, so it measures the rule and not a copy
# of it. Setup goes in BeforeAll: top-level code here would only run during discovery (Pester 5).
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    # Every tracked file, as git sees them (this is also what a clone would check out).
    $script:tracked = @(& git -C $repoRoot ls-files)

    # One line per file and attribute: "<path>: text: <value>", "<path>: eol: <value>".
    $script:attrs = @()
    if ($script:tracked.Count -gt 0) {
        $script:attrs = @(& git -C $repoRoot check-attr text eol -- $script:tracked)
    }
}

Describe 'line endings' {
    It 'has a file list from git to judge' {
        $script:tracked.Count | Should -BeGreaterThan 100 -Because 'git must answer for the tracked files; an empty list would make every rule below pass by saying nothing'
    }

    It 'asks git to convert nothing: no text and no eol attribute anywhere' {
        # `unset` (from `* -text`) and `unspecified` are the wanted answers. `auto`, `set`, `crlf`
        # and `lf` all mean git rewrites the bytes, and then a checkout is not this tree.
        $converting = @($script:attrs | Where-Object { $_ -match ': (text|eol):\s*(auto|set|crlf|lf)\s*$' })
        ($converting -join '; ') | Should -Be '' -Because 'git must store and check out the bytes unchanged; a converting attribute makes every clone differ from this tree in line endings, which check J then reports as 113 changed files'
    }

    It 'lets the whole file list be judged (git answered for every tracked file)' {
        $script:attrs.Count | Should -Be ($script:tracked.Count * 2) -Because 'git answers once per file and attribute; a shorter answer would hide files from the rule above'
    }

    It 'keeps every shell script free of CRLF' {
        # `* -text` dropped the old `*.sh text eol=lf` rule, and nothing else misses it: the
        # independent review measured that `bash -n` exits 0 on a CRLF copy of bootstrap.sh. On
        # macOS and Linux the shebang line would carry a carriage return and the script would not
        # start. The stored form equals the working tree now, so judging the working tree is
        # judging what a clone gets.
        $repo = Split-Path -Parent $PSScriptRoot
        $shellScripts = @($script:tracked | Where-Object { $_ -like '*.sh' })
        $shellScripts.Count | Should -BeGreaterThan 0 -Because 'bootstrap.sh is the file a Unix machine starts with, so an empty list would make this rule pass by saying nothing'
        $withCrLf = @()
        foreach ($rel in $shellScripts) {
            $text = [IO.File]::ReadAllText((Join-Path $repo $rel))
            if ($text.Contains("`r`n")) { $withCrLf += $rel }
        }
        ($withCrLf -join ', ') | Should -Be '' -Because 'a shell script with CRLF line endings fails at its shebang on macOS and Linux'
    }
}
