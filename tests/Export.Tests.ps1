# Pester 5.9.1 (pinned). The `append` rule of setup/export.ps1.
#
# The rule adds the personal-layer import to the end of an exported rule file unless the file
# already carries it. It looked for the block with the manifest's own LF line breaks, so a live
# file saved with CRLF line breaks never matched, and every export appended a second copy
# (measured 2026-10-23: the global CLAUDE.md in the working tree ended with the block twice,
# the live file once). The check now compares line endings normalised.
BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:export = Join-Path $script:repo 'setup\export.ps1'
    # The system temp folder, not tests/_tmp: the export refuses a source below a `\projects\` folder
    # (setup/lib/manifest.ps1), and this repository lives in one.
    $script:work = Join-Path ([IO.Path]::GetTempPath()) 'personal-os-setup-export-append'
    $script:block = "<!-- personal-os-setup: personal additions stay local (never in this repo) -->`n@~/.personal-os/instructions.local.md"

    function Invoke-AppendExport([string]$liveText) {
        if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force }
        $dev = Join-Path $script:work 'dev'
        $fake = Join-Path $script:work 'repo'
        New-Item -ItemType Directory -Force -Path $dev, (Join-Path $fake 'setup') | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:repo 'setup\platforms.yaml') -Destination (Join-Path $fake 'setup\platforms.yaml')
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $dev 'RULES.md'), $liveText, $utf8)
        $manifest = @(
            'version: 1'
            'components:'
            '  - id: rules-fixture'
            '    area: claude'
            '    type: template'
            '    core: true'
            '    source: "{DEV}/RULES.md"'
            '    target: "DEV/RULES.md"'
            '    append: "\n<!-- personal-os-setup: personal additions stay local (never in this repo) -->\n@~/.personal-os/instructions.local.md\n"'
        ) -join "`n"
        [IO.File]::WriteAllText((Join-Path $fake 'manifest.yaml'), $manifest, $utf8)
        # the dummy values, with the two roots moved into the scratch folder
        $config = (@(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\personal.dummy.yaml') | Where-Object { $_ -notmatch '^(vault_path|dev_root):' }) +
            @(
                ('vault_path: "' + ((Join-Path $script:work 'vault') -replace '\\', '\\') + '"')
                ('dev_root: "' + ($dev -replace '\\', '\\') + '"')
            )) -join "`n"
        [IO.File]::WriteAllText((Join-Path $fake 'personal.yaml'), $config, $utf8)
        $out = & pwsh -NoProfile -File $script:export -RepoRoot $fake -ManifestPath (Join-Path $fake 'manifest.yaml') `
            -ConfigPath (Join-Path $fake 'personal.yaml') -StatePath (Join-Path $fake 'state.json') -SkipScan 2>&1 | Out-String
        $written = Get-ChildItem -LiteralPath $fake -Recurse -File -Filter 'RULES.md' | Where-Object { $_.FullName -ne (Join-Path $dev 'RULES.md') } | Select-Object -First 1
        return @{ Output = $out; Exit = $LASTEXITCODE; Text = $(if ($written) { [IO.File]::ReadAllText($written.FullName) } else { '' }) }
    }
    function Get-BlockCount([string]$text) {
        return [int]([regex]::Matches(($text -replace "`r`n", "`n"), [regex]::Escape('@~/.personal-os/instructions.local.md'))).Count
    }
}

Describe 'export append rule' {
    It 'adds the import once to a file that lacks it' {
        $r = Invoke-AppendExport ("# Rules`n`nBe short.`n")
        $r.Exit | Should -Be 0 -Because $r.Output
        Get-BlockCount $r.Text | Should -Be 1
    }
    It 'adds nothing to a file with LF line breaks that already carries it' {
        $r = Invoke-AppendExport ("# Rules`n`nBe short.`n`n" + $script:block + "`n")
        $r.Exit | Should -Be 0 -Because $r.Output
        Get-BlockCount $r.Text | Should -Be 1
    }
    It 'adds nothing to a file with CRLF line breaks that already carries it' {
        $r = Invoke-AppendExport ((("# Rules`n`nBe short.`n`n" + $script:block + "`n") -replace "`n", "`r`n"))
        $r.Exit | Should -Be 0 -Because $r.Output
        Get-BlockCount $r.Text | Should -Be 1 -Because 'a live file saved with CRLF must not get the block a second time'
    }
}
