# ---- PowerShell profile for macOS and Linux (pwsh 7) ----
# pwsh reads its all-hosts profile from ~/.config/powershell/profile.ps1 on macOS and Linux
# ($PROFILE.CurrentUserAllHosts). Windows keeps two profiles in the Documents folder instead
# (Microsoft.PowerShell_profile.ps1 for PowerShell 7 and for Windows PowerShell 5.1); this file
# is their counterpart and carries the same two blocks in POSIX spelling.
#
# Written in the repository: the machine this kit grew on runs Windows, where this component is
# `unsupported` (setup/platforms.yaml). On a macOS or Linux machine setup/export.ps1 takes the
# live file, exactly as it does for every other mirror file.

# ---- Claude Code: provider profiles (version 12, 2026-10-18) ----
#   claude      = Pro plan (Anthropic), uses only ~/.claude/settings.json
#   claude-ds   = DeepSeek
#   claude-or   = OpenRouter
# All three start the same everywhere, also in {{VAULT}}.

# Git read commands (status, branch, diff) take no optional index lock then, so they cannot
# collide with Obsidian Git's auto-commit in the vault. Commits and writes still lock normally
# (git docs, GIT_OPTIONAL_LOCKS).
$env:GIT_OPTIONAL_LOCKS = '0'

function claude-ds { claude --settings "{{HOME_ENV}}/.claude/profiles/deepseek.json" @args }
function claude-or { claude --settings "{{HOME_ENV}}/.claude/profiles/openrouter.json" @args }
# ---- End Claude Code ----

# ---- The same global instructions for all agent harnesses (version 11, 2026-09-28) ----
# Source: ~/.claude/CLAUDE.md plus every rule in ~/.claude/rules/. OpenCode reads
# CLAUDE.md directly; Codex (~/.codex/AGENTS.md), Gemini CLI (~/.gemini/GEMINI.md)
# and DeepSeek Harness (~/.dsh/AGENTS.md, DSH_HOME = ~/.dsh) get one assembled copy,
# but only if the program in question is installed (its folder exists).
#
# Why the rules are appended here: Claude Code only loads a rule file when Claude
# reads a file matching its "paths" frontmatter. No other harness understands that
# field, so for them the patterns have to be written out as text - "Applies to: ..."
# above each rule - and every rule is always present.
#
# Runs every time PowerShell starts and only writes when the source is newer.
# Same function as in the Windows profiles, with "/" instead of "\": on macOS and Linux a
# backslash is an ordinary character in a file name, not a separator.

function Get-RuleAppliesTo {
    # Reads the "paths:" value from a rule's YAML frontmatter. Accepts both a
    # comma-separated string and a YAML list, and returns one readable line.
    param([string]$Text)
    $m = [regex]::Match($Text, '(?s)^\s*---\s*\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return '' }
    $out = @()
    $inPaths = $false
    foreach ($line in ($m.Groups[1].Value -split '\r?\n')) {
        if ($line -match '^\s*paths\s*:\s*(.*)$') {
            $inPaths = $true
            $v = $Matches[1].Trim().Trim('[', ']')
            if ($v) { $out += $v }
            continue
        }
        if ($inPaths) {
            if ($line -match '^\s*-\s*(.+)$') { $out += $Matches[1].Trim() }
            elseif ($line -match '^\S') { $inPaths = $false }   # next top-level key
        }
    }
    if ($out.Count -eq 0) { return '' }
    $joined = ($out -join ', ') -replace '["'']', ''
    return ($joined -replace '\s{2,}', ' ').Trim()
}

function Sync-AgentInstructions {
    $src = Join-Path {{HOME_ENV}} '.claude/CLAUDE.md'
    if (-not (Test-Path $src)) { return }
    $rulesDir = Join-Path {{HOME_ENV}} '.claude/rules'

    $ruleFiles = @()
    if (Test-Path $rulesDir) {
        $ruleFiles = @(Get-ChildItem $rulesDir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name)
    }

    $newest = (Get-Item $src).LastWriteTime
    foreach ($r in $ruleFiles) { if ($r.LastWriteTime -gt $newest) { $newest = $r.LastWriteTime } }

    $targets = @(
        (Join-Path {{HOME_ENV}} '.codex/AGENTS.md'),
        (Join-Path {{HOME_ENV}} '.gemini/GEMINI.md'),
        (Join-Path {{HOME_ENV}} '.dsh/AGENTS.md')
    )
    $oc = Join-Path {{HOME_ENV}} '.config/opencode/AGENTS.md'
    if (Test-Path $oc) { $targets += $oc }   # only if OpenCode has a file of its own

    $needsWrite = $false
    foreach ($dst in $targets) {
        if (-not (Test-Path (Split-Path $dst))) { continue }    # program not installed
        if ((-not (Test-Path $dst)) -or ((Get-Item $dst).LastWriteTime -lt $newest)) { $needsWrite = $true }
    }
    if (-not $needsWrite) { return }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Get-Content $src -Raw).TrimEnd())
    foreach ($r in $ruleFiles) {
        $body = Get-Content $r.FullName -Raw
        $applies = Get-RuleAppliesTo $body
        $body = ($body -replace '(?s)^\s*---\s*\r?\n.*?\r?\n---\s*\r?\n', '').Trim()
        [void]$sb.Append("`r`n`r`n---`r`n`r`n## Rule: $($r.BaseName)`r`n`r`n")
        if ($applies) { [void]$sb.Append("Applies to: $applies`r`n`r`n") }
        [void]$sb.Append($body + "`r`n")
    }
    $content = $sb.ToString()

    foreach ($dst in $targets) {
        if (-not (Test-Path (Split-Path $dst))) { continue }
        [IO.File]::WriteAllText($dst, $content, (New-Object Text.UTF8Encoding($false)))
    }
}
Sync-AgentInstructions
# ---- End ----
