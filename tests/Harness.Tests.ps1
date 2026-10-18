# The OpenCode/Codex merge: adds what is missing, never rewrites a value the person set.
# Pure functions from setup/lib/harness.ps1; no config of this machine is touched.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\setup\lib\harness.ps1')
    $script:opencodeTemplate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\home\.claude\setup\other-harnesses\opencode\opencode.json'))
    $script:codexTemplate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\home\.claude\setup\other-harnesses\codex\config-mcp.toml'))
}

Describe 'OpenCode JSON merge' {
    It 'adds the exa entry with its key template and keeps existing servers and values' {
        $existing = '{"mcp":{"mine":{"type":"remote","url":"https://mine.example"},"exa":{"type":"remote","url":"https://custom.example","enabled":false}},"model":"keep-me"}'
        $text = Get-OpenCodeMergedText -ExistingText $existing -TemplateText $script:opencodeTemplate
        $obj = $text | ConvertFrom-Json
        $obj.model | Should -Be 'keep-me'
        $obj.mcp.mine.url | Should -Be 'https://mine.example'
        $obj.mcp.exa.url | Should -Be 'https://custom.example' -Because 'an existing value wins'
        $obj.mcp.exa.enabled | Should -BeFalse -Because 'an existing value wins, even a false one'
        $obj.mcp.'exa-key'.headers.'x-api-key' | Should -Be '{env:EXA_API_KEY}'
        $obj.mcp.'exa-key'.url | Should -Match 'web_search_advanced_exa'
        $obj.agent.researcher.prompt | Should -Match '\.agents/skills/web-research'
    }

    It 'does not overwrite a header value the person already set' {
        $existing = '{"mcp":{"exa":{"type":"remote","url":"https://mine.example","headers":{"x-api-key":"{env:MY_OWN_KEY}"}}}}'
        $text = Get-OpenCodeMergedText -ExistingText $existing -TemplateText $script:opencodeTemplate
        ($text | ConvertFrom-Json).mcp.exa.headers.'x-api-key' | Should -Be '{env:MY_OWN_KEY}'
    }

    It 'is idempotent' {
        $once = Get-OpenCodeMergedText -ExistingText '{"mcp":{}}' -TemplateText $script:opencodeTemplate
        $twice = Get-OpenCodeMergedText -ExistingText $once -TemplateText $script:opencodeTemplate
        $twice | Should -Be $once
    }

    It 'leaves an empty target as the template' {
        $text = Get-OpenCodeMergedText -ExistingText '' -TemplateText $script:opencodeTemplate
        ($text | ConvertFrom-Json).mcp.exa.headers.'x-api-key' | Should -Be '{env:EXA_API_KEY}'
    }

    It 'refuses invalid JSON instead of replacing the file' {
        { Get-OpenCodeMergedText -ExistingText '{broken' -TemplateText $script:opencodeTemplate } |
            Should -Throw -Because 'overwriting would throw away the person''s configuration'
    }
}

Describe 'Codex TOML merge' {
    It 'appends missing sections and keys, and keeps an existing section value' {
        $existing = "# my own comment`n[mcp_servers.node_repl]`ncommand = 'keep-me'`n`n[mcp_servers.exa]`nurl = 'https://old.example'`n"
        $text = Get-CodexMergedText -ExistingText $existing -TemplateText $script:codexTemplate
        $text | Should -Match '# my own comment'
        $text | Should -Match '\[mcp_servers\.node_repl\]'
        $text | Should -Match "url = 'https://old\.example'" -Because 'an existing value wins'
        $text | Should -Match '\[mcp_servers\.exa-key\]'
        $text | Should -Match '\[mcp_servers\.tavily\]'
        ([regex]::Matches($text, '(?m)^\s*\[mcp_servers\.exa\]\s*$')).Count |
            Should -Be 1 -Because 'a second table header would be invalid TOML'
        $sections = Get-TomlSections -Text $text
        ($sections['mcp_servers.exa'] -join "`n") | Should -Match 'env_http_headers = \{ "x-api-key" = "EXA_API_KEY" \}'
    }

    It 'sees quoted keys and a header with a trailing comment' {
        # Both are valid TOML. Missing them made the merge insert the same key a second time,
        # and tomllib then refused the file ("Cannot overwrite a value").
        $existing = "[mcp_servers.exa] # my note`n`"url`" = 'https://old.example'`n"
        $text = Get-CodexMergedText -ExistingText $existing -TemplateText $script:codexTemplate
        ([regex]::Matches($text, '(?m)^\s*\[mcp_servers\.exa\]')).Count |
            Should -Be 1 -Because 'the header with a comment is still one section'
        $exa = ((Get-TomlSections -Text $text)['mcp_servers.exa']) -join "`n"
        $exa | Should -Match '"url" = ''https://old\.example''' -Because 'an existing value wins'
        ([regex]::Matches($exa, '(?m)^\s*(?:"url"|url)\s*=')).Count |
            Should -Be 1 -Because 'a second url key would be invalid TOML'
        $exa | Should -Match 'env_http_headers' -Because 'the missing key still goes into the section'
    }

    It 'is idempotent' {
        $once = Get-CodexMergedText -ExistingText '' -TemplateText $script:codexTemplate
        $twice = Get-CodexMergedText -ExistingText $once -TemplateText $script:codexTemplate
        $twice | Should -Be $once
    }

    It 'keeps CRLF when the target uses it' {
        $existing = "[mcp_servers.node_repl]`r`ncommand = 'x'`r`n"
        $text = Get-CodexMergedText -ExistingText $existing -TemplateText $script:codexTemplate
        $text | Should -Match "`r`n"
        $text | Should -Match '\[mcp_servers\.exa\]'
    }
}

Describe 'which harnesses are present' {
    BeforeAll {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('harness-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:tmp | Out-Null
        $script:repo = Split-Path -Parent $PSScriptRoot
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:tmp) { Remove-Item -LiteralPath $script:tmp -Recurse -Force }
    }

    It 'returns nothing when neither harness folder exists' {
        $u = @(Get-HarnessConfigUpdates -HomeDir $script:tmp -RepoRoot $script:repo)
        $u.Count | Should -Be 0
    }

    It 'plans the OpenCode merge when its folder exists' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:tmp '.config/opencode') | Out-Null
        $u = @(Get-HarnessConfigUpdates -HomeDir $script:tmp -RepoRoot $script:repo)
        ($u | Where-Object { $_.Name -eq 'opencode' }).Changed | Should -BeTrue
        ($u | Where-Object { $_.Name -eq 'codex' }) | Should -BeNullOrEmpty
    }

    It 'sees the codex folder beside it without duplicating the opencode plan' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:tmp '.codex') | Out-Null
        $u = @(Get-HarnessConfigUpdates -HomeDir $script:tmp -RepoRoot $script:repo)
        @($u).Count | Should -Be 2
        @($u | ForEach-Object { $_.Name } | Sort-Object) -join ',' | Should -Be 'codex,opencode'
    }

    It 'writes ~/.codex/AGENTS.md from the global rules when Codex is present and it is missing' {
        # Codex reads its global rules from ~/.codex/AGENTS.md; without the file it would run
        # without the person's rules. OpenCode already falls back to ~/.claude/CLAUDE.md.
        $home2 = Join-Path $script:tmp 'home2'
        New-Item -ItemType Directory -Force -Path (Join-Path $home2 '.codex') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $home2 '.claude') | Out-Null
        [IO.File]::WriteAllText((Join-Path $home2 '.claude/CLAUDE.md'), "# my rules`n",
            (New-Object Text.UTF8Encoding($false)))
        $u = @(Get-HarnessConfigUpdates -HomeDir $home2 -RepoRoot $script:repo)
        $agents = $u | Where-Object { $_.Name -eq 'codex-agents' }
        $agents.Target | Should -Be (Join-Path $home2 '.codex/AGENTS.md')
        $agents.Text | Should -Match '# my rules'
        $agents.Changed | Should -BeTrue
    }

    It 'never touches an existing ~/.codex/AGENTS.md' {
        $home3 = Join-Path $script:tmp 'home3'
        New-Item -ItemType Directory -Force -Path (Join-Path $home3 '.codex') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $home3 '.claude') | Out-Null
        [IO.File]::WriteAllText((Join-Path $home3 '.claude/CLAUDE.md'), "# mine`n",
            (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $home3 '.codex/AGENTS.md'), "# the person's own`n",
            (New-Object Text.UTF8Encoding($false)))
        $u = @(Get-HarnessConfigUpdates -HomeDir $home3 -RepoRoot $script:repo)
        @($u | Where-Object { $_.Name -eq 'codex-agents' }).Count | Should -Be 0
    }
}
