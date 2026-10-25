# hub-reminder.ps1
#
# WHAT THIS FILE IS:
#   A Stop hook for every agent profile. Rule: at the end of a task in a project under
#   {{DEV}}\Projects the agent updates the project hub {{VAULT}}\200-projects\<repo>.md
#   (see {{DEV}}\Projects\CLAUDE.md). This hook catches the case where it forgot: it blocks the
#   stop ONCE, with the reason below, when the hub is older than the newest commit of the
#   repository or the last change of its PROGRESS.md. It is a reminder, not a gate.
#
# WHEN IT SAYS ANYTHING:
#   Only when ALL of this holds: the working directory is inside a repository directly under
#   -DevRoot, that repository has a hub in the vault, stop_hook_active is false, the hub's
#   hub_written (ISO local time) is missing or older than the repository, and this session has
#   not been reminded about this exact state yet (marker file in -StateDir).
#   In every other case it prints nothing and exits 0. Any error also exits 0 (fail open):
#   a broken reminder must never trap the agent in a loop.
#
# SPEED:
#   Idle path = reading stdin, a path check, one `git log -1` and two file reads (about 30 ms
#   on top of the PowerShell start). The tests hold it under 500 ms.
#
# The vault path is the owner's decision (personal.yaml); the defaults below are replaced by
# the install step.

param(
    [string]$VaultPath = '{{VAULT}}',
    [string]$DevRoot = '{{DEV}}\Projects',
    [string]$StateDir = ''
)

$ErrorActionPreference = 'SilentlyContinue'

try {
    $raw = [Console]::In.ReadToEnd()
    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) { exit 0 }
    if ($data.stop_hook_active -eq $true) { exit 0 }
    $cwd = [string]$data.cwd
    if (-not $cwd) { exit 0 }
    $session = ([string]$data.session_id) -replace '[^A-Za-z0-9_-]', '_'
    if (-not $session) { exit 0 }

    # cwd must be inside <DevRoot>\<repo>; the repo is the first path component below DevRoot.
    $root = [IO.Path]::GetFullPath($DevRoot).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($cwd).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { exit 0 }
    $name = $full.Substring($root.Length).Split('\')[0]
    if (-not $name -or $name -notmatch '^[A-Za-z0-9._ -]+$') { exit 0 }
    $repo = $root + $name
    $hub = Join-Path $VaultPath ('200-projects\' + $name + '.md')
    if (-not (Test-Path -LiteralPath $hub)) { exit 0 }
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { exit 0 }

    # newest change of the repository: last commit or PROGRESS.md, whichever is later
    $log = @(& git --no-optional-locks -C $repo log -1 '--format=%H%n%cI' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $log.Count -lt 2) { exit 0 }
    $hash = [string]$log[0]
    $newest = ([datetimeoffset]::Parse([string]$log[1], [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
    $progressTicks = 0
    $progress = Join-Path $repo 'PROGRESS.md'
    if (Test-Path -LiteralPath $progress) {
        $pm = (Get-Item -LiteralPath $progress).LastWriteTime
        $progressTicks = $pm.Ticks
        if ($pm -gt $newest) { $newest = $pm }
    }

    # hub_written from the frontmatter of the hub
    $written = $null
    $head = [IO.File]::ReadAllText($hub)
    $fm = [regex]::Match($head, '(?s)^---\r?\n(.*?)\r?\n---')
    if ($fm.Success) {
        $w = [regex]::Match($fm.Groups[1].Value, '(?m)^hub_written:\s*(.+?)\s*$')
        if ($w.Success) {
            try { $written = [datetime]::Parse($w.Groups[1].Value.Trim("'", '"'), [Globalization.CultureInfo]::InvariantCulture) } catch { $written = $null }
        }
    }
    if ($null -ne $written -and $written -ge $newest) { exit 0 }

    # one reminder per session and state
    if (-not $StateDir) { $StateDir = Join-Path {{HOME_ENV}} '.claude\state' }
    $marker = Join-Path $StateDir ('hub-reminder-' + $session + '.txt')
    $key = $name + '|' + $hash + '|' + $progressTicks
    if ((Test-Path -LiteralPath $marker) -and (@([IO.File]::ReadAllLines($marker)) -contains $key)) { exit 0 }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    [IO.File]::AppendAllText($marker, $key + "`n")

    $reason = 'The project hub ' + $hub + ' is older than the newest commit or PROGRESS.md of this repository. ' +
        'Before your final reply, update it as the rule in ' + $DevRoot + '\CLAUDE.md says: ' +
        'Status, Next step, Goal if it changed, one Timeline line "- <YYYY-MM-DD> - <what changed>", ' +
        'set hub_written to the current local time (yyyy-MM-ddTHH:mm:ss) in its frontmatter, and commit only that hub file in the vault. ' +
        'If this session changed nothing in the repository, skip the update and say so. ' +
        'Then give your final answer.'
    $out = ConvertTo-Json -Compress @{ decision = 'block'; reason = $reason }
    [Console]::Out.Write($out)
    exit 0
} catch {
    exit 0
}
