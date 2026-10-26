# morning-checks.ps1 - token-free helpers of the Life OS morning run. Dot-source, do not run.
#
# Everything here is plain file and git work: it decides whether the agent has anything to order,
# and it writes the hint lines of the Morgenbericht that need no language model. The agent starts
# only for work (a transcript, a loose note, a conflict, typed text after the anchor, a project
# hub that is older than its repository); a hint such as "Nicht committet seit 4 Tag(en)" is
# written by Set-MorgenberichtBlock.
# ASCII only (Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page): the one
# non-ASCII word is built with [char].

. "$PSScriptRoot\life-os-common.ps1"

$script:BlockBegin = '<!-- morning.ps1 -->'
$script:BlockEnd = '<!-- /morning.ps1 -->'

# What the morning run really costs. Claude Code's total_cost_usd (the run log's cost=) is NOT
# what DeepSeek bills: it prices the tokens at Anthropic list prices. cost_ds is computed from the
# result's modelUsage instead, one entry per model, each model with its own DeepSeek rates.
# Prices per 1M tokens, the one place they live (read 2026-10-26 from Source). Peak: 01:00-04:00
# and 06:00-10:00 UTC, Monday to Friday (Chinese public holidays are not modelled); every other
# hour is off-peak. Models and Aliases: a model name that is in neither has no known price.
$script:DeepSeekPrices = @{
    Source  = 'https://api-docs.deepseek.com/quick_start/pricing'
    Read    = '2026-10-26'
    Models  = @{
        'deepseek-flash'  = @{
            OffPeak = @{ Hit = 0.003; Miss = 0.15; Output = 0.60 }
            Peak    = @{ Hit = 0.006; Miss = 0.30; Output = 1.20 }
        }
        'deepseek-v4-pro' = @{
            OffPeak = @{ Hit = 0.022; Miss = 0.66; Output = 1.98 }
            Peak    = @{ Hit = 0.044; Miss = 1.32; Output = 3.96 }
        }
    }
    # retired names that DeepSeek still accepts and bills at the Flash price (footnote 1 of the page)
    Aliases = @{
        'deepseek-v4-flash'              = 'deepseek-flash'
        'deepseek-v4-flash-vision-exp'   = 'deepseek-flash'
    }
}

function Get-DeepSeekCost($ModelUsage, [datetime]$AtUtc) {
    # USD rounded to 6 places for the whole run; '' when the result has no modelUsage; 'unknown'
    # when any model in it has no known price (never a guess, never a partial sum). A cache hit is
    # cacheReadInputTokens; everything else sent as input (new and cache-creation tokens) is a miss.
    # The model key may carry a context tag ("deepseek-flash[1m]"), which is not part of the name.
    # The rate (peak or off-peak) is the one of $AtUtc, the end of the run.
    if ($null -eq $ModelUsage) { return '' }
    $entries = @($ModelUsage.PSObject.Properties)
    if ($entries.Count -eq 0) { return '' }
    $t = $AtUtc.ToUniversalTime()
    $hour = $t.Hour
    $weekday = $t.DayOfWeek -ne [DayOfWeek]::Saturday -and $t.DayOfWeek -ne [DayOfWeek]::Sunday
    $peak = $weekday -and (($hour -ge 1 -and $hour -lt 4) -or ($hour -ge 6 -and $hour -lt 10))
    $usd = 0.0
    foreach ($entry in $entries) {
        $name = ([regex]::Replace([string]$entry.Name, '\[[^\]]*\]\s*$', '')).Trim().ToLowerInvariant()
        if ($script:DeepSeekPrices.Aliases.ContainsKey($name)) { $name = $script:DeepSeekPrices.Aliases[$name] }
        if (-not $script:DeepSeekPrices.Models.ContainsKey($name)) { return 'unknown' }
        $model = $script:DeepSeekPrices.Models[$name]
        if ($peak) { $p = $model.Peak } else { $p = $model.OffPeak }
        $u = $entry.Value
        $hit = [double]$u.cacheReadInputTokens
        $miss = [double]$u.inputTokens + [double]$u.cacheCreationInputTokens
        $out = [double]$u.outputTokens
        $usd += ($hit * $p.Hit + $miss * $p.Miss + $out * $p.Output) / 1000000
    }
    return [math]::Round($usd, 6)
}

function Read-JsonFile([string]$path) {
    # $null when the file does not exist; an exception when it exists but is not valid JSON.
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Get-Items($value) {
    # An empty JSON array and a missing property both come back as an empty array.
    # The comma keeps a one-element array an array when it leaves the function (Windows
    # PowerShell 5.1 unrolls it, and a lone object has no Count there).
    return , @($value | Where-Object { $null -ne $_ })
}

function Get-FrontmatterValue([string]$text, [string]$key) {
    $m = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return $null }
    foreach ($line in ($m.Groups[1].Value -split '\r?\n')) {
        if ($line -match ('^' + [regex]::Escape($key) + '\s*:\s*(.*?)\s*$')) {
            return $Matches[1].Trim().Trim("'").Trim('"')
        }
    }
    return $null
}

function Get-FrontmatterList([string]$text, [string]$key) {
    # A frontmatter list as an array of strings: inline [a, b], a single value, or a block of "- x" lines.
    $m = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return , @() }
    $lines = @($m.Groups[1].Value -split '\r?\n')
    $out = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch ('^' + [regex]::Escape($key) + '\s*:\s*(.*?)\s*$')) { continue }
        $rest = $Matches[1]
        if ($rest -match '^\[(.*)\]$') {
            $out = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
        } elseif ($rest) {
            $out = @($rest.Trim("'").Trim('"'))
        } else {
            for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s*-\s+(.*?)\s*$'; $j++) {
                $out += $Matches[1].Trim("'").Trim('"')
            }
        }
        break
    }
    return , @($out)
}

function Write-AreasJson {
    # 000-meta/life-os-areas.json: every note under 300-areas with its file name and aliases.
    # Names only - the agent gets no content from here, it reads the notes it needs itself.
    param([string]$VaultPath)
    $dir = Join-Path $VaultPath '300-areas'
    $areas = @()
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse | Sort-Object FullName)) {
            $rel = $f.FullName.Substring($VaultPath.TrimEnd('\').Length + 1) -replace '\\', '/'
            $aliases = Get-FrontmatterList ([IO.File]::ReadAllText($f.FullName)) 'aliases'
            $areas += [pscustomobject]@{ file = [IO.Path]::GetFileNameWithoutExtension($f.Name); path = $rel; aliases = @($aliases) }
        }
    }
    $obj = [pscustomobject]@{ generated = (Get-Date).ToString('s'); areas = @($areas) }
    Write-Utf8 (Join-Path $VaultPath '000-meta\life-os-areas.json') ($obj | ConvertTo-Json -Depth 5)
}

function New-AreaSnapshot {
    # A copy of every note under 300-areas as it stands BEFORE the agent runs. The safety net
    # compares with this copy and restores from it, so a hand edit of the owner that is not
    # committed yet can never be mistaken for an agent change and thrown away.
    param([string]$VaultPath, [string]$SnapshotDir)
    $dir = Join-Path $VaultPath '300-areas'
    if (Test-Path -LiteralPath $SnapshotDir) {
        Get-ChildItem -LiteralPath $SnapshotDir -File -Recurse | Remove-Item -Force
    } else {
        New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse)) {
        $rel = $f.FullName.Substring($dir.TrimEnd('\').Length + 1)
        $target = Join-Path $SnapshotDir $rel
        $td = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Force -Path $td | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
    }
}

function Get-RohLastLine([string]$text) {
    # The last non-blank line of the "## Roh" section, or $null when the section is empty.
    $lines = $text -split '\r?\n'
    $inside = $false
    $last = $null
    foreach ($line in $lines) {
        if ($line -match '^## Roh\s*$') { $inside = $true; continue }
        if ($inside -and $line -match '^## ') { break }
        if ($inside -and $line.Trim()) { $last = $line }
    }
    return $last
}

function Get-LastMorningRun([string]$vault) {
    $runsLog = Join-Path $vault '000-meta\life-os-runs.log'
    if (-not (Test-Path -LiteralPath $runsLog)) { return $null }
    $last = $null
    # Only a run that finished (ok, skip) moves the mark: after a failed run, the Roh lines it
    # copied in before the agent died are still unordered.
    foreach ($line in @(Get-Content -LiteralPath $runsLog -Encoding UTF8 | Select-Object -Last 15)) {
        if ($line -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}) \| morning \| (ok|skip) \|') { $last = [datetime]$Matches[1] }
    }
    return $last
}

function Get-InboxScan {
    # Loose files directly in inbox/ (no subfolders: inbox/audio stays with the transcriber)
    # that were last changed at least $MinAgeMinutes ago - a younger file may still be open on
    # the phone. .md and .txt are notes; any other file is only named.
    param([string]$VaultPath, [int]$MinAgeMinutes = 10, [datetime]$Now = (Get-Date))
    $notes = @()
    $other = @()
    $dir = Join-Path $VaultPath 'inbox'
    if (Test-Path -LiteralPath $dir) {
        $limit = $Now.AddMinutes(-$MinAgeMinutes)
        $skipAttr = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
        foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Force | Sort-Object Name)) {
            if ($f.Attributes -band $skipAttr) { continue }
            if ($f.Name.StartsWith('~syncthing~') -or $f.Name.StartsWith('.syncthing.')) { continue }
            if ($f.LastWriteTime -gt $limit) { continue }
            $ext = $f.Extension.ToLowerInvariant()
            if ($ext -eq '.md' -or $ext -eq '.txt') {
                $text = [IO.File]::ReadAllText($f.FullName)
                $notes += [pscustomobject]@{ file = $f.Name; modified = $f.LastWriteTime.ToString('s'); chars = $text.Length }
            } else {
                $other += [pscustomobject]@{ file = $f.Name; bytes = $f.Length }
            }
        }
    }
    return [pscustomobject]@{ notes = $notes; other = $other }
}

function Update-InboxJson {
    # Adds the keys notes and other to 000-meta/life-os-inbox.json (written before by the
    # transcriber with the key transcripts, which stays as it is).
    param([string]$VaultPath, [int]$MinAgeMinutes = 10)
    $path = Join-Path $VaultPath '000-meta\life-os-inbox.json'
    $obj = $null
    try { $obj = Read-JsonFile $path } catch { $obj = $null }
    if (-not $obj) { $obj = [pscustomobject]@{ generated = (Get-Date).ToString('s'); transcripts = @() } }
    $scan = Get-InboxScan -VaultPath $VaultPath -MinAgeMinutes $MinAgeMinutes
    $obj | Add-Member -NotePropertyName notes -NotePropertyValue @($scan.notes) -Force
    $obj | Add-Member -NotePropertyName other -NotePropertyValue @($scan.other) -Force
    Write-Utf8 $path ($obj | ConvertTo-Json -Depth 6)
}

function Initialize-DailyNote([string]$vault, [string]$date) {
    # Returns the path of 100-daily/<date>.md, created from the vault template when missing.
    $note = Join-Path $vault ('100-daily\' + $date + '.md')
    if (-not (Test-Path -LiteralPath $note)) {
        $tpl = Join-Path $vault '000-meta\templates\daily.md'
        if (-not (Test-Path -LiteralPath $tpl)) { throw 'daily template missing' }
        Write-Utf8 $note (([IO.File]::ReadAllText($tpl)) -replace '\{\{date\}\}', $date)
    }
    return $note
}

function Add-InboxNotesToRoh {
    # Takes every loose note of inbox/ (see Get-InboxScan) verbatim into the end of "## Roh" of
    # its change day as "- **HH:MM (Notiz: <file>)** <text>", then queues the file in
    # 000-meta/trash-queue.txt (the cleanup moves it to trash/; nothing is ever deleted here).
    # A script copies exactly; measured 2026-10-25: the agent, asked to copy a 60,000-character
    # note, invented one line and dropped another (vault rule 14: never invent or delete).
    # The only changes to the text: Markdown images become their alt text (vault rule 5), and a
    # line that starts like a heading gets a backslash so it cannot split the note.
    param([string]$VaultPath, [int]$MinAgeMinutes = 10)
    $scan = Get-InboxScan -VaultPath $VaultPath -MinAgeMinutes $MinAgeMinutes
    $queue = Join-Path $VaultPath '000-meta\trash-queue.txt'
    $taken = @()
    foreach ($n in $scan.notes) {
        $mod = [datetime]$n.modified
        $date = $mod.ToString('yyyy-MM-dd')
        $time = $mod.ToString('HH:mm')
        $file = [string]$n.file
        $text = [IO.File]::ReadAllText((Join-Path $VaultPath ('inbox\' + $file)))
        $text = ($text -replace "`r`n", "`n" -replace "`r", "`n").Trim("`n", ' ', "`t")
        $text = [regex]::Replace($text, '!\[([^\]]*)\]\([^)]*\)', '$1')
        $text = [regex]::Replace($text, '(?m)^(#{1,6})(?=\s)', '\$1')
        if ($text) {
            $daily = Initialize-DailyNote $VaultPath $date
            $old = [IO.File]::ReadAllText($daily)
            $nl = "`n"; if ($old.Contains("`r`n")) { $nl = "`r`n" }
            $words = @($text -split '\s+' | Select-Object -First 8) -join ' '
            $dup = $false
            foreach ($m in [regex]::Matches($old, '(?m)^- \*\*' + $time + ' \(Notiz: ' + [regex]::Escape($file) + '\)\*\* (.*)$')) {
                $oldWords = @(($m.Groups[1].Value.TrimEnd("`r")) -split '\s+' | Select-Object -First 8) -join ' '
                if ($oldWords -eq $words) { $dup = $true }
            }
            if (-not $dup) {
                $entry = '- **' + $time + ' (Notiz: ' + $file + ')** ' + ($text -replace "`n", $nl)
                $h = [regex]::Match($old, '(?m)^## Roh[ \t]*\r?$')
                if (-not $h.Success) { throw ('no "## Roh" section in ' + $daily) }
                $after = $h.Index + $h.Length
                $next = [regex]::Match($old.Substring($after), '(?m)^## ')
                $end = $old.Length
                if ($next.Success) { $end = $after + $next.Index }
                $body = $old.Substring($after, $end - $after).TrimEnd()
                $rest = $old.Substring($end)
                $gap = ''; if (-not $body.Trim()) { $gap = $nl; $body = '' }
                $new = $old.Substring(0, $after) + $body + $nl + $gap + $entry + $nl
                if ($rest) { $new += $nl + $rest }
                Write-Utf8 $daily $new
                $check = ([IO.File]::ReadAllText($daily)) -replace "`r`n", "`n"
                if (-not $check.Contains(($entry -replace "`r`n", "`n"))) { throw ('read-back check failed for ' + $file) }
            }
        }
        $line = 'inbox/' + $file
        $queued = @()
        if (Test-Path -LiteralPath $queue) { $queued = @(Get-Content -LiteralPath $queue -Encoding UTF8) }
        if ($queued -notcontains $line) { Append-Utf8 $queue ($line + "`n") }
        $taken += $file
    }
    return , @($taken)
}

function Get-TaskKey([string]$text) {
    # The wording of a task for the duplicate check: no link, no due marker, no case, no punctuation.
    $cal = [char]::ConvertFromUtf32(0x1F4C5)
    $t = [regex]::Replace($text, '\(\[\[[^\]]*\]\]\)', ' ')
    $t = [regex]::Replace($t, [regex]::Escape($cal) + '\s*\d{4}-\d{2}-\d{2}', ' ')
    $t = [regex]::Replace($t.ToLowerInvariant(), '[\p{P}\p{S}]+', ' ')
    return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function Move-DailyTasksToTodo {
    # One task list: every new "- [ ] task" that the agent wrote under "## Aufgaben" of a daily
    # note changed since $Since is appended to "## Next" of 000-meta/todo.md as
    # "- [ ] task ([[100-daily/<date>]]) <due marker>", and the daily line becomes
    # "- task -> todo" (no checkbox, so there is one box to tick). A task whose wording is
    # already an open task in todo.md is not added again. Append only: nothing in todo.md is
    # ticked, removed or reordered. todo.md is written first, so a crash in between is repaired
    # by the duplicate check on the next run.
    param([string]$VaultPath, [datetime]$Since)
    $cal = [char]::ConvertFromUtf32(0x1F4C5)
    $arrow = [string][char]0x2192
    $todoPath = Join-Path $VaultPath '000-meta\todo.md'
    $dailyDir = Join-Path $VaultPath '100-daily'
    if (-not (Test-Path -LiteralPath $todoPath) -or -not (Test-Path -LiteralPath $dailyDir)) { return }
    $todo = [IO.File]::ReadAllText($todoPath)
    $nl = "`n"; if ($todo.Contains("`r`n")) { $nl = "`r`n" }
    $keys = @{}
    foreach ($m in [regex]::Matches($todo, '(?m)^\s*- \[ \] (.*)$')) { $keys[(Get-TaskKey $m.Groups[1].Value)] = $true }

    $script:__newLines = @()
    $script:__changed = $false
    $rewrites = @()
    foreach ($f in (Get-ChildItem -LiteralPath $dailyDir -Filter '*.md' -File)) {
        if ($f.LastWriteTime -lt $Since) { continue }
        $date = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $text = [IO.File]::ReadAllText($f.FullName)
        $h = [regex]::Match($text, '(?m)^## Aufgaben[ \t]*\r?$')
        if (-not $h.Success) { continue }
        $after = $h.Index + $h.Length
        $next = [regex]::Match($text.Substring($after), '(?m)^## ')
        $end = $text.Length
        if ($next.Success) { $end = $after + $next.Index }
        $section = $text.Substring($after, $end - $after)
        $changed = $false
        $section = [regex]::Replace($section, '(?m)^([ \t]*)- \[ \] (.+?)[ \t]*(\r?)$', {
            param($m)
            $task = $m.Groups[2].Value
            $key = Get-TaskKey $task
            if (-not $key) { $key = $task.Trim().ToLowerInvariant() }
            if ($key -and -not $keys.ContainsKey($key)) {
                $keys[$key] = $true
                $due = ''
                $dm = [regex]::Match($task, [regex]::Escape($cal) + '\s*(\d{4}-\d{2}-\d{2})')
                $desc = $task
                if ($dm.Success) { $due = ' ' + $cal + ' ' + $dm.Groups[1].Value; $desc = ($task.Remove($dm.Index, $dm.Length)).Trim() }
                $script:__newLines += ('- [ ] ' + $desc + ' ([[100-daily/' + $date + ']])' + $due)
            }
            $script:__changed = $true
            return $m.Groups[1].Value + '- ' + $task + ' ' + $arrow + ' todo' + $m.Groups[3].Value
        })
        if ($script:__changed) { $rewrites += [pscustomobject]@{ path = $f.FullName; text = $text.Substring(0, $after) + $section + $text.Substring($end) } }
        $script:__changed = $false
    }
    $newLines = @($script:__newLines)
    $script:__newLines = @()

    if ($newLines.Count -gt 0) {
        $nh = [regex]::Match($todo, '(?m)^## Next[ \t]*\r?$')
        if (-not $nh.Success) { throw 'no "## Next" section in todo.md' }
        $after = $nh.Index + $nh.Length
        $nx = [regex]::Match($todo.Substring($after), '(?m)^## ')
        $end = $todo.Length
        if ($nx.Success) { $end = $after + $nx.Index }
        $body = $todo.Substring($after, $end - $after).TrimEnd()
        $rest = $todo.Substring($end)
        $new = $todo.Substring(0, $after) + $body + $nl + ($newLines -join $nl) + $nl
        if ($rest) { $new += $nl + $rest }
        Write-Utf8 $todoPath $new
    }
    foreach ($r in $rewrites) { Write-Utf8 $r.path $r.text }
}

function Get-DueTaskLine([string]$vault, [datetime]$today) {
    # "Heute: a; b" - the open tasks of todo.md whose due marker is today or earlier.
    $todoPath = Join-Path $vault '000-meta\todo.md'
    if (-not (Test-Path -LiteralPath $todoPath)) { return $null }
    $cal = [char]::ConvertFromUtf32(0x1F4C5)
    $due = @()
    foreach ($line in ([IO.File]::ReadAllText($todoPath) -split '\r?\n')) {
        if ($line -notmatch '^\s*- \[ \] (.*)$') { continue }
        $task = $Matches[1]
        $dm = [regex]::Match($task, [regex]::Escape($cal) + '\s*(\d{4}-\d{2}-\d{2})')
        if (-not $dm.Success) { continue }
        if ([datetime]$dm.Groups[1].Value -gt $today.Date) { continue }
        $desc = [regex]::Replace($task, '\(\[\[[^\]]*\]\]\)', ' ')
        $desc = [regex]::Replace($desc, [regex]::Escape($cal) + '\s*\d{4}-\d{2}-\d{2}', ' ')
        $due += ([regex]::Replace($desc, '\s+', ' ')).Trim()
    }
    if ($due.Count -eq 0) { return $null }
    return ('Heute: ' + ($due -join '; '))
}

function Save-VaultCommit {
    # One commit per run for what the morning run may have changed (daily notes, project hubs,
    # area notes, 000-meta), so every automatic change can be undone with git. Other folders and
    # other staged files are not part of it. Never pushes: Obsidian Git does that.
    param([string]$VaultPath, [string]$Message)
    if (-not (Test-Path -LiteralPath (Join-Path $VaultPath '.git'))) { return 'no git repository - nothing committed' }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @('100-daily', '200-projects', '300-areas', '000-meta') | Where-Object { Test-Path -LiteralPath (Join-Path $VaultPath $_) }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & git -C $VaultPath add -- @paths 2>&1
        $files = @(& git -C $VaultPath -c core.quotepath=off diff --cached --name-only -- @paths 2>$null | Where-Object { $_ })
        if ($files.Count -eq 0) { return 'nothing to commit' }
        $out = & git -C $VaultPath commit -q -m $Message -- @files 2>&1
        if ($LASTEXITCODE -ne 0) {
            $first = (@($out) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() } | Select-Object -First 1)
            return ('commit failed: ' + $first)
        }
        $hash = (& git -C $VaultPath rev-parse --short HEAD 2>$null)
        return ('committed ' + $hash)
    } finally { $ErrorActionPreference = $prev }
}

function Save-InboxSeen {
    # Remembers which other files the Morgenbericht has named, so a forgotten photo starts the
    # agent once, not every day (the hint line stays). Kept outside the vault, like the lock.
    param([string]$VaultPath, [string]$SeenPath)
    if (-not $SeenPath) { return }
    $inbox = $null
    try { $inbox = Read-JsonFile (Join-Path $VaultPath '000-meta\life-os-inbox.json') } catch { return }
    $others = Get-Items $inbox.other
    $files = @(foreach ($o in $others) { [string]$o.file + '|' + [string]$o.bytes })
    Write-Utf8 $SeenPath ([pscustomobject]@{ files = $files } | ConvertTo-Json -Depth 3)
}

function Get-HubStaleNames([string]$vault, [string]$devRoot, $flag) {
    # Projects of the tracker flag whose hub exists but was last written by a model before the
    # newest commit of the repository or the last change of its PROGRESS.md.
    $stale = @()
    foreach ($p in (Get-Items $flag.projects)) {
        $name = [string]$p.name
        if (-not $name) { continue }
        $hub = Join-Path $vault ('200-projects\' + $name + '.md')
        $repo = Join-Path $devRoot $name
        if (-not (Test-Path -LiteralPath $hub) -or -not (Test-Path -LiteralPath $repo)) { continue }
        $written = $null
        $w = Get-FrontmatterValue ([IO.File]::ReadAllText($hub)) 'hub_written'
        if ($w) { try { $written = [datetime]::Parse($w, [Globalization.CultureInfo]::InvariantCulture) } catch { $written = $null } }
        $newest = $null
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $ct = & git --no-optional-locks -C $repo log -1 --format=%cI 2>$null
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
        if ($code -eq 0 -and $ct) { try { $newest = ([datetimeoffset]::Parse([string]$ct, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { $newest = $null } }
        $progress = Join-Path $repo 'PROGRESS.md'
        if (Test-Path -LiteralPath $progress) {
            $pm = (Get-Item -LiteralPath $progress).LastWriteTime
            if ($null -eq $newest -or $pm -gt $newest) { $newest = $pm }
        }
        if ($null -eq $written) { $stale += $name; continue }
        if ($null -ne $newest -and $written -lt $newest) { $stale += $name }
    }
    return $stale
}

function Get-AreaStaleness {
    # Weekly check without a language model: per area, is there a document in the archive that is
    # newer than the newest Timeline date of the area note? Only file NAMES are read (the date at
    # their end), never content. The mapping area -> archive folder is the folder the note names
    # in backticks (`600-archive/...`). It is used only where it is unambiguous: a folder that
    # another area also names, or that encloses a folder of another area, is skipped.
    param([string]$VaultPath)
    $dir = Join-Path $VaultPath '300-areas'
    $archive = Join-Path $VaultPath '600-archive'
    $found = @()
    if (-not (Test-Path -LiteralPath $dir) -or -not (Test-Path -LiteralPath $archive)) { return @() }
    $areas = @()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse | Sort-Object FullName)) {
        $text = [IO.File]::ReadAllText($f.FullName)
        $folders = @()
        foreach ($m in [regex]::Matches($text, '`600-archive/([^`]+?)/?`')) { $folders += $m.Groups[1].Value.Trim('/').ToLower() }
        $tl = [regex]::Match($text, '(?s)(?:^|\n)## Timeline[^\n]*\n(.*?)(?=\n## |\z)')
        $noteDate = $null
        if ($tl.Success) {
            $dates = @([regex]::Matches($tl.Groups[1].Value, '(?m)^- (\d{4}-\d{2}-\d{2})') | ForEach-Object { $_.Groups[1].Value })
            if ($dates.Count -gt 0) { $noteDate = ($dates | Sort-Object | Select-Object -Last 1) }
        }
        $areas += [pscustomobject]@{ file = [IO.Path]::GetFileNameWithoutExtension($f.Name); folders = @($folders | Select-Object -Unique); note_date = $noteDate }
    }
    foreach ($a in $areas) {
        if (-not $a.note_date) { continue }
        $newest = $null
        foreach ($folder in $a.folders) {
            $ambiguous = $false
            foreach ($b in $areas) {
                if ($b.file -eq $a.file) { continue }
                foreach ($g in $b.folders) {
                    if ($g -eq $folder -or $g.StartsWith($folder + '/')) { $ambiguous = $true }
                }
            }
            if ($ambiguous) { continue }
            $path = Join-Path $archive ($folder -replace '/', '\')
            if (-not (Test-Path -LiteralPath $path)) { continue }
            foreach ($n in (Get-ChildItem -LiteralPath $path -Filter '*.md' -File -Name)) {
                if ($n -match '_(\d{4}-\d{2}-\d{2})\.md$') {
                    if ($null -eq $newest -or $Matches[1] -gt $newest) { $newest = $Matches[1] }
                }
            }
        }
        if ($newest -and $newest -gt $a.note_date) {
            $found += [pscustomobject]@{ file = $a.file; note_date = $a.note_date; newest_document = $newest }
        }
    }
    return @($found)
}

function Update-AreasStale {
    # Monday job of morning.ps1: writes 000-meta/life-os-areas-stale.json (area names and two
    # dates, nothing else). Get-HintLines turns it into one Morgenbericht line on the day it was
    # written.
    param([string]$VaultPath)
    $found = @(Get-AreaStaleness -VaultPath $VaultPath)
    $obj = [pscustomobject]@{ generated = (Get-Date).ToString('s'); areas = @($found) }
    Write-Utf8 (Join-Path $VaultPath '000-meta\life-os-areas-stale.json') ($obj | ConvertTo-Json -Depth 5)
}

function Set-FlagHubStale {
    # Tells the agent which hubs to catch up: the names from the "hub-stale: <name>" reasons go
    # into life-os-projects.json as "hub_stale". A flag file that is not there is not created.
    param([string]$VaultPath, [string[]]$Reasons)
    $names = @($Reasons | Where-Object { $_ -match '^hub-stale: ' } | ForEach-Object { $_.Substring(11) })
    if ($names.Count -eq 0) { return }
    $path = Join-Path $VaultPath '000-meta\life-os-projects.json'
    $flag = Read-JsonFile $path
    if ($null -eq $flag) { return }
    $flag | Add-Member -NotePropertyName hub_stale -NotePropertyValue $names -Force
    Write-Utf8 $path ($flag | ConvertTo-Json -Depth 8)
}

function Get-AgentReasons {
    # Returns the reasons why the agent has to start; an empty list means: nothing to order.
    param(
        [string]$VaultPath,
        [string]$DevRoot = '{{DEV}}\Projects',
        [string]$SeenPath = ''
    )
    $reasons = New-Object System.Collections.ArrayList
    $meta = Join-Path $VaultPath '000-meta'

    try {
        $inbox = Read-JsonFile (Join-Path $meta 'life-os-inbox.json')
        if ($inbox) {
            $n = (Get-Items $inbox.transcripts).Count
            if ($n -gt 0) { [void]$reasons.Add('transcripts: ' + $n) }
            $n = (Get-Items $inbox.notes).Count
            if ($n -gt 0) { [void]$reasons.Add('notes: ' + $n) }
            $other = Get-Items $inbox.other
            if ($other.Count -gt 0) {
                $seen = @()
                if ($SeenPath) {
                    $s = $null
                    try { $s = Read-JsonFile $SeenPath } catch { $s = $null }
                    if ($s) { $seen = Get-Items $s.files }
                }
                $new = @($other | Where-Object { ($_.file + '|' + $_.bytes) -notin $seen })
                if ($new.Count -gt 0) { [void]$reasons.Add('other files: ' + $new.Count) }
            }
        }
    } catch { [void]$reasons.Add('unreadable: life-os-inbox.json (' + $_.Exception.Message + ')') }

    try {
        $c = Read-JsonFile (Join-Path $meta 'life-os-conflicts.json')
        if ($c) {
            $n = (Get-Items $c.conflicts).Count
            if ($n -gt 0) { [void]$reasons.Add('conflicts: ' + $n) }
        }
    } catch { [void]$reasons.Add('unreadable: life-os-conflicts.json (' + $_.Exception.Message + ')') }

    try {
        $flag = Read-JsonFile (Join-Path $meta 'life-os-projects.json')
        if ($flag) {
            foreach ($name in (Get-HubStaleNames $VaultPath $DevRoot $flag)) { [void]$reasons.Add('hub-stale: ' + $name) }
        }
    } catch { [void]$reasons.Add('unreadable: life-os-projects.json (' + $_.Exception.Message + ')') }

    try {
        $state = Read-JsonFile (Join-Path $meta 'life-os-state.json')
        $lastRun = Get-LastMorningRun $VaultPath
        $dailyDir = Join-Path $VaultPath '100-daily'
        if (Test-Path -LiteralPath $dailyDir) {
            foreach ($f in (Get-ChildItem -LiteralPath $dailyDir -Filter '*.md' -File)) {
                if ($null -ne $lastRun -and $f.LastWriteTime -le $lastRun) { continue }
                $date = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                $last = Get-RohLastLine ([IO.File]::ReadAllText($f.FullName))
                if ($null -eq $last) { continue }
                $anchor = $null
                if ($state -and $state.notes -and $state.notes.PSObject.Properties[$date]) { $anchor = [string]$state.notes.$date.roh_anchor }
                $head = $last; if ($head.Length -gt 120) { $head = $head.Substring(0, 120) }
                if ($null -eq $anchor -or $anchor.TrimEnd() -ne $head.TrimEnd()) { [void]$reasons.Add('roh: ' + $date) }
            }
        }
    } catch { [void]$reasons.Add('unreadable: daily notes (' + $_.Exception.Message + ')') }

    return @($reasons)
}

function Get-HintLines {
    # The Morgenbericht lines that need no language model, in the fixed formats of the skill.
    param([string]$VaultPath, [datetime]$Today = (Get-Date))
    $lines = New-Object System.Collections.ArrayList
    $meta = Join-Path $VaultPath '000-meta'
    $ss = [string][char]0x00DF

    $flag = $null
    try { $flag = Read-JsonFile (Join-Path $meta 'life-os-projects.json') } catch { [void]$lines.Add('Hinweisdatei life-os-projects.json nicht lesbar: ' + $_.Exception.Message) }
    if ($flag) {
        $attention = Get-Items $flag.attention
        $unpushed = @($attention | Where-Object { [int]$_.unpushed -gt 0 } | ForEach-Object { [string]$_.name + ' (' + [int]$_.unpushed + ' Commit(s))' })
        if ($unpushed.Count -gt 0) { [void]$lines.Add('Nicht gepusht: ' + ($unpushed -join '; ')) }
        foreach ($a in ($attention | Where-Object { $_.uncommitted -eq $true })) {
            if ([int]$a.dirty_days -gt 0) { [void]$lines.Add('Nicht committet seit ' + [int]$a.dirty_days + ' Tag(en): ' + $a.name) }
            else { [void]$lines.Add('Nicht committet: ' + $a.name) }
        }
        foreach ($a in ($attention | Where-Object { $_.no_upstream -eq $true })) { [void]$lines.Add('Kein Upstream: ' + $a.name) }
        foreach ($e in (Get-Items $flag.git_errors)) { [void]$lines.Add('Git-Fehler: ' + $e.name + ' (' + $e.error + ')') }
        foreach ($f in (Get-Items $flag.large_files)) {
            [void]$lines.Add('Gro' + $ss + 'e Datei im Backup (au' + $ss + 'erhalb media\raw): ' + $f.path + ' (' + $f.size_gb + ' GB)')
        }
        foreach ($p in (Get-Items $flag.projects)) { if ($p.note_missing -eq $true) { [void]$lines.Add('Projekt ohne Notiz: ' + $p.name) } }
        $noGit = Get-Items $flag.no_git
        if ($noGit.Count -gt 0) { [void]$lines.Add('Projektordner ohne Git: ' + ($noGit -join ', ')) }
        $missing = Get-Items $flag.missing
        if ($missing.Count -gt 0) { [void]$lines.Add('Projekt verschwunden: ' + ($missing -join ', ')) }
        if ($flag.media_raw_total_gb -and [double]$flag.media_raw_total_gb -gt 0) { [void]$lines.Add('media\raw gesamt: ' + $flag.media_raw_total_gb + ' GB') }
    }

    try {
        $dueLine = Get-DueTaskLine $VaultPath $Today
        if ($dueLine) { [void]$lines.Add($dueLine) }
    } catch { }

    try {
        $inboxNow = Read-JsonFile (Join-Path $meta 'life-os-inbox.json')
        if ($inboxNow) { foreach ($o in (Get-Items $inboxNow.other)) { [void]$lines.Add('Nicht verarbeitet: ' + $o.file) } }
    } catch { }

    try {
        $exp = Read-JsonFile (Join-Path $meta 'life-os-expiry.json')
        $items = Get-Items $exp
        if ($items.Count -gt 0) {
            [void]$lines.Add('Ablaufend: ' + (($items | ForEach-Object { [string]$_.file + ' am ' + [string]$_.valid_until }) -join '; '))
        }
    } catch { }

    try {
        # weekly (Monday) hint; the file is from the run that wrote it, so other days stay quiet
        $stale = Read-JsonFile (Join-Path $meta 'life-os-areas-stale.json')
        $staleDay = ''
        if ($stale -and $stale.generated) { $staleDay = ([datetime]$stale.generated).ToString('yyyy-MM-dd') }
        if ($staleDay -eq $Today.ToString('yyyy-MM-dd')) {
            $staleItems = Get-Items $stale.areas
            $names = @($staleItems | ForEach-Object { [string]$_.file })
            if ($names.Count -gt 0) { [void]$lines.Add('Neuere Dokumente als die Notiz: ' + ($names -join ', ')) }
        }
    } catch { }

    try {
        $tr = Read-JsonFile (Join-Path $meta 'life-os-transcribe.json')
        if ($tr -and [int]$tr.local_fallback -gt 0) {
            [void]$lines.Add('Transkription: lokaler Fallback (' + ((Get-Items $tr.fallback_reasons_de) -join '; ') + ')')
        }
    } catch { }

    $runsLog = Join-Path $meta 'life-os-runs.log'
    if (Test-Path -LiteralPath $runsLog) {
        $dates = @($Today.ToString('yyyy-MM-dd'), $Today.AddDays(-1).ToString('yyyy-MM-dd'))
        foreach ($l in @(Get-Content -LiteralPath $runsLog -Encoding UTF8 | Select-Object -Last 200)) {
            if ($l -match '^(\d{4}-\d{2}-\d{2})T(\S+) \| (\w+) \| (fail|warn) \| (.*)$' -and ($dates -contains $Matches[1])) {
                [void]$lines.Add('Lauf-Meldung (' + $Matches[4] + '): ' + $Matches[1] + ' ' + $Matches[2] + ' ' + $Matches[3] + ' - ' + $Matches[5])
            }
        }
    }
    return @($lines)
}

function Get-HintLabel([string]$line) {
    # "Nicht committet seit 4 Tag(en): proj" -> "nicht committet seit # tag(en)". The text after the
    # first colon is left out, so the same hint with another count or name counts as the same hint.
    $t = ([string]$line).Trim()
    $i = $t.IndexOf(':')
    if ($i -gt 0 -and $i -le 60) { $t = $t.Substring(0, $i) }
    return ([regex]::Replace($t.ToLowerInvariant(), '\d+', '#'))
}

function Remove-ResolvedUnclearLines {
    # An entry that became a task is not "unclear": drops "Nicht eingetragen (unklar): <entry>" from
    # "## Morgenbericht" of every daily note changed since $Since when the entry holds the wording of
    # a task in that note's "## Aufgaben" (see Get-TaskKey). Nothing else in the note is touched.
    param([string]$VaultPath, [datetime]$Since)
    $arrow = [string][char]0x2192
    $dailyDir = Join-Path $VaultPath '100-daily'
    if (-not (Test-Path -LiteralPath $dailyDir)) { return }
    foreach ($f in (Get-ChildItem -LiteralPath $dailyDir -Filter '*.md' -File)) {
        if ($f.LastWriteTime -lt $Since) { continue }
        $text = [IO.File]::ReadAllText($f.FullName)
        $a = [regex]::Match($text, '(?m)^## Aufgaben[ \t]*\r?$')
        $m = [regex]::Match($text, '(?m)^## Morgenbericht[ \t]*\r?$')
        if (-not $a.Success -or -not $m.Success) { continue }
        $aEnd = $text.Length
        $aNext = [regex]::Match($text.Substring($a.Index + $a.Length), '(?m)^## ')
        if ($aNext.Success) { $aEnd = $a.Index + $a.Length + $aNext.Index }
        $taskKeys = @()
        foreach ($tm in [regex]::Matches($text.Substring($a.Index + $a.Length, $aEnd - $a.Index - $a.Length), '(?m)^\s*- (.+?) ' + [regex]::Escape($arrow) + ' todo\s*$')) {
            $k = Get-TaskKey $tm.Groups[1].Value
            if ($k) { $taskKeys += $k }
        }
        if ($taskKeys.Count -eq 0) { continue }
        $after = $m.Index + $m.Length
        $end = $text.Length
        $next = [regex]::Match($text.Substring($after), '(?m)^## ')
        if ($next.Success) { $end = $after + $next.Index }
        $section = $text.Substring($after, $end - $after)
        $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
        $changed = $false
        $kept = @(foreach ($l in ($section -split '\r?\n')) {
            $um = [regex]::Match([string]$l, '^\s*- Nicht eingetragen \(unklar\): (.+?)\s*$')
            if ($um.Success) {
                $ek = ' ' + (Get-TaskKey $um.Groups[1].Value) + ' '
                $hit = $false
                foreach ($k in $taskKeys) { if ($ek.Contains(' ' + $k + ' ')) { $hit = $true } }
                if ($hit) { $changed = $true; continue }
            }
            $l
        })
        if ($changed) {
            $new = $text.Substring(0, $after) + ($kept -join $nl) + $text.Substring($end)
            Write-Utf8 $f.FullName $new
        }
    }
}

function Set-MorgenberichtBlock {
    # Writes (or replaces, or removes) the script's own block at the end of "## Morgenbericht" of
    # one daily note. Nothing else in the note is touched. No lines and no note: nothing is created.
    param([string]$VaultPath, [string]$Date, [string[]]$Lines = @())
    $note = Join-Path $VaultPath ('100-daily\' + $Date + '.md')
    $Lines = @($Lines | Where-Object { $_ })
    if (-not (Test-Path -LiteralPath $note)) {
        if ($Lines.Count -eq 0) { return }
        $note = Initialize-DailyNote $VaultPath $Date
    }
    $text = [IO.File]::ReadAllText($note)
    $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
    $pattern = '(?s)\r?\n?' + [regex]::Escape($script:BlockBegin) + '.*?' + [regex]::Escape($script:BlockEnd) + '[ \t]*\r?\n?'
    $clean = [regex]::Replace($text, $pattern, $nl)
    if ($Lines.Count -eq 0) {
        if ($clean -ne $text) { Write-Utf8 $note $clean }
        return
    }
    $block = $script:BlockBegin + $nl + (($Lines | ForEach-Object { '- ' + $_ }) -join $nl) + $nl + $script:BlockEnd
    $m = [regex]::Match($clean, '(?m)^## Morgenbericht[ \t]*\r?$')
    if (-not $m.Success) {
        $new = $clean.TrimEnd() + $nl + $nl + '## Morgenbericht' + $nl + $nl + $block + $nl
    } else {
        $after = $m.Index + $m.Length
        $next = [regex]::Match($clean.Substring($after), '(?m)^## ')
        $end = $clean.Length
        if ($next.Success) { $end = $after + $next.Index }
        $section = $clean.Substring($after, $end - $after).TrimEnd()
        # The block belongs to the script: an agent line that says the same (same text, or the same
        # label up to the first colon, digits ignored) is dropped, so no hint stands twice.
        $labels = @{}
        foreach ($l in $Lines) { $labels[(Get-HintLabel $l)] = $true }
        $kept = @(foreach ($l in ($section -split '\r?\n')) {
            $t = ([string]$l).Trim() -replace '^-\s+', ''
            if ($t -and $labels.ContainsKey((Get-HintLabel $t))) { continue }
            $l
        })
        $section = ($kept -join $nl).TrimEnd()
        $rest = $clean.Substring($end)
        $new = $clean.Substring(0, $after) + $section + $nl + $nl + $block + $nl
        if ($rest) { $new += $nl + $rest }
    }
    Write-Utf8 $note $new
}
