# Pester 5.9.1 (pinned). The /distill skill: home/.claude/skills/distill/SKILL.md, its portable twin
# home/.agents/skills/distill-portable/ and the one CLAUDE.md line that lets it write into the vault.
#
# What is measured here: the Claude Code skill is manual only (zero tokens until the owner types it),
# takes a topic, reads the vault AGENTS.md before it searches or writes, and prescribes the seven
# page parts in the agreed order plus the vault rules (page length, link, log line, push proof,
# no images, no star counts, no emojis); the portable twin is manual only for OpenCode and Codex and
# carries the same body; CLAUDE.md names /distill as the single exception to "a project session never
# writes in the vault". DISTILL_TEST_ROOT points the tests at a broken copy for the red proof.
BeforeAll {
    $script:root = if ($env:DISTILL_TEST_ROOT) { $env:DISTILL_TEST_ROOT } else { Split-Path -Parent $PSScriptRoot }
    $script:skill = Join-Path $script:root 'home/.claude/skills/distill/SKILL.md'
    $script:portable = Join-Path $script:root 'home/.agents/skills/distill-portable/SKILL.md'
    $script:policy = Join-Path $script:root 'home/.agents/skills/distill-portable/agents/openai.yaml'
    $script:claudeMd = Join-Path $script:root 'home/.claude/CLAUDE.md'

    function Read-Text([string]$Path) { return [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false))) -replace "`r`n", "`n" }
    # The frontmatter block between the first two --- lines, as a list of lines.
    function Get-Front([string]$Text) {
        $lines = $Text -split "`n"
        $lines[0] | Should -BeExactly '---'
        $end = [array]::IndexOf($lines, '---', 1)
        $end | Should -BeGreaterThan 0
        return , @($lines[1..($end - 1)])
    }
    # The body from the line that starts "Idea (Karpathy" on; both skills share it.
    function Get-Shared([string]$Text) { return $Text.Substring($Text.IndexOf('Idea (Karpathy')) }
}

Describe 'the distill skill for Claude Code' {
    It 'is manual only and takes a topic' {
        $front = Get-Front (Read-Text $script:skill)
        $front | Should -Contain 'name: distill'
        $front | Should -Contain 'disable-model-invocation: true'
        $front | Should -Contain 'argument-hint: [topic]'
        ($front | Where-Object { $_ -like 'description:*' }) | Should -Match 'Manual only'
    }

    It 'passes the topic on with $ARGUMENTS' {
        (Read-Text $script:skill) | Should -Match 'filed as a knowledge page: \$ARGUMENTS'
    }

    It 'reads the vault AGENTS.md first, then looks for an existing page, then writes' {
        $t = Read-Text $script:skill
        $read = $t.IndexOf('AGENTS.md')
        $search = $t.IndexOf('Look for an existing page')
        $write = $t.IndexOf('Write the page from this session only')
        $read | Should -BeGreaterThan 0
        $read | Should -BeLessThan $search
        $search | Should -BeLessThan $write
        $t | Should -Match 'rule 6'
        $t | Should -Match '## Timeline'
    }

    It 'prescribes the seven page parts in the agreed order' {
        $t = Read-Text $script:skill
        $at = -1
        foreach ($part in '**Question**', '**Answer**', '**Decisions**', '**Rejected**', '**Measured facts**', '**How to check it again**', '**Open points**') {
            $i = $t.IndexOf($part)
            $i | Should -BeGreaterThan $at -Because "$part must come after the previous part"
            $at = $i
        }
        $t | Should -Match 'five lines at most'
    }

    It 'carries the vault rules for the page and the closing steps' {
        $t = Read-Text $script:skill
        foreach ($needle in 'about 200 lines', 'review_by', 'rule 13', '000-meta/log.md', 'status -sb', 'no `ahead`', 'Strip Markdown images', 'no star counts', 'no emojis', 'never invented', 'path and its line count') {
            $t.Contains($needle) | Should -BeTrue -Because "the skill must say: $needle"
        }
        $t.Contains('never `-A`') | Should -BeTrue
    }

    It 'never lets the session choose a storage location on its own' {
        (Read-Text $script:skill) | Should -Match 'Never choose a storage location on your own'
    }
}

Describe 'the portable twin' {
    It 'is manual only for OpenCode and Codex and its folder matches its name' {
        $front = Get-Front (Read-Text $script:portable)
        $front | Should -Contain 'name: distill-portable'
        (Split-Path -Leaf (Split-Path -Parent $script:portable)) | Should -BeExactly 'distill-portable'
        $front | Should -Contain '  opencode/autoinvoke: "false"'
        $front | Should -Contain '  opencode/slash: "true"'
        ($front | Where-Object { $_ -like 'description:*' }) | Should -Match 'Manual only'
        $front | Should -Not -Contain 'disable-model-invocation: true' -Because 'that field belongs to Claude Code'
    }

    It 'forbids implicit invocation for Codex' {
        (Read-Text $script:policy) | Should -Match '(?m)^policy:\n  allow_implicit_invocation: false\n?$'
    }

    It 'has the same body as the Claude Code skill' {
        (Get-Shared (Read-Text $script:portable)) | Should -BeExactly (Get-Shared (Read-Text $script:skill))
    }
}

Describe 'CLAUDE.md' {
    It 'names /distill as the one exception to "a project session never writes in the vault"' {
        $line = (Read-Text $script:claudeMd) -split "`n" | Where-Object { $_ -like '*never writes in the vault*' }
        @($line).Count | Should -Be 1
        $line | Should -BeLike '* Exception: when I run /distill, it writes its one page and the log line, nothing else.'
    }
}
