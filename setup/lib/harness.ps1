<#
setup/lib/harness.ps1 - the OpenCode and Codex configuration merge.

The templates under home/.claude/setup/other-harnesses/ carry the MCP servers and their key
headers as ${VAR}/{env:VAR} templates, never a key value. install.ps1 merges them into an
existing configuration only when that harness is present (its config folder exists), and only
ADDS missing entries: a value the person already set - a URL, a header, a model - wins.

Pure functions, no writes and no operating-system literals:
  Get-OpenCodeMergedText  existing JSON text + template JSON text -> merged JSON text
  Get-CodexMergedText     existing TOML text + template TOML text -> merged TOML text
  Get-HarnessConfigUpdates  reads both targets for one home folder and returns the planned writes
The caller writes the result (install.ps1 backs the old file up first).

ASCII-only on purpose (Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page).
#>

function Merge-JsonValue {
    # Existing values win; objects are merged key by key; missing keys come from the template.
    [CmdletBinding()]
    param($Existing, $Template)
    if ($null -eq $Existing) { return $Template }
    if (($Existing -is [System.Management.Automation.PSCustomObject]) -and
        ($Template -is [System.Management.Automation.PSCustomObject])) {
        $merged = [ordered]@{}
        foreach ($p in $Existing.PSObject.Properties) { $merged[$p.Name] = $p.Value }
        foreach ($p in $Template.PSObject.Properties) {
            if ($merged.Contains($p.Name)) {
                $merged[$p.Name] = Merge-JsonValue $merged[$p.Name] $p.Value
            }
            else {
                $merged[$p.Name] = $p.Value
            }
        }
        return [pscustomobject]$merged
    }
    return $Existing
}

function Get-OpenCodeMergedText {
    # Returns the merged opencode.json text. An existing file that is not a JSON object is an
    # error: overwriting it would throw away the person's configuration.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory)][string]$TemplateText
    )
    $template = $TemplateText | ConvertFrom-Json
    if (-not $template) { throw 'the OpenCode template is not a JSON object' }
    if ([string]::IsNullOrWhiteSpace($ExistingText)) {
        return ($template | ConvertTo-Json -Depth 20)
    }
    try { $existing = $ExistingText | ConvertFrom-Json }
    catch { throw ('the existing opencode.json does not parse as JSON: ' + $_.Exception.Message) }
    if ($existing -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'the existing opencode.json is not a JSON object'
    }
    $merged = Merge-JsonValue $existing $template
    return ($merged | ConvertTo-Json -Depth 20)
}

function Get-TomlSections {
    # name -> the lines of that section, header included. Comments before a section are not
    # part of it; the merge adds only the template's key lines.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sections = [ordered]@{}
    $current = $null
    $buffer = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        # a trailing comment after the header is valid TOML: [mcp_servers.exa] # my note
        $m = [regex]::Match($line, '^\s*\[([^\]]+)\]\s*(?:#.*)?$')
        if ($m.Success) {
            if ($current) { $sections[$current] = @($buffer) }
            $current = $m.Groups[1].Value
            $buffer = New-Object System.Collections.Generic.List[string]
            $buffer.Add($line)
        }
        elseif ($current) { $buffer.Add($line) }
    }
    if ($current) { $sections[$current] = @($buffer) }
    return $sections
}

function Get-TomlKeyName {
    # The key of a TOML assignment line: bare, "double quoted" or 'single quoted'. A quoted
    # key is legal TOML, and missing it made the merge insert the same key a second time.
    [CmdletBinding()]
    param([string]$Line)
    $m = [regex]::Match($Line, "^\s*(?:`"([^`"]+)`"|'([^']+)'|([A-Za-z0-9_-]+))\s*=")
    if (-not $m.Success) { return $null }
    foreach ($i in 1, 2, 3) { if ($m.Groups[$i].Success) { return $m.Groups[$i].Value } }
    return $null
}

function Get-TomlKeyNames {
    [CmdletBinding()]
    param([string[]]$Lines)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Lines)) {
        $key = Get-TomlKeyName -Line $line
        if ($key) { $keys.Add($key) }
    }
    return $keys
}

function Get-CodexMergedText {
    # Adds every template section the target does not have, and every template key a present
    # section does not have. Missing keys go INSIDE their existing section: a second
    # [mcp_servers.exa] header would be invalid TOML (measured 2026-10-17). An existing key is
    # never touched; the preamble, comments and blank lines of the target stay where they are.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingText,
        [Parameter(Mandatory)][string]$TemplateText
    )
    $newline = if ($ExistingText -match "`r`n") { "`r`n" } else { "`n" }
    $templateSections = Get-TomlSections -Text $TemplateText
    if ($templateSections.Count -eq 0) { throw 'the Codex template has no TOML section' }
    if ([string]::IsNullOrWhiteSpace($ExistingText)) {
        return (($TemplateText -replace "`r?`n", $newline).TrimEnd() + $newline)
    }

    # split the target into preamble and blocks (a block starts at a [header])
    $preamble = New-Object System.Collections.Generic.List[string]
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in ($ExistingText -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*\[([^\]]+)\]\s*(?:#.*)?$')
        if ($m.Success) {
            $current = [pscustomobject]@{ Name = $m.Groups[1].Value; Lines = (New-Object System.Collections.Generic.List[string]) }
            $current.Lines.Add($line)
            $blocks.Add($current)
        }
        elseif ($current) { $current.Lines.Add($line) }
        else { $preamble.Add($line) }
    }

    $seen = @{}
    foreach ($block in $blocks) {
        if ($seen.ContainsKey($block.Name)) { continue }
        $seen[$block.Name] = $true
        if (-not $templateSections.Contains($block.Name)) { continue }
        $existingKeys = @(Get-TomlKeyNames -Lines $block.Lines)
        $insertAt = $block.Lines.Count
        while ($insertAt -gt 1 -and $block.Lines[$insertAt - 1].Trim() -eq '') { $insertAt-- }
        foreach ($line in @($templateSections[$block.Name])) {
            $key = Get-TomlKeyName -Line $line
            if ($key -and ($existingKeys -notcontains $key)) {
                $block.Lines.Insert($insertAt, $line)
                $insertAt++
                $existingKeys += $key
            }
        }
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $preamble) { $out.Add($line) }
    foreach ($block in $blocks) { foreach ($line in $block.Lines) { $out.Add($line) } }
    foreach ($name in $templateSections.Keys) {
        if ($seen.ContainsKey($name)) { continue }
        $out.Add('')
        foreach ($line in @($templateSections[$name])) { $out.Add($line) }
    }
    return (($out -join $newline).TrimEnd() + $newline)
}

function Get-CodexAgentsUpdate {
    # Codex reads its global rules from ~/.codex/AGENTS.md; OpenCode already falls back to
    # ~/.claude/CLAUDE.md. Only a MISSING AGENTS.md is created from the installed global
    # rules: an existing file belongs to the person and is never touched.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HomeDir)
    $target = Join-Path $HomeDir '.codex/AGENTS.md'
    if (Test-Path -LiteralPath $target -PathType Leaf) { return $null }
    $rules = Join-Path $HomeDir '.claude/CLAUDE.md'
    if (-not (Test-Path -LiteralPath $rules -PathType Leaf)) { return $null }
    $text = [IO.File]::ReadAllText($rules)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return [pscustomobject]@{ Name = 'codex-agents'; Target = $target; TemplatePath = $rules; Text = $text; Changed = $true }
}

function Get-HarnessConfigUpdates {
    # One object per harness whose folder exists under $HomeDir:
    #   Name, Target, TemplatePath, Text (the merged content), Changed
    # A harness that is not installed is simply absent from the list.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HomeDir,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $updates = New-Object System.Collections.Generic.List[object]
    $templateRoot = Join-Path $RepoRoot 'home/.claude/setup/other-harnesses'
    $targets = @(
        @{ Name = 'opencode'; Dir = (Join-Path $HomeDir '.config/opencode'); Target = (Join-Path $HomeDir '.config/opencode/opencode.json'); Template = (Join-Path $templateRoot 'opencode/opencode.json'); Kind = 'json' }
        @{ Name = 'codex'; Dir = (Join-Path $HomeDir '.codex'); Target = (Join-Path $HomeDir '.codex/config.toml'); Template = (Join-Path $templateRoot 'codex/config-mcp.toml'); Kind = 'toml' }
    )
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Dir -PathType Container)) { continue }
        if (-not (Test-Path -LiteralPath $t.Template -PathType Leaf)) { throw ('the template is missing: ' + $t.Template) }
        $templateText = [IO.File]::ReadAllText($t.Template)
        $existingText = ''
        if (Test-Path -LiteralPath $t.Target -PathType Leaf) { $existingText = [IO.File]::ReadAllText($t.Target) }
        if ($t.Kind -eq 'json') {
            $text = Get-OpenCodeMergedText -ExistingText $existingText -TemplateText $templateText
        }
        else {
            $text = Get-CodexMergedText -ExistingText $existingText -TemplateText $templateText
        }
        $changed = -not ((Test-Path -LiteralPath $t.Target -PathType Leaf) -and ($existingText -ceq $text))
        $updates.Add([pscustomobject]@{ Name = $t.Name; Target = $t.Target; TemplatePath = $t.Template; Text = $text; Changed = $changed })
    }
    if (Test-Path -LiteralPath (Join-Path $HomeDir '.codex') -PathType Container) {
        $agents = Get-CodexAgentsUpdate -HomeDir $HomeDir
        if ($null -ne $agents) { $updates.Add($agents) }
    }
    return $updates
}
