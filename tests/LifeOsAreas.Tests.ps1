#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.9.1' }
# Part 4: areas update themselves. life-os-areas.json, the pre-agent snapshot, and the safety net
# area-check.ps1 that reverts what has no source.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LifeOsTestVault.ps1')
    $script:Src = $env:LIFEOS_SRC
    if (-not $script:Src) { $script:Src = New-RenderedMirror (Join-Path (Split-Path -Parent $PSScriptRoot) 'home\.claude\life-os') (Join-Path ([IO.Path]::GetTempPath()) ('lifeos-src-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    $script:Lib = Join-Path $script:Src 'morning-checks.ps1'
    if (Test-Path -LiteralPath $script:Lib) { . $script:Lib }
    $script:Check = Join-Path $script:Src 'area-check.ps1'
    if (Test-Path -LiteralPath $script:Check) { . $script:Check }
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-areas-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
    $script:Dash = [string][char]0x2014

    function New-Area([string]$vault, [string]$name, [string]$truth = '- Antrag laeuft.', [string]$timeline = '- 2026-03-05: letztes Dokument', [string]$aliases = '') {
        $fm = "type: organisation`nstatus: active`ndate: 2026-09-21`n"
        if ($aliases) { $fm += "aliases: $aliases`n" }
        $text = "---`n$fm---`n# $name`n`n## Current truth`n$truth`n`n## Documents`n29 documents in the archive.`n`n## Timeline`n$timeline`n"
        $p = Join-Path $vault "300-areas\$name.md"
        Write-TestFile $p $text
        return $p
    }
    function New-Source([string]$vault, [string]$date, [string]$roh) {
        $null = New-Daily $vault $date $roh
    }
    function New-Snapshot([string]$vault) {
        $s = Join-Path $script:Work ('snap-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-AreaSnapshot -VaultPath $vault -SnapshotDir $s
        return $s
    }
    function Edit-Area([string]$path, [scriptblock]$change) {
        $t = [IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path, (& $change $t), (New-Object Text.UTF8Encoding($false)))
    }
}

AfterAll {
    if ($script:Src -and $script:Src -like '*lifeos-src-*') { Remove-Item -LiteralPath $script:Src -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Write-AreasJson' {
    It 'lists every area note with file name and aliases, and no content' {
        $v = New-TestVault (Join-Path $script:Work 'aj')
        $null = New-Area $v 'ma40'
        $null = New-Area $v 'oegk' -aliases '[ÖGK, Gesundheitskasse]'
        $p = New-Area $v 'agency'
        Edit-Area $p { param($t) $t -replace 'aliases:.*\n', '' -replace '(?m)^date: 2026-09-21$', "date: 2026-09-21`naliases:`n  - Arbeitsmarktservice`n  - 'Agency Wien'" }
        Write-AreasJson -VaultPath $v
        $j = Get-Content -LiteralPath (Join-Path $v '000-meta\life-os-areas.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($j.areas).Count | Should -Be 3
        ($j.areas | Where-Object file -eq 'ma40').aliases.Count | Should -Be 0
        @(($j.areas | Where-Object file -eq 'oegk').aliases) | Should -Contain 'Gesundheitskasse'
        @(($j.areas | Where-Object file -eq 'oegk').aliases) | Should -Contain ([string][char]0x00D6 + 'GK')
        @(($j.areas | Where-Object file -eq 'agency').aliases) | Should -Contain 'Agency Wien'
        (Get-Content -LiteralPath (Join-Path $v '000-meta\life-os-areas.json') -Raw) | Should -Not -Match 'Antrag'
    }
}

Describe 'Invoke-AreaCheck' {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('c-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $script:A = New-Area $script:V 'ma40' '- Antrag laeuft.' '- 2026-03-05: letztes Dokument'
        New-Source $script:V '2026-10-25' '- **08:00 (Sprachaufnahme)** Die MA40 hat den Folgeantrag genehmigt.'
        $script:S = New-Snapshot $script:V
    }

    It 'leaves a note alone that did not change' {
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        @($r | Where-Object status -ne 'unchanged').Count | Should -Be 0
    }

    It 'accepts a Timeline line with a source whose words are in the source note' {
        Edit-Area $script:A { param($t) $t.TrimEnd() + "`n- 2026-10-25 $script:Dash Folgeantrag genehmigt ([[100-daily/2026-10-25]])`n" }
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        $r[0].status | Should -Be 'ok'
        (Get-Content -LiteralPath $script:A -Raw -Encoding UTF8) | Should -Match 'Folgeantrag genehmigt'
    }

    It 'accepts a changed current state when the old sentence is kept as a Vorher line' {
        Edit-Area $script:A { param($t) ($t -replace '- Antrag laeuft\.', '- Folgeantrag genehmigt.').TrimEnd() + "`n- 2026-10-25 $script:Dash Folgeantrag genehmigt ([[100-daily/2026-10-25]])`n- 2026-10-25 $script:Dash Vorher: Antrag laeuft. ([[100-daily/2026-10-25]])`n" }
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        $r[0].status | Should -Be 'ok'
    }

    It 'reverts a changed current state that leaves no Vorher line (the old sentence would be lost)' {
        Edit-Area $script:A { param($t) ($t -replace '- Antrag laeuft\.', '- Folgeantrag genehmigt.').TrimEnd() + "`n- 2026-10-25 $script:Dash Folgeantrag genehmigt ([[100-daily/2026-10-25]])`n" }
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        $r[0].status | Should -Be 'reverted'
        (Get-Content -LiteralPath $script:A -Raw -Encoding UTF8) | Should -Match 'Antrag laeuft'
    }

    It 'reverts a Timeline line without a source link' {
        Edit-Area $script:A { param($t) $t.TrimEnd() + "`n- 2026-10-25 $script:Dash Folgeantrag genehmigt`n" }
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        $r[0].status | Should -Be 'reverted'
        $r[0].reasons -join ' ' | Should -Match 'source'
        (Get-Content -LiteralPath $script:A -Raw -Encoding UTF8) | Should -Not -Match 'Folgeantrag'
    }

    It 'reverts a line whose source note does not contain the words' {
        Edit-Area $script:A { param($t) $t.TrimEnd() + "`n- 2026-10-25 $script:Dash Rueckforderung angekuendigt ([[100-daily/2026-10-25]])`n" }
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        $r[0].status | Should -Be 'reverted'
        $r[0].reasons -join ' ' | Should -Match 'words'
    }

    It 'reverts a line whose source note does not exist' {
        Edit-Area $script:A { param($t) $t.TrimEnd() + "`n- 2026-10-26 $script:Dash Folgeantrag genehmigt ([[100-daily/2026-10-26]])`n" }
        (Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)[0].status | Should -Be 'reverted'
    }

    It 'reverts a line with a digit run of four or more outside the date (case number)' {
        Edit-Area $script:A { param($t) $t.TrimEnd() + "`n- 2026-10-25 $script:Dash Folgeantrag genehmigt 123456 ([[100-daily/2026-10-25]])`n" }
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        $r[0].status | Should -Be 'reverted'
        $r[0].reasons -join ' ' | Should -Match 'digit'
    }

    It 'accepts a date inside the line that the owner names, written as the first date' {
        New-Source $script:V '2026-10-26' '- **08:00** Der Bescheid kam am 3. November.'
        $script:S2 = New-Snapshot $script:V
        Edit-Area $script:A { param($t) $t.TrimEnd() + "`n- 2026-11-03 $script:Dash Bescheid ([[100-daily/2026-10-26]])`n" }
        (Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S2)[0].status | Should -Be 'ok'
    }

    It 'reverts a change to the frontmatter' {
        Edit-Area $script:A { param($t) $t -replace 'status: active', 'status: inactive' }
        (Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)[0].status | Should -Be 'reverted'
        (Get-Content -LiteralPath $script:A -Raw -Encoding UTF8) | Should -Match 'status: active'
    }

    It 'reverts a removed Timeline line (the Timeline only grows)' {
        Edit-Area $script:A { param($t) $t -replace '- 2026-03-05: letztes Dokument\r?\n', '' }
        (Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)[0].status | Should -Be 'reverted'
        (Get-Content -LiteralPath $script:A -Raw -Encoding UTF8) | Should -Match 'letztes Dokument'
    }

    It 'reverts a change outside Current truth and Timeline' {
        Edit-Area $script:A { param($t) $t -replace '29 documents in the archive\.', '30 documents in the archive.' }
        (Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)[0].status | Should -Be 'reverted'
    }

    It 'restores the pre-agent text, so an unsaved hand edit of the owner is not lost' {
        Edit-Area $script:A { param($t) $t -replace 'Antrag laeuft', 'Antrag laeuft noch' }
        $script:S3 = New-Snapshot $script:V
        Edit-Area $script:A { param($t) $t.TrimEnd() + "`n- 2026-10-25 $script:Dash Erfundenes Datum ([[100-daily/2026-10-25]])`n" }
        (Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S3)[0].status | Should -Be 'reverted'
        (Get-Content -LiteralPath $script:A -Raw -Encoding UTF8) | Should -Match 'Antrag laeuft noch'
    }

    It 'names a new area note the agent created (new notes stay manual) and leaves it alone' {
        $null = New-Area $script:V 'neuer-bereich'
        $r = @(Invoke-AreaCheck -VaultPath $script:V -SnapshotDir $script:S)
        ($r | Where-Object file -eq 'neuer-bereich').status | Should -Be 'new'
        Test-Path -LiteralPath (Join-Path $script:V '300-areas\neuer-bereich.md') | Should -BeTrue
    }
}

Describe 'Save-VaultCommit' {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('g-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        & git -C $script:V init -q 2>$null | Out-Null
        & git -C $script:V config user.name t | Out-Null
        & git -C $script:V config user.email t@example.com | Out-Null
        & git -C $script:V config commit.gpgsign false | Out-Null
        Write-TestFile (Join-Path $script:V '.gitignore') "inbox/`ntrash/`n"
        & git -C $script:V add -A 2>$null | Out-Null
        & git -C $script:V commit -q -m 'base' 2>$null | Out-Null
    }

    It 'makes one commit with the changes of the morning folders and leaves other folders alone' {
        $null = New-Area $script:V 'ma40'
        Write-TestFile (Join-Path $script:V '400-knowledge\x.md') 'not part of the morning run'
        $r = Save-VaultCommit -VaultPath $script:V -Message 'chore(morning): test'
        $r | Should -Match 'committed'
        (& git -C $script:V log -1 --format=%s) | Should -Be 'chore(morning): test'
        (& git -C $script:V show --stat --format= HEAD) -join "`n" | Should -Match '300-areas/ma40.md'
        (& git -C $script:V show --stat --format= HEAD) -join "`n" | Should -Not -Match '400-knowledge'
        (& git -C $script:V status --porcelain) -join "`n" | Should -Match '400-knowledge'
    }

    It 'makes no commit when nothing changed' {
        $before = & git -C $script:V rev-parse HEAD
        $r = Save-VaultCommit -VaultPath $script:V -Message 'chore(morning): none'
        $r | Should -Match 'nothing'
        (& git -C $script:V rev-parse HEAD) | Should -Be $before
    }

    It 'does nothing when the vault is not a git repository' {
        $d = Join-Path $script:Work 'nogit'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        Save-VaultCommit -VaultPath $d -Message 'x' | Should -Match 'no git'
    }
}

Describe 'morning.ps1 area flow (Windows PowerShell 5.1)' {
    It 'keeps a good area change, restores a bad one, names it, and commits once' {
        $v = New-TestVault (Join-Path $script:Work 'flow')
        & git -C $v init -q 2>$null | Out-Null
        & git -C $v config user.name t | Out-Null; & git -C $v config user.email t@example.com | Out-Null; & git -C $v config commit.gpgsign false | Out-Null
        Write-TestFile (Join-Path $v '.gitignore') "inbox/`ntrash/`n"
        $good = New-Area $v 'ma40'
        $bad = New-Area $v 'oegk'
        $today = (Get-Date).ToString('yyyy-MM-dd')
        New-Source $v $today '- **08:00 (Sprachaufnahme)** Die MA40 hat den Folgeantrag genehmigt.'
        Write-TestFile (Join-Path $v '000-meta\life-os-runs.log') "2026-10-24T07:01:15 | morning | ok | done`n"
        & git -C $v add -A 2>$null | Out-Null; & git -C $v commit -q -m base 2>$null | Out-Null
        $d = Join-Path $script:Work 'flow-dev'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        $stub = Join-Path $script:Work 'flow-stub'; New-Item -ItemType Directory -Force -Path $stub | Out-Null
        $dash = [string][char]0x2014
        $agent = @"
`$enc = New-Object Text.UTF8Encoding(`$false)
`$d = [string][char]0x2014
`$g = '$good'; `$b = '$bad'
[IO.File]::AppendAllText(`$g, ('- $today ' + `$d + ' Folgeantrag genehmigt ([[100-daily/$today]])' + [char]10), `$enc)
[IO.File]::AppendAllText(`$b, ('- $today ' + `$d + ' Etwas Erfundenes ([[100-daily/$today]])' + [char]10), `$enc)
"@
        Write-TestFile (Join-Path $stub 'agent.ps1') $agent
        Write-TestFile (Join-Path $stub 'claude.cmd') "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0agent.ps1`"`r`necho {`"is_error`":false,`"subtype`":`"success`",`"num_turns`":1,`"total_cost_usd`":0,`"result`":`"stub`"}`r`n"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') -VaultPath $v -DevRoot $d -ClaudeExe (Join-Path $stub 'claude.cmd') -LogDir (Join-Path $stub 'logs') -LockPath (Join-Path $stub 'l.lock') -TrackerStatePath (Join-Path $stub 'ts.json') -SeenPath (Join-Path $stub 's.json') -SettingsPath (Join-Path $stub 'none.json') -ForceAgent | Out-Null
        (Get-Content -LiteralPath $good -Raw -Encoding UTF8) | Should -Match 'Folgeantrag genehmigt'
        (Get-Content -LiteralPath $bad -Raw -Encoding UTF8) | Should -Not -Match 'Erfundenes'
        (Get-Content -LiteralPath (Join-Path $v "100-daily\$today.md") -Raw -Encoding UTF8) | Should -Match ('Bereich zur' + [char]0x00FC + 'ckgesetzt: oegk')
        (Test-Path -LiteralPath (Join-Path $v '000-meta\life-os-areas.json')) | Should -BeTrue
        (& git -C $v log --format=%s -3) | Should -Contain "chore(morning): daily run $today"
        (& git -C $v status --porcelain -- 100-daily 200-projects 300-areas) | Should -BeNullOrEmpty
    }
}

Describe 'Format-AreaResultLines' {
    It 'names a reverted area with the reason and a new area note' {
        $res = @(
            [pscustomobject]@{ file = 'ma40'; status = 'reverted'; reasons = @('no source', 'digit run') },
            [pscustomobject]@{ file = 'neu'; status = 'new'; reasons = @() },
            [pscustomobject]@{ file = 'oegk'; status = 'ok'; reasons = @() })
        $lines = @(Format-AreaResultLines $res)
        $lines | Should -Contain ('Bereich zur' + [char]0x00FC + 'ckgesetzt: ma40 (no source; digit run)')
        $lines | Should -Contain 'Neue Bereichsnotiz ohne Auftrag: neu'
        $lines.Count | Should -Be 2
    }
}