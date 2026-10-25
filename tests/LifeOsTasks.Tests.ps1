#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.9.1' }
# Part 3: one task list. The agent writes "- [ ] task" into ## Aufgaben of the daily note (as before);
# the runner moves each new one into 000-meta/todo.md under ## Next and leaves "- task -> todo".

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
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-tasks-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
    $script:Cal = [char]::ConvertFromUtf32(0x1F4C5)
    $script:Arrow = [string][char]0x2192
    function New-DailyWithTasks([string]$vault, [string]$date, [string]$tasks) {
        $text = "---`ntype: daily`nstatus: active`ndate: '$date'`n---`n# $date`n`n## Roh`n`n- **08:00** Ich muss Milch kaufen.`n`n## Protokoll`n`n## Aufgaben`n$tasks`n## Morgenbericht`n"
        $p = Join-Path $vault "100-daily\$date.md"
        Write-TestFile $p $text
        return $p
    }
    function Get-Todo([string]$vault) { (Get-Content -LiteralPath (Join-Path $vault '000-meta\todo.md') -Raw -Encoding UTF8) -replace "`r`n", "`n" }
}

AfterAll {
    if ($script:Src -and $script:Src -like '*lifeos-src-*') { Remove-Item -LiteralPath $script:Src -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Move-DailyTasksToTodo' -Skip:$script:notWindows {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('t-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $script:Since = (Get-Date).AddMinutes(-5)
    }

    It 'appends a new task to ## Next with a link to the day, and leaves a line without a checkbox in the daily note' {
        $p = New-DailyWithTasks $script:V '2026-10-25' "- [ ] Milch kaufen`n"
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        (Get-Todo $script:V) | Should -Match "(?s)## Next\n- \[ \] Milch kaufen \(\[\[100-daily/2026-10-25\]\]\)\n\n## Waiting"
        $d = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $d | Should -Match "## Aufgaben\n- Milch kaufen $script:Arrow todo\n"
        $d | Should -Not -Match '\[ \] Milch'
    }

    It 'moves a task made only of punctuation instead of making it disappear' {
        $null = New-DailyWithTasks $script:V '2026-10-25' "- [ ] ?!`n"
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        (Get-Todo $script:V) | Should -Match ([regex]::Escape('- [ ] ?! ([[100-daily/2026-10-25]])'))
    }

    It 'keeps a concrete date as the due marker after the link' {
        $null = New-DailyWithTasks $script:V '2026-10-25' "- [ ] Zahnarzt anrufen $script:Cal 2026-11-03`n"
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        (Get-Todo $script:V) | Should -Match "- \[ \] Zahnarzt anrufen \(\[\[100-daily/2026-10-25\]\]\) $script:Cal 2026-11-03"
    }

    It 'does not add a task twice when the same wording is already open in todo.md' {
        $todo = Join-Path $script:V '000-meta\todo.md'
        $t = (Get-Content -LiteralPath $todo -Raw -Encoding UTF8) -replace '## Now\r?\n', "## Now`n- [ ] milch kaufen ([[100-daily/2026-10-20]])`n"
        Write-TestFile $todo $t
        $p = New-DailyWithTasks $script:V '2026-10-25' "- [ ] Milch kaufen.`n"
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        ([regex]::Matches((Get-Todo $script:V), '(?i)milch kaufen')).Count | Should -Be 1
        (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | Should -Match "Milch kaufen\. $script:Arrow todo"
    }

    It 'adds a task again when the earlier one is already done' {
        $todo = Join-Path $script:V '000-meta\todo.md'
        $t = (Get-Content -LiteralPath $todo -Raw -Encoding UTF8) -replace '## Now\r?\n', "## Now`n- [x] Milch kaufen`n"
        Write-TestFile $todo $t
        $null = New-DailyWithTasks $script:V '2026-10-25' "- [ ] Milch kaufen`n"
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        (Get-Todo $script:V) | Should -Match '- \[ \] Milch kaufen \(\[\[100-daily/2026-10-25\]\]\)'
    }

    It 'leaves ticked tasks and tasks already moved alone' {
        $p = New-DailyWithTasks $script:V '2026-10-25' "- [x] Erledigt`n- Schon drin $script:Arrow todo`n"
        $before = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        $todoBefore = Get-Todo $script:V
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | Should -BeExactly $before
        (Get-Todo $script:V) | Should -BeExactly $todoBefore
    }

    It 'leaves a daily note alone that was not changed since the run began' {
        $p = New-DailyWithTasks $script:V '2026-10-12' "- [ ] Alte Aufgabe`n"
        (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddDays(-10)
        $before = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | Should -BeExactly $before
        (Get-Todo $script:V) | Should -Not -Match 'Alte Aufgabe'
    }

    It 'never touches Roh, Protokoll or Morgenbericht' {
        $p = New-DailyWithTasks $script:V '2026-10-25' "- [ ] Milch kaufen`n"
        $before = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace '(?s)## Aufgaben.*?## Morgenbericht', '## Morgenbericht'
        Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since
        $after = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace '(?s)## Aufgaben.*?## Morgenbericht', '## Morgenbericht'
        $after | Should -BeExactly $before
    }

    It 'keeps the task in the daily note as a checkbox when todo.md has no ## Next (nothing is lost)' {
        Write-TestFile (Join-Path $script:V '000-meta\todo.md') "# Todo`n"
        $p = New-DailyWithTasks $script:V '2026-10-25' "- [ ] Milch kaufen`n"
        { Move-DailyTasksToTodo -VaultPath $script:V -Since $script:Since } | Should -Throw '*## Next*'
        (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | Should -Match '\[ \] Milch kaufen'
    }
}

Describe 'Heute line' -Skip:$script:notWindows {
    BeforeEach {
        $script:V = New-TestVault (Join-Path $script:Work ('h-' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    }

    It 'lists the open tasks of todo.md that are due today or earlier, without link and date marker' {
        $todo = Join-Path $script:V '000-meta\todo.md'
        $add = "- [ ] Zahnarzt anrufen ([[100-daily/2026-10-20]]) $script:Cal 2026-10-25`n- [ ] Steuer $script:Cal 2026-10-01`n- [ ] Später $script:Cal 2026-12-01`n- [x] Fertig $script:Cal 2026-10-25`n- [ ] Ohne Datum`n"
        $t = (Get-Content -LiteralPath $todo -Raw -Encoding UTF8) -replace '## Next\r?\n', ("## Next`n" + $add)
        Write-TestFile $todo $t
        $lines = Get-HintLines -VaultPath $script:V -Today ([datetime]'2026-10-25')
        $lines | Should -Contain 'Heute: Zahnarzt anrufen; Steuer'
    }

    It 'writes no Heute line when nothing is due' {
        $lines = @(Get-HintLines -VaultPath $script:V -Today ([datetime]'2026-10-25'))
        ($lines -join "`n") | Should -Not -Match 'Heute:'
    }
}

Describe 'morning.ps1 moves tasks after the agent (Windows PowerShell 5.1)' -Skip:$script:notWindows {
    It 'moves a task the agent wrote into the daily note to todo.md' {
        $v = New-TestVault (Join-Path $script:Work 'e2e')
        $d = Join-Path $script:Work 'e2e-dev'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        $stub = Join-Path $script:Work 'e2e-stub'; New-Item -ItemType Directory -Force -Path $stub | Out-Null
        $today = (Get-Date).ToString('yyyy-MM-dd')
        # the stub plays the agent: it writes one task into today's daily note
        $note = Join-Path $v "100-daily\$today.md"
        Write-TestFile (Join-Path $stub 'agent.ps1') ("`$p = '$note'`n`$t = [IO.File]::ReadAllText(`$p)`n[IO.File]::WriteAllText(`$p, (`$t -replace '(?m)^## Aufgaben\r?\n', ('## Aufgaben' + [char]10 + '- [ ] Milch kaufen' + [char]10)), (New-Object Text.UTF8Encoding(`$false)))`n")
        Write-TestFile (Join-Path $stub 'claude.cmd') "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0agent.ps1`"`r`necho {`"is_error`":false,`"subtype`":`"success`",`"num_turns`":1,`"total_cost_usd`":0,`"result`":`"stub`"}`r`n"
        $null = New-Daily $v $today "- **08:00** Ich muss Milch kaufen."
        Write-TestFile (Join-Path $v '000-meta\life-os-runs.log') "2026-10-24T07:01:15 | morning | ok | done`n"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') -VaultPath $v -DevRoot $d -ClaudeExe (Join-Path $stub 'claude.cmd') -LogDir (Join-Path $stub 'logs') -LockPath (Join-Path $stub 'l.lock') -TrackerStatePath (Join-Path $stub 'ts.json') -SeenPath (Join-Path $stub 's.json') -SettingsPath (Join-Path $stub 'none.json') | Out-Null
        (Get-Todo $v) | Should -Match "- \[ \] Milch kaufen \(\[\[100-daily/$today\]\]\)"
        (Get-Content -LiteralPath $note -Raw -Encoding UTF8) | Should -Match "- Milch kaufen $script:Arrow todo"
    }

    It 'does not leave the entry that became a task as "Nicht eingetragen (unklar)"' {
        $v = New-TestVault (Join-Path $script:Work 'e2e-unclear')
        $d = Join-Path $script:Work 'e2e-unclear-dev'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        $stub = Join-Path $script:Work 'e2e-unclear-stub'; New-Item -ItemType Directory -Force -Path $stub | Out-Null
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $note = Join-Path $v "100-daily\$today.md"
        # the stub plays the agent: one task and, for the same entry, an "unclear" report line
        $agent = "`$p = '$note'`n`$t = [IO.File]::ReadAllText(`$p)`n" +
            "`$t = `$t -replace '(?m)^## Aufgaben\r?\n', ('## Aufgaben' + [char]10 + '- [ ] Milch kaufen' + [char]10)`n" +
            "`$t = `$t -replace '(?m)^## Morgenbericht\r?\n', ('## Morgenbericht' + [char]10 + '- Nicht eingetragen (unklar): Ich muss Milch kaufen.' + [char]10 + '- Nicht eingetragen (unklar): Vielleicht Urlaub planen' + [char]10)`n" +
            "[IO.File]::WriteAllText(`$p, `$t, (New-Object Text.UTF8Encoding(`$false)))`n"
        Write-TestFile (Join-Path $stub 'agent.ps1') $agent
        Write-TestFile (Join-Path $stub 'claude.cmd') "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0agent.ps1`"`r`necho {`"is_error`":false,`"subtype`":`"success`",`"num_turns`":1,`"total_cost_usd`":0,`"result`":`"stub`"}`r`n"
        $null = New-Daily $v $today "- **08:00** Ich muss Milch kaufen."
        Write-TestFile (Join-Path $v '000-meta\life-os-runs.log') "2026-10-24T07:01:15 | morning | ok | done`n"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Src 'morning.ps1') -VaultPath $v -DevRoot $d -ClaudeExe (Join-Path $stub 'claude.cmd') -LogDir (Join-Path $stub 'logs') -LockPath (Join-Path $stub 'l.lock') -TrackerStatePath (Join-Path $stub 'ts.json') -SeenPath (Join-Path $stub 's.json') -SettingsPath (Join-Path $stub 'none.json') | Out-Null
        $text = Get-Content -LiteralPath $note -Raw -Encoding UTF8
        $text | Should -Not -Match 'unklar\): Ich muss Milch'
        $text | Should -Match 'unklar\): Vielleicht Urlaub planen'
    }
}
