#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.9.1' }
# Tests for the token-free helpers of the Life OS morning run (morning-checks.ps1) and for the
# end-to-end behaviour of morning.ps1. Everything runs against throw-away copies.

# The Life OS scripts are Windows scripts (Windows PowerShell 5.1, German vault paths): on macOS and Linux
# every Describe below is skipped. The flag is set at the top level because -Skip is evaluated at discovery.
$script:notWindows = -not ($IsWindows -or $env:OS -eq 'Windows_NT')

BeforeAll {
    $script:notWindows = -not ($IsWindows -or $env:OS -eq 'Windows_NT')
    if ($script:notWindows) { return }
    . (Join-Path $PSScriptRoot 'LifeOsTestVault.ps1')
    $script:Src = $env:LIFEOS_SRC
    if (-not $script:Src) { $script:Src = New-RenderedMirror (Join-Path (Split-Path -Parent $PSScriptRoot) 'home\.claude\life-os') (Join-Path ([IO.Path]::GetTempPath()) ('lifeos-src-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    $script:Lib = Join-Path $script:Src 'morning-checks.ps1'
    if (Test-Path -LiteralPath $script:Lib) { . $script:Lib }
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null

    function Write-Flag([string]$vault, [hashtable]$flag) {
        $base = @{ generated = '2026-10-25T06:00:00'; changed = $false; projects = @(); attention = @(); missing = @(); no_git = @(); large_files = @(); git_errors = @(); media_raw_total_gb = 0 }
        foreach ($k in $flag.Keys) { $base[$k] = $flag[$k] }
        Write-TestFile (Join-Path $vault '000-meta\life-os-projects.json') (ConvertTo-Json $base -Depth 8)
    }
    function Write-RunsLog([string]$vault, [string[]]$lines) {
        Write-TestFile (Join-Path $vault '000-meta\life-os-runs.log') (($lines -join "`n") + "`n")
    }
    function Write-State([string]$vault, [hashtable]$notes) {
        $n = @{}; foreach ($k in $notes.Keys) { $n[$k] = @{ roh_anchor = $notes[$k] } }
        Write-TestFile (Join-Path $vault '000-meta\life-os-state.json') (ConvertTo-Json @{ version = 1; notes = $n; last_run = '2026-10-24T07:00:00' } -Depth 5)
    }
}

AfterAll {
    if ($script:Src -and $script:Src -like '*lifeos-src-*') { Remove-Item -LiteralPath $script:Src -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-AgentReasons' -Skip:$script:notWindows {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('v-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $script:D = Join-Path $script:Work ('d-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $script:D | Out-Null
        $script:Seen = Join-Path $script:Work ('seen-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        Write-RunsLog $script:V @('2026-10-24T07:00:10 | transcribe | ok | files=0', '2026-10-24T07:01:15 | morning | ok | turns=3 cost=0.1 | done')
        Write-State $script:V @{}
    }

    It 'is empty on a quiet day' {
        @(Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen).Count | Should -Be 0
    }

    It 'stays empty when the only news is an attention hint (uncommitted, unpushed)' {
        Write-Flag $script:V @{ attention = @(@{ name = 'proj'; uncommitted = $true; dirty_days = 4; unpushed = 1; no_upstream = $false }) }
        @(Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen).Count | Should -Be 0
    }

    It 'stays empty when a note is about to expire (a hint, not work)' {
        Write-TestFile (Join-Path $script:V '000-meta\life-os-expiry.json') '[{"file":"300-areas/x.md","valid_until":"2026-10-30","days":5,"status":"soon"}]'
        @(Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen).Count | Should -Be 0
    }

    It 'names a transcript that waits in the inbox' {
        Write-TestFile (Join-Path $script:V '000-meta\life-os-inbox.json') '{"generated":"x","transcripts":[{"txt":"a.txt","audio":"a.m4a","recorded":"2026-10-25T08:00:00","chars":10}]}'
        Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen | Should -Contain 'transcripts: 1'
    }

    It 'names a sync conflict' {
        Write-TestFile (Join-Path $script:V '000-meta\life-os-conflicts.json') '{"generated":"x","conflicts":[{"file":"a.sync-conflict.md","original":"a.md"}]}'
        Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen | Should -Contain 'conflicts: 1'
    }

    It 'names a changed project whose hub is older than its newest commit' {
        $null = New-TestRepo $script:D 'proj'
        $null = New-Hub $script:V 'proj' '2000-01-01T00:00:00'
        Write-Flag $script:V @{ changed = $true; projects = @(@{ name = 'proj'; changed = $true }) }
        Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen | Should -Contain 'hub-stale: proj'
    }

    It 'names a changed project whose hub never had hub_written' {
        $null = New-TestRepo $script:D 'proj'
        $null = New-Hub $script:V 'proj'
        Write-Flag $script:V @{ changed = $true; projects = @(@{ name = 'proj'; changed = $true }) }
        Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen | Should -Contain 'hub-stale: proj'
    }

    It 'ignores a changed project whose hub was written after its newest commit' {
        $null = New-TestRepo $script:D 'proj'
        $null = New-Hub $script:V 'proj' '2999-01-01T00:00:00'
        Write-Flag $script:V @{ changed = $true; projects = @(@{ name = 'proj'; changed = $true }) }
        @(Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen).Count | Should -Be 0
    }

    It 'ignores a changed project that has no hub (a hint line names it)' {
        $null = New-TestRepo $script:D 'proj'
        Write-Flag $script:V @{ changed = $true; projects = @(@{ name = 'proj'; changed = $true; note_missing = $true }) }
        @(Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen).Count | Should -Be 0
    }

    It 'names a daily note with a Roh line after the stored anchor' {
        $p = New-Daily $script:V '2026-10-25' "- **08:00** old line`n- **09:30** new typed line"
        Write-State $script:V @{ '2026-10-25' = '- **08:00** old line' }
        Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen | Should -Contain 'roh: 2026-10-25'
    }

    It 'ignores a daily note that was touched after the last run when its anchor still matches' {
        $p = New-Daily $script:V '2026-10-25' '- **08:00** only line'
        Write-State $script:V @{ '2026-10-25' = '- **08:00** only line' }
        (Get-Item -LiteralPath $p).LastWriteTime = Get-Date
        @(Get-AgentReasons -VaultPath $script:V -DevRoot $script:D -SeenPath $script:Seen).Count | Should -Be 0
    }
}

Describe 'Save-InboxSeen' -Skip:$script:notWindows {
    It 'remembers every other file by name and size, not one joined string' {
        $v = New-TestVault (Join-Path $script:Work ('s-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        Write-TestFile (Join-Path $v '000-meta\life-os-inbox.json') '{"generated":"x","transcripts":[],"notes":[],"other":[{"file":"a.jpg","bytes":1},{"file":"b.jpg","bytes":2}]}'
        $seen = Join-Path $script:Work ('seen-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        Save-InboxSeen -VaultPath $v -SeenPath $seen
        $files = @((Get-Content -LiteralPath $seen -Raw -Encoding UTF8 | ConvertFrom-Json).files)
        $files.Count | Should -Be 2
        $files | Should -Contain 'a.jpg|1'
        $files | Should -Contain 'b.jpg|2'
    }
}

Describe 'Get-AgentReasons after a failed run' -Skip:$script:notWindows {
    It 'still names a Roh line that was copied before the run failed' {
        $v = New-TestVault (Join-Path $script:Work ('f-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $d = Join-Path $script:Work ('fd-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $p = New-Daily $v '2026-10-25' "- **08:00** typed line"
        Write-State $v @{}
        (Get-Item -LiteralPath $p).LastWriteTime = [datetime]'2026-10-25T06:00:30'
        Write-RunsLog $v @('2026-10-24T07:01:15 | morning | ok | turns=3 cost=0.1 | done', '2026-10-25T06:30:00 | morning | fail | FAILED timedOut=True exit=1 | ')
        Get-AgentReasons -VaultPath $v -DevRoot $d -SeenPath '' | Should -Contain 'roh: 2026-10-25'
    }
}

Describe 'Get-HintLines' -Skip:$script:notWindows {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('h-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    }

    It 'writes the project hints from the tracker flag in the fixed formats' {
        Write-Flag $script:V @{
            attention = @(
                @{ name = 'a'; uncommitted = $true; dirty_days = 4; unpushed = 1; no_upstream = $false },
                @{ name = 'b'; uncommitted = $true; dirty_days = 0; unpushed = 0; no_upstream = $false },
                @{ name = 'c'; uncommitted = $false; dirty_days = 0; unpushed = 2; no_upstream = $true })
            git_errors = @(@{ name = 'g'; error = 'git status failed' })
            no_git = @('.claude'); missing = @('gone')
            projects = @(@{ name = 'p'; changed = $true; note_missing = $true })
            media_raw_total_gb = 1.5
        }
        $lines = Get-HintLines -VaultPath $script:V -Today ([datetime]'2026-10-25')
        $lines | Should -Contain 'Nicht gepusht: a (1 Commit(s)); c (2 Commit(s))'
        $lines | Should -Contain 'Nicht committet seit 4 Tag(en): a'
        $lines | Should -Contain 'Nicht committet: b'
        $lines | Should -Contain 'Kein Upstream: c'
        $lines | Should -Contain 'Git-Fehler: g (git status failed)'
        $lines | Should -Contain 'Projekt ohne Notiz: p'
        $lines | Should -Contain 'Projektordner ohne Git: .claude'
        $lines | Should -Contain 'Projekt verschwunden: gone'
        $lines | Should -Contain 'media\raw gesamt: 1.5 GB'
    }

    It 'writes the expiry and fallback hints from their files' {
        Write-TestFile (Join-Path $script:V '000-meta\life-os-expiry.json') '[{"file":"300-areas/x.md","valid_until":"2026-10-30","days":5,"status":"soon"},{"file":"300-areas/y.md","valid_until":"2026-10-28","days":3,"status":"soon"}]'
        Write-TestFile (Join-Path $script:V '000-meta\life-os-transcribe.json') '{"engine":"local","files":1,"local_fallback":1,"fallback_reasons_de":["Groq-Tageslimit erreicht"]}'
        $lines = Get-HintLines -VaultPath $script:V -Today ([datetime]'2026-10-25')
        $lines | Should -Contain 'Ablaufend: 300-areas/x.md am 2026-10-30; 300-areas/y.md am 2026-10-28'
        $lines | Should -Contain 'Transkription: lokaler Fallback (Groq-Tageslimit erreicht)'
    }

    It 'names a failed run of today or yesterday, and only those' {
        Write-RunsLog $script:V @(
            '2026-10-20T07:00:27 | morning | fail | old failure',
            '2026-10-24T07:00:27 | morning | fail | yesterday failure',
            '2026-10-25T06:00:10 | transcribe | warn | today warning',
            '2026-10-25T06:00:49 | morning | ok | fine')
        $lines = @(Get-HintLines -VaultPath $script:V -Today ([datetime]'2026-10-25'))
        ($lines -join "`n") | Should -Match 'yesterday failure'
        ($lines -join "`n") | Should -Match 'today warning'
        ($lines -join "`n") | Should -Not -Match 'old failure'
        ($lines -join "`n") | Should -Not -Match 'fine'
    }

    It 'is empty when there is nothing to say' {
        @(Get-HintLines -VaultPath $script:V -Today ([datetime]'2026-10-25')).Count | Should -Be 0
    }
}

Describe 'Set-MorgenberichtBlock' -Skip:$script:notWindows {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('m-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    }

    It 'creates the daily note from the template and writes the block' {
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-26' -Lines @('Nicht committet: x')
        $t = Get-Content -LiteralPath (Join-Path $script:V '100-daily\2026-10-26.md') -Raw -Encoding UTF8
        $t | Should -Match "(?s)date: '2026-10-26'.*## Morgenbericht.*Nicht committet: x"
    }

    It 'keeps the agent lines and replaces only its own block on a second run' {
        $p = New-Daily $script:V '2026-10-26' '' "`n- Agent line one`n"
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-26' -Lines @('first hint')
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-26' -Lines @('second hint')
        $t = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        $t | Should -Match 'Agent line one'
        $t | Should -Match 'second hint'
        $t | Should -Not -Match 'first hint'
        ([regex]::Matches($t, 'morning\.ps1')).Count | Should -Be 2
    }

    It 'drops an agent line that repeats a line of its own block, and keeps the other agent lines' {
        $agent = "`n- 1 Notiz eingeordnet.`n- Nicht gepusht: proj (1 Commit(s))`n- Nicht committet seit 4 Tag(en): proj`n- Heute: keine f$([char]0x00E4)lligen Aufgaben.`n"
        $p = New-Daily $script:V '2026-10-26' '' $agent
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-26' -Lines @('Nicht gepusht: proj (1 Commit(s))', 'Nicht committet seit 5 Tag(en): proj', ('Heute: Milch kaufen'))
        $t = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace "`r`n", "`n"
        ([regex]::Matches($t, 'Nicht gepusht')).Count | Should -Be 1
        ([regex]::Matches($t, 'Nicht committet')).Count | Should -Be 1
        ([regex]::Matches($t, 'Heute:')).Count | Should -Be 1
        $t | Should -Match '1 Notiz eingeordnet'
    }

    It 'never touches Roh, Protokoll or Aufgaben' {
        $p = New-Daily $script:V '2026-10-26' '- **08:00** raw'
        $before = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace '(?s)## Morgenbericht.*', ''
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-26' -Lines @('hint')
        $after = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace '(?s)## Morgenbericht.*', ''
        $after | Should -BeExactly $before
    }

    It 'creates nothing and removes an old block when there are no lines' {
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-26' -Lines @()
        Test-Path -LiteralPath (Join-Path $script:V '100-daily\2026-10-26.md') | Should -BeFalse
        $p = New-Daily $script:V '2026-10-27'
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-27' -Lines @('x')
        Set-MorgenberichtBlock -VaultPath $script:V -Date '2026-10-27' -Lines @()
        (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | Should -Not -Match 'morning\.ps1'
    }
}

Describe 'Remove-ResolvedUnclearLines' -Skip:$script:notWindows {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('u-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $arrow = [string][char]0x2192
        $ue = [string][char]0x00FC
        $text = "---`ntype: daily`nstatus: active`ndate: '2026-10-26'`n---`n# 2026-10-26`n`n## Roh`n`n- **13:21** Ich muss die Rezeptgeb${ue}hr-Befreiung neu beantragen.`n`n## Protokoll`n`n## Aufgaben`n`n- Rezeptgeb${ue}hr-Befreiung neu beantragen $arrow todo`n`n## Morgenbericht`n`n- 1 Aufgabe erg${([char]0x00E4)}nzt.`n- Nicht eingetragen (unklar): Ich muss die Rezeptgeb${ue}hr-Befreiung neu beantragen.`n- Nicht eingetragen (unklar): Vielleicht mal den Keller aufr${([char]0x00E4)}umen`n"
        $script:P = Join-Path $script:V '100-daily\2026-10-26.md'
        Write-TestFile $script:P $text
        $script:Since = (Get-Date).AddMinutes(-5)
    }

    It 'drops the unclear line of an entry that became a task, and keeps the others' {
        Remove-ResolvedUnclearLines -VaultPath $script:V -Since $script:Since
        $t = Get-Content -LiteralPath $script:P -Raw -Encoding UTF8
        $t | Should -Not -Match 'Rezeptgeb.hr-Befreiung neu beantragen\.\s*$'
        ([regex]::Matches($t, 'Nicht eingetragen')).Count | Should -Be 1
        $t | Should -Match 'Keller'
        $t | Should -Match '1 Aufgabe'
    }

    It 'never touches Roh, Protokoll or Aufgaben' {
        $before = (Get-Content -LiteralPath $script:P -Raw -Encoding UTF8) -replace '(?s)## Morgenbericht.*', ''
        Remove-ResolvedUnclearLines -VaultPath $script:V -Since $script:Since
        ((Get-Content -LiteralPath $script:P -Raw -Encoding UTF8) -replace '(?s)## Morgenbericht.*', '') | Should -BeExactly $before
    }
}

Describe 'project-tracker.ps1 flag' -Skip:$script:notWindows {
    It 'writes the flag file for an attention-only day (dirty repo, nothing else changed)' {
        $v = New-TestVault (Join-Path $script:Work 'tv')
        $d = Join-Path $script:Work 'td'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $null = New-TestRepo $d 'proj' -Dirty
        $state = Join-Path $script:Work 'tracker-state.json'
        $tracker = Join-Path $script:Src 'project-tracker.ps1'
        # first run: the repo is new, so the flag is written for that reason
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tracker -DevRoot $d -VaultPath $v -StatePath $state -LogDir $script:Work | Out-Null
        Remove-Item -LiteralPath (Join-Path $v '000-meta\life-os-projects.json') -Force
        # second run: nothing changed, the repo is still dirty - only "attention" is left
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tracker -DevRoot $d -VaultPath $v -StatePath $state -LogDir $script:Work | Out-Null
        $flag = Join-Path $v '000-meta\life-os-projects.json'
        Test-Path -LiteralPath $flag | Should -BeTrue
        $o = Get-Content -LiteralPath $flag -Raw -Encoding UTF8 | ConvertFrom-Json
        @($o.attention).Count | Should -Be 1
        @($o.projects).Count | Should -Be 0
    }

    It 'carries goal, status and next step of PROGRESS.md for a changed project' {
        $v = New-TestVault (Join-Path $script:Work 'tv2')
        $d = Join-Path $script:Work 'td2'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $repo = New-TestRepo $d 'proj'
        Write-TestFile (Join-Path $repo 'PROGRESS.md') "# P`n`n## Goal`nShip the thing.`n`n## Status`nPart one done.`nPart two half done.`n`n## Next step`nFinish part two.`n"
        $null = New-Hub $v 'proj'
        $state = Join-Path $script:Work 'tracker-state2.json'
        $tracker = Join-Path $script:Src 'project-tracker.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tracker -DevRoot $d -VaultPath $v -StatePath $state -LogDir $script:Work | Out-Null
        $o = Get-Content -LiteralPath (Join-Path $v '000-meta\life-os-projects.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $p = @($o.projects)[0]
        $p.progress_goal | Should -Be 'Ship the thing.'
        $p.progress_status | Should -Be 'Part one done. Part two half done.'
        $p.next_step | Should -Be 'Finish part two.'
    }
}

Describe 'Get-AreaStaleness' -Skip:$script:notWindows {
    BeforeEach {
        $script:SV = New-TestVault (Join-Path $script:Work ('st-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $script:Arch = Join-Path $script:SV '600-archive'
    }
    BeforeAll {
        function New-AreaWith([string]$name, [string[]]$folders, [string]$lastTimeline) {
            $doc = ($folders | ForEach-Object { '`600-archive/' + $_ + '/`' }) -join ' and '
            Write-TestFile (Join-Path $script:SV "300-areas\$name.md") ("---`ntype: organisation`nstatus: active`ndate: 2026-09-21`n---`n# $name`n`n## Current truth`n- x`n`n## Documents`n3 documents, in`n$doc.`n`n## Timeline`n- 2024-01-01: first`n- ${lastTimeline}: latest`n")
        }
        function New-Sidecar([string]$folder, [string]$stem) {
            Write-TestFile (Join-Path $script:Arch "$folder\$stem.md") "x`n"
        }
    }

    It 'names an area whose leaf folder holds a newer document than its Timeline' {
        New-AreaWith 'ma40' @('06_Folder/MA40') '2026-03-05'
        New-Sidecar '06_Folder\MA40' 'MA40_Antrag_2026-09-17'
        New-Sidecar '06_Folder\MA40' 'MA40_Bescheid_2026-03-05'
        $r = @(Get-AreaStaleness -VaultPath $script:SV)
        $r.Count | Should -Be 1
        $r[0].file | Should -Be 'ma40'
        $r[0].note_date | Should -Be '2026-03-05'
        $r[0].newest_document | Should -Be '2026-09-17'
    }
    It 'is silent when the Timeline is as new as the newest document' {
        New-AreaWith 'ma40' @('06_Folder/MA40') '2026-09-17'
        New-Sidecar '06_Folder\MA40' 'MA40_Antrag_2026-09-17'
        @(Get-AreaStaleness -VaultPath $script:SV).Count | Should -Be 0
    }
    It 'skips two areas that name the same folder' {
        New-AreaWith 'a' @('06_Folder/Shared') '2026-01-01'
        New-AreaWith 'b' @('06_Folder/Shared') '2026-01-01'
        New-Sidecar '06_Folder\Shared' 'X_2026-09-17'
        @(Get-AreaStaleness -VaultPath $script:SV).Count | Should -Be 0
    }
    It 'skips the area whose folder encloses the folder of another area, and keeps the inner one' {
        New-AreaWith 'wide' @('03_Bildung') '2026-01-01'
        New-AreaWith 'inner' @('03_Bildung/Inner') '2026-01-01'
        New-Sidecar '03_Bildung\Inner' 'Inner_Bericht_2026-09-17'
        $r = @(Get-AreaStaleness -VaultPath $script:SV)
        $r.Count | Should -Be 1
        $r[0].file | Should -Be 'inner'
    }
    It 'uses the second folder of an area when the first is ambiguous' {
        New-AreaWith 'x' @('01_A', '02_B') '2026-01-01'
        New-AreaWith 'y' @('01_A') '2026-01-01'
        New-Sidecar '02_B' 'Doc_2026-09-17'
        $r = @(Get-AreaStaleness -VaultPath $script:SV)
        $r.Count | Should -Be 1
        $r[0].file | Should -Be 'x'
    }
    It 'ignores an area without an archive folder and a missing archive' {
        Write-TestFile (Join-Path $script:SV '300-areas\plain.md') "---`ntype: organisation`nstatus: active`ndate: 2026-09-21`n---`n# plain`n`n## Timeline`n- 2024-01-01: x`n"
        New-AreaWith 'ghost' @('09_Missing') '2026-01-01'
        @(Get-AreaStaleness -VaultPath $script:SV).Count | Should -Be 0
    }
    It 'ignores files without a date at the end of the name' {
        New-AreaWith 'ma40' @('06_Folder/MA40') '2026-03-05'
        New-Sidecar '06_Folder\MA40' 'Notes_without_date'
        @(Get-AreaStaleness -VaultPath $script:SV).Count | Should -Be 0
    }
}

Describe 'weekly area hint' -Skip:$script:notWindows {
    It 'writes life-os-areas-stale.json and the hint line names the areas' {
        $v = New-TestVault (Join-Path $script:Work 'wk1')
        Write-TestFile (Join-Path $v '300-areas\ma40.md') "---`ntype: organisation`nstatus: active`ndate: 2026-09-21`n---`n# ma40`n`n## Documents`nin ``600-archive/06/MA40/``.`n`n## Timeline`n- 2026-03-05: latest`n"
        Write-TestFile (Join-Path $v '600-archive\06\MA40\Antrag_2026-09-17.md') "x`n"
        Update-AreasStale -VaultPath $v
        $o = Get-Content -LiteralPath (Join-Path $v '000-meta\life-os-areas-stale.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($o.areas)[0].file | Should -Be 'ma40'
        ([datetime]$o.generated).ToString('yyyy-MM-dd') | Should -Be (Get-Date).ToString('yyyy-MM-dd')
        Get-HintLines -VaultPath $v -Today (Get-Date) | Should -Contain 'Neuere Dokumente als die Notiz: ma40'
    }
    It 'writes no hint line when the file is from another day' {
        $v = New-TestVault (Join-Path $script:Work 'wk2')
        Write-TestFile (Join-Path $v '000-meta\life-os-areas-stale.json') (ConvertTo-Json @{ generated = '2026-01-05T06:00:00'; areas = @(@{ file = 'ma40'; note_date = '2026-03-05'; newest_document = '2026-09-17' }) } -Depth 4)
        @(Get-HintLines -VaultPath $v -Today (Get-Date)) -match 'Neuere Dokumente' | Should -BeNullOrEmpty
    }
    It 'writes no hint line when nothing is stale' {
        $v = New-TestVault (Join-Path $script:Work 'wk3')
        Update-AreasStale -VaultPath $v
        @(Get-HintLines -VaultPath $v -Today (Get-Date)) -match 'Neuere Dokumente' | Should -BeNullOrEmpty
    }
}

Describe 'Set-FlagHubStale' -Skip:$script:notWindows {
    It 'adds the names of the stale hubs to the flag and keeps the rest' {
        $v = New-TestVault (Join-Path $script:Work 'fs1')
        Write-Flag $v @{ projects = @(@{ name = 'proj'; changed = $true }); changed = $true }
        Set-FlagHubStale -VaultPath $v -Reasons @('hub-stale: proj', 'transcripts: 1')
        $o = Get-Content -LiteralPath (Join-Path $v '000-meta\life-os-projects.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($o.hub_stale) | Should -Be @('proj')
        @($o.projects).Count | Should -Be 1
    }
    It 'writes nothing when no hub is stale' {
        $v = New-TestVault (Join-Path $script:Work 'fs2')
        Write-Flag $v @{ changed = $false }
        Set-FlagHubStale -VaultPath $v -Reasons @('transcripts: 1')
        $o = Get-Content -LiteralPath (Join-Path $v '000-meta\life-os-projects.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $o.PSObject.Properties['hub_stale'] | Should -BeNullOrEmpty
    }
    It 'does not create a flag file that is not there' {
        $v = New-TestVault (Join-Path $script:Work 'fs3')
        Set-FlagHubStale -VaultPath $v -Reasons @('hub-stale: proj')
        Test-Path -LiteralPath (Join-Path $v '000-meta\life-os-projects.json') | Should -BeFalse
    }
}

Describe 'morning.ps1 end to end' -Skip:$script:notWindows {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('e-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $script:D = Join-Path $script:Work ('ed-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $script:D | Out-Null
        $script:Stub = Join-Path $script:Work ('stub-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $script:Stub | Out-Null
        Write-TestFile (Join-Path $script:Stub 'claude.cmd') "@echo off`r`necho called> `"%~dp0called.txt`"`r`necho {`"is_error`":false,`"subtype`":`"success`",`"num_turns`":1,`"total_cost_usd`":0,`"result`":`"stub`"}`r`n"
        $script:MArgs = @{
            VaultPath = $script:V; DevRoot = $script:D; ClaudeExe = (Join-Path $script:Stub 'claude.cmd')
            LogDir = (Join-Path $script:Stub 'logs'); LockPath = (Join-Path $script:Stub 'morning.lock')
            TrackerStatePath = (Join-Path $script:Stub 'tracker-state.json'); SeenPath = (Join-Path $script:Stub 'seen.json')
            SettingsPath = (Join-Path $script:Stub 'none.json')
        }
        Write-RunsLog $script:V @('2026-10-24T07:00:10 | transcribe | ok | files=0', '2026-10-24T07:01:15 | morning | ok | turns=3 cost=0.1 | done')
        # one earlier tracker run, so the repo is known and unchanged
        $null = New-TestRepo $script:D 'proj' -Dirty
        $null = New-Hub $script:V 'proj' '2999-01-01T00:00:00'
        $tracker = Join-Path $script:Src 'project-tracker.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tracker -DevRoot $script:D -VaultPath $script:V -StatePath $script:MArgs.TrackerStatePath -LogDir $script:Work | Out-Null
        Remove-Item -LiteralPath (Join-Path $script:V '000-meta\life-os-projects.json') -Force -ErrorAction SilentlyContinue
    }

    It 'does not start the agent for hints alone, and writes them into the Morgenbericht itself' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') @script:MArgs | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Stub 'called.txt') | Should -BeFalse
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $note = Join-Path $script:V "100-daily\$today.md"
        Test-Path -LiteralPath $note | Should -BeTrue
        (Get-Content -LiteralPath $note -Raw -Encoding UTF8) | Should -Match 'Nicht committet.*: proj'
        (Get-Content -LiteralPath (Join-Path $script:V '000-meta\life-os-runs.log') -Raw) | Should -Match 'morning \| skip'
    }

    It 'starts the agent when a transcript waits, and still writes the hints after it' {
        Write-TestFile (Join-Path $script:V 'inbox\audio\a.txt') 'hello'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') @script:MArgs | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Stub 'called.txt') | Should -BeTrue
        $today = (Get-Date).ToString('yyyy-MM-dd')
        (Get-Content -LiteralPath (Join-Path $script:V "100-daily\$today.md") -Raw -Encoding UTF8) | Should -Match 'Nicht committet.*: proj'
    }

    It 'leaves no copy of the area notes in the log folder after the run' {
        Write-TestFile (Join-Path $script:V 'inbox\audio\a.txt') 'hello'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') @script:MArgs | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Stub 'called.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Stub 'logs\area-snapshot') | Should -BeFalse
    }

    It 'refuses a vault path that is not an existing absolute folder and creates nothing' {
        # A hashtable handed over as the first positional argument arrives as the text
        # "System.Collections.Hashtable"; it once created that folder in the repository.
        $cwd = Join-Path $script:Work ('cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $cwd | Out-Null
        Push-Location $cwd
        try {
            $bad = @{ LogDir = (Join-Path $script:Stub 'badlogs'); LockPath = (Join-Path $script:Stub 'bad.lock')
                TrackerStatePath = (Join-Path $script:Stub 'bad-tracker.json'); SeenPath = (Join-Path $script:Stub 'bad-seen.json')
                DevRoot = $script:D; ClaudeExe = (Join-Path $script:Stub 'claude.cmd') }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') 'System.Collections.Hashtable' @bad 2>&1 | Out-Null
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        $code | Should -Be 2
        Test-Path -LiteralPath (Join-Path $cwd 'System.Collections.Hashtable') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Stub 'called.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Stub 'bad-tracker.json') | Should -BeFalse
    }

    It 'writes the weekly area hint without starting the agent' {
        Write-TestFile (Join-Path $script:V '300-areas\ma40.md') "---`ntype: organisation`nstatus: active`ndate: 2026-09-21`n---`n# ma40`n`n## Documents`nin ``600-archive/06/MA40/``.`n`n## Timeline`n- 2026-03-05: latest`n"
        Write-TestFile (Join-Path $script:V '600-archive\06\MA40\Antrag_2026-09-17.md') "x`n"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') @script:MArgs -ForceWeekly | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Stub 'called.txt') | Should -BeFalse
        $today = (Get-Date).ToString('yyyy-MM-dd')
        (Get-Content -LiteralPath (Join-Path $script:V "100-daily\$today.md") -Raw -Encoding UTF8) | Should -Match 'Neuere Dokumente als die Notiz: ma40'
    }

    It 'hands the stale hub names to the agent in the flag file' {
        Write-TestFile (Join-Path $script:Stub 'claude.cmd') ("@echo off`r`ncopy /y `"" + (Join-Path $script:V '000-meta\life-os-projects.json') + "`" `"%~dp0flag-seen.json`" >nul`r`necho {`"is_error`":false,`"subtype`":`"success`",`"num_turns`":1,`"total_cost_usd`":0,`"result`":`"stub`"}`r`n")
        $null = New-Hub $script:V 'proj' '2000-01-01T00:00:00'
        $repo = Join-Path $script:D 'proj'
        Write-TestFile (Join-Path $repo 'c.txt') "c`n"
        & git -C $repo add -A 2>$null | Out-Null
        & git -C $repo -c commit.gpgsign=false commit -q -m 'newer' 2>$null | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') @script:MArgs | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Stub 'flag-seen.json') | Should -BeTrue
        $o = Get-Content -LiteralPath (Join-Path $script:Stub 'flag-seen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($o.hub_stale) | Should -Be @('proj')
    }

    It 'logs why the agent started' {
        Write-TestFile (Join-Path $script:V 'inbox\audio\a.txt') 'hello'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') @script:MArgs | Out-Null
        $log = Get-Content -LiteralPath (Join-Path $script:Stub ('logs\morning-' + (Get-Date).ToString('yyyy-MM-dd') + '.log')) -Raw
        $log | Should -Match 'agent reasons: .*transcripts: 1'
    }
}
