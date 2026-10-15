# Pester 5.9.1 (pinned). The agent rule files carry a token budget, not a line count.
#
# Why this file exists. The owner's rule files - this repository's AGENTS.md, the global
# CLAUDE.md and the vault's agent constitution - used to carry a line count ("keep this file
# under 200/300 lines"). A line count is the wrong measure twice over. It does not describe what
# the file costs, because a line of prose and a line of a table differ by an order of magnitude;
# and it pushes an agent to delete rules to reach a number, which is how a rule file loses the
# very rule its reader needed. Measured 2026-10-15: the global CLAUDE.md stood at 307 lines
# against its own 300-line rule, and nothing was wrong with it.
#
# The owner replaced the line count with a size budget on 2026-10-15. The budget is generous on
# purpose: it is a ceiling that says "this file has grown into something nobody follows", not a
# target. The number is an approximation - characters / 4, the usual rule of thumb for prose, and
# deliberately simple so a reader can check it in one line without a tokenizer.
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    # Up to about 10,000 tokens. The three files a session loads before it does any work.
    $script:budgetTokens = 10000
    $script:ruleFiles = @(
        'AGENTS.md'
        'home/.claude/CLAUDE.md'
        'vault/AGENTS.md'
    )
}

Describe 'agent rule file size budget' {
    It 'has every rule file to measure' {
        $script:ruleFiles.Count | Should -Be 3 -Because 'the list is the thing being measured; an empty list would make the budget below pass by saying nothing'
        foreach ($rel in $script:ruleFiles) {
            (Join-Path $repoRoot $rel) | Should -Exist -Because "$rel loads into a session, so a missing file would quietly remove rules instead of reporting it"
        }
    }

    It 'keeps every rule file inside the token budget' {
        foreach ($rel in $script:ruleFiles) {
            $text = [IO.File]::ReadAllText((Join-Path $repoRoot $rel))
            $tokens = [int][math]::Floor($text.Length / 4)
            $tokens | Should -BeLessOrEqual $script:budgetTokens -Because "$rel is about $tokens tokens against a budget of $($script:budgetTokens). Move a rule to a file that is loaded only when it is needed, or shorten it - but never delete a rule to reach a number"
        }
    }
}
