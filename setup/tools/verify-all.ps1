<#
setup/tools/verify-all.ps1 - the acceptance run for this repo.

Each check prints the command it ran, the decisive output and the exit code. The last line is
exactly "VERIFY-ALL: ALL CHECKS PASSED".

  1  the PROGRESS.md in the work root has no open work (no `[ ]` box in any shape, no non-heading
     line whose first word - after table pipes, quotes and bullets - is NEXT/TODO/TBD/FIXME/Open/
     OFFEN, and nothing but "none" under a heading that opens with one of those words)
  S  the repository is in the state setup/config/repo.yaml describes: the visibility matches,
     and the settings that must be on are on. This was check 2 ("the GitHub repository is
     private") until v3.0.0; the release task's acceptance table names it S, and it kept that
     letter so the table and the run use one name. Two of the settings exist on a public
     repository only, so while repo.yaml says `published: false` the check demands PRIVATE and
     reports them as not readable yet; with `published: true` it demands PUBLIC and them.
  3  gitleaks and trufflehog over the full history find nothing
  4  privacy-scan: worktree and history clean; the scan proves it can fail (red fixture)
  5  setup/tools/check.ps1: analyzer, Pester, guard suites, docs freshness
  6  a test install into a NEW empty target, then verify
  7  the latest CI run on GitHub is for the newest commit that changed something other than
     documentation (*.md, docs/, CHANGELOG.md) and success. A documentation-only commit on top
     needs no run of its own - the matrix runs the same code either way (AGENTS.md, "CI")
  8  export writes nothing new; git status is empty
  9  before/after fingerprint: only the logged live changes, nothing unexpected
 10  every hook command the live settings.json names exists, every hook file is named there,
     no settings file switches the hooks off (disableAllHooks), every PreToolUse matcher names a
     tool that exists, every event name is a known one, a matcher naming tools sits under
     PreToolUse, two guards are hash-identical, nothing is paused, and the live add-to-archive
     suite (run against a throw-away archive under Temp) is green
 11  the newest review-N.md states exactly one closing verdict pair (OPEN-CRITICAL/OPEN-HIGH,
     alone on their lines, outside any fenced code block, in the last 20 non-empty lines), that
     pair is 0 / 0, and no line of the report opens with CRITICAL or HIGH (a stated finding must
     show in the pair)
 12  BERICHT.md exists with all 8 numbered sections AND names the version of the newest
     CHANGELOG section (an old report cannot pass this)
  A  the repo tree matches the block in docs/structure.md
  B  the root holds exactly the documented folders and files
  C  no old path survives - every file on disk under the repo root (only .git and the scratch
     folders are skipped), the claude-config rules and the vault rules, searched for the old
     paths listed in setup/tools/old-paths.txt (that file also states what the search cannot see)
  D  for five moved files, git log --follow still shows commits from before the move
  E  every tracked file is in English (setup/tools/check-language.ps1)
  F  the mirror folders hold only what may be installed (tests/Structure.Tests.ps1)
  G  a test install produces the five dot-named files at the right places
  H  the platform map answers for every manifest component on all three systems
  I  the portable engine and the guards carry no Windows literal, except where one is inherent:
     setup/platform/windows.ps1, the windows/ folder, and three files this check names with
     their reason and their hit count
  J  a test install on Windows is byte-identical to the v2.1.2 baseline except for changes that
     are documented in this file, one by one
  K  every hook entry of the RENDERED settings.json is in exec form and names a PowerShell host
     - no default shell (Git Bash / sh / cmd) decides what runs
  L  CLAUDE.md imports AGENTS.md, AGENTS.md carries the "Platform first" rules, and
     docs/platforms.md matches setup/platforms.yaml component for component
  M  bootstrap.ps1 and bootstrap.sh exist, pass the analyzer / the shell syntax check, and the
     README has a "Start from zero" section for all three systems
  N  the CI matrix is defined for windows, ubuntu and macOS, and the newest run on windows and
     ubuntu (and on macOS when it ran) is green for the newest commit that changed code - the
     same commit 7 uses, so a documentation-only commit on top needs no run; of several runs of
     that commit it judges the newest one that has the macOS job, found by job name
  O  every CI job ran the idempotency step ("second install changes nothing") and it passed
  P  a live dry run of install.ps1 reaches the summary, so the code paths that only a real
     machine uses (the OS stages and the summary) are exercised too
  Q  the archive category list is in no version of this repository: the personal layer's
     terms are found neither in the tree nor in any commit, the tree really carries the
     invented example values in their place, and the live add-to-archive suite is green
  R  setup/tools/archive-name-scan.ps1 finds no folder name of the real vault in the tree and
     in the commit messages (it prints the count and the places, never a name)
  U  the Actions settings hold: a pull request from a fork runs only after approval, and the
     workflow token may read and nothing else
  V  the log of the newest CI run carries no personal value (privacy-scan reads the downloaded
     logs, with the personal layer loaded)

The cross-platform work (2026-10-14) added H to O. The live dry run was check H before that and
kept its text - only its letter moved, to P, so the letters of the new checks could follow the
task's own table.

Usage: pwsh setup/tools/verify-all.ps1
Scratch goes to C:\Dev\Temp\folder-structure by default (fingerprints, test targets, red
fixture); -WorkRoot names the folder of the task at hand, and checks 1, 9, 11 and 12 read their
evidence - PROGRESS.md, the fingerprint scripts, review-N.md, BERICHT.md - from there. The
report of a task therefore lives in that task's own folder.

The acceptance run is that call with no -Only and the live profile. -Only and -HomeRoot exist so
that a single check can be made to fail on purpose (the repo rule: every check fails once on a
seeded defect before its pass counts). A run that uses either of them can never print the
acceptance line: it ends with VERIFY-ALL: <n> OF 28 CHECKS PASSED (partial run) and exits 3, so
a filtered run cannot be mistaken for the real one. The number in that line is the count the
run really had (32), never a constant.

-WorkRoot is NOT one of those switches any more (order item 3, 2026-10-14). It used to be: review
7 showed that pointing it at a folder of one's own let a run print VERIFY-ALL: ALL CHECKS PASSED
while checks 1, 9, 11 and 12 read files the caller had placed there and check 9 executed the
caller's fingerprint scripts. The task now hands the work root to the caller on purpose - one
folder per task instead of one folder for all of them - so the guard holds what is still
objective: the folder must EXIST and must lie OUTSIDE the repository the run certifies. A work
root inside that tree could feed the run its own answers; a caller's folder elsewhere cannot be
told apart from a prepared one, and the run prints "Work:" at the top so a reader sees which
evidence the checks used. The other clauses stay literals: the live profile, the repository and
the shipped copy of this script.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$WorkRoot = 'C:\Dev\Temp\folder-structure',
    # check 10 reads the live wiring; a red proof points it at a throw-away home instead
    [string]$HomeRoot = $env:USERPROFILE,
    # empty = the whole acceptance run; otherwise only these check numbers ('5', 'A', ...)
    [string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
$script:results = New-Object System.Collections.Generic.List[object]
$script:checkCount = 32

function Get-LastCodeCommit {
    # The newest commit that changed something a CI run can fail on. Checks 7 and N compare the
    # newest run against THIS commit and not against HEAD, because a commit that only touches
    # documentation cannot turn a matrix job red or green: it runs the same code. The owner's
    # rule is "start CI on purpose, not in a loop" (AGENTS.md, "CI"), and a documentation commit
    # that has to wait for a run is exactly the loop that rule is about.
    # Excluded: every *.md at any depth, everything under docs/, and CHANGELOG.md.
    Push-Location $RepoRoot
    try {
        $sha = (& git rev-list -1 HEAD -- . ':(exclude)*.md' ':(exclude)docs/**' ':(exclude)CHANGELOG.md' 2>&1 | Out-String).Trim()
    }
    finally { Pop-Location }
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw ('git rev-list returned no commit for the code pathspec: ' + $sha) }
    return $sha
}
$script:acceptanceWorkRoot = 'C:\Dev\Temp\folder-structure'
# acceptanceWorkRoot is the DEFAULT of -WorkRoot; it is no longer part of the guard (see below).
# What it still does is name the folder a tool must not come from: $script:toolDirs keeps the
# default work root, the whole Temp area and the repository on the refusal list, so a program
# that a check calls and that resolves in there is not the system's own tool.
# The canonical paths are LITERALS, not values derived from where this file happens to lie.
# Round 9 cloned the repository next to the work root and ran the clone with no switches: the
# derived default equalled the clone, $PSCommandPath was the clone's copy of this script, and
# the run announced itself as the acceptance run. With the literal, only this machine's checkout
# can print the acceptance line.
$script:acceptanceRepoRoot = 'C:\Dev\Projects\personal-os-setup'
$script:selfPath = "$script:acceptanceRepoRoot\setup\tools\verify-all.ps1"
# The live profile comes from the operating system, not from the environment: USERPROFILE can be
# pointed somewhere else, and then a comparison against $env:USERPROFILE compares a value with
# itself (review 8, finding 2).
$script:realProfile = [Environment]::GetFolderPath('UserProfile')
# -Only accepts '1,11' as well as '1','11' (review 7: -Only 1,11 selected nothing and printed
# a green partial run, which reads like a success)
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
# Every parameter that changes WHAT is checked or WHERE the evidence comes from belongs here.
# Round 7 and round 8 each found a parameter the guard did not know, and both are answered above
# or below: -RepoRoot (a caller's tree, whose code fifteen checks execute) is compared with the
# literal repository, -WorkRoot has its own objection check, and a copy of this script outside
# the repository is caught by the $PSCommandPath clause - it is not the shipped file, so it does
# not get to certify anything.
$script:selfPath = "$script:acceptanceRepoRoot\setup\tools\verify-all.ps1"
# The work root is the caller's folder per task (order item 3 of the 2026-10-14 task). What the
# acceptance line still demands of it is objective: it must exist, and it must lie OUTSIDE the
# repository this run certifies - a work root inside that tree could hand the run its own answers
# (checks 1, 9, 11, 12 read PROGRESS.md, execute the fingerprint scripts, read review-N.md and
# BERICHT.md). A folder elsewhere is indistinguishable from a prepared one; that is why the run
# prints "Work:" above the checks and why the profile, the repository and the copy of this script
# stay literals in the guard below.
function Get-WorkRootObjection([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return ('the work root does not exist: ' + $Path) }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $repo = [IO.Path]::GetFullPath($script:acceptanceRepoRoot).TrimEnd('\', '/')
    if ($full.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return ('the work root lies inside the repository it certifies: ' + $full)
    }
    return ''
}
$script:workRootObjection = Get-WorkRootObjection -Path $WorkRoot
$isAcceptanceCall = ($Only.Count -eq 0) -and ($HomeRoot -eq $script:realProfile) -and
                    (-not $script:workRootObjection) -and ($RepoRoot -eq $script:acceptanceRepoRoot) -and
                    ($env:USERPROFILE -eq $script:realProfile) -and ($PSCommandPath -eq $script:selfPath)
# --- output: failures plus one line per check on the console, everything in the log ----------
# Owner's order (agent-upgrade-task.md, Part 4.1). A green run used to print 32 blocks of command
# lines and outputs - a wall of text with two interesting lines in it. Now the console carries one
# line per check plus the full block of every FAILED check, and the complete output (every block,
# this header, the tools line and the summary) goes to <WorkRoot>\verify-all.log. `-Verbose`
# restores the old console output; it is a switch every advanced script already has, so no new
# name has to be remembered.
$script:verboseOutput = ($VerbosePreference -ne 'SilentlyContinue')
$script:logPath = Join-Path $WorkRoot 'verify-all.log'
$script:log = $null
try {
    $script:log = New-Object System.IO.StreamWriter($script:logPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $script:log.AutoFlush = $true
} catch { $script:log = $null }
function Write-Log([string]$line) { if ($null -ne $script:log) { try { $script:log.WriteLine($line) } catch { } } }
function Write-Both([string]$line) { Write-Log $line; Write-Host $line }
function Close-Log { if ($null -ne $script:log) { try { $script:log.Flush(); $script:log.Close() } catch { }; $script:log = $null } }

if ($isAcceptanceCall) { Write-Both ('Checks: all ' + $script:checkCount + ', live profile, repo root and the work root below (this is the acceptance run)') }
else {
    $why = New-Object System.Collections.Generic.List[string]
    if ($Only.Count -gt 0) { $why.Add('only ' + ($Only -join ', ')) }
    if ($HomeRoot -ne $script:realProfile) { $why.Add('home ' + $HomeRoot) }
    if ($script:workRootObjection) { $why.Add($script:workRootObjection) }
    if ($RepoRoot -ne $script:acceptanceRepoRoot) { $why.Add('repo root ' + $RepoRoot) }
    if ($env:USERPROFILE -ne $script:realProfile) { $why.Add('USERPROFILE is ' + $env:USERPROFILE + ', the profile of this account is ' + $script:realProfile) }
    if ($PSCommandPath -ne $script:selfPath) { $why.Add('the script is not the repository copy (' + $PSCommandPath + ')') }
    Write-Both ('Checks: NOT the acceptance run (' + ($why -join '; ') + ')')
}
Write-Both ('Home:   ' + $HomeRoot)
Write-Both ('Work:   ' + $WorkRoot)

# The evidence of checks 2, 3 and 4 comes from programs, and a program is found on PATH: review 9
# put three .cmd shims in front of the PATH and the checks reported the shims' answers. The
# resolved location of every tool a check calls is printed, and a tool that resolves into the
# work root, into C:\Dev\Temp or into the repository is refused - the system's own tools live
# outside all three.
$script:toolDirs = @($script:acceptanceWorkRoot, 'C:\Dev\Temp', $script:acceptanceRepoRoot)
function Get-ToolReport([string[]]$names) {
    $lines = New-Object System.Collections.Generic.List[string]
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($n in $names) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if (-not $cmd) { $lines.Add($n + '=(not found)'); $bad.Add($n + ' is not on PATH'); continue }
        $src = [string]$cmd.Source
        $lines.Add($n + '=' + $src)
        foreach ($d in $script:toolDirs) {
            if ($src.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { $bad.Add($n + ' resolves into ' + $d + ' (' + $src + ')') }
        }
    }
    return [pscustomobject]@{ Text = ($lines -join ', '); Bad = $bad }
}
$script:tools = Get-ToolReport @('gh', 'gitleaks', 'trufflehog', 'git')
$script:toolsOk = ($script:tools.Bad.Count -eq 0)
Write-Both ('Tools:  ' + $script:tools.Text)
foreach ($b in $script:tools.Bad) { Write-Both ('        REFUSED: ' + $b) }
if (-not $script:toolsOk) { Write-Both '        A check whose tool is not the system''s tool cannot certify anything: every check that calls one of them fails.' }

function Add-Result([string]$nr, [string]$name, [string]$cmd, [string]$out, [string]$exitCode, [bool]$ok) {
    # A run whose tools are not the system's tools certifies nothing - not even a check that
    # happens not to call one. Review 11 measured check 7 and check E passing on refused tools
    # while the header claimed the opposite; the rule lives here once instead of in every check.
    if ($ok -and (-not $script:toolsOk)) { $ok = $false; $out = $out + ' [FAIL: a tool of this run is not the system''s tool - see the Tools line above]' }
    $script:results.Add([pscustomobject]@{ Nr = $nr; Name = $name; OK = $ok })
    $verdict = if ($ok) { 'PASS' } else { 'FAIL' }
    # The log gets the whole block, always. The console gets it for a failure, and for a passing
    # check only when -Verbose asked for the old output.
    Write-Log ('CHECK {0,2}: {1}' -f $nr, $name)
    Write-Log ('  Command: ' + $cmd)
    Write-Log ('  Output:  ' + $out)
    Write-Log ('  Exit:    ' + $exitCode)
    Write-Log ('  Result:  ' + $verdict)
    Write-Log ''
    if ($script:verboseOutput -or (-not $ok)) {
        Write-Host ('CHECK {0,2}: {1}' -f $nr, $name)
        Write-Host ('  Command: ' + $cmd)
        Write-Host ('  Output:  ' + $out)
        Write-Host ('  Exit:    ' + $exitCode)
        Write-Host ('  Result:  ' + $verdict)
        Write-Host ''
    }
    else {
        Write-Host ('{0,2}  PASS  {1}' -f $nr, $name)
    }
}

function Test-Selected([string]$nr) { return (($Only.Count -eq 0) -or ($Only -contains $nr)) }

Write-Both ('== verify-all  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  Repo: ' + $RepoRoot + ' ==')
Write-Both ''

# ---------------------------------------------------------------- 1 PROGRESS ---
if (Test-Selected '1') { try {
    $progress = Join-Path $WorkRoot 'PROGRESS.md'
    # Open work is recognisable in ANY shape: a [ ] box anywhere (list, table cell, bare line) is
    # one, and so is a line whose first word - after any heading marks, table pipes, quote marks
    # and list bullets - is a marker word. Review 5 measured that a pattern demanding a colon or
    # dash after the marker let `## Next steps`, `| NEXT: x |` and `Open work: x` through; review 6
    # measured that too. The marker must stand at the start of the line: prose that merely names
    # the markers in the middle of a sentence is not open work. Select-String folds case, so
    # `Next` hits as `NEXT`.
    $boxPattern = '\[ \]'
    $markerPattern = '^\s*(?:[#>\|\-\*\+]|\d+[\.\)]?|\s)*\**\s*(NEXT|TODO|TBD|FIXME|Open|OFFEN)\b'
    $open = @(Select-String -LiteralPath $progress -Pattern $boxPattern).Count
    # A Markdown heading is outline, not open work (the PROGRESS.md format of the agent rule has
    # "## Next step" and "## Open questions" on purpose). What stands under such a heading is
    # judged instead: every non-empty line under a heading that opens with a marker word counts as
    # open work unless it says none/nothing; a marker word at the start of any other line counts too.
    $nonePattern = '^\s*(?:[>\-\*\+]|\d+[\.\)])?\s*\**\s*(none|nothing( open| left)?|n/a)\b[\s\.\!\*]*$'
    $next = 0
    $inOpenSection = $false
    foreach ($line in (Get-Content -LiteralPath $progress)) {
        if ($line -match '^\s{0,3}#{1,6}\s') { $inOpenSection = [bool]($line -match $markerPattern); continue }
        if ($line -match $markerPattern) { $next++; continue }
        if ($inOpenSection -and $line.Trim() -ne '' -and $line -notmatch $nonePattern) { $next++ }
    }
    $ok = ($open -eq 0) -and ($next -eq 0)
    Add-Result 1 'PROGRESS.md has no open work' ("Select-String -LiteralPath <work>\PROGRESS.md -Pattern '" + $boxPattern + "' (any shape) and '" + $markerPattern + "' (first word of a non-heading line, after table/bullet marks) and the lines under a Next/Open heading") ('unchecked boxes: ' + $open + '; lines opening with an open-work marker: ' + $next) '0' $ok
} catch { Add-Result 1 'PROGRESS.md has no open work' 'Select-String PROGRESS.md' $_.Exception.Message '2' $false } }

# ------------------------------------------- S visibility and repo settings ---
# Was check 2, "the GitHub repository is private", until v3.0.0. What has to hold now is that
# the repository is in the state setup/config/repo.yaml describes - visibility AND the security
# settings the release promises. Two of those settings cannot even be READ while a repository
# is private, so the check splits by the `published` flag of that file and never guesses:
#   published: false  -> the repository must be PRIVATE, and the public-only settings are
#                        reported as not readable yet.
#   published: true   -> the repository must be PUBLIC and every setting must be on.
# A repository that went public while the file still says false fails, and so does a private
# one that claims to be published - the flag cannot hide a wrong state in either direction.
if (Test-Selected 'S') { try {
    . (Join-Path $RepoRoot 'setup/lib/personal.ps1')
    $repoYaml = Join-Path $RepoRoot 'setup/config/repo.yaml'
    if (-not (Test-Path -LiteralPath $repoYaml)) { throw ('repo.yaml is missing: ' + $repoYaml) }
    $wantVisibility = ([string](Get-ConfigScalar -ConfigPath $repoYaml -Key 'visibility')).Trim()
    $publishedText = ([string](Get-ConfigScalar -ConfigPath $repoYaml -Key 'published')).Trim()
    if (($wantVisibility -ne 'public') -and ($wantVisibility -ne 'private')) { throw ('repo.yaml: visibility must be public or private, found "' + $wantVisibility + '"') }
    if (($publishedText -ne 'true') -and ($publishedText -ne 'false')) { throw ('repo.yaml: published must be true or false, found "' + $publishedText + '"') }
    # The four settings are read from the file, not hard-coded here: repo.yaml is the single
    # source of truth this check's name promises, so editing it must change what is demanded -
    # and a key that is missing or spells anything but 'enabled' fails the check instead of
    # being ignored (review 22, F7: the file was dead config).
    foreach ($k in @('secret_scanning', 'push_protection', 'dependabot_alerts', 'private_vulnerability_reporting')) {
        $v = ([string](Get-ConfigScalar -ConfigPath $repoYaml -Key $k)).Trim()
        if ($v -ne 'enabled') { throw ('repo.yaml: ' + $k + ' must be enabled, found "' + $v + '"') }
    }
    $published = ($publishedText -eq 'true')
    $want = if ($published) { 'PUBLIC' } else { 'PRIVATE' }
    Push-Location $RepoRoot
    $out = (& gh repo view --json visibility,nameWithOwner 2>&1 | Out-String).Trim()
    $exit = $LASTEXITCODE
    $slug = [regex]::Match($out, '"nameWithOwner"\s*:\s*"([^"]+)"').Groups[1].Value
    $actual = [regex]::Match($out, '"visibility"\s*:\s*"([^"]+)"').Groups[1].Value
    $ss = '(not read)'; $pp = '(not read)'
    $dv = $false; $pvr = $false; $pvrText = '(not read)'
    if (($exit -eq 0) -and $slug) {
        # `gh api --jq` on a field that does not exist prints nothing and exits 0, so the empty
        # answer is kept as it is and never read as "enabled".
        $ss = ((& gh api ('repos/' + $slug) --jq '.security_and_analysis.secret_scanning.status' 2>&1 | Out-String).Trim())
        $pp = ((& gh api ('repos/' + $slug) --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>&1 | Out-String).Trim())
        if (-not $ss) { $ss = '(absent)' }
        if (-not $pp) { $pp = '(absent)' }
        # 204 = on, 404 = off - the only two answers this endpoint gives
        $dv = ((& gh api -i ('repos/' + $slug + '/vulnerability-alerts') 2>&1 | Select-Object -First 1) -match '\s204\s')
        # Not the status line this time: measured on 2026-10-15, the private vulnerability
        # reporting endpoint answers HTTP 200 with a JSON body in both states - `{"enabled":true}`
        # on public repositories that have it on (cli/cli, actions/checkout, github/gitignore)
        # and `{"enabled":false}` on one that does not (octocat/Hello-World). A private repository
        # answers 404. So this reads the field and never the status code, and the empty answer of
        # an absent field is not read as "on".
        $pvrBody = ((& gh api ('repos/' + $slug + '/private-vulnerability-reporting') 2>&1 | Out-String).Trim())
        $pvr = ($pvrBody -match '"enabled"\s*:\s*true')
        $pvrText = if ($pvr) { 'on' } elseif ($pvrBody -match '"enabled"\s*:\s*false') { 'OFF' } elseif ($pvrBody -match '404') { '(not available while the repository is private)' } else { '(not read)' }
    }
    Pop-Location
    $publicOnly = '(secret scanning: ' + $ss + '; push protection: ' + $pp + '; private vulnerability reporting: ' + $pvrText + ')'
    # Secret scanning and push protection are refused on a private repository ("Secret scanning is
    # not available for this repository", HTTP 422, measured 2026-10-15), and private vulnerability
    # reporting answers 404 there. So all three are demanded when repo.yaml says the release
    # happened - and when it does, this check is the one that asks.
    # dependabot alerts are settable in both states (204) and are demanded in both.
    $ok = ($exit -eq 0) -and ($slug -ne '') -and ($actual -eq $want) -and $dv -and ($script:tools.Bad.Count -eq 0)
    if ($published) { $ok = $ok -and ($ss -eq 'enabled') -and ($pp -eq 'enabled') -and $pvr }
    $detail = 'repo.yaml says visibility ' + $wantVisibility + ', published ' + $publishedText + ' -> the repository must be ' + $want +
              '; GitHub answers ' + $actual + ' for ' + $slug +
              '; secret scanning, push protection and private vulnerability reporting ' + $(if ($published) { 'are demanded' } else { 'exist on a public repository only, so they are not demanded while published is false' }) +
              ' ' + $publicOnly +
              '; dependabot alerts: ' + $(if ($dv) { 'on' } else { 'OFF' })
    Add-Result 'S' 'repository state matches setup/config/repo.yaml' ('read ' + $repoYaml + '; gh repo view --json visibility,nameWithOwner; gh api repos/<slug> --jq .security_and_analysis; gh api -i repos/<slug>/vulnerability-alerts; gh api -i repos/<slug>/private-vulnerability-reporting (gh = ' + (($script:tools.Text -split ', ' | Where-Object { $_ -like 'gh=*' }) -join '' ) + ')') $detail $exit $ok
} catch { Add-Result 'S' 'repository state matches setup/config/repo.yaml' 'read repo.yaml and ask GitHub' $_.Exception.Message '2' $false } }

# ------------------------------------------------------------ 3 secret scanner ---
if (Test-Selected '3') { try {
    Push-Location $RepoRoot
    $glOut = (& gitleaks git --redact --no-banner --config .gitleaks.toml 2>&1 | Out-String)
    $glExit = $LASTEXITCODE
    Pop-Location
    $glOk = ($glExit -eq 0) -and ($glOut -match 'no leaks found')
    # two slashes, not three: trufflehog turns file:///C:/... into C:/C:/... (measured) and then
    # fails to clone, which would make this check red for a reason that has nothing to do with
    # secrets
    $thGitOut = (& trufflehog git ('file://' + ($RepoRoot -replace '\\', '/')) --no-update --json 2>&1 | Out-String)
    $thGitExit = $LASTEXITCODE
    $thGitFindings = @($thGitOut -split "`n" | Where-Object { $_ -match '"DetectorName"' }).Count
    $thFsOut = (& trufflehog filesystem $RepoRoot --no-update --json 2>&1 | Out-String)
    $thFsExit = $LASTEXITCODE
    $thFsFindings = @($thFsOut -split "`n" | Where-Object { $_ -match '"DetectorName"' }).Count
    $ok = $glOk -and ($thGitFindings -eq 0) -and ($thFsFindings -eq 0) -and ($thGitExit -eq 0) -and ($thFsExit -eq 0) -and ($script:tools.Bad.Count -eq 0)
    Add-Result 3 'gitleaks + trufflehog, full history' ('gitleaks git --redact --config .gitleaks.toml | trufflehog git <repo> --json | trufflehog filesystem <repo> --json; tools: ' + $script:tools.Text) ("gitleaks: " + $(if ($glOk) { 'no leaks found' } else { 'FINDINGS' }) + '; trufflehog git: ' + $thGitFindings + '; trufflehog filesystem: ' + $thFsFindings) ($glExit.ToString() + '/' + $thGitExit + '/' + $thFsExit) $ok
} catch { Add-Result 3 'gitleaks + trufflehog, full history' 'gitleaks + trufflehog' $_.Exception.Message '2' $false } }

# ------------------------------------------------------------- 4 privacy scan ---
if (Test-Selected '4') { try {
    Push-Location $RepoRoot
    $wtOut = (& pwsh -NoProfile -File setup/tools/privacy-scan.ps1 2>&1 | Out-String)
    $wtExit = $LASTEXITCODE
    $hiOut = (& pwsh -NoProfile -File setup/tools/privacy-scan.ps1 -History 2>&1 | Out-String)
    $hiExit = $LASTEXITCODE
    Pop-Location
    # red fixture: the scan must find seeded patterns (strings assembled at runtime so this
    # file itself carries nothing the scan would flag)
    $redDir = Join-Path $WorkRoot 'scan-red'
    New-Item -ItemType Directory -Force -Path $redDir | Out-Null
    $redText = 'mail: max.mustermann@' + 'firma.at' + "`r`n" + 'IBAN AT61' + ' 1904 3002 3457 3201' + "`r`n" + 'key AKIA' + 'QPWOEIRUTYALSKDJ' + "`r`n"
    [IO.File]::WriteAllText((Join-Path $redDir 'fixture.txt'), $redText, (New-Object Text.UTF8Encoding($false)))
    # Join-Path $RepoRoot: this call sits after Pop-Location, so a relative path would resolve
    # against the CALLER's directory (the same hole review 17 (F3) found in check J). Every
    # other call in this file runs inside a Push-Location $RepoRoot window.
    $redOut = (& pwsh -NoProfile -File (Join-Path $RepoRoot 'setup/tools/privacy-scan.ps1') -Path $redDir 2>&1 | Out-String)
    $redExit = $LASTEXITCODE
    $redFindings = [regex]::Match($redOut, '(\d+) finding').Groups[1].Value
    $ok = ($wtExit -eq 0) -and ($wtOut -match 'clean') -and ($hiExit -eq 0) -and ($redExit -eq 1)
    Add-Result 4 'privacy-scan clean + red proof' 'privacy-scan.ps1 | -History | -Path <red-fixture>' ('worktree Exit ' + $wtExit + ' (clean); history Exit ' + $hiExit + '; fixture Exit ' + $redExit + ' (' + $redFindings + ' findings expected: >=1)') ($wtExit.ToString() + '/' + $hiExit + '/' + $redExit) $ok
} catch { Add-Result 4 'privacy-scan clean + red proof' 'privacy-scan.ps1' $_.Exception.Message '2' $false } }

# -------------------------------------------------------------- 5 check.ps1 ---
if (Test-Selected '5') { try {
    Push-Location $RepoRoot
    # a check.ps1 run of its own, with its own render folder: two acceptance runs (or a reviewer
    # and the worker) would otherwise share tests\_tmp\check and delete each other's rendered tree
    # while a guard suite is running in it (measured by review 5)
    $checkWork = Join-Path $WorkRoot ('check-' + $PID)
    # the log of this check.ps1 run goes NEXT TO verify-all.log into the task folder, per-run
    # named: two runs at the same time (a reviewer and the worker) must not truncate each other's
    # log, and the task folder is where a report looks (owner's order, Part 4.1)
    $coLog = Join-Path $WorkRoot ('check-' + $PID + '.log')
    $coOut = (& pwsh -NoProfile -File setup/tools/check.ps1 -WorkDir $checkWork -LogPath $coLog 2>&1 | Out-String)
    $coExit = $LASTEXITCODE
    Pop-Location
    $pesterLine = ([regex]::Match($coOut, 'PESTER: [^\r\n]+')).Value
    $ok = ($coExit -eq 0) -and ($coOut -match 'CHECK-OK') -and ($coOut -match 'PESTER: [1-9][0-9]* passed, 0 failed') -and ($coOut -match 'ANALYZER-OK')
    # The output line carries what the run really printed. A constant '(ANALYZER-OK; CHECK-OK)'
    # would sit under a FAIL verdict and invent evidence (review 6, finding 4) - so: on a pass the
    # decisive lines, on a failure the first error lines and the tail of the real output.
    $tailLines = @($coOut -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 2)
    $shown = @()
    if (-not $ok) { $shown += @($coOut -split "`r?`n" | Where-Object { $_ -match 'ERROR|FAIL|errors' } | Select-Object -First 3) }
    $shown += @($pesterLine) + $tailLines
    $shownText = (@($shown | Where-Object { $_ -and $_.Trim() -ne '' }) -join ' | ')
    Add-Result 5 'Analyzer + Pester + guard suites' 'pwsh -File setup/tools/check.ps1 -WorkDir <per-run>' ('(real last lines) ' + $shownText) $coExit $ok
} catch { Add-Result 5 'Analyzer + Pester + guard suites' 'pwsh -File setup/tools/check.ps1' $_.Exception.Message '2' $false } }

# ------------------------------------------------------- 6 test install fresh ---
if (Test-Selected '6') { try {
    $target = Join-Path $WorkRoot ('verify-all-target-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Push-Location $RepoRoot
    $inOut = (& pwsh -NoProfile -File install.ps1 -TargetRoot $target -NonInteractive 2>&1 | Out-String)
    $inExit = $LASTEXITCODE
    $veOut = (& pwsh -NoProfile -File setup/verify.ps1 -TargetRoot $target 2>&1 | Out-String)
    $veExit = $LASTEXITCODE
    Pop-Location
    $veLine = ([regex]::Match($veOut, 'VERIFY-OK: [^\r\n]+')).Value
    $ok = ($inExit -eq 0) -and ($inOut -match 'INSTALL-OK') -and ($veExit -eq 0) -and ($veOut -match 'VERIFY-OK')
    Add-Result 6 'test install into a new empty target' ('install.ps1 -TargetRoot ' + (Split-Path $target -Leaf) + ' -NonInteractive; setup/verify.ps1 -TargetRoot <same>') ('INSTALL-OK (Exit 0); ' + $veLine) ($inExit.ToString() + '/' + $veExit) $ok
} catch { Add-Result 6 'test install into a new empty target' 'install.ps1 -TargetRoot <new>' $_.Exception.Message '2' $false } }

# ------------------------------------------------------------------ 7 CI run ---
if (Test-Selected '7') { try {
    Push-Location $RepoRoot
    $head = (& git rev-parse HEAD).Trim()
    $code = Get-LastCodeCommit
    # The run FOR the newest code commit, not the newest run of the workflow: a commit that only
    # changes documentation still starts a run of its own (the workflow has no paths filter), and
    # that run would sit on top and make this check red for a state the owner's rule blesses. What
    # has to hold is that the code at HEAD has a green run - a docs-only commit on top needs none.
    # --workflow ci, not any workflow: GitHub's own "Dependency Graph" runs report success for the
    # same commit and would let this check pass without ci ever finishing.
    $runJson = (& gh run list --workflow ci --commit $code --limit 1 --json headSha,status,conclusion 2>&1 | Out-String)
    Pop-Location
    $run = @($runJson | ConvertFrom-Json)[0]
    $ok = ($null -ne $run) -and ($run.status -eq 'completed') -and ($run.conclusion -eq 'success')
    $detail = if ($null -eq $run) { 'no ci run exists for the newest code commit ' + $code.Substring(0, 7) + ' (HEAD ' + $head.Substring(0, 7) + ')' }
              else { $run.headSha.Substring(0, 7) + ' ' + $run.status + ' ' + $run.conclusion + ' (newest code commit ' + $code.Substring(0, 7) + ', HEAD ' + $head.Substring(0, 7) + ')' }
    Add-Result 7 'CI: newest code commit, success' 'gh run list --workflow ci --commit <newest code commit> --limit 1 --json headSha,status,conclusion' $detail '0' $ok
} catch { Add-Result 7 'CI: newest code commit, success' 'gh run list' $_.Exception.Message '2' $false } }

# ----------------------------------------------------------------- 8 export ---
if (Test-Selected '8') { try {
    Push-Location $RepoRoot
    $exOut = (& pwsh -NoProfile -File setup/export.ps1 2>&1 | Out-String)
    $exExit = $LASTEXITCODE
    $status = (& git status --porcelain | Out-String).Trim()
    Pop-Location
    $exLine = ([regex]::Match($exOut, 'EXPORT: [^\r\n]+')).Value
    $ok = ($exExit -eq 0) -and ($exOut -match 'EXPORT-OK') -and ($exOut -match 'EXPORT: 0 new, 0 changed') -and ($status -eq '') -and $script:toolsOk
    $statusText = if ($status -eq '') { 'git status: empty' } else { 'git status: ' + (($status -split "`n") | Measure-Object).Count + ' line(s)' }
    Add-Result 8 'export writes nothing new, git clean' 'pwsh -File setup/export.ps1; git status --porcelain' ($exLine + '; ' + $statusText) $exExit $ok
} catch { Add-Result 8 'export writes nothing new, git clean' 'setup/export.ps1' $_.Exception.Message '2' $false } }

# ----------------------------------------------------------- 9 fingerprint ---
if (Test-Selected '9') { try {
    $mk = Join-Path $WorkRoot 'make-fingerprint.ps1'
    $cmp = Join-Path $WorkRoot 'compare-fingerprint.ps1'
    if (-not (Test-Path -LiteralPath $mk) -or -not (Test-Path -LiteralPath $cmp)) { throw 'make/compare-fingerprint.ps1 missing in ' + $WorkRoot }
    $mkOut = (& pwsh -NoProfile -File $mk -Out (Join-Path $WorkRoot 'after.json') 2>&1 | Out-String)
    $cmpOut = (& pwsh -NoProfile -File $cmp 2>&1 | Out-String)
    $cmpExit = $LASTEXITCODE
    $cmpLine = ([regex]::Match($cmpOut, 'COMPARE: [^\r\n]+')).Value
    $ok = ($cmpExit -eq 0) -and ($cmpLine -match 'logged live changes')
    # The two scripts decide this check, and they live in the work root: printing their hashes
    # puts on record which version produced the verdict (review 8, medium - the check pins the
    # path of the work root, not the content of what it executes).
    $mkHash = (Get-FileHash -LiteralPath $mk -Algorithm SHA256).Hash.Substring(0, 12)
    $cmpHash = (Get-FileHash -LiteralPath $cmp -Algorithm SHA256).Hash.Substring(0, 12)
    Add-Result 9 'before/after: logged changes only' 'make-fingerprint.ps1 -Out after.json; compare-fingerprint.ps1 (both from the work root, hashes printed)' ($cmpLine + '; make-fingerprint ' + $mkHash + ', compare-fingerprint ' + $cmpHash) $cmpExit $ok
} catch { Add-Result 9 'before/after: logged changes only' 'compare-fingerprint.ps1' $_.Exception.Message '2' $false } }

# ---------------------------------------------------------------- 10 guards ---
if (Test-Selected '10') { try {
    $hooksDir = Join-Path $HomeRoot '.claude\hooks'
    $hookFiles = @(Get-ChildItem -LiteralPath $hooksDir -File -ErrorAction SilentlyContinue)
    # The two window guards carry a pinned live-file hash so a change that never went through
    # the repo stays visible here. Re-recorded 2026-10-16: both pins still carried their 3741935
    # (initial release) values while the umlaut commit fb5b0b9 rewrote both guards - found stale
    # by the first acceptance run since that commit. Live equals the repo modulo placeholders
    # (drift-check.ps1, green in the same run).
    $guardHashA = '9F8DBFFC5E5CFF909AD1009F3E1AE7402145AD66048F9A2B2C19A8358CE61BDF'
    $guardHashB = '8CED3ADF762F091C1F5C252F80F215502D02FC33E0899241D0E321A9C7E48D50'
    $hashAOk = $false; $hashBOk = $false
    if (Test-Path -LiteralPath (Join-Path $hooksDir 'onedrive-guard.ps1')) { $hashAOk = ((Get-FileHash -LiteralPath (Join-Path $hooksDir 'onedrive-guard.ps1') -Algorithm SHA256).Hash -eq $guardHashA) }
    if (Test-Path -LiteralPath (Join-Path $hooksDir 'trifecta-guard.ps1')) { $hashBOk = ((Get-FileHash -LiteralPath (Join-Path $hooksDir 'trifecta-guard.ps1') -Algorithm SHA256).Hash -eq $guardHashB) }
    $paused = @(Get-ChildItem -LiteralPath (Join-Path $WorkRoot 'safety') -Filter '*.ps1' -ErrorAction SilentlyContinue).Count
    # the eighth suite needs the live script pair and runs its throw-away archive under Temp
    $suite = Join-Path $HomeRoot '.claude\setup\tests\test-add-to-archive.ps1'
    $sExit = 2; $sLine = '(missing)'; $sCount = 0
    if (Test-Path -LiteralPath $suite) {
        $sOut = (& pwsh -NoProfile -File $suite 2>&1 | Out-String)
        $sExit = $LASTEXITCODE
        $m = [regex]::Match($sOut, '(\d+) checks, (\d+) failed')
        if ($m.Success) { $sLine = $m.Value; $sCount = [int]$m.Groups[1].Value }
    }
    $suiteOk = ($sExit -eq 0) -and ($sLine -match 'checks, 0 failed') -and ($sCount -ge 40)
    # A hook only works while the file that settings.json names exists - and while the settings
    # actually name it. Counting files in the hooks folder proves nothing: renaming one to *.off
    # leaves the count at nine and the guard dead (measured by review 4). So the live settings are
    # read as JSON, every hook command's -File path must exist, and no *.ps1 may sit in the hooks
    # folder without being named. Content beyond the two hashes below is compared against the repo
    # by drift-check.ps1 - this check is about wiring, not about text.
    $settingsPath = Join-Path $HomeRoot '.claude\settings.json'
    $registered = New-Object System.Collections.Generic.List[string]
    $missingHooks = New-Object System.Collections.Generic.List[string]
    $eventSummary = New-Object System.Collections.Generic.List[string]
    # Wiring is not only "the file exists and is named". Two ways to switch every guard off while
    # all of the above still holds (both measured by review 6):
    #  - settings.json carries disableAllHooks: true  -> nothing runs at all;
    #  - a PreToolUse matcher names no tool that exists ("ToolsThatDoNotExist") -> that entry
    #    never fires. The tool names below are a snapshot of the tool vocabulary; one alternative
    #    matching is enough, so a matcher may mix known names with new ones.
    $disabled = New-Object System.Collections.Generic.List[string]
    $deadMatchers = New-Object System.Collections.Generic.List[string]
    $misplaced = New-Object System.Collections.Generic.List[string]
    # The only script allowed to sit behind a tool matcher outside PreToolUse: the skill usage
    # logger (PostToolUse, async, fail-open). It observes; it does not decide. Any other script
    # there is still reported as dead wiring.
    $postToolObservers = @('skill-usage.ps1')
    $unknownEvents = New-Object System.Collections.Generic.List[string]
    $knownEvents = @('PreToolUse', 'PostToolUse', 'UserPromptSubmit', 'Notification', 'Stop',
        'SubagentStop', 'PreCompact', 'SessionStart', 'SessionEnd')
    $preToolUsePaths = 0
    # The five guards that must fire before a tool runs, by file name. This is the wiring this
    # acceptance run asserts - it is written down here on purpose, because a count alone proves
    # nothing: review 8 moved four of the five entries to Stop and stripped their matcher keys,
    # and every count stayed right. An entry without a matcher fires for every tool, so a missing
    # matcher cannot be the test - the event the file is registered under can.
    $requiredUnderPreToolUse = @('block-dangerous.ps1', 'downloads-guard.ps1', 'onedrive-guard.ps1',
        'trifecta-guard.ps1', 'archive-guard.ps1')
    $preToolUseNames = New-Object System.Collections.Generic.List[string]
    $notUnderPreToolUse = New-Object System.Collections.Generic.List[string]
    # A tool matcher is only meaningful under PreToolUse. Review 7 moved all five PreToolUse
    # entries to Stop in a byte-faithful copy: every path existed, every file was named, and all
    # five guards were dead. So the event name is checked too, and a matcher that names tools
    # outside PreToolUse fails.
    $knownTools = @('Bash', 'PowerShell', 'Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit',
        'Grep', 'Glob', 'BashOutput', 'KillShell', 'Task', 'Agent', 'TodoWrite', 'Skill', 'Monitor',
        'Artifact', 'ArtifactData', 'ArtifactComments', 'LSP', 'WebFetch', 'WebSearch',
        'ListAgents', 'SendMessage', 'PushNotification', 'AskUserQuestion', 'EnterPlanMode',
        'ExitPlanMode', 'EnterWorktree', 'ExitWorktree', 'CronCreate', 'CronList', 'CronDelete',
        'ScheduleWakeup', 'Workflow', 'ReadMcpResourceTool', 'ListMcpResourcesTool',
        'ReadMcpResourceDirTool', 'ReportFindings')
    # a sibling settings file can switch the hooks off while settings.json stays clean (review 7)
    foreach ($sf in @(Get-ChildItem -LiteralPath (Join-Path $HomeRoot '.claude') -Filter 'settings*.json' -File -ErrorAction SilentlyContinue)) {
        if ($sf.FullName -eq $settingsPath) { continue }
        try {
            $sib = [IO.File]::ReadAllText($sf.FullName) | ConvertFrom-Json
            if ($sib.PSObject.Properties.Name -contains 'disableAllHooks' -and ($sib.disableAllHooks -eq $true)) {
                $disabled.Add('disableAllHooks: true in ' + $sf.Name)
            }
            if ($sib.PSObject.Properties.Name -contains 'hooks') {
                $disabled.Add('a hooks block in ' + $sf.Name + ' (not read by this check - review it by hand)')
            }
        }
        catch { $disabled.Add($sf.Name + ' does not parse: ' + $_.Exception.Message) }
    }
    $settingsReadable = $false
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
            $settingsReadable = $true
            if ($settings.PSObject.Properties.Name -contains 'disableAllHooks' -and ($settings.disableAllHooks -eq $true)) {
                $disabled.Add('disableAllHooks: true')
            }
            foreach ($ev in $settings.hooks.PSObject.Properties) {
                $eventPaths = New-Object System.Collections.Generic.List[string]
                if ($knownEvents -notcontains $ev.Name) { $unknownEvents.Add($ev.Name) }
                foreach ($entry in @($ev.Value)) {
                    # Deferred on purpose: a matcher naming tools outside PreToolUse is dead
                    # wiring only when the entry registers no allowed observer. The skill usage
                    # logger runs under PostToolUse, async and fail-open; it cannot block and is
                    # the one script allowed there. Everything else still fails below.
                    $entryMatcher = ''
                    $entryMatchesATool = $false
                    $entryScriptLeaves = New-Object System.Collections.Generic.List[string]
                    if ($entry.PSObject.Properties.Name -contains 'matcher') {
                        $matcher = [string]$entry.matcher
                        if ($matcher -and ($matcher -ne '*')) {
                            $matchesATool = $false
                            foreach ($alt in ($matcher -split '\|')) {
                                $a = $alt.Trim()
                                if (-not $a) { continue }
                                if ($a -like 'mcp__*') { $matchesATool = $true; break }
                                if ($knownTools -contains $a) { $matchesATool = $true; break }
                            }
                            $entryMatcher = $matcher
                            $entryMatchesATool = $matchesATool
                            if ((-not $matchesATool) -and ($ev.Name -eq 'PreToolUse')) { $deadMatchers.Add($matcher) }
                        }
                    }
                    foreach ($h in @($entry.hooks)) {
                        # the executable sits in `command`, the script path in `args`
                        # ({"type":"command","command":"powershell.exe","args":[...,"-File","...ps1"]});
                        # only a path that follows -File counts as the executed script - a mere
                        # mention of a guard path in the arguments is not a registration
                        # (review 9 measured a green check with `-File other.ps1 <guard path>`)
                        $parts = @()
                        if ($h.command) { $parts += [string]$h.command }
                        if ($h.args) { $parts += @($h.args | ForEach-Object { [string]$_ }) }
                        if ($parts.Count -eq 0) { continue }
                        $execPaths = New-Object System.Collections.Generic.List[string]
                        for ($ai = 0; $ai -lt $parts.Count; $ai++) {
                            if (($parts[$ai] -match '^-{1,2}(file|f)$') -and ($ai + 1 -lt $parts.Count) -and ($parts[$ai + 1] -match '\.ps1$')) {
                                $execPaths.Add($parts[$ai + 1])
                            }
                        }
                        if ($execPaths.Count -eq 0) {
                            # The fail-closed wrapper: the script is invoked inside a -Command
                            # string, not passed as -File, because a missing -File exits with
                            # 0xFFFD0000 and the harness records that as exit 0 (measured
                            # 2026-10-18). Only the exact wrapper counts - Test-Path, &, and
                            # the script's own exit code - so a mere mention is still no wiring.
                            $wrapPattern = '^if \(-not \(Test-Path -LiteralPath ''([^'']+\.ps1)''\)\) \{ exit 1 \}; & ''\1''; exit \$LASTEXITCODE$'
                            foreach ($part in $parts) {
                                $mw = [regex]::Match($part, $wrapPattern)
                                if ($mw.Success) { $execPaths.Add($mw.Groups[1].Value) }
                            }
                        }
                        if ($execPaths.Count -eq 0) {
                            # no -File: then the script must be named inside command itself
                            $mAll = [regex]::Matches(($parts[0]), '[A-Za-z]:[\\/][^"''\s]*\.ps1')
                            if ($mAll.Count -gt 0) { $execPaths.Add($mAll[$mAll.Count - 1].Value) }
                        }
                        foreach ($rawPath in $execPaths) {
                            $p = $rawPath -replace '/', '\'
                            $leafName = Split-Path $p -Leaf
                            if (-not $entryScriptLeaves.Contains($leafName)) { $entryScriptLeaves.Add($leafName) }
                            if (-not $eventPaths.Contains($p)) { $eventPaths.Add($p) }
                            if (-not $registered.Contains($p)) {
                                $registered.Add($p)
                                if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missingHooks.Add($p) }
                            }
                        }
                    }
                    if ($entryMatchesATool -and ($ev.Name -ne 'PreToolUse')) {
                        $observerOnly = ($ev.Name -eq 'PostToolUse') -and ($entryScriptLeaves.Count -gt 0)
                        foreach ($leaf in $entryScriptLeaves) {
                            if ($postToolObservers -notcontains $leaf) { $observerOnly = $false }
                        }
                        if (-not $observerOnly) { $misplaced.Add($entryMatcher + ' under ' + $ev.Name) }
                    }
                }
                $eventSummary.Add($ev.Name + ' ' + $eventPaths.Count)
                if ($ev.Name -eq 'PreToolUse') { $preToolUsePaths += $eventPaths.Count; foreach ($p in $eventPaths) { $preToolUseNames.Add((Split-Path $p -Leaf)) } }
            }
        }
        catch { $settingsReadable = $false; $missingHooks.Add('settings.json does not parse: ' + $_.Exception.Message) }
    }
    $unregistered = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($hookFiles | Where-Object { $_.Name -like '*.ps1' })) {
        $named = $false
        foreach ($p in $registered) { if ((Split-Path $p -Leaf) -eq $f.Name) { $named = $true; break } }
        if (-not $named) { $unregistered.Add($f.Name) }
    }
    # A hook that only one profile may run (ADR 0020) is named in that profile file, never in
    # settings.json - putting it there would load it into every profile. It counts as named when
    # the profile registers parts 1, 2 and 3 of it under SessionStart and under SubagentStart,
    # each with an existing -File path. The live profile is read; a test target holds only the
    # template (placeholders still in it), so there the template must name it the same way.
    $profileOnlyHooks = @{ 'deepseek-orientation.ps1' = 'deepseek.json' }
    foreach ($leaf in @($profileOnlyHooks.Keys)) {
        if (-not $unregistered.Contains($leaf)) { continue }
        $liveProfile = Join-Path $HomeRoot ('.claude\profiles\' + $profileOnlyHooks[$leaf])
        $templateProfile = Join-Path $HomeRoot ('.claude\profiles-template\' + $profileOnlyHooks[$leaf])
        $useTemplate = -not (Test-Path -LiteralPath $liveProfile -PathType Leaf)
        $profilePath = if ($useTemplate) { $templateProfile } else { $liveProfile }
        try {
            $prof = [IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
            $wired = New-Object System.Collections.Generic.List[string]
            foreach ($ev in $prof.hooks.PSObject.Properties) {
                foreach ($entry in @($ev.Value)) {
                    foreach ($h in @($entry.hooks)) {
                        $parts = @($h.args | ForEach-Object { [string]$_ })
                        for ($ai = 0; $ai -lt $parts.Count - 3; $ai++) {
                            if (($parts[$ai] -match '^-{1,2}(file|f)$') -and ((Split-Path $parts[$ai + 1] -Leaf) -eq $leaf) -and ($parts[$ai + 2] -eq '-Part')) {
                                $scriptPath = $parts[$ai + 1] -replace '/', '\'
                                # a template still carries {{...}} placeholders; the file itself is judged by the live path only
                                if ($useTemplate -or (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { $wired.Add($ev.Name + ' ' + $parts[$ai + 3]) }
                            }
                        }
                    }
                }
            }
            $allWired = $true
            foreach ($evName in 'SessionStart', 'SubagentStart') { foreach ($n in 1, 2, 3) { if (-not $wired.Contains($evName + ' ' + $n)) { $allWired = $false } } }
            if ($allWired) { [void]$unregistered.Remove($leaf) }
        }
        catch { }   # unreadable profile: the file stays reported as not named
    }
    foreach ($need in $requiredUnderPreToolUse) {
        if (-not ($preToolUseNames -contains $need)) { $notUnderPreToolUse.Add($need) }
    }
    $ok = ($hookFiles.Count -ge 9) -and $hashAOk -and $hashBOk -and ($paused -eq 0) -and $suiteOk -and
          $settingsReadable -and ($registered.Count -ge 9) -and ($missingHooks.Count -eq 0) -and ($unregistered.Count -eq 0) -and
          ($disabled.Count -eq 0) -and ($deadMatchers.Count -eq 0) -and ($misplaced.Count -eq 0) -and
          ($unknownEvents.Count -eq 0) -and ($preToolUsePaths -ge 1) -and ($notUnderPreToolUse.Count -eq 0)
    $hookDetail = 'registered hook paths: ' + $registered.Count + ' (' + ($eventSummary -join ', ') + ')' +
                  $(if ($missingHooks.Count -gt 0) { '; MISSING/BROKEN: ' + ($missingHooks -join ', ') } else { ', all present' }) +
                  $(if ($unregistered.Count -gt 0) { '; NOT NAMED in settings.json: ' + ($unregistered -join ', ') } else { '; every hook file is named' }) +
                  $(if ($preToolUsePaths -ge 1) { '' } else { '; NO PreToolUse HOOK AT ALL' }) +
                  $(if ($disabled.Count -gt 0) { '; HOOKS SWITCHED OFF: ' + ($disabled -join ', ') } else { '' }) +
                  $(if ($deadMatchers.Count -gt 0) { '; MATCHER NAMES NO KNOWN TOOL: ' + ($deadMatchers -join ', ') } else { '' }) +
                  $(if ($misplaced.Count -gt 0) { '; TOOL MATCHER OUTSIDE PreToolUse: ' + ($misplaced -join ', ') } else { '' }) +
                  $(if ($unknownEvents.Count -gt 0) { '; EVENT NAME NOT KNOWN: ' + ($unknownEvents -join ', ') } else { '' }) +
                  $(if ($notUnderPreToolUse.Count -gt 0) { '; GUARD NOT REGISTERED UNDER PreToolUse: ' + ($notUnderPreToolUse -join ', ') } else { '; all five tool guards sit under PreToolUse' })
    Add-Result 10 'guards wired, nothing paused' 'settings.json and its siblings parsed as JSON; disableAllHooks must not be true anywhere; every PreToolUse matcher must name a known tool and a matcher naming tools must sit under PreToolUse (PostToolUse may register only the listed observer skill-usage.ps1); the event names must be known ones; every hook command path must exist and every hook file must be named; SHA256 of the two window guards; safety folder for *.ps1; test-add-to-archive.ps1 (live; it uses one fixed scratch folder of its own, so two runs at the same time can disturb it)' ($hookFiles.Count.ToString() + ' hook files; ' + $hookDetail + '; Hash A ok: ' + $hashAOk + '; Hash B ok: ' + $hashBOk + '; paused: ' + $paused + '; add-to-archive: ' + $sLine + ' (Exit ' + $sExit + '; suites 1-7: check 5)') '0' $ok
} catch { Add-Result 10 'guards active, nothing paused' 'check hooks' $_.Exception.Message '2' $false } }

# --------------------------------------------------------------- 11 review ---
if (Test-Selected '11') { try {
    $reviews = @(Get-ChildItem -LiteralPath $WorkRoot -Filter 'review-*.md' -File -ErrorAction SilentlyContinue | Sort-Object { [int]([regex]::Match($_.Name, 'review-(\d+)').Groups[1].Value) } -Descending)
    if ($reviews.Count -eq 0) { Add-Result 11 'review: 0 critical, 0 high' 'Get-ChildItem <work>\review-*.md' 'no review found' '2' $false }
    else {
        $latest = $reviews[0]
        $txt = [IO.File]::ReadAllText($latest.FullName)
        # The verdict: there may be exactly ONE adjacent OPEN-CRITICAL/OPEN-HIGH pair in the whole
        # file, each line standing alone, and it has to sit in the closing part (the last 20
        # non-empty lines). Two pairs mean the file states two verdicts - then it is not read at
        # all, because that is how a report quoting the closing block could decide the gate
        # (measured three times: reviews 3, 4 and 5 each defeated the previous rule). A missing
        # pair fails too.
        $allLines = @($txt -split "`r?`n")
        $nonEmpty = @($allLines | Where-Object { $_.Trim() -ne '' })
        # A pair inside a fenced code block is quoted text, not a verdict. Review 6 measured that a
        # report stating its findings in prose and quoting the closing block once inside ```text
        # otherwise decided this gate with the quoted pair.
        $fence = New-Object System.Collections.Generic.List[bool]
        $inFence = $false
        foreach ($line in $nonEmpty) {
            if ($line -match '^\s*(```|~~~)') { $fence.Add($true); $inFence = -not $inFence; continue }
            $fence.Add($inFence)
        }
        $pairs = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $nonEmpty.Count - 1; $i++) {
            $mK = [regex]::Match($nonEmpty[$i], '^OPEN-CRITICAL:\s*(\d+)\s*$')
            if (-not $mK.Success) { continue }
            $mH = [regex]::Match($nonEmpty[$i + 1], '^OPEN-HIGH:\s*(\d+)\s*$')
            if (-not $mH.Success) { continue }
            $pairs.Add([pscustomobject]@{ Critical = $mK.Groups[1].Value; High = $mH.Groups[1].Value; Index = $i; Fenced = ($fence[$i] -or $fence[$i + 1]) })
        }
        $quoted = @($pairs | Where-Object { $_.Fenced })
        $pairs = @($pairs | Where-Object { -not $_.Fenced })
        # A closing pair of 0/0 next to a report that states findings is a contradiction. Round 7
        # measured a report with a 2-critical findings table and a clean pair; it counted a finding
        # only when the word stood at the start of a line, and round 8 showed that 'Findings: 2
        # critical, 1 high' in the middle of a line stayed invisible. So: if the pair is 0/0, the
        # words critical and high may not occur at all outside the two lines of the CHOSEN pair and
        # outside fenced blocks (a quoted older report). Round 10 showed that exempting every line
        # shaped like a pair let a report put its findings in that very shape; only the two lines
        # the verdict is read from are exempt now. A report with nothing open writes its findings
        # history in other words - the check says so in its own output.
        $tailStart = [Math]::Max(0, $nonEmpty.Count - 20)
        $inTail = @($pairs | Where-Object { $_.Index -ge $tailStart })
        $krit = ''; $hoch = ''
        if ($pairs.Count -eq 1 -and $inTail.Count -eq 1) { $krit = $pairs[0].Critical; $hoch = $pairs[0].High }
        $verdictLines = New-Object System.Collections.Generic.List[int]
        if ($krit -ne '') { $verdictLines.Add($pairs[0].Index); $verdictLines.Add($pairs[0].Index + 1) }
        $claims = 0; $claimText = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $nonEmpty.Count; $i++) {
            if ($fence[$i]) { continue }
            if ($verdictLines -contains $i) { continue }
            if ($nonEmpty[$i] -match '\b(critical|high)\b') { $claims++; $claimText.Add($nonEmpty[$i].Trim()) }
        }
        $ok = ($krit -ne '') -and ($hoch -ne '') -and ([int]$krit -eq 0) -and ([int]$hoch -eq 0)
        if ($ok -and ($claims -gt 0)) { $ok = $false }
        $why = ''
        if (($krit -ne '') -and ([int]$krit -eq 0) -and ([int]$hoch -eq 0) -and ($claims -gt 0)) {
            $why = ' (the report states findings in ' + $claims + ' line(s) while its closing pair says 0/0 - e.g. "' + $claimText[0] + '"; a report with nothing open must not use those words)'
        }
        elseif ($pairs.Count -eq 0 -and $quoted.Count -gt 0) { $why = ' (the only verdict pair sits inside a fenced code block - quoted text is not a verdict)' }
        elseif ($pairs.Count -eq 0) { $why = ' (no verdict pair found)' }
        elseif ($pairs.Count -gt 1) { $why = ' (' + $pairs.Count + ' verdict pairs in the file - an ambiguous report is not read as a pass)' }
        elseif ($inTail.Count -eq 0) { $why = ' (the pair stands before the last 20 non-empty lines)' }
        $fileList = (@(Get-ChildItem -LiteralPath $WorkRoot -Filter 'review-*.md' -File | Sort-Object Name | ForEach-Object { $_.Name + ' ' + $_.LastWriteTime.ToString('HH:mm') }) -join ', ')
        Add-Result 11 'review: 0 critical, 0 high' ('Require exactly one OPEN-CRITICAL/OPEN-HIGH pair, standing alone, outside a code fence, in the last 20 non-empty lines of the newest ' + $latest.Name + '; a 0/0 pair forbids the words critical/high anywhere else in the file (outside fences) - a report with nothing open writes its history in other words') ($latest.Name + ': critical=' + $(if ($krit -eq '') { 'not read' } else { $krit }) + ', high=' + $(if ($hoch -eq '') { 'not read' } else { $hoch }) + ', findings stated in the text: ' + $claims + $why + '; review files on record: ' + $fileList) '0' $ok
    }
} catch { Add-Result 11 'review: 0 critical, 0 high' 'parse review-*.md' $_.Exception.Message '2' $false } }

# -------------------------------------------------------------- 12 BERICHT ---
# The report of the CURRENT state, not just any report. Measured 2026-10-14: the work root still
# held the report of the previous task (its title announced a final folder structure, dated
# 2026-10-12) and this check would have called it a pass while the report of the running task sat
# in C:\Dev\Temp\cross-platform. The report must therefore name the version of the newest CHANGELOG
# section - an old report cannot satisfy that - and the output names the file it read and that
# version, so a reader sees which report was judged.
if (Test-Selected '12') { try {
    $bericht = Join-Path $WorkRoot 'BERICHT.md'
    $changelog = Join-Path $RepoRoot 'CHANGELOG.md'
    $version = ''
    if (Test-Path -LiteralPath $changelog) {
        $m = [regex]::Match([IO.File]::ReadAllText($changelog), '(?m)^##\s+(\d+\.\d+\.\d+)')
        if ($m.Success) { $version = $m.Groups[1].Value }
    }
    if (-not $version) { Add-Result 12 'BERICHT.md with 8 sections' ('read the newest ## <version> from ' + $changelog) 'CHANGELOG.md has no version heading' '2' $false }
    elseif (-not (Test-Path -LiteralPath $bericht)) { Add-Result 12 'BERICHT.md with 8 sections' ('Test-Path ' + $bericht) ('file missing - the report of this state belongs there (its path is the work root the acceptance run reads)') '2' $false }
    else {
        $txt = [IO.File]::ReadAllText($bericht)
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($i in 1..8) { if ($txt -notmatch ('(?m)^## ' + $i + '[\.\)]?\s')) { $missing.Add([string]$i) } }
        $stale = ($txt -notmatch [regex]::Escape($version))
        $ok = ($missing.Count -eq 0) -and (-not $stale)
        $detail = 'read ' + $bericht + ' (' + (Get-Item -LiteralPath $bericht).LastWriteTime.ToString('yyyy-MM-dd HH:mm') + '); names version ' + $version + ': ' + (-not $stale) +
                  $(if ($missing.Count -gt 0) { '; missing sections: ' + ($missing -join ', ') } else { '; all 8 sections present' }) +
                  $(if ($stale) { '; IT DOES NOT NAME ' + $version + ' - this is the report of an older state' } else { '' })
        Add-Result 12 'BERICHT.md with 8 sections' ('Parse ^## 1..8 and the newest CHANGELOG version in ' + $bericht) $detail '0' $ok
    }
} catch { Add-Result 12 'BERICHT.md with 8 sections' 'check BERICHT.md' $_.Exception.Message '2' $false } }

# ------------------------------------------------------------------- A layout ---
if (Test-Selected 'A') { try {
    Push-Location $RepoRoot
    $stOut = (& pwsh -NoProfile -File setup/tools/check-structure.ps1 2>&1 | Out-String)
    $stExit = $LASTEXITCODE
    Pop-Location
    $stLine = ([regex]::Match($stOut, 'STRUCTURE: [^\r\n]+')).Value
    $ok = ($stExit -eq 0) -and ($stOut -match 'STRUCTURE-OK') -and $script:toolsOk
    Add-Result 'A' 'layout matches docs/structure.md' 'pwsh -File setup/tools/check-structure.ps1' ($stLine + '; STRUCTURE-OK') $stExit $ok
} catch { Add-Result 'A' 'layout matches docs/structure.md' 'check-structure.ps1' $_.Exception.Message '2' $false } }

# --------------------------------------------------------------- B clean root ---
if (Test-Selected 'B') { try {
    $expectedDirs = @('.github', 'dev', 'docs', 'home', 'linux', 'macos', 'setup', 'tests', 'vault', 'windows')
    # SECURITY.md came with the release (v3.0.0): a public repository needs a way to report a problem
    $expectedFiles = @('.gitattributes', '.gitignore', '.gitleaks.toml', 'AGENTS.md', 'bootstrap.ps1', 'bootstrap.sh', 'CHANGELOG.md', 'CLAUDE.md', 'README.md', 'SECURITY.md', 'install.ps1')
    Push-Location $RepoRoot
    $tracked = @(& git ls-files)
    Pop-Location
    $top = @($tracked | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique | Sort-Object)
    $unexpected = @($top | Where-Object { ($expectedDirs -notcontains $_) -and ($expectedFiles -notcontains $_) })
    $missing = @(@($expectedDirs + $expectedFiles) | Where-Object { $top -notcontains $_ })
    # git ls-files cannot see an untracked file, so the real directory is read too: a stray
    # notes.txt in the root is exactly the mess this check exists for
    $onDisk = @(Get-ChildItem -LiteralPath $RepoRoot -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object { $_.Name } | Sort-Object)
    # PROGRESS.md is local working state (the agent rule in CLAUDE.md writes it; .gitignore lists it): it is no
    # stray file while git ignores it. Anything else untracked stays a finding, and a tracked PROGRESS.md is one
    # too (it is not in $expectedFiles, so it shows as UNEXPECTED above).
    $allowedLocal = @('PROGRESS.md')
    $localOk = @()
    # The repo's own .gitignore must list it: a per-clone .git/info/exclude would hide the file on this PC only.
    $ignoreFile = Join-Path $RepoRoot '.gitignore'
    $ignoreLines = if (Test-Path -LiteralPath $ignoreFile) { @(Get-Content -LiteralPath $ignoreFile) } else { @() }
    foreach ($name in $allowedLocal) {
        if ($tracked -contains $name) { continue }
        if ($ignoreLines | Where-Object { $_.Trim() -eq $name -or $_.Trim() -eq "/$name" }) { $localOk += $name }
    }
    $stray = @($onDisk | Where-Object { ($expectedDirs -notcontains $_) -and ($expectedFiles -notcontains $_) -and ($localOk -notcontains $_) })
    $ok = ($unexpected.Count -eq 0) -and ($missing.Count -eq 0) -and ($stray.Count -eq 0) -and $script:toolsOk
    $detail = 'root: ' + ($top -join ' ') + $(if ($unexpected.Count -gt 0) { '; UNEXPECTED: ' + ($unexpected -join ' ') } else { '' }) + $(if ($missing.Count -gt 0) { '; MISSING: ' + ($missing -join ' ') } else { '' }) + $(if ($stray.Count -gt 0) { '; UNTRACKED ON DISK: ' + ($stray -join ' ') } else { '; ' + $onDisk.Count + ' entries on disk, none untracked' })
    Add-Result 'B' 'root holds exactly the documented entries' 'git ls-files + Get-ChildItem -Force at the root, compared with the list in the task section 3' $detail '0' $ok
} catch { Add-Result 'B' 'root holds exactly the documented entries' 'git ls-files' $_.Exception.Message '2' $false } }

# ------------------------------------------------------------ C no old paths ---
if (Test-Selected 'C') { try {
    # The old paths live in their own file. They cannot sit here: most of them are unanchored
    # substrings, so this search would find its own pattern list in this file - and hiding the
    # acceptance script from the very search it runs would be the weakest possible answer.
    # setup/tools/old-paths.txt carries the patterns and explains the guards.
    $patternFile = Join-Path $PSScriptRoot 'old-paths.txt'
    if (-not (Test-Path -LiteralPath $patternFile)) { throw ('pattern file missing: ' + $patternFile) }
    $oldPatterns = @(Get-Content -LiteralPath $patternFile | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })
    if ($oldPatterns.Count -eq 0) { throw 'the pattern file is empty' }
    Push-Location $RepoRoot
    $repoHits = New-Object System.Collections.Generic.List[string]
    # Five documented exceptions, each with its reason in the output. They are the files that
    # have to name the old paths: the record of what was true (CHANGELOG), the record of the move
    # itself (ADR 0014), the pattern list, the German word list of check E, and the unmanaged
    # scan of drift-check.ps1 (its exclusion table must spell the owner's live German vault
    # folder to exclude it - found by the first acceptance run after the unmanaged scan landed,
    # 2026-10-16; this very file may not spell that name, or the search finds itself).
    $skipOldPathFiles = @('CHANGELOG.md', 'docs/decisions/0014-final-layout.md',
                          'setup/tools/old-paths.txt', 'setup/tools/check-language.ps1',
                          'setup/tools/drift-check.ps1')
    # The documented scratch paths are skipped by their REPO-RELATIVE path, not by name: review 5
    # showed that a plain name match silently skipped docs/install-test/ (which is content, not
    # scratch). Junctions and symlinks are not followed - the walk stays inside the repository.
    # .git is not descended into at all.
    $skipRegex = '^(tests/_tmp|tools/_scratch|install-test)(/|$)|(^|/)__pycache__(/|$)'
    $repoFiles = New-Object System.Collections.Generic.List[string]
    $skipped = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $RepoRoot -Force)) {
        if ($item.Name -eq '.git') { $skipped++; continue }
        if ($item.PSIsContainer) {
            foreach ($f in @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force)) {
                # parentheses around the -replace: inside a method call PowerShell otherwise reads
                # it as two arguments and throws "no overload for Add with 2 arguments"
                $rel = ($f.FullName.Substring($RepoRoot.Length).TrimStart('\') -replace '\\', '/')
                if ($rel -match $skipRegex) { $skipped++; continue }
                $repoFiles.Add($rel)
            }
        }
        else { $repoFiles.Add($item.Name) }
    }
    # the counters tell what was READ, not what was listed: review 6 measured that the excluded
    # files and every binary were counted as searched (finding 6)
    $searched = 0; $excluded = 0; $binary = 0; $unread = 0
    foreach ($rel in $repoFiles) {
        if ($skipOldPathFiles -contains $rel) { $excluded++; continue }
        $full = Join-Path $RepoRoot ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $unread++; continue }
        $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
        if (@('.png', '.jpg', '.ico', '.pdf', '.zip') -contains $ext) { $binary++; continue }
        $text = ''
        try { $text = [IO.File]::ReadAllText($full) } catch { $unread++; continue }
        $searched++
        foreach ($p in $oldPatterns) { if ($text -match $p) { $repoHits.Add($rel + '  <- ' + $p); break } }
    }
    Pop-Location
    # the same search outside the repo: the rules that tell an agent what to run
    $outsideHits = New-Object System.Collections.Generic.List[string]
    $outsideFiles = New-Object System.Collections.Generic.List[string]
    $outsideFiles.Add((Join-Path $env:USERPROFILE '.claude\CLAUDE.md'))
    $outsideFiles.Add((Join-Path $env:USERPROFILE '.claude\TROUBLESHOOTING.md'))
    foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.claude\rules') -File -ErrorAction SilentlyContinue)) { $outsideFiles.Add($f.FullName) }
    $vaultPath = ([string]((Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.personal-os\personal.yaml') -Raw) -split "`n" | Where-Object { $_ -match '^vault_path:' }) -replace '^vault_path:\s*', '').Trim("'", '"', ' ')
    if ($vaultPath -and (Test-Path -LiteralPath $vaultPath)) {
        $outsideFiles.Add((Join-Path $vaultPath 'AGENTS.md'))
        $outsideFiles.Add((Join-Path $vaultPath 'CLAUDE.md'))
        $vr = Join-Path $vaultPath '.claude\rules'
        if (Test-Path -LiteralPath $vr) { foreach ($f in (Get-ChildItem -LiteralPath $vr -File -ErrorAction SilentlyContinue)) { $outsideFiles.Add($f.FullName) } }
    }
    foreach ($f in $outsideFiles) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $text = [IO.File]::ReadAllText($f)
        # the full path, not the leaf name: three files named CLAUDE.md are searched here and the
        # leaf alone does not tell which one hit
        foreach ($p in $oldPatterns) { if ($text -match $p) { $outsideHits.Add($f + '  <- ' + $p); break } }
    }
    $total = $repoHits.Count + $outsideHits.Count
    $ok = ($total -eq 0)
    $detail = 'repo: ' + $repoHits.Count + ' hit(s)' + $(if ($repoHits.Count -gt 0) { ' [' + ($repoHits -join ' | ') + ']' } else { '' }) +
              '; claude-config + vault rules: ' + $outsideHits.Count + ' hit(s)' + $(if ($outsideHits.Count -gt 0) { ' [' + ($outsideHits -join ' | ') + ']' } else { '' }) +
              '; ' + $oldPatterns.Count + ' patterns from old-paths.txt; ' + $searched + ' of ' + $repoFiles.Count + ' file(s) on disk read (' + $excluded + ' documented exclusions, ' + $binary + ' binary by extension, ' + $unread + ' unreadable); ' + $skipped + ' path(s) not walked at all (.git and the scratch paths tests/_tmp, tools/_scratch, install-test, __pycache__; junctions and symlinks are not followed); excluded files that must name the old paths: ' + ($skipOldPathFiles -join ', ') +
              '; limit: a bare folder name is only searched in its single-quoted form - bare winget is a legitimate value 14 times and cannot be told apart'
    Add-Result 'C' 'no old path survives' 'every file on disk under the repo root (skipping .git and the scratch folders) + the claude-config rules + the vault rules, searched for every old path (setup/tools/old-paths.txt)' $detail '0' $ok
} catch { Add-Result 'C' 'no old path survives' 'search old paths' $_.Exception.Message '2' $false } }

# ------------------------------------------------------------ D history kept ---
if (Test-Selected 'D') { try {
    # five files that were moved: the history must reach back BEFORE the move. Counting commits
    # is not the test (review 10): a file added and then edited today has two of them. The test
    # is whether any commit that `--follow` reaches is an ancestor of the phase-0 baseline
    # (41c583d, the commit this task started from). The rule was red for real until the v2.1.0
    # history repair: the old targets folder's VAULT subtree had been recorded as a deletion in
    # one commit and the identical tree as an addition in the next, which --follow cannot
    # bridge. The two move commits were rebuilt, the second as a rename (every tree but the
    # first replacement's is byte-identical to the original); every probe reaches back now, and
    # the check turns red again the moment a move is recorded as delete plus add. One measured
    # limit: a later commit that renames an unrelated file with pre-move history onto a probed
    # path satisfies this rule without bridging the move - the check asks whether `--follow`
    # reaches back, not along which lineage.
    # (The wording avoids the old-path pattern on purpose: this file stays visible to check C,
    # which found the first version of this very comment - review 11, finding 1.)
    $baseline = '41c583d'
    # --- the release history: the old history lives in the archive --------------------------
    # Since v3.0.0 this repository IS the fresh release history (docs/decisions/0016): the tree
    # of the release, and the whole old history in the private repository
    # `personal-os-setup-history`. `git log --follow` has nothing to follow there, so the five
    # probes above cannot be asked at all - and skipping the check would let a repository whose
    # history was thrown away pass as "history kept". What is asked instead is the property the
    # release promises: a release tag that HEAD builds on, the `history` remote names the
    # archive, and that archive still answers.
    # Two shapes of it are asked. The release itself, one commit with the tag on it (v3.0.0).
    # And every commit after it (v3.0.1 added five): there `headCount` is more than one and no
    # tag points at HEAD, so the `-eq 1` test alone turned this check red for the repository's
    # own normal state - the acceptance run of 2026-10-15 measured exactly that. What decides
    # whether the probes can be asked at all is not the commit count but whether the old
    # baseline is part of this repository's lineage: it is in the archive, not here. A repository
    # that really carries the old history still takes the probe branch below, unchanged.
    Push-Location $RepoRoot
    $headCount = 0
    try { $headCount = [int](@(& git rev-list --count HEAD 2>$null)[0]) } catch { $headCount = 0 }
    $baselineHere = $false
    if ($headCount -gt 1) {
        try {
            $null = (& git cat-file -e ($baseline + '^{commit}') 2>$null)
            if ($LASTEXITCODE -eq 0) {
                $null = (& git merge-base --is-ancestor $baseline HEAD 2>$null)
                $baselineHere = ($LASTEXITCODE -eq 0)
            }
        } catch { $baselineHere = $false }
    }
    if ($headCount -eq 1) {
        $tagAtHead = @(& git tag --points-at HEAD 2>$null)
        $histUrl = ''
        try { $histUrl = [string](& git remote get-url history 2>$null) } catch { $histUrl = '' }
        $reachable = $false
        if ($histUrl) {
            $null = (& git ls-remote --exit-code history HEAD 2>&1)
            $reachable = ($LASTEXITCODE -eq 0)
        }
        Pop-Location
        $ok = ($tagAtHead.Count -ge 1) -and ($histUrl -match 'personal-os-setup-history') -and $reachable -and $script:toolsOk
        $detail = 'one commit (the release history), tags on it: ' + $(if ($tagAtHead.Count -gt 0) { $tagAtHead -join ', ' } else { 'NONE' }) +
                  '; history remote: ' + $(if ($histUrl) { $histUrl } else { 'MISSING' }) +
                  '; the archive answers ls-remote: ' + $reachable +
                  '; the five --follow probes of the old history are not asked here - a repository with one commit has no history to follow'
        Add-Result 'D' 'history of moved files kept' ('git rev-list --count HEAD; git tag --points-at HEAD; git remote get-url history; git ls-remote --exit-code history HEAD; the old test (git log --follow over 5 moved files against the ancestors of ' + $baseline + ') applies to a history with more than one commit and is kept for that case') $detail '0' $ok
    }
    elseif ($headCount -eq 0) { Pop-Location; throw 'git rev-list --count HEAD answered nothing - is this a repository?' }
    elseif (-not $baselineHere) {
        $tagReachable = @(& git tag --merged HEAD 2>$null)
        $histUrl = ''
        try { $histUrl = [string](& git remote get-url history 2>$null) } catch { $histUrl = '' }
        $reachable = $false
        if ($histUrl) {
            $null = (& git ls-remote --exit-code history HEAD 2>&1)
            $reachable = ($LASTEXITCODE -eq 0)
        }
        Pop-Location
        $ok = ($tagReachable.Count -ge 1) -and ($histUrl -match 'personal-os-setup-history') -and $reachable -and $script:toolsOk
        $detail = ($headCount.ToString() + ' commit(s) (the release history, grown past the release); release tags HEAD builds on: ' + $(if ($tagReachable.Count -gt 0) { $tagReachable -join ', ' } else { 'NONE' })) +
                  '; history remote: ' + $(if ($histUrl) { $histUrl } else { 'MISSING' }) +
                  '; the archive answers ls-remote: ' + $reachable +
                  '; the baseline ' + $baseline + ' is not in this lineage, so the five --follow probes have nothing to follow here - a history with the old baseline in it still takes the probe branch'
        Add-Result 'D' 'history of moved files kept' ('git rev-list --count HEAD; git tag --merged HEAD; git remote get-url history; git ls-remote --exit-code history HEAD; the old test (git log --follow over 5 moved files against the ancestors of ' + $baseline + ') is asked whenever ' + $baseline + ' is an ancestor of HEAD') $detail '0' $ok
    }
    else {
        $probe = @(
            'home/.claude/hooks/block-dangerous.ps1',
            'vault/AGENTS.md',
            'dev/External/CLAUDE.md',
            'setup/tools/check.ps1',
            'home/Documents/PowerShell/Microsoft.PowerShell_profile.ps1'
        )
        $ancestors = @(& git rev-list $baseline)
        $ancestorSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($a in $ancestors) { [void]$ancestorSet.Add($a.Trim()) }
        $bad = New-Object System.Collections.Generic.List[string]
        $detail = New-Object System.Collections.Generic.List[string]
        foreach ($p in $probe) {
            $hashes = @(& git log --follow --format='%H' -- $p)
            $before = $false
            foreach ($h in $hashes) { if ($ancestorSet.Contains($h.Trim())) { $before = $true; break } }
            if (-not $before) { $bad.Add($p) }
            $detail.Add((Split-Path $p -Leaf) + ': ' + $hashes.Count + ' commit(s) via --follow, reaches back before the move: ' + $before)
        }
        Pop-Location
        $ok = ($bad.Count -eq 0) -and $script:toolsOk
        Add-Result 'D' 'history of moved files kept' ('git log --follow --format=%H -- <5 moved files>, each result checked against the ancestors of the phase-0 baseline ' + $baseline) (($detail -join '; ') + $(if ($bad.Count -gt 0) { '; NO COMMIT FROM BEFORE THE MOVE: ' + ($bad -join ', ') } else { '' })) '0' $ok
    }
} catch { Add-Result 'D' 'history of moved files kept' 'git log --follow' $_.Exception.Message '2' $false } }

# ----------------------------------------------------------- E English only ---
if (Test-Selected 'E') { try {
    Push-Location $RepoRoot
    $lgOut = (& pwsh -NoProfile -File setup/tools/check-language.ps1 2>&1 | Out-String)
    $lgExit = $LASTEXITCODE
    Pop-Location
    $lgLine = ([regex]::Match($lgOut, 'LANGUAGE: [^\r\n]+')).Value
    $tol = ([regex]::Match($lgOut, 'tolerated \([^)]*\): (\d+) file')).Groups[1].Value
    $ok = ($lgExit -eq 0) -and ($lgOut -match 'LANGUAGE-OK')
    Add-Result 'E' 'English only' 'pwsh -File setup/tools/check-language.ps1' ($lgLine + '; LANGUAGE-OK; tolerated files, each with a written reason: ' + $tol + ' (the check is a word list plus umlauts - it finds German prose, it does not prove English)') $lgExit $ok
} catch { Add-Result 'E' 'English only' 'check-language.ps1' $_.Exception.Message '2' $false } }

# --------------------------------------------------------- F skeleton only ---
if (Test-Selected 'F') { try {
    Import-Module Pester -RequiredVersion 5.9.1 -ErrorAction Stop
    Push-Location $RepoRoot
    $r = Invoke-Pester (Join-Path $RepoRoot 'tests\Structure.Tests.ps1') -Output None -PassThru
    Pop-Location
    $ok = ($r.FailedCount -eq 0) -and ($r.PassedCount -gt 0)
    Add-Result 'F' 'mirror folders hold only the installable skeleton' 'Invoke-Pester tests/Structure.Tests.ps1' ('PESTER: ' + $r.PassedCount + ' passed, ' + $r.FailedCount + ' failed, ' + $r.SkippedCount + ' skipped') '0' $ok
} catch { Add-Result 'F' 'mirror folders hold only the installable skeleton' 'Invoke-Pester tests/Structure.Tests.ps1' $_.Exception.Message '2' $false } }

# ------------------------------------------------------------- G dot names ---
if (Test-Selected 'G') { try {
    $target = Join-Path $WorkRoot ('verify-all-dots-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Push-Location $RepoRoot
    $inOut = (& pwsh -NoProfile -File install.ps1 -TargetRoot $target -NonInteractive 2>&1 | Out-String)
    $inExit = $LASTEXITCODE
    Pop-Location
    $dots = @(
        (Join-Path $target 'HOME\.claude\.gitignore'),
        (Join-Path $target 'HOME\.claude\.gitattributes'),
        (Join-Path $target 'HOME\.claude\.gitleaksignore'),
        (Join-Path $target 'HOME\.claude\.kopiaignore'),
        (Join-Path $target 'VAULT\.stignore')
    )
    $missing = @($dots | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    # and the repo must store them WITHOUT the dot
    $repoDots = @(
        'home/.claude/gitignore', 'home/.claude/gitattributes', 'home/.claude/gitleaksignore',
        'home/.claude/kopiaignore', 'vault/stignore'
    )
    Push-Location $RepoRoot
    $tracked = @(& git ls-files)
    Pop-Location
    $repoMissing = @($repoDots | Where-Object { $tracked -notcontains $_ })
    $ok = ($inExit -eq 0) -and ($missing.Count -eq 0) -and ($repoMissing.Count -eq 0) -and $script:toolsOk
    $detail = 'installed: ' + ($dots.Count - $missing.Count) + '/' + $dots.Count + ' dot-named file(s) present' +
              $(if ($missing.Count -gt 0) { '; MISSING: ' + (($missing | ForEach-Object { Split-Path $_ -Leaf }) -join ' ') } else { '' }) +
              '; stored without the dot in the repo: ' + ($repoDots.Count - $repoMissing.Count) + '/' + $repoDots.Count
    Add-Result 'G' 'dot-name convention works in a test install' 'install.ps1 -TargetRoot <new>; Test-Path the five dot names; git ls-files for the stored form' $detail $inExit $ok
} catch { Add-Result 'G' 'dot-name convention works in a test install' 'install.ps1 -TargetRoot <new>' $_.Exception.Message '2' $false } }

# ------------------------------------------------------ H platform map ---
# Every manifest component must answer for all three systems. A missing entry is how a
# component silently disappears on a system nobody tested - exactly the gap this task exists
# to close. An entry may be `unsupported: <reason>`; a bare "unsupported" without a reason is
# a hole, not an answer.
#
# Second half, added after the ubuntu job failed on it: where the map says `files`, the file
# has to BE there. Measured 2026-10-14: `pwsh-profile-unix` promised
# home/.config/powershell/profile.ps1, nobody had written it, and the linux job died in the
# file stage with `repo file missing` while Windows never noticed (the component is
# `unsupported` there, so the stage skips it before it looks). A promise without the file is
# a hole of the same kind, so it belongs to the same check.
if (Test-Selected 'H') { try {
    . (Join-Path $RepoRoot 'setup/lib/manifest.ps1')
    . (Join-Path $RepoRoot 'setup/lib/platform.ps1')
    $manifest = Get-Manifest -Path (Join-Path $RepoRoot 'setup/manifest.yaml')
    $platforms = Get-PlatformData -RepoRoot $RepoRoot
    $components = @(Get-ManifestField $manifest 'components')
    $missing = New-Object System.Collections.Generic.List[string]
    $reasonless = New-Object System.Collections.Generic.List[string]
    $noFile = New-Object System.Collections.Generic.List[string]
    $unsupported = 0
    foreach ($e in $components) {
        $id = [string](Get-ManifestField $e 'id')
        $type = [string](Get-ManifestField $e 'type')
        foreach ($os in @('windows', 'macos', 'linux')) {
            $v = [string](Get-PlatformValue -Platforms $platforms -ComponentId $id -Os $os)
            if (-not $v) { $missing.Add($id + '/' + $os); continue }
            if (Test-PlatformUnsupported $v) {
                $unsupported++
                if ((Get-UnsupportedReason $v).Length -lt 10) { $reasonless.Add($id + '/' + $os) }
                continue
            }
            if ($type -notin @('copy', 'template', 'doc-only')) { continue }
            $err = Test-RepoContentPresent -RepoRoot $RepoRoot -Entry $e -Target ([string](Get-ManifestField $e 'target'))
            if ($err) { $noFile.Add($id + '/' + $os + ': ' + $err) }
        }
    }
    $ok = ($missing.Count -eq 0) -and ($reasonless.Count -eq 0) -and ($noFile.Count -eq 0)
    $detail = $components.Count.ToString() + ' component(s) x 3 systems = ' + ($components.Count * 3) + ' entries; ' +
              $unsupported.ToString() + ' of them unsupported here and there, each with a reason' +
              $(if ($missing.Count -gt 0) { '; MISSING: ' + (($missing | Select-Object -First 5) -join ', ') } else { '' }) +
              $(if ($reasonless.Count -gt 0) { '; UNSUPPORTED WITHOUT A REASON: ' + (($reasonless | Select-Object -First 5) -join ', ') } else { '' }) +
              $(if ($noFile.Count -gt 0) { '; PROMISED BUT NOT IN THE REPO: ' + (($noFile | Select-Object -First 5) -join '; ') } else { '' })
    Add-Result 'H' 'platform map complete for all three systems' 'setup/platforms.yaml read through setup/lib/platform.ps1: Get-PlatformValue per component and system, Test-RepoContentPresent for every entry that installs content' $detail '0' $ok
} catch { Add-Result 'H' 'platform map complete for all three systems' 'read setup/platforms.yaml' $_.Exception.Message '2' $false } }

# --------------------------------------------------- I no Windows literals ---
# The portable engine must not carry an operating system of its own. A Windows literal is a
# drive path, a %VAR% or $env:VAR of Windows, a .exe, a winget/schtasks/registry/firewall call -
# the pattern table below is the list.
#
# Rule: a hit is a failure. Three kinds of exception exist, every one of them printed with its
# reason, and every one of them FAILS the check when it stops matching anything (so an exception
# cannot sit here after the text it excused is gone):
#   1. a DETECTION REGEX - a line whose job is to recognize a Windows command in someone else's
#      text. Two of them exist, both in one guard.
#   2. an ALLOWED FILE - a file where a Windows literal is inherent by its nature. Each carries
#      its reason and is reported with its hit count, so growth stays visible.
#   3. comment lines are not read at all. A comment cannot change what the code does, and the
#      guards' headers are the live system's text (the mirror may not change them).
# Not read at all: setup/platform/*.ps1 (the stage module of a system, Windows' literals live in
# windows.ps1), windows/ (the mirror folder with the package and task files) and this file.
if (Test-Selected 'I') { try {
    $patterns = [ordered]@{
        'drive-back'       = '(?:^|[^A-Za-z0-9_\\/])[A-Za-z]:[\\/][A-Za-z0-9_.$~-]'
        'drive-fwd'        = '(?:^|[^A-Za-z0-9_\\/])[A-Za-z]:/[A-Za-z0-9_.$~-]'
        # a UNC path (\\host\share...), not the "\\segment\\" of a regular expression
        'unc-path'         = '\\\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_.$-]'
        'env-userprofile'  = '\$env:USERPROFILE'
        'env-appdata'      = '\$env:APPDATA'
        'env-localappdata' = '\$env:LOCALAPPDATA'
        # TEMP and TMP are Windows names: on macOS/Linux they are unset, and a Join-Path with
        # them throws (measured in CI, 2026-10-14, in tests/Privacy-Scan.Tests.ps1)
        'env-temp'         = '\$env:TEMP\b'
        'env-tmp'          = '\$env:TMP\b'
        'cmd-userprofile'  = '%USERPROFILE%'
        'cmd-appdata'      = '%APPDATA%'
        'host-exe'         = '[A-Za-z0-9_-]\.exe\b'
        'winget-call'      = '\bwinget\s+(import|install|list|configure|source|search|upgrade|uninstall|export)\b'
        'schtasks'         = '\bschtasks\b'
        'task-cmdlet'      = '\b(Register|Get|Export|Unregister|Set|Enable|Disable|Start|Stop)-ScheduledTask\b'
        'firewall-cmdlet'  = '\b(New|Get|Remove|Set)-NetFirewallRule\b'
        'registry-drive'   = '\b(HKLM|HKCU|HKCR|HKU|HKCC):'
        'junction'         = 'New-Item\s+-ItemType\s+Junction'
        'runas'            = 'Start-Process[^\r\n]*-Verb\s+RunAs'
    }
    # 1. detection regexes: the line has to recognize a Windows command in text somebody else
    #    wrote. file | pattern | reason
    $exceptions = @(
        @{ File = 'home/.claude/hooks/onedrive-guard.ps1'; Pattern = 'cmd-userprofile'; Reason = 'its detection regex matches the Windows spelling of the home variable (case-insensitively) in a command it is judging' }
        @{ File = 'home/.claude/hooks/onedrive-guard.ps1'; Pattern = 'env-userprofile'; Reason = 'the same detection regex, PowerShell spelling' }
    )
    # 2. allowed files: Windows literals are inherent here. file | reason
    $allowedFiles = @(
        @{ File = 'setup/lib/platform.ps1'; Reason = 'it IS the platform module: the ONE placeholder table (three systems) and the per-system answers (home, state folder, venv, PowerShell host) live here' }
        @{ File = 'bootstrap.ps1'; Reason = 'the Windows start command: it runs before the repository is on disk and therefore cannot read the platform map; bootstrap.sh is the same file for macOS and Linux' }
        @{ File = 'setup/tools/check.ps1'; Reason = 'two dummy root values it feeds to the rendered guard suites; the guards under test carry drive-root path patterns, and the file states that reason at length' }
    )
    $engineFiles = @(
        'install.ps1', 'bootstrap.ps1',
        'setup/export.ps1', 'setup/verify.ps1', 'setup/restore.ps1',
        'setup/lib/manifest.ps1', 'setup/lib/platform.ps1', 'setup/lib/placeholders.ps1',
        'setup/lib/releases.ps1', 'setup/lib/ci-runs.ps1',
        'setup/tools/check.ps1', 'setup/tools/check-structure.ps1', 'setup/tools/check-language.ps1',
        'setup/tools/privacy-scan.ps1', 'setup/tools/drift-check.ps1', 'setup/tools/generate-docs.ps1',
        'setup/tools/install-fingerprint.ps1', 'setup/tools/ci-smoke.ps1',
        # added with the full-setup job (2026-10-14): the runner script runs on all three
        # systems, so the rule that no Windows literal creeps into it applies to it too
        'setup/tools/ci-full-setup.ps1'
    )
    $guardDir = Join-Path $RepoRoot 'home/.claude/hooks'
    $guardFiles = @(Get-ChildItem -LiteralPath $guardDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        ForEach-Object { 'home/.claude/hooks/' + $_.Name } | Sort-Object)
    $scanned = @($engineFiles) + @($guardFiles)
    $hits = New-Object System.Collections.Generic.List[string]
    $allowed = New-Object System.Collections.Generic.List[string]
    $usedExceptions = New-Object System.Collections.Generic.List[string]
    $missingFiles = 0
    foreach ($rel in $scanned) {
        $full = Join-Path $RepoRoot ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full)) { $hits.Add($rel + '  <- FILE MISSING'); $missingFiles++; continue }
        $allowedHere = @($allowedFiles | Where-Object { $_.File -eq $rel })
        $countHere = 0
        $inBlockComment = $false
        $lines = @([IO.File]::ReadAllText($full) -split "`r?`n")
        for ($ln = 0; $ln -lt $lines.Count; $ln++) {
            $line = $lines[$ln]
            $trimmed = $line.TrimStart()
            # comment lines: a `#` at the start of the line, or anywhere inside <# ... #>
            $wasInBlock = $inBlockComment
            if ($trimmed -match '^\s*<#') { $inBlockComment = $true }
            if ($trimmed -match '#>\s*$') { $inBlockComment = $false }
            if ($wasInBlock -or $trimmed.StartsWith('#') -or ($trimmed -match '^\s*<#')) { continue }
            foreach ($name in $patterns.Keys) {
                if ($line -notmatch $patterns[$name]) { continue }
                $ex = @($exceptions | Where-Object { ($_.File -eq $rel) -and ($_.Pattern -eq $name) })
                if ($ex.Count -gt 0) { $usedExceptions.Add($rel + '/' + $name); continue }
                if ($allowedHere.Count -gt 0) { $countHere++; continue }
                $hits.Add($rel + ':' + ($ln + 1) + '  <- ' + $name)
            }
        }
        if ($allowedHere.Count -gt 0) { $allowed.Add($rel + ': ' + $countHere + ' allowed hit(s) - ' + $allowedHere[0].Reason) }
    }
    # an exception or an allowed file that matches nothing any more is a lie - fail on it
    $stale = New-Object System.Collections.Generic.List[string]
    foreach ($ex in $exceptions) {
        if (-not ($usedExceptions -contains ($ex.File + '/' + $ex.Pattern))) { $stale.Add('exception unused: ' + $ex.File + '/' + $ex.Pattern) }
    }
    foreach ($a in $allowedFiles) {
        if (-not ($allowed -like ($a.File + ':*'))) { $stale.Add('allowed file without a hit: ' + $a.File) }
    }
    $ok = ($hits.Count -eq 0) -and ($stale.Count -eq 0) -and ($missingFiles -eq 0)
    $detail = [string]$scanned.Count + ' file(s) read (' + $engineFiles.Count + ' engine, ' + $guardFiles.Count + ' guard) against ' + $patterns.Count + ' patterns: ' + $hits.Count + ' hit(s)' +
              $(if ($hits.Count -gt 0) { ' [' + (($hits | Select-Object -First 5) -join ' | ') + ']' } else { '' }) +
              '; ' + $exceptions.Count + ' detection-regex exception(s), each in use; ' + $allowedFiles.Count + ' allowed file(s): ' + ($allowed -join ' + ') +
              $(if ($stale.Count -gt 0) { '; STALE: ' + ($stale -join ', ') } else { '' }) +
              '; comment lines are not read (a comment cannot change what the code does, and the guards'' headers are the live text); not read at all: setup/platform/*.ps1 (Windows literals belong in windows.ps1), windows/ (the package and task files) and this script'
    Add-Result 'I' 'no Windows literal outside the Windows module' 'every code line of the engine and of home/.claude/hooks/*.ps1 matched against the pattern table above' $detail '0' $ok
} catch { Add-Result 'I' 'no Windows literal outside the Windows module' 'scan the engine' $_.Exception.Message '2' $false } }

# --------------------------------------------------- J Windows unchanged ---
# The task's red line: Windows behaviour does not change. The proof is a fingerprint of a test
# install, taken from the v2.1.2 state BEFORE the first line of this work (2026-10-13 13:29, the
# tree in the acceptance work folder) and stored as tests/fixtures/install-baseline-v2.1.2.json.
# Paths and dates are normalised, so two runs in different folders on different days are
# comparable.
#
# The baseline was recorded with the LIVE personal values (a test install without -ConfigPath,
# which reads <home>/.personal-os/personal.yaml) - so this check installs the same way. With the
# dummy fixture config instead, eight files that render the account name would differ and the
# comparison would report a change that is none (measured 2026-10-14).
# An intended change must be listed below with its reason - one line each, never a blanket.
if (Test-Selected 'J') { try {
    $baselinePath = Join-Path $RepoRoot 'tests/fixtures/install-baseline-v2.1.2.json'
    if (-not (Test-Path -LiteralPath $baselinePath)) { throw ('baseline missing: ' + $baselinePath) }
    $liveConfig = Join-Path (Join-Path $HomeRoot '.personal-os') 'personal.yaml'
    if (-not (Test-Path -LiteralPath $liveConfig)) { throw ('the personal values of this account are missing: ' + $liveConfig + ' - without them the recorded state cannot be reproduced') }
    $baseline = [IO.File]::ReadAllText($baselinePath) | ConvertFrom-Json
    # Intended file changes on Windows: one. Everything else renders the live Windows text back
    # character for character (measured 2026-10-14: 131 of 132 identical). The exception is
    # home/.claude/life-os/requirements.txt, which the manifest marks as repo-authored (it has no
    # live source of its own, and the recursive export excludes it) - so it is the one mirrored
    # file whose text the repository owns. Its three nvidia-*-cu12 pins carry
    # `; sys_platform != "darwin"` since v2.3.1: pip stops at the first wheel it cannot find, and
    # no such wheel exists for macOS on Apple Silicon, so the whole venv stayed empty there
    # (measured in the first full-setup run of 2026-10-14). On Windows and Linux the marker
    # excludes nothing, so the same wheels install as before.
    $intended = @(
        @{ Path = 'HOME/.claude/life-os/requirements.txt'; Reason = 'repo-authored file: the three CUDA pins carry `; sys_platform != "darwin"` since v2.3.1, without which pip leaves the whole venv empty on macOS (measured 2026-10-14, first full-setup run)' }
        @{ Path = 'HOME/.claude/gitignore'; Reason = '2026-10-29 (video task): the two fetched video workflow templates are ignored, so neither repository keeps them (a decimal number in them reads as a 12-digit id to the privacy scan, ADR 0022)' }
        @{ Path = 'HOME/.claude/setup/powershell/add-to-archive.ps1'; Reason = 'v3.0.0: the category list left the file. It was a ValidateSet and is now read from the personal layer at run time (setup/lib/personal.ps1), because the folder names are personal and the repository is public' }
        @{ Path = 'HOME/.claude/setup/tests/test-add-to-archive.ps1'; Reason = 'v3.0.0: the same change on the test side - invented fixture names and a fixture personal values file, so no category name of this machine stands in a public repository' }
        @{ Path = 'HOME/.claude/setup/tests/test-archive-guard.ps1'; Reason = 'v3.0.0: personal fixture names replaced by invented ones (categories, authority abbreviations, life-area note names)' }
        @{ Path = 'HOME/.claude/setup/tests/test-onedrive-guard.ps1'; Reason = 'v3.0.0: personal fixture names replaced by invented ones' }
        @{ Path = 'HOME/.claude/setup/tests/test-trifecta-guard.ps1'; Reason = 'v3.0.0: personal fixture names replaced by invented ones' }
        @{ Path = 'HOME/.claude/CLAUDE.md'; Reason = 'v3.0.1: the size budget replaced the line count, and the copy rule names the source URL' }
        @{ Path = 'VAULT/AGENTS.md'; Reason = 'v3.0.1: the size budget replaced the line count, and the copy rule joined the hard rules' }
        @{ Path = 'HOME/.claude/docs/CHANGELOG.md'; Reason = 'v3.0.0: the vault skeleton note says "the repository" where it said "the private repository" - the sentence is untrue once the repository is public' }
        @{ Path = 'VAULT/README.md'; Reason = 'v3.0.0: the bullet that pointed at a blueprint repository nobody can open names this kit its own README instead; review 22 (F8) found the dead pointer' }
        @{ Path = 'HOME/.claude/skills/research/scripts/ai_patterns.py'; Reason = 'v3.0.1: the German lists are the source''s own lists again, restored verbatim from the pinned commit' }
        @{ Path = 'HOME/.claude/skills/research/references/style-rules.md'; Reason = 'v3.0.1: the German example sentences are the source''s own again, restored verbatim' }
        @{ Path = 'HOME/.claude/docs/research-standard.md'; Reason = 'v3.0.1: the style section names both sources of the condensed rules again' }
        @{ Path = 'HOME/.claude/hooks/no-license-files.ps1'; Reason = 'the owner''s task of 2026-10-15 (Part 3.1): a PreToolUse guard refuses an attribution file by name inside the project folder, the vault and .claude - measured red first (25 of 51 cases against a copy whose name list was emptied), green after' }
        @{ Path = 'HOME/.claude/setup/tests/test-no-license-files.ps1'; Reason = 'the suite of that guard: 51 cases, each a whole tool call, including the relative-path and dot-dot cases the review asked for' }
        @{ Path = 'HOME/.claude/skills/reuse-first/SKILL.md'; Reason = 'the same task (Part 2): the skill that says look for a proven solution before writing your own, with its form taken from anthropics/skills and the source line in the body' }
        @{ Path = 'HOME/.claude/settings.json'; Reason = 'the same task (Part 3.1): one PreToolUse entry for the file tools names the new guard - a hook file that no settings file names protects nothing' }
        @{ Path = 'HOME/.claude/setup/powershell/claude-profile-functions.ps1'; Reason = 'the same task (Part 3.3): version 12 sets CLAUDE_CODE_GOAL_CHECKIN_MINUTES=0 above the launcher functions, so an idle goal check-in no longer wakes a session nobody is waiting for' }
        @{ Path = 'HOME/.claude/skills/research/scripts/check_note.py'; Reason = 'the same task (Part 0.1): the guard that skipped a version standing behind a licence word is gone' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_check_note.py'; Reason = 'the same task (Part 0.1): the test case for that removed guard is gone' }
        @{ Path = 'HOME/.claude/setup/tests/research/run_mutations.py'; Reason = 'the same task (Part 0.1): the mutation entry for the removed guard is gone; the runner still catches 109 of 109' }
        @{ Path = 'HOME/.claude/hooks/stop-notify.ps1'; Reason = '2026-10-16: the notification is a real Windows toast (WinRT) under the PowerShell AUMID instead of a NotifyIcon balloon tip. Measured: a balloon from this hook never reaches the notification platform on this Windows build (no row for any of the machine''s 14 NotifyIcon handlers in wpndatabase.db), the toast does' }
        @{ Path = 'HOME/.claude/hooks/notification-idle.ps1'; Reason = 'the same change as stop-notify.ps1 (2026-10-16), for the idle_prompt notification' }
        @{ Path = 'HOME/.claude/hooks/notification-events.ps1'; Reason = 'the same change as stop-notify.ps1 (2026-10-16), for permission_prompt/agent_needs_input/agent_completed; the two texts are XML-escaped now, a message may contain <, > or &' }
        @{ Path = 'HOME/.claude/hooks/archive-guard.ps1'; Reason = 'the owner''s umlaut task (2026-10-16): the session state is read with [IO.File]::ReadAllText instead of Get-Content, which reads a BOM-less UTF-8 file in the ANSI code page under 5.1 - an umlaut document never matched its stored spelling again, was counted twice, and the eleven-document limit blocked one the session had already read. Red-proved against a copy with Get-Content: "document number 12 ... limit is 10" where the fixed guard allows' }
        @{ Path = 'HOME/.claude/hooks/block-dangerous.ps1'; Reason = 'the same task: Send-Block writes the message as UTF-8 bytes through [Console]::OpenStandardError() instead of [Console]::Error.WriteLine, which writes in the console''s OEM code page (a quoted Buecher arrived as the bytes 81 84 9A instead of C3 BC). Red-proved against a copy with only Send-Block reverted: exactly the new umlaut message case fails, 1 of 131' }
        @{ Path = 'HOME/.claude/hooks/downloads-guard.ps1'; Reason = 'the same Send-Block change; red-proved against a copy with only Send-Block reverted (1 of 73 cases) and against a copy whose stdin is read in the console code page (the same case, because the message quotes the statement)' }
        @{ Path = 'HOME/.claude/hooks/onedrive-guard.ps1'; Reason = 'the same Send-Block change; its block message quotes the blocked statement, so an umlaut path in it arrived as mojibake. Red-proved against a copy with only Send-Block reverted: 1 of 199 cases' }
        @{ Path = 'HOME/.claude/hooks/trifecta-guard.ps1'; Reason = 'the same Send-Block change. This guard''s messages are fixed text carrying no path, so no case of its suite can show the mojibake; measured instead that a copy reading stdin in the console code page passes the new umlaut cases and fails the suite''s older byte-order-mark case, which is this guard''s real detector for that defect' }
        @{ Path = 'HOME/.claude/setup/tests/test-block-dangerous.ps1'; Reason = 'the same task: the umlaut block - every case beside its ASCII twin, plus a case that reads stderr as UTF-8 and matches the umlaut in the message; 120 -> 131 cases, and $OutputEncoding is UTF-8 so the payload really carries the umlaut under both PowerShell hosts (measured: with the 5.1 default of us-ascii two suites went red against the correct guard)' }
        @{ Path = 'HOME/.claude/setup/tests/test-block-dangerous-51.ps1'; Reason = 'the same suite with one line changed - it starts the guard under Windows PowerShell 5.1 instead of pwsh, which is the host the pipe encoding broke. Regenerated from the main suite in the same step, so the two differ by that one line and by nothing else; measured green under both hosts, and red against a copy that decodes stdin as Windows-1252' }
        @{ Path = 'HOME/.claude/setup/tests/test-downloads-guard.ps1'; Reason = 'the same task: the umlaut block; 64 -> 73 cases, including the byte-exact message case that goes red against the old Send-Block and against a console-code-page stdin read' }
        @{ Path = 'HOME/.config/gitleaks/gitleaks.toml'; Reason = '2026-10-16: repo-authored now (type: doc-only). Mirroring the live file with the three personal paths dropped left an EMPTY [[allowlists]], and gitleaks 8.30.1 refuses such a config - a fresh install would have blocked every commit in every repository. The stored file keeps the public docs/vendor allowlist and the two extra rules and says where the personal exemptions live' }
        @{ Path = 'HOME/.claude/setup/tests/test-block-dangerous.ps1'; Reason = 'the same day, the previous task''s last fixes that had never been exported: the read-only exception for `git config core.hooksPath` and its two cases' }
        @{ Path = 'HOME/.claude/docs/repositories.md'; Reason = '2026-10-16: found by drift-check.ps1''s new unmanaged scan - the file sat live with no manifest entry. The same genre as agent-tooling.md, so it is mirrored like it (claude-docs-repositories)' }
        @{ Path = 'HOME/.claude/agents/web-researcher.md'; Reason = '2026-10-17: exa-key points at the tools-enabled URL (web_search_advanced_exa), and the agent carries the per-run caps, the Serper reserve and the skip-without-key rule' }
        @{ Path = 'HOME/.claude/skills/research/scripts/save_pages.py'; Reason = '2026-10-17: crawl4ai is the first fetcher, the services are the fallback, and PAGE_CAP bounds the fallback pages per service (arithmetic for 90 runs a month)' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_save_pages.py'; Reason = '2026-10-17: tests for the crawl4ai-first order (red-proved against the old order) and for the per-service page cap' }
        @{ Path = 'HOME/.claude/skills/research/SKILL.md'; Reason = '2026-10-17: per-run service caps, the Serper reserve rule, the skip-without-key rule, and a trigger narrowed so quick-research owns the single fact' }
        @{ Path = 'HOME/.claude/skills/quick-research/SKILL.md'; Reason = '2026-10-17: new skill for one quick fact - two searches and one page, no subagent, no scripts' }
        @{ Path = 'HOME/.claude/CLAUDE.md'; Reason = '2026-10-17: the quick-lookup line names the quick-research skill instead of sending the reader to Exa/Parallel by hand' }
        @{ Path = 'HOME/.claude/docs/research-standard.md'; Reason = '2026-10-17: section 2 states the per-run cap, the skipped service without a key, and the Serper reserve' }
        @{ Path = 'HOME/.claude/docs/agent-tooling.md'; Reason = '2026-10-17: crawl4ai is the first page reader, and the budget section carries the 90-runs-a-month arithmetic for every free tier' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/opencode/opencode.json'; Reason = '2026-10-17: the exa server carries the x-api-key env template and the tools URL; exa-key gets the same URL' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/codex/config-mcp.toml'; Reason = '2026-10-17: the exa server carries env_http_headers (x-api-key) and the tools URL; exa-key gets the same URL' }
        @{ Path = 'HOME/.agents/skills/web-research/SKILL.md'; Reason = '2026-10-17: new manifest component agents-skills deploys the portable skills to ~/.agents/skills; this is the web-research twin' }
        @{ Path = 'HOME/.agents/skills/docs-import/SKILL.md'; Reason = '2026-10-17: the same component, the docs-import twin; renamed on 2026-10-18 to docs-import-portable so OpenCode never sees two skills with one name' }
        @{ Path = 'HOME/.agents/skills/docs-import-portable/SKILL.md'; Reason = '2026-10-18: the neutral twin renamed to docs-import-portable (OpenCode docs require unique skill names across ~/.claude/skills and ~/.agents/skills)' }
        @{ Path = 'HOME/.agents/skills/quick-research-portable/SKILL.md'; Reason = '2026-10-18: the harness-neutral quick-research (inline steps, same scripts), named -portable so it cannot clash with the Claude Code skill' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/docs-import/SKILL.md'; Reason = '2026-10-17: the template twin of docs-import; renamed on 2026-10-18 to docs-import-portable with its ~/.agents twin' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/docs-import-portable/SKILL.md'; Reason = '2026-10-18: the template twin renamed to the non-clashing name' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/quick-research-portable/SKILL.md'; Reason = '2026-10-18: the template twin of the harness-neutral quick-research' }
        @{ Path = 'HOME/.claude/skills/research/scripts/crawl4ai_fetch.py'; Reason = '2026-10-18: one browser session for all URLs through arun_many and MemoryAdaptiveDispatcher, stealth on, UTF-8 JSON lines out; the per-URL crwl call died on the Windows charmap (measured)' }
        @{ Path = 'HOME/.claude/skills/research/scripts/check_services.py'; Reason = '2026-10-18: a keyed service without a key is reported as skipped and Serper as the reserve, not as missing; --transcript-dir counts a Workflow run''s agent transcripts' }
        @{ Path = 'HOME/.claude/skills/research/research.workflow.js'; Reason = '2026-10-18 (batch-and-hygiene Part 5b): the research skill as a dynamic workflow - same passes, order and caps, args input, no Date.now' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_check_services.py'; Reason = '2026-10-18: tests for skipped-without-key and the Serper reserve; the key environment is fixed per test' }
        @{ Path = 'HOME/.claude/setup/tests/research/testlib.py'; Reason = '2026-10-18: run_script takes an explicit environment, so a test never inherits the machine''s real keys' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/web-research/SKILL.md'; Reason = '2026-10-17: the portable twin now names exa and exa-key as one EXA_API_KEY account, matching the installed servers' }
        @{ Path = 'HOME/.claude/setup/powershell/set-research-keys.ps1'; Reason = '2026-10-17: on macOS/Linux the keys persist in a 0600 env file sourced from the profiles; Windows keeps its user environment variables' }
        @{ Path = 'DOCUMENTS/PowerShell/Microsoft.PowerShell_profile.ps1'; Reason = '2026-10-19: restore-tools appends the key import to an existing profile; the owner ran it' }
        @{ Path = 'DOCUMENTS/WindowsPowerShell/Microsoft.PowerShell_profile.ps1'; Reason = '2026-10-19: the same key import in the 5.1 profile' }
        @{ Path = 'HOME/.claude/agents/research-writer.md'; Reason = '2026-10-19: the writer is told that fix_quotes.py repairs near-miss quotes as a safety net; the exact-copy rule stays' }
        @{ Path = 'HOME/.claude/skills/research/scripts/fix_quotes.py'; Reason = '2026-10-19: deterministic quoting - a fragment at least 90 % similar to its evidence is replaced with the evidence''s exact span before check_article.py; no model call' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_fix_quotes.py'; Reason = '2026-10-19: tests for the deterministic quote repair, red before the implementation' }
        @{ Path = 'HOME/.claude/skills/research/scripts/fetch_page.py'; Reason = '2026-10-18 (fetch-always Part 1): the one entry point for every page fetch - Crawl4AI first through save_pages.py, direct download for non-HTML files, 24 h cache, output without page text. It reuses save_pages.py instead of duplicating fetch logic' }
        @{ Path = 'HOME/.claude/hooks/fetch-guard.ps1'; Reason = '2026-10-18 (fetch-always Part 3): PreToolUse guard - WebFetch, the MCP page readers by pattern and shell fetches that print a page are denied; search tools, file downloads, API calls and gh stay allowed; the user-only override is honoured and setting it persistently is denied; fail closed. The review of the same day measured six bypasses (URL in a variable, line continuation, path-qualified command, uv run, node require, server-prefixed MCP name) and one false block (override words in a commit message); all fixed and covered by 19 new cases; 2026-10-24: online picture services (pollinations.ai and the like), image endpoints and image-making MCP tools are denied for every sink and under the override, so pictures come only from the /image skill' }
        @{ Path = 'HOME/.claude/setup/tests/test-fetch-guard.ps1'; Reason = '2026-10-18 (fetch-always Part 3): 93 cases - red-proved against a copy that allows everything (52 errors) and, for the 19 bypass cases the review found, against the pre-fix guard (19 errors); green against the guard; checks the onFailure wiring of every security guard; 2026-10-24: 27 image-service cases (26 errors before the guard change, 0 after) and the matcher check for browser navigate and image-making MCP tools' }
        @{ Path = 'HOME/.claude/statusline.ps1'; Reason = '2026-10-18 (fetch-always Part 3b.2): the context fill is labelled "ctx NN%"; the percentage field itself was already read from context_window.used_percentage' }
        @{ Path = 'HOME/.claude/hooks/session-check.ps1'; Reason = '2026-10-18 (fetch-always Part 3b): it reads a -File argument or a script path inside the fail-closed -Command wrapper, for Windows and Unix paths (the first CI run measured the Unix half: the wrapper case failed on ubuntu-latest); without that it warned falsely at every session start although block-dangerous was registered, and it reported no missing guard file in the wrapper form. Red-proved: the real folder warned and the wrapper case failed; green after, under pwsh and 5.1' }
        @{ Path = 'HOME/.claude/setup/tests/test-session-check.ps1'; Reason = '2026-10-18 (fetch-always Part 3b): two wrapper cases (registered, missing); the real-folder case fails on any warning instead of only on the exit code, and it asks for silence only when the folder IS the profile .claude - the repository mirror and the rendered tree CI runs the suites from may warn, because their settings name hooks that are not installed there' }
        @{ Path = 'HOME/.claude/skills/docs-import/SKILL.md'; Reason = '2026-10-18 (fetch-always Part 4): every page fetch goes through fetch_page.py; no curl status call and no MCP page reader remains in the procedure' }
        @{ Path = 'HOME/.claude/setup/powershell/batch-run.ps1'; Reason = '2026-10-18 (batch-and-hygiene Part 1): one fresh headless session per list item, JSONL state with cost and session id, resume, 3-failure stop, never --bare' }
        @{ Path = 'HOME/.claude/setup/tests/test-batch-run.ps1'; Reason = '2026-10-18 (batch-and-hygiene Part 1): fake claude covers success, failure and invalid JSON; resume, the 3-failure stop, cost parsing, dry run, the >20 confirm and the exact argument contract' }
        @{ Path = 'HOME/.claude/hooks/skill-usage.ps1'; Reason = '2026-10-18 (batch-and-hygiene Part 3): PostToolUse logger for the Skill tool; date, skill name and session id only, fail-open, no prompt text' }
        @{ Path = 'HOME/.claude/setup/tests/test-skill-usage.ps1'; Reason = '2026-10-18 (batch-and-hygiene Part 3): 11 cases - valid call, append, missing skill, invalid JSON, CSV quoting, and no argument text in the log' }
        @{ Path = 'HOME/.claude/settings.json'; Reason = '2026-10-18 (batch-and-hygiene Part 3): one PostToolUse entry, matcher Skill, async, without onFailure - logging must never block' }
        @{ Path = 'HOME/.claude/CLAUDE.md'; Reason = '2026-10-18 (batch-and-hygiene Parts 1-3): batch-run line, the red-status-line session rule, and the Gotchas rule' }
        @{ Path = 'HOME/.claude/skills/research/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas section from recorded failures only (compose comments, bare reference numbers, Crawl4AI UTF-8, dedupe, subagent language ask)' }
        @{ Path = 'HOME/.claude/skills/quick-research/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas section from recorded failures only (one fetch vs Jina fallback, measured runtime, the old two-search design)' }
        @{ Path = 'HOME/.claude/skills/docs-import/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas section from recorded failures only (one-project filing, the Netlify path assumption, the vault-lint path that did not resolve)' }
        @{ Path = 'HOME/.claude/skills/life-os-morning/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas section - none recorded yet' }
        @{ Path = 'HOME/.claude/skills/reuse-first/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas section - none recorded yet' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/docs-import-portable/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): the same Gotchas as the main docs-import skill' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/quick-research-portable/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): the same Gotchas as the main quick-research skill' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/web-research/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): the same Gotchas as the main research skill' }
        @{ Path = 'HOME/.claude/life-os/morning.ps1'; Reason = '2026-10-18 (batch-and-hygiene Part 4): runs expiry.py with --days 7 before the agent and writes 000-meta/life-os-expiry.json; a note expiring soon now keeps the agent run from being skipped; 2026-10-26 (small-fixes Part 2): the skip path runs the same cleanup step (trash queue, log rotation) and so writes its own cleanup line' }
        @{ Path = 'VAULT/.claude/skills/json-canvas/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas - none recorded yet' }
        @{ Path = 'VAULT/.claude/skills/obsidian-bases/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas - none recorded yet' }
        @{ Path = 'VAULT/.claude/skills/obsidian-cli/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotcha - start Obsidian yourself instead of asking the owner' }
        @{ Path = 'VAULT/.claude/skills/obsidian-markdown/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Part 3): Gotchas - none recorded yet' }
        @{ Path = 'VAULT/.claude/skills/vault-lint/SKILL.md'; Reason = '2026-10-18 (batch-and-hygiene Parts 3-4): Gotchas from recorded failures and the expiry.py check in sections 2 and 3' }
        @{ Path = 'VAULT/.claude/skills/vault-lint/expiry.py'; Reason = '2026-10-18 (batch-and-hygiene Part 4): read-only valid_until report, exit 1 on findings, names file and date' }
        @{ Path = 'VAULT/.claude/skills/vault-lint/test_expiry.py'; Reason = '2026-10-18 (batch-and-hygiene Part 4): 13 fixture cases (past, soon, far, missing, malformed, quoted, out-of-scope, days limit, frontmatter position, CLI exit codes and JSON)' }
        @{ Path = 'VAULT/000-meta/templates/person.md'; Reason = '2026-10-18 (batch-and-hygiene Part 4): the optional valid_until field as a YAML comment' }
        @{ Path = 'VAULT/000-meta/templates/project.md'; Reason = '2026-10-18 (batch-and-hygiene Part 4): the optional valid_until field as a YAML comment' }
        @{ Path = 'HOME/.claude/life-os/groq_worker.py'; Reason = '2026-10-21 (media-and-projects Part 3): Groq whisper-large-v3-turbo as the default engine, 16 kHz mono FLAC preprocessing, 600 s chunks with 10 s overlap copied from the Groq cookbook, the 21,600 s daily cap shared with dictation, and one German fallback reason' }
        @{ Path = 'HOME/.claude/life-os/project-tracker.ps1'; Reason = '2026-10-21 (Part 4): read-only git scan of C:\Dev\Projects with a state file, the five edge cases, the activity log, the three frontmatter keys, the Next-step carry-over, the Bases data and the >1 GB safety net' }
        @{ Path = 'HOME/.claude/skills/media-tools/SKILL.md'; Reason = '2026-10-21 (Part 5b): the personal skill with the tested recipes for downloads, ffmpeg, markitdown, docling, pypdf, archives, images and ebooks, and the media-project template' }
        @{ Path = 'HOME/.agents/skills/media-tools-portable/SKILL.md'; Reason = '2026-10-21 (Part 5b): the portable copy of the media-tools skill for OpenCode and Codex; folder renamed to media-tools-portable on 2026-10-23 so it matches the name: field (ADR 0017)' }
        @{ Path = 'HOME/.claude/life-os/transcribe.ps1'; Reason = '2026-10-21 (Part 3): -Engine groq|local, the user-key import, the Groq worker call, the German fallback line and the transcribe.json handover to the morning report' }
        @{ Path = 'VAULT/000-meta/overview.base'; Reason = '2026-10-21 (Part 4.5): a Project activity view with last_activity, uncommitted and unpushed, sorted newest first' }
        @{ Path = 'HOME/.claude/skills/video/SKILL.md'; Reason = '2026-10-29 (video task, Part 4): the /video skill - local clip generation with LTX-2.3 through comfy-cli, user-invoked only, with the measured RAM guard and the text-in-picture note (ADR 0022)' }
        @{ Path = 'HOME/.claude/skills/video/scripts/new-video.ps1'; Reason = '2026-10-29 (Part 4): the one script behind /video - fetches the pinned LTX templates and checks SHA-256 on every use, sets the nodes by type, starts ComfyUI on 127.0.0.1 with partner nodes off, runs with --where local, refuses below 15.9 GiB free RAM in German (amended 2026-10-29 from 20.8 GiB, the measured floor of two clean runs), refuses while another program holds the GPU, stops the server it started, prints the mp4 path, a contact sheet and the seed' }
        @{ Path = 'HOME/.agents/skills/video-portable/SKILL.md'; Reason = '2026-10-29 (Part 4): the portable twin of the /video skill for OpenCode and Codex, explicit invocation only' }
        @{ Path = 'HOME/.agents/skills/video-portable/agents/openai.yaml'; Reason = '2026-10-29 (Part 4): Codex policy allow_implicit_invocation false for the portable /video skill' }
        @{ Path = 'HOME/.claude/skills/image/SKILL.md'; Reason = '2026-10-23 (ComfyUI task, Part 4): the /image skill - local picture generation through comfy-cli, user-invoked only, with the binding local-only rules (ADR 0019); 2026-10-29: the "Video is not set up" section points to the separate /video skill (ADR 0022)' }
        @{ Path = 'HOME/.agents/skills/image-portable/SKILL.md'; Reason = '2026-10-23 (ComfyUI task, Part 4): the portable twin of the /image skill; 2026-10-29: the same section points to video-portable (ADR 0022)' }
        @{ Path = 'HOME/.claude/skills/image/scripts/new-image.ps1'; Reason = '2026-10-23 (Part 4): the one script behind /image - fetches the pinned official template (SHA-256 checked), starts ComfyUI on 127.0.0.1 with partner nodes off, runs the workflow with --where local, prints the image path and the seed; the official template itself stays out of the repository (ADR 0019)' }
        @{ Path = 'HOME/.agents/skills/image-portable/SKILL.md'; Reason = '2026-10-23 (Part 4): the portable twin of the /image skill for OpenCode and Codex, explicit invocation only' }
        @{ Path = 'HOME/.agents/skills/image-portable/agents/openai.yaml'; Reason = '2026-10-23 (Part 4): Codex policy allow_implicit_invocation false for the portable /image skill' }
        @{ Path = 'HOME/.claude/hooks/deepseek-orientation.ps1'; Reason = '2026-10-23 (Part 8): the orientation hook - reads the owner''s orientation file, splits it at "## " headings into at most three parts of 9,500 characters, prints one part as additionalContext; registered by the DeepSeek profile only (ADR 0020)' }
        @{ Path = 'HOME/.claude/orientation/deepseek.md'; Reason = '2026-10-23 (Part 8): the owner-written orientation file for DeepSeek sessions; shipped as a one-line placeholder until the owner writes it (ADR 0020)' }
        @{ Path = 'HOME/.claude/.gitignore'; Reason = '2026-10-23 (Part 8): the claude-config whitelist names orientation/ and orientation/*.md, otherwise the orientation file would never be committed' }
        @{ Path = 'HOME/.claude/skills/distill/SKILL.md'; Reason = '2026-10-24 (vault-knowledge task, Part 4): the /distill skill - files a finished session back into the vault as one knowledge page, user-invoked only' }
        @{ Path = 'HOME/.agents/skills/distill-portable/SKILL.md'; Reason = '2026-10-24 (Part 4): the portable twin of the /distill skill for OpenCode and Codex, explicit invocation only' }
        @{ Path = 'HOME/.agents/skills/distill-portable/agents/openai.yaml'; Reason = '2026-10-24 (Part 4): Codex policy allow_implicit_invocation false for the portable /distill skill' }
        @{ Path = 'HOME/.claude/CLAUDE.md'; Reason = '2026-10-24 (vault-knowledge task, Parts 1, 2 and 4): the orientation blocks count as the owner''s instructions (Safety exception), Parallel is free without a key with unpublished limits, and /distill is the one exception to "a project session never writes in the vault"; 2026-10-25: the project hub is the second (ADR 0021)' }
        @{ Path = 'HOME/.claude/profiles-template/deepseek.json'; Reason = '2026-10-23 (Part 8): the DeepSeek profile template carries the SessionStart (startup|clear|compact) and SubagentStart hooks of the orientation file, three parts each; no other profile gets them' }
        @{ Path = 'HOME/.claude/life-os/morning-checks.ps1'; Reason = '2026-10-25 (Life OS inbox task, ADR 0021): the token-free helpers of the morning run - why the agent starts, the hint lines the script writes itself, loose notes into Roh, tasks into todo.md, the weekly area hint' }
        @{ Path = 'HOME/.claude/life-os/area-check.ps1'; Reason = '2026-10-25 (Life OS inbox task, ADR 0021): the safety net for the self-updating area notes - compares with a snapshot taken before the agent and restores every change without a source' }
        @{ Path = 'HOME/.claude/hooks/hub-reminder.ps1'; Reason = '2026-10-25 (Life OS inbox task, ADR 0021): Stop hook that blocks the end of a turn once when the project hub in the vault is older than the repository; fails open' }
        @{ Path = 'DEV/Projects/CLAUDE.md'; Reason = '2026-10-25 (Life OS inbox task, ADR 0021): the hub rule - the agent writes the project hub in the vault at the end of every task and commits only that file' }
        @{ Path = 'VAULT/.claude/skills/vault-lint/test_project_sync.py'; Reason = '2026-10-25 (Life OS inbox task): unit tests for the new project-sync finding (a finished hub whose repo path does not exist)' }
        @{ Path = 'VAULT/.claude/skills/vault-lint/project_sync.py'; Reason = '2026-10-25 (Life OS inbox task): also reports a hub with status done whose repo: path does not exist' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_store_results.py'; Reason = '2026-10-25 (search tuning, Part 4): a copied page keeps its frontmatter on the first line although a saved page now opens with the untrusted marker line' }
        @{ Path = 'HOME/.claude/skills/research/scripts/common.py'; Reason = '2026-10-25 (search tuning, Part 4): read_page skips the untrusted marker line that save_pages.py writes on top of every saved page' }
        @{ Path = 'HOME/.claude/life-os/crawl4ai-selftest.ps1'; Reason = '2026-10-26 (crawl4ai-watch, Part 3): the token-free Crawl4AI self-test - one small page through crawl4ai_fetch.py with a 60 s limit, prints crawl4ai=ok or crawl4ai=fail: <reason>; morning.ps1, install.ps1 and verify.ps1 call it. On 2026-10-25 the browser folder had been empty for two days and nothing said so' }
        @{ Path = 'HOME/.claude/skills/research/scripts/build_references.py'; Reason = '2026-10-26 (crawl4ai-watch, Part 2): page_types reads pages/index.json through common.load_index, so the new object form {crawl4ai_ok, crawl4ai_reason, pages} and the old list both work' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_build_references.py'; Reason = '2026-10-26 (crawl4ai-watch, Part 2): one test - pages/index.json is read in its new object form {crawl4ai_ok, crawl4ai_reason, pages} as well as the old list' }
        @{ Path = 'HOME/.claude/skills/research/scripts/crawl4ai_fetch.py'; Reason = '2026-10-26 (small-fixes, Part 1): main() sets PLAYWRIGHT_BROWSERS_PATH to Crawl4AI''s own browser folder (browsers_path()), because Playwright''s shared ms-playwright folder loses a browser version when no other installation needs it' }
        @{ Path = 'HOME/.claude/skills/research/SKILL.md'; Reason = '2026-10-26 (small-fixes, Part 1): one Gotchas line for the own browser folder, and the repair command that names it' }
        @{ Path = 'HOME/.claude/life-os/crawl4ai-repair.ps1'; Reason = '2026-10-26 (small-fixes, Part 1): the one command that repairs Crawl4AI - own browser folder (asked from crawl4ai_fetch.py), crawl4ai-setup, then the self-test; exit 0 only when the test passes; morning.ps1 calls it once when its self-test fails' }
        @{ Path = 'HOME/.claude/skills/quick-research/SKILL.md'; Reason = '2026-10-26 (small-fixes, Part 1): the repair named in the report line is crawl4ai-repair.ps1, not a bare crawl4ai-setup' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/web-research/SKILL.md'; Reason = '2026-10-26 (small-fixes, Part 1): the repair is crawl4ai-repair.ps1; one Gotchas line for the own browser folder, as in the research skill' }
        @{ Path = 'HOME/.claude/setup/other-harnesses/agents-skills/quick-research-portable/SKILL.md'; Reason = '2026-10-26 (small-fixes, Part 1): the repair named in the report line is crawl4ai-repair.ps1' }
        @{ Path = 'HOME/.claude/docs/agent-tooling.md'; Reason = '2026-10-26 (small-fixes, Part 1): the Crawl4AI row names the own browser folder and the one repair command' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_crawl4ai_browsers.py'; Reason = '2026-10-26 (small-fixes, Part 1): five tests, red first - the default folder, the override, and that main() replaces a shared folder from outside' }
        @{ Path = 'HOME/.claude/skills/research/scripts/count_usage.py'; Reason = '2026-10-27 (usage-count-fix, Part 1): the one script that counts tokens and DeepSeek cost, once per request (message.id + requestId, the line with the most output); a transcript writes one response as several lines, and summing the lines counted each request about 2.7 times' }
        @{ Path = 'HOME/.claude/setup/tests/research/test_count_usage.py'; Reason = '2026-10-27 (usage-count-fix, Part 1): 26 tests, red first against the missing script; one key counts once, two keys twice, the fallback to message.id, peak and off-peak, an unknown model, a model of another provider, the three miss kinds' }
        @{ Path = 'HOME/.claude/skills/research/SKILL.md'; Reason = '2026-10-27 (usage-count-fix, Part 2): the deep cost limit is 1.20 USD at peak price, measured with count_usage.py; the standard-level figure is 0.55 USD' }
        @{ Path = 'HOME/.claude/skills/research/scripts/store_results.py'; Reason = '2026-10-25 (search tuning, Part 4): the vault copy of a page moves the marker line below the frontmatter, so the frontmatter stays on line 1' }
        @{ Path = 'HOME/.claude/skills/distill/SKILL.md'; Reason = '2026-10-27 (knowledge-flat, Part 3): step 3 files a new page flat into 400-knowledge/ as <subject>-<topic>.md with a topic key, never into a folder and never asking where; an empty argument proposes up to three topics once' }
        @{ Path = 'HOME/.agents/skills/distill-portable/SKILL.md'; Reason = '2026-10-27 (knowledge-flat, Part 3): the same body as the Claude Code skill, kept identical from the Idea line on' }
        @{ Path = 'HOME/.claude/docs/agent-tooling.md'; Reason = '2026-10-27 (knowledge-flat, Part 2): the web search analysis moved to 400-knowledge/web-search-index.md' }
        @{ Path = 'VAULT/AGENTS.md'; Reason = '2026-10-27 (knowledge-flat, Part 1): 400-knowledge is flat with research/ as the only subfolder, the name is <subject>-<topic>.md, and topic is one plain value - rule 4 says why never a list' }
        @{ Path = 'VAULT/README.md'; Reason = '2026-10-27 (knowledge-flat, Part 2): the help page moved to 400-knowledge/personal-os-how-to-use-my-system.md' }
        @{ Path = 'VAULT/.obsidian/app.json'; Reason = '2026-10-27 (knowledge-flat, Part 2): alwaysUpdateLinks=true and newLinkFormat=absolute - without them the obsidian CLI moves a note and leaves every link pointing at the old name (measured on a throwaway note)' }
        @{ Path = 'VAULT/.claude/settings.json'; Reason = '2026-10-28: the deny list keeps only the Edit path rule for the cloud-synced folder. Write(path) and NotebookEdit(path) rules are never matched by the file permission checks, and Claude Code warned about both at every session start (measured 2026-10-28); Edit rules cover all file-editing tools (code.claude.com/docs/en/permissions)' }
        @{ Path = 'HOME/.claude/skills/image/scripts/restore-models.ps1'; Reason = '2026-10-29 (comfy-restore): the shared model restore script - the eight /image and /video files with pinned URL, size and SHA-256, resumable download, size and hash check, 30 GB free-space reserve, -WhatIf; tested only against a fake list' }
        @{ Path = 'HOME/.claude/skills/image/SKILL.md'; Reason = '2026-10-29 (comfy-restore): the reinstall section points at restore-models.ps1 and docs/restore-comfyui.md' }
        @{ Path = 'HOME/.claude/skills/video/SKILL.md'; Reason = '2026-10-29 (comfy-restore): the reinstall section points at the shared restore script and docs/restore-comfyui.md' }
    )
    $target = Join-Path $WorkRoot ('verify-all-j-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Push-Location $RepoRoot
    $inOut = (& pwsh -NoProfile -File install.ps1 -TargetRoot $target -NonInteractive 2>&1 | Out-String)
    $inExit = $LASTEXITCODE
    Pop-Location
    if (($inExit -ne 0) -or ($inOut -notmatch 'INSTALL-OK')) { throw ('the test install did not reach INSTALL-OK (exit ' + $inExit + ')') }
    $fpPath = Join-Path $target 'after.json'
    # Join-Path $RepoRoot, not a relative path: the install above runs inside Push-Location
    # $RepoRoot and Pop-Location has already run here, so a bare 'setup/tools/...' resolved
    # against whatever directory the CALLER was in. Measured in review 17 (F3): the documented
    # red-proof call `verify-all.ps1 -Only J -RepoRoot <copy>` from any other directory failed
    # with "the argument setup/tools/install-fingerprint.ps1 was not recognized" - a false red
    # for a reason that has nothing to do with what the check checks, and a program the caller's
    # directory picks.
    $fpOut = (& pwsh -NoProfile -File (Join-Path $RepoRoot 'setup/tools/install-fingerprint.ps1') -TargetRoot $target -Out $fpPath 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ('fingerprint failed: ' + $fpOut) }
    $after = [IO.File]::ReadAllText($fpPath) | ConvertFrom-Json
    $baseMap = @{}
    foreach ($f in $baseline.files) { $baseMap[[string]$f.path] = [string]$f.sha256 }
    $afterMap = @{}
    foreach ($f in $after.files) { $afterMap[[string]$f.path] = [string]$f.sha256 }
    $missing = @($baseMap.Keys | Where-Object { -not $afterMap.ContainsKey($_) } | Sort-Object)
    $added = @($afterMap.Keys | Where-Object { -not $baseMap.ContainsKey($_) } | Sort-Object)
    $changed = @($baseMap.Keys | Where-Object { $afterMap.ContainsKey($_) -and ($afterMap[$_] -ne $baseMap[$_]) } | Sort-Object)
    $unexplained = New-Object System.Collections.Generic.List[string]
    foreach ($p in $added) { if (-not ($intended | Where-Object { $_.Path -eq $p })) { $unexplained.Add('added: ' + $p) } }
    foreach ($p in @($missing + $changed)) { if (-not ($intended | Where-Object { $_.Path -eq $p })) { $unexplained.Add('differs: ' + $p) } }
    $ok = ($unexplained.Count -eq 0)
    $detail = [string]$baseline.fileCount + ' file(s) in the v2.1.2 baseline, ' + $after.fileCount + ' now; ' +
              $changed.Count + ' changed, ' + $added.Count + ' added, ' + $missing.Count + ' gone; ' +
              $intended.Count + ' documented intended change(s)' +
              $(if ($unexplained.Count -gt 0) { '; NOT DOCUMENTED: ' + (($unexplained | Select-Object -First 8) -join ' | ') } else { '' }) +
              '; the target is a fresh folder in the work root, the install reads the live personal values and writes only into that target; .install-state is outside the fingerprint by design (it carries the run date and the version)'
    Add-Result 'J' 'test install on Windows unchanged since v2.1.2' ('install.ps1 -TargetRoot <new> -NonInteractive (live personal values, as the baseline was recorded), then setup/tools/install-fingerprint.ps1, compared with ' + $baseline.fileCount + ' recorded entries') $detail '0' $ok
} catch { Add-Result 'J' 'test install on Windows unchanged since v2.1.2' 'fingerprint a test install' $_.Exception.Message '2' $false } }

# ------------------------------------------------------- K hooks exec form ---
# Decision D10 / G6: no default shell decides what a hook runs. Claude Code runs a shell-form
# hook through sh on macOS and Linux and through Git Bash on Windows; the exec form starts the
# program directly. This check renders home/.claude/settings.json for every system and looks at
# every hook entry.
# Windows keeps powershell.exe on purpose: the live wiring must not change (red line 2) and the
# export round trip could not reproduce a different value. macOS and Linux get pwsh.
if (Test-Selected 'K') { try {
    . (Join-Path $RepoRoot 'setup/lib/manifest.ps1')
    . (Join-Path $RepoRoot 'setup/lib/platform.ps1')
    . (Join-Path $RepoRoot 'setup/lib/placeholders.ps1')
    $cfgPath = Join-Path $RepoRoot 'tests/fixtures/personal.dummy.yaml'
    $cfg = @{}
    $loaded = ConvertFrom-Yaml (Get-Content -LiteralPath $cfgPath -Raw)
    if ($loaded -is [System.Collections.IDictionary]) { foreach ($k in $loaded.Keys) { $cfg[[string]$k] = $loaded[$k] } }
    else { foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    $repoSettings = Join-Path $RepoRoot 'home/.claude/settings.json'
    $raw = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($repoSettings))
    $shells = @('sh', 'bash', 'zsh', 'dash', 'cmd', 'cmd.exe', 'sh.exe', 'bash.exe')
    $bad = New-Object System.Collections.Generic.List[string]
    $summary = New-Object System.Collections.Generic.List[string]
    foreach ($os in @('windows', 'macos', 'linux')) {
        $roots = @{ HOME = '/home/check'; DOCUMENTS = '/home/check/Documents'; VAULT = '/home/check/PersonalOS'; DEV = '/home/check/Dev' }
        if ($os -eq 'windows') { $roots = @{ HOME = 'C:\Users\check'; DOCUMENTS = 'C:\Users\check\Documents'; VAULT = 'C:\PersonalOS'; DEV = 'C:\Dev' } }
        $map = Get-PlaceholderMap -Roots $roots -ConfigValues $cfg -Os $os
        $map['{{USER_SID}}'] = 'S-1-5-21-0-0-0-1001'
        $rendered = Expand-Placeholders $raw $map
        try { $json = $rendered | ConvertFrom-Json } catch { $bad.Add($os + ': settings.json does not parse after rendering: ' + $_.Exception.Message); continue }
        $count = 0
        foreach ($ev in $json.hooks.PSObject.Properties) {
            foreach ($entry in @($ev.Value)) {
                foreach ($h in @($entry.hooks)) {
                    $count++
                    $where = $os + '/' + $ev.Name
                    if (-not $h.command) { $bad.Add($where + ': no command'); continue }
                    $cmd = [string]$h.command
                    # not $args: that name belongs to PowerShell itself
                    $hookArgs = @($h.args | ForEach-Object { [string]$_ })
                    if ($h.type -and ([string]$h.type -ne 'command')) { $bad.Add($where + ': type is "' + $h.type + '", must be "command"'); continue }
                    if ($hookArgs.Count -eq 0) { $bad.Add($where + ': no args array (that is the shell form)'); continue }
                    if ($shells -contains $cmd.ToLowerInvariant()) { $bad.Add($where + ': command is a shell (' + $cmd + ')'); continue }
                    if ($cmd -notmatch '(?i)(^|[\\/])(powershell|pwsh)(\.exe)?$') { $bad.Add($where + ': command is no PowerShell host (' + $cmd + ')'); continue }
                    if (($os -ne 'windows') -and ($cmd -cne 'pwsh')) { $bad.Add($where + ': command is "' + $cmd + '", must be pwsh on ' + $os); continue }
                    $fileArgs = @()
                    for ($i = 0; $i -lt $hookArgs.Count; $i++) {
                        if (($hookArgs[$i] -match '^-{1,2}file$') -and (($i + 1) -lt $hookArgs.Count)) { $fileArgs += $hookArgs[$i + 1] }
                    }
                    if ($fileArgs.Count -gt 1) { $bad.Add($where + ': needs at most one -File argument, found ' + $fileArgs.Count); continue }
                    $scriptPath = ''
                    if ($fileArgs.Count -eq 1) {
                        $scriptPath = [string]$fileArgs[0]
                    }
                    else {
                        # No -File: the entry is allowed only as the exact fail-closed wrapper. A
                        # missing -File exits with 0xFFFD0000 under Windows PowerShell 5.1, whose
                        # low byte is 0, so the harness records exit 0 and onFailure never fires
                        # (measured 2026-10-18). The wrapper tests the file first and exits 1 when
                        # it is gone. It is still exec form: the PowerShell host starts directly,
                        # no sh/bash/cmd decides, and the script's own exit code is passed on.
                        $wrapPattern = '^if \(-not \(Test-Path -LiteralPath ''([^'']+\.ps1)''\)\) \{ exit 1 \}; & ''\1''; exit \$LASTEXITCODE$'
                        $wraps = @($hookArgs | Where-Object { $_ -match $wrapPattern })
                        if ($wraps.Count -ne 1) { $bad.Add($where + ': needs exactly one -File argument or the exact fail-closed wrapper, found neither'); continue }
                        $scriptPath = [regex]::Match([string]$wraps[0], $wrapPattern).Groups[1].Value
                    }
                    if ($scriptPath -notmatch '\.ps1$') { $bad.Add($where + ': the script argument does not name a .ps1 (' + $scriptPath + ')'); continue }
                    if ($scriptPath -match '\{\{') { $bad.Add($where + ': an unrendered placeholder survived in the path') }
                }
            }
        }
        $summary.Add($os + ': ' + $count + ' hook(s), command ' + $(if ($os -eq 'windows') { 'powershell.exe' } else { 'pwsh' }))
    }
    $ok = ($bad.Count -eq 0)
    $detail = ($summary -join '; ') + '; every entry carries command + args, names a PowerShell host and either exactly one -File ending in .ps1 or the exact fail-closed wrapper (Test-Path, &, exit $LASTEXITCODE)' +
              $(if ($bad.Count -gt 0) { '; PROBLEMS: ' + (($bad | Select-Object -First 5) -join ' | ') } else { '; no shell (sh, bash, cmd) decides anything' }) +
              '; Windows keeps powershell.exe on purpose - a live change is forbidden and the export round trip could not reproduce another value'
    Add-Result 'K' 'every hook in exec form, no shell decides' 'home/.claude/settings.json rendered for windows, macos and linux, then every hooks entry parsed as JSON' $detail '0' $ok
} catch { Add-Result 'K' 'every hook in exec form, no shell decides' 'render and parse settings.json' $_.Exception.Message '2' $false } }

# --------------------------------------------------------- L agent files ---
# D11 / G5: one shared file (AGENTS.md) plus the tool-specific lines, docs/platforms.md as the
# human-readable matrix - and the matrix really describes the map.
if (Test-Selected 'L') { try {
    . (Join-Path $RepoRoot 'setup/lib/manifest.ps1')
    . (Join-Path $RepoRoot 'setup/lib/platform.ps1')
    $bad = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $rootClaude = Join-Path $RepoRoot 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $rootClaude)) { $bad.Add('CLAUDE.md is missing') }
    else {
        $firstLine = ''
        $nonEmpty = @([IO.File]::ReadAllLines($rootClaude) | Where-Object { $_.Trim() -ne '' })
        if ($nonEmpty.Count -gt 0) { $firstLine = $nonEmpty[0].Trim() }
        if ($firstLine -ne '@AGENTS.md') { $bad.Add('CLAUDE.md does not start with @AGENTS.md (first non-empty line: "' + $firstLine + '")') }
        else { $notes.Add('CLAUDE.md line 1 is @AGENTS.md') }
    }
    $agents = Join-Path $RepoRoot 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agents)) { $bad.Add('AGENTS.md is missing') }
    else {
        $agentText = [IO.File]::ReadAllText($agents)
        if ($agentText -notmatch '(?m)^##\s+Platform first\s*$') { $bad.Add('AGENTS.md has no "Platform first" section') }
        else { $notes.Add('AGENTS.md carries the section "Platform first"') }
        foreach ($needle in @('setup/platforms.yaml', 'docs/platforms.md', 'unsupported')) {
            if ($agentText -notmatch [regex]::Escape($needle)) { $bad.Add('AGENTS.md does not name ' + $needle) }
        }
    }
    $docsPath = Join-Path $RepoRoot 'docs/platforms.md'
    if (-not (Test-Path -LiteralPath $docsPath)) { $bad.Add('docs/platforms.md is missing') }
    else {
        $docsText = [IO.File]::ReadAllText($docsPath)
        $manifest = Get-Manifest -Path (Join-Path $RepoRoot 'setup/manifest.yaml')
        $components = @(Get-ManifestField $manifest 'components')
        $notInDocs = New-Object System.Collections.Generic.List[string]
        foreach ($e in $components) {
            $id = [string](Get-ManifestField $e 'id')
            if ($docsText -notmatch ('\| `' + [regex]::Escape($id) + '` \|')) { $notInDocs.Add($id) }
        }
        if ($notInDocs.Count -gt 0) { $bad.Add([string]$notInDocs.Count + ' component(s) have no row in docs/platforms.md: ' + (($notInDocs | Select-Object -First 5) -join ', ')) }
        $rows = @([regex]::Matches($docsText, '(?m)^\| `([a-z0-9-]+)` \|') | ForEach-Object { $_.Groups[1].Value })
        $known = @($components | ForEach-Object { [string](Get-ManifestField $_ 'id') })
        $unknown = @($rows | Where-Object { $known -notcontains $_ } | Select-Object -Unique)
        if ($unknown.Count -gt 0) { $bad.Add('docs/platforms.md names components the manifest does not know: ' + ($unknown -join ', ')) }
        $notes.Add($components.Count.ToString() + ' component(s) in the manifest, ' + (@($rows | Select-Object -Unique).Count) + ' row(s) in docs/platforms.md')
        # the freshness proof lives in generate-docs.ps1 -Check (check 5 runs it too); this call
        # makes the failure land in THIS check's output as well
        $genOut = (& pwsh -NoProfile -File (Join-Path $RepoRoot 'setup/tools/generate-docs.ps1') -Check 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { $bad.Add('docs/platforms.md is not what the generator would write: ' + $genOut.Trim()) }
        else { $notes.Add('generate-docs.ps1 -Check is green for components.md and platforms.md') }
    }
    $ok = ($bad.Count -eq 0)
    Add-Result 'L' 'agent files share one source and match the map' 'read CLAUDE.md, AGENTS.md, docs/platforms.md and setup/manifest.yaml; run generate-docs.ps1 -Check' (($notes -join '; ') + $(if ($bad.Count -gt 0) { '; PROBLEMS: ' + ($bad -join ' | ') } else { '; every component has a row and every row a component' })) '0' $ok
} catch { Add-Result 'L' 'agent files share one source and match the map' 'read the agent files' $_.Exception.Message '2' $false } }

# ------------------------------------------------------- M start command ---
# D12 / G2: one documented start command per system. The shell script is checked with shellcheck
# where shellcheck exists (the CI jobs install it on Linux and macOS); when it is absent here,
# the output says so instead of implying a check that did not run.
#
# Finding bash is not the same as finding git: on Windows, Git for Windows puts `git.exe` in
# `Git\cmd` (which the installer adds to PATH) and bash only in `Git\bin` and `Git\usr\bin`
# (which it does not). Measured 2026-10-14: `pwsh -File verify-all.ps1` from a plain PowerShell
# window found no bash and check M failed on a machine where bootstrap.sh is perfectly fine -
# a check that only passes where the caller's PATH happens to carry bash would guard nothing.
# So the lookup asks PATH first (that is where a Unix system answers) and then the documented
# install locations of Git for Windows. A bash that resolves into the work root, into
# C:\Dev\Temp or into the repository is refused, like every other tool (the shim rule, above).
function Get-BashPath {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) {
        $src = [string]$cmd.Source
        foreach ($d in $script:toolDirs) { if ($src.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return '' } }
        return $src
    }
    $roots = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) { $roots.Add($env:ProgramFiles) }
    if (${env:ProgramFiles(x86)}) { $roots.Add(${env:ProgramFiles(x86)}) }
    if ($env:LOCALAPPDATA) { $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs')) }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        $candidates.Add((Join-Path $root 'Git\bin\bash.exe'))
        $candidates.Add((Join-Path $root 'Git\usr\bin\bash.exe'))
    }
    foreach ($p in $candidates) {
        foreach ($d in $script:toolDirs) { if ($p.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return '' } }
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return ''
}
if (Test-Selected 'M') { try {
    $bad = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $ps1 = Join-Path $RepoRoot 'bootstrap.ps1'
    $sh = Join-Path $RepoRoot 'bootstrap.sh'
    if (-not (Test-Path -LiteralPath $ps1 -PathType Leaf)) { $bad.Add('bootstrap.ps1 is missing') }
    if (-not (Test-Path -LiteralPath $sh -PathType Leaf)) { $bad.Add('bootstrap.sh is missing') }
    if (Test-Path -LiteralPath $ps1) {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $issues = @(Invoke-ScriptAnalyzer -Path $ps1 -Severity Error)
        if ($issues.Count -gt 0) { $bad.Add('PSScriptAnalyzer (Error): ' + (($issues | Select-Object -First 3 | ForEach-Object { $_.RuleName + ' line ' + $_.Line }) -join ', ')) }
        else { $notes.Add('bootstrap.ps1: PSScriptAnalyzer 0 errors') }
    }
    if (Test-Path -LiteralPath $sh) {
        $bash = Get-BashPath
        if ($bash) {
            $bashOut = (& $bash -n $sh 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { $bad.Add('bash -n bootstrap.sh failed: ' + $bashOut.Trim()) } else { $notes.Add('bootstrap.sh: bash -n clean (' + $bash + ')') }
        }
        else { $bad.Add('no bash found - bootstrap.sh cannot be syntax-checked here') }
        $sc = Get-Command shellcheck -ErrorAction SilentlyContinue
        if ($sc) {
            $scOut = (& $sc.Source $sh 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { $bad.Add('shellcheck reports: ' + (($scOut -split "`n" | Where-Object { $_ -match 'SC\d+' } | Select-Object -First 2) -join ' / ')) }
            else { $notes.Add('bootstrap.sh: shellcheck clean') }
        }
        else { $notes.Add('shellcheck is not installed on this machine - the CI jobs install it on Linux and macOS and run it there') }
    }
    $readme = [IO.File]::ReadAllText((Join-Path $RepoRoot 'README.md'))
    if ($readme -notmatch '(?m)^##\s+Start from zero\s*$') { $bad.Add('README has no "Start from zero" section') }
    else { $notes.Add('README has the section "Start from zero"') }
    foreach ($word in @('bootstrap.ps1', 'bootstrap.sh')) {
        if ($readme -notmatch [regex]::Escape($word)) { $bad.Add('README does not name ' + $word) }
    }
    # the executable bit travels with git - a .sh that cannot be started is not a start command
    Push-Location $RepoRoot
    $mode = (& git ls-files -s bootstrap.sh | Out-String).Trim()
    Pop-Location
    if (-not $mode) { $bad.Add('bootstrap.sh is not tracked by git yet') }
    elseif ($mode -notmatch '^100755') { $bad.Add('bootstrap.sh is not committed as executable (git ls-files -s says mode ' + ($mode -split '\s+')[0] + ')') }
    else { $notes.Add('git records bootstrap.sh as 100755 (executable)') }
    $ok = ($bad.Count -eq 0)
    Add-Result 'M' 'start command present and checked' 'PSScriptAnalyzer on bootstrap.ps1; bash -n and shellcheck on bootstrap.sh; git ls-files -s bootstrap.sh; README section "Start from zero"' (($notes -join '; ') + $(if ($bad.Count -gt 0) { '; PROBLEMS: ' + ($bad -join ' | ') } else { '; one start command per system, both named in the README' })) '0' $ok
} catch { Add-Result 'M' 'start command present and checked' 'check the bootstrap files' $_.Exception.Message '2' $false } }

# ---------------------------------------------------------- N CI matrix ---
# G7: the matrix is the point. windows and ubuntu run on every push; macOS runs on tags, the
# weekly schedule and manual dispatch, and its newest run must be green too - a job that exists
# but never ran is not evidence.
if (Test-Selected 'N') { try {
    Push-Location $RepoRoot
    $head = (& git rev-parse HEAD | Out-String).Trim()
    $code = Get-LastCodeCommit
    # the run FOR the newest code commit (check 7 states why), so a documentation-only commit on
    # top with a run of its own does not make this red
    # Several runs can belong to one commit (push, manual, schedule), and two that start in the same
    # second have no promised order. The run judged is the newest one that HAS the macOS job, picked
    # by job name (setup/lib/ci-runs.ps1); without any, the newest run, which then fails on "no macOS job".
    . (Join-Path $RepoRoot 'setup/lib/ci-runs.ps1')
    $runJson = (& gh run list --workflow ci --commit $code --limit 20 --json headSha,status,conclusion,databaseId 2>&1 | Out-String)
    Pop-Location
    $picked = Select-CiRunWithMacOs -Runs @($runJson | ConvertFrom-Json) -GetJobs {
        param($id)
        Push-Location $RepoRoot
        try { $jj = (& gh run view $id --json jobs 2>&1 | Out-String) } finally { Pop-Location }
        return @(($jj | ConvertFrom-Json).jobs)
    }
    $bad = New-Object System.Collections.Generic.List[string]
    if (-not $picked) { throw 'gh returned no run of the ci workflow for the newest code commit ' + $code.Substring(0, 7) }
    $run = $picked.Run
    if ($run.status -ne 'completed') { $bad.Add('the run for the newest code commit is still ' + $run.status) }
    elseif ($run.conclusion -ne 'success') { $bad.Add('the newest run concluded ' + $run.conclusion) }
    $jobs = @($picked.Jobs)
    $matrix = @($jobs | Where-Object { $_.name -like 'checks*' })
    $mac = @($jobs | Where-Object { $_.name -like 'macos*' })
    $matrixOk = 0
    foreach ($j in $matrix) { if ($j.conclusion -eq 'success') { $matrixOk++ } else { $bad.Add('job ' + $j.name + ' concluded ' + $j.conclusion) } }
    if ($matrix.Count -eq 0) { $bad.Add('the newest run has no matrix job (checks)') }
    $macState = 'missing'
    if ($mac.Count -gt 0) {
        $macState = [string]$mac[0].conclusion
        if ($mac[0].conclusion -ne 'success') { $bad.Add('the macOS job concluded ' + $mac[0].conclusion + ' (trigger one with: gh workflow run ci)') }
    }
    else { $bad.Add('the newest run has no macOS job (trigger one with: gh workflow run ci)') }
    $wf = [IO.File]::ReadAllText((Join-Path $RepoRoot '.github/workflows/ci.yml'))
    foreach ($needle in @('windows-latest', 'ubuntu-latest', 'macos-latest', 'schedule:', 'workflow_dispatch:')) {
        if ($wf -notmatch [regex]::Escape($needle)) { $bad.Add('ci.yml does not contain ' + $needle) }
    }
    $ok = ($bad.Count -eq 0)
    $detail = 'run ' + $run.databaseId + ' (' + $run.conclusion + ' at ' + ([string]$run.headSha).Substring(0, 7) + '); matrix jobs green: ' + $matrixOk + '/' + $matrix.Count +
              '; macOS job: ' + $macState +
              '; ci.yml defines windows-latest and ubuntu-latest for every push, macos-latest for tags, the weekly schedule and manual dispatch' +
              $(if ($bad.Count -gt 0) { '; PROBLEMS: ' + ($bad -join ' | ') } else { '' })
    Add-Result 'N' 'CI matrix green on windows, ubuntu and macOS' 'gh run list --workflow ci --commit <newest code commit> --limit 20 --json headSha,status,conclusion,databaseId; gh run view <id> --json jobs for each run until one has the macOS job; the workflow file' $detail '0' $ok
} catch { Add-Result 'N' 'CI matrix green on windows, ubuntu and macOS' 'read the CI runs' $_.Exception.Message '2' $false } }

# --------------------------------------------------------- O idempotent ---
# "The second install run reports 0 changes". setup/tools/ci-smoke.ps1 does exactly that in
# every CI job and throws when the second run changes anything, so a successful step of that
# name IS the proof - and the step names and their conclusions are part of the run's JSON, which
# keeps this check small. The same proof runs on this machine as part of check 6.
# Since v2.3.2 a job carries the proof in one of two steps, and the name says which install it
# was: the push/weekly jobs run ci-smoke.ps1 (a -TargetRoot install into a throw-away folder,
# step "Test install, verify, second install changes nothing"), the full-setup jobs run
# ci-full-setup.ps1, which does the same on the LIVE machine (install, verify twice, second
# install) and exits 1 unless the second install reports "new 0, replaced 0" (step "Full setup
# on this machine (live install, verify, second install)"). Both steps are the same promise
# under a different name; a full-setup job that is missing its step, or whose step did not
# conclude success, is a problem exactly as before.
if (Test-Selected 'O') { try {
    $stepName = 'Test install, verify, second install changes nothing'
    $fullSetupStepName = 'Full setup on this machine (live install, verify, second install)'
    Push-Location $RepoRoot
    $runJson = (& gh run list --workflow ci --limit 1 --json databaseId,status,conclusion 2>&1 | Out-String)
    Pop-Location
    $run = @($runJson | ConvertFrom-Json)[0]
    if (-not $run) { throw 'gh returned no run for the ci workflow' }
    $jobs = @()
    if ($run.status -eq 'completed') {
        Push-Location $RepoRoot
        $jobsJson = (& gh run view $run.databaseId --json jobs 2>&1 | Out-String)
        Pop-Location
        $jobs = @(($jobsJson | ConvertFrom-Json).jobs)
    }
    $checked = New-Object System.Collections.Generic.List[string]
    $checkedLive = New-Object System.Collections.Generic.List[string]
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($j in $jobs) {
        $wanted = if ($j.name -like 'full-setup*') { @($fullSetupStepName) } else { @($stepName) }
        $step = @($j.steps | Where-Object { $wanted -contains $_.name })
        if ($step.Count -eq 0) { $bad.Add($j.name + ': no step "' + ($wanted -join '" / "') + '"'); continue }
        if ($step[0].conclusion -ne 'success') { $bad.Add($j.name + ': the idempotency step concluded ' + $step[0].conclusion); continue }
        $checked.Add($j.name)
        if ($step[0].name -eq $fullSetupStepName) { $checkedLive.Add($j.name) }
    }
    if ($jobs.Count -eq 0) { $bad.Add('the newest CI run (id ' + $run.databaseId + ', ' + $run.status + ') has no jobs to read yet') }
    $ok = ($bad.Count -eq 0) -and ($checked.Count -ge 2)
    # a run without a single passing step leaves the list empty; "passed in " with nothing after
    # it reads like a pass in the output, so it says what is true instead
    $where = if ($checked.Count -gt 0) { ($checked -join ', ') } else { 'no job (see PROBLEMS)' }
    $detail = 'run ' + $run.databaseId + ': the idempotency step ran and passed in ' + $where +
              '; it is setup/tools/ci-smoke.ps1 (throw-away target, fails unless the second install reports "new 0, replaced 0")' +
              $(if ($checkedLive.Count -gt 0) { ', and on the live machine in ' + ($checkedLive -join ', ') + ' the step runs setup/tools/ci-full-setup.ps1, which fails unless the same report comes from the live install' } else { '' }) +
              $(if ($bad.Count -gt 0) { '; PROBLEMS: ' + ($bad -join ' | ') } else { '' })
    Add-Result 'O' 'the second install changes nothing in every CI job' ('gh run view ' + $run.databaseId + ' --json jobs, the step "' + $stepName + '" (or "' + $fullSetupStepName + '" in a full-setup job)') $detail '0' $ok
} catch { Add-Result 'O' 'the second install changes nothing in every CI job' 'read the CI run steps' $_.Exception.Message '2' $false } }

# ------------------------------------------------------- P live dry run ---
# Checks 6 and G never touch the live-only code paths of install.ps1 (the OS stages and the
# summary block). A helper that only those paths called was missing in the repo for months and
# nothing noticed, because no check ever ran a live install. -WhatIf writes nothing outside the
# installer's own state folder.
if (Test-Selected 'P') { try {
    Push-Location $RepoRoot
    $dryOut = (& pwsh -NoProfile -File install.ps1 -NonInteractive -WhatIf 2>&1 | Out-String)
    $dryExit = $LASTEXITCODE
    Pop-Location
    $stageError = @($dryOut -split "`r?`n" | Where-Object { $_ -match '^\s{2}\S+\s+ERROR\s' }).Count
    $ok = ($dryExit -eq 0) -and ($dryOut -match 'INSTALL-OK') -and ($stageError -eq 0)
    $detail = $(if ($dryOut -match 'INSTALL-OK') { 'reached the summary (INSTALL-OK)' } else { 'no summary - the run stopped early' }) + '; stage errors: ' + $stageError
    Add-Result 'P' 'live dry run of install.ps1 reaches the summary' 'pwsh -File install.ps1 -NonInteractive -WhatIf' $detail $dryExit $ok
} catch { Add-Result 'P' 'live dry run of install.ps1 reaches the summary' 'install.ps1 -NonInteractive -WhatIf' $_.Exception.Message '2' $false } }

# --------------------------------------------------------- Q category list gone ---
# The release of v3.0.0 took the archive category list out of the tree; it lives in the
# personal layer now (docs/decisions/0016-public-repository.md). The proof has three parts,
# and the third is what keeps the first two from being satisfied by an emptied file:
#   1. the personal layer's terms are found neither in the tree nor in any commit - the scan
#      loads them, so the check never names one;
#   2. the live add-to-archive suite is green, which is what says the list still reaches the
#      script from the personal layer;
#   3. the tree really carries the invented example values where the real ones stood.
if (Test-Selected 'Q') { try {
    Push-Location $RepoRoot
    $qTree = (& pwsh -NoProfile -File setup/tools/privacy-scan.ps1 2>&1 | Out-String)
    $qTreeExit = $LASTEXITCODE
    $qHist = (& pwsh -NoProfile -File setup/tools/privacy-scan.ps1 -History 2>&1 | Out-String)
    $qHistExit = $LASTEXITCODE
    $qCommits = 0
    try { $qCommits = [int](& git rev-list --count --all 2>$null) } catch { $qCommits = 0 }
    Pop-Location
    $catLine = ([regex]::Match($qTree, 'PRIVACY-SCAN [^\r\n]*')).Value
    $catTerms = [regex]::Match($catLine, 'categories:\s*(\d+)\s*term').Groups[1].Value
    $catFindings = @($qTree -split "`r?`n" | Where-Object { $_ -match 'FINDING \[category#' }).Count
    $histFindings = @($qHist -split "`r?`n" | Where-Object { $_ -match 'FINDING \[category#' }).Count
    $withExample = New-Object System.Collections.Generic.List[string]
    foreach ($p in @('setup/config/personal.example.yaml', 'home/.claude/setup/powershell/add-to-archive.ps1', 'home/.claude/setup/tests/test-add-to-archive.ps1', 'tests/PersonalLayer.Tests.ps1')) {
        $full = Join-Path $RepoRoot $p
        if ((Test-Path -LiteralPath $full) -and ([IO.File]::ReadAllText($full) -match 'Example')) { $withExample.Add($p) }
    }
    $suite = Join-Path $HomeRoot '.claude\setup\tests\test-add-to-archive.ps1'
    $sExit = 2; $sLine = '(missing)'; $sCount = 0
    if (Test-Path -LiteralPath $suite) {
        $sOut = (& pwsh -NoProfile -File $suite 2>&1 | Out-String)
        $sExit = $LASTEXITCODE
        $m = [regex]::Match($sOut, '(\d+) checks, (\d+) failed')
        if ($m.Success) { $sLine = $m.Value; $sCount = [int]$m.Groups[1].Value }
    }
    $ok = ($catTerms -ne '') -and ([int]$catTerms -ge 1) -and ($qTreeExit -eq 0) -and ($qHistExit -eq 0) -and
          ($catFindings -eq 0) -and ($histFindings -eq 0) -and ($withExample.Count -ge 3) -and
          ($sExit -eq 0) -and ($sCount -ge 40) -and ($sLine -match '0 failed') -and $script:toolsOk
    $detail = 'the personal layer loads ' + $(if ($catTerms) { $catTerms } else { '0' }) + ' category term(s) as denylist entries; ' +
              'findings in the tree: ' + $catFindings + ' (exit ' + $qTreeExit + '); in ' + $qCommits + ' commit(s): ' + $histFindings + ' (exit ' + $qHistExit + '); ' +
              'files that carry the invented example value: ' + $withExample.Count + ' of 4; ' +
              'live add-to-archive suite: ' + $sLine + ' (exit ' + $sExit + ')'
    Add-Result 'Q' 'the archive category list is in no version of this repo' ('privacy-scan.ps1 (worktree) | privacy-scan.ps1 -History | grep the invented example value | pwsh -File <home>/.claude/setup/tests/test-add-to-archive.ps1') $detail '0' $ok
} catch { Add-Result 'Q' 'the archive category list is in no version of this repo' 'privacy-scan and the live suite' $_.Exception.Message '2' $false } }

# ------------------------------------------------------- R no vault folder name ---
# privacy-scan knows the category names because the personal layer lists them. The foldernames
# nobody wrote down - the sub-folders of the archive and the life-area folders of the vault -
# are known to the vault alone, so this check reads them from there at run time. The tool
# prints the count and the places, never a name; the same holds for this output.
if (Test-Selected 'R') { try {
    Push-Location $RepoRoot
    $rOut = (& pwsh -NoProfile -File setup/tools/archive-name-scan.ps1 -Path $RepoRoot -Repo $RepoRoot 2>&1 | Out-String)
    $rExit = $LASTEXITCODE
    Pop-Location
    $rHead = ([regex]::Match($rOut, 'ARCHIVE-NAME-SCAN: [^\r\n]*')).Value
    $rHits = [regex]::Match($rOut, 'hits:\s*(\d+)').Groups[1].Value
    $rPlaces = @($rOut -split "`r?`n" | Where-Object { $_ -match '^\s+HIT ' }).Count
    $ok = ($rExit -eq 0) -and ($rHits -eq '0') -and $script:toolsOk
    $detail = $rHead + '; hits: ' + $(if ($rHits -eq '') { 'not read' } else { $rHits }) + '; hit lines: ' + $rPlaces +
              ' (the names come from the vault at run time and are printed nowhere - the tool masks them, and so does this line)'
    Add-Result 'R' 'no vault folder name in the tree or the commit messages' 'setup/tools/archive-name-scan.ps1 -Path <repo> -Repo <repo>' $detail $rExit $ok
} catch { Add-Result 'R' 'no vault folder name in the tree or the commit messages' 'archive-name-scan.ps1' $_.Exception.Message '2' $false } }

# ----------------------------------------------------------- U Actions settings ---
if (Test-Selected 'U') { try {
    . (Join-Path $RepoRoot 'setup/lib/personal.ps1')
    $repoYaml = Join-Path $RepoRoot 'setup/config/repo.yaml'
    $published = (([string](Get-ConfigScalar -ConfigPath $repoYaml -Key 'published')).Trim() -eq 'true')
    $wantToken = ([string](Get-ConfigScalar -ConfigPath $repoYaml -Key 'workflow_token')).Trim()
    $wantFork = ([string](Get-ConfigScalar -ConfigPath $repoYaml -Key 'fork_pr_approval')).Trim()
    # The declaration is read, but it cannot talk the check out of the floor: a repository whose
    # workflow token may write is wrong whatever repo.yaml says, so 'read' is demanded as well.
    if ($wantToken -ne 'read') { throw ('repo.yaml asks for workflow_token: ' + $wantToken + ' - a workflow token that may write fails this check whatever the file says') }
    if ($wantFork -ne 'all_external_contributors') { throw ('repo.yaml asks for fork_pr_approval: ' + $wantFork + ' - anything else lets a fork run without approval and fails this check') }
    Push-Location $RepoRoot
    $slug = ([regex]::Match(((& gh repo view --json nameWithOwner 2>&1 | Out-String).Trim()), '"nameWithOwner"\s*:\s*"([^"]+)"').Groups[1].Value)
    $wf = ''
    $fk = ''
    if ($slug) {
        $wf = ((& gh api ('repos/' + $slug + '/actions/permissions/workflow') --jq '.default_workflow_permissions' 2>&1 | Out-String).Trim())
        $fkRaw = (& gh api ('repos/' + $slug + '/actions/permissions/fork-pr-contributor-approval') 2>&1 | Out-String)
        if ($fkRaw -match '"approval_policy"\s*:\s*"([^"]+)"') { $fk = $Matches[1] }
        elseif ($fkRaw -match 'not allowed for private repositories') { $fk = '(not readable while the repository is private)' }
        else { $fk = '(not read)' }
    }
    Pop-Location
    $ok = ($slug -ne '') -and ($wf -eq 'read') -and $script:toolsOk
    if ($published) { $ok = $ok -and ($fk -eq 'all_external_contributors') }
    $detail = 'repo.yaml declares workflow_token ' + $wantToken + ' and fork_pr_approval ' + $wantFork +
              '; workflow token: ' + $(if ($wf) { $wf } else { 'not read' }) + ' (must be read)' +
              '; fork pull requests: ' + $fk +
              $(if ($published) { ' (must be all_external_contributors)' } else { ' (the setting exists on a public repository only, so it is not demanded while repo.yaml says published: false)' })
    Add-Result 'U' 'fork pull requests need approval, token reads only' ('gh api repos/<slug>/actions/permissions/workflow; gh api repos/<slug>/actions/permissions/fork-pr-contributor-approval; repo.yaml decides whether the second one is demanded') $detail '0' $ok
} catch { Add-Result 'U' 'fork pull requests need approval, token reads only' 'gh api actions/permissions' $_.Exception.Message '2' $false } }

# --------------------------------------------------------------- V CI log clean ---
# "Actions history and logs will be visible to everyone" is one of the three reasons this
# release uses a fresh repository (docs/decisions/0016). A fresh repository has no old logs,
# but the new ones must be clean too: install.ps1 runs in CI with a rendered config, and this
# check reads the log of the newest run back through the same denylist the tree is held to.
if (Test-Selected 'V') { try {
    Push-Location $RepoRoot
    $runJson = (& gh run list --workflow ci --limit 1 --json databaseId,status,conclusion,headSha 2>&1 | Out-String)
    Pop-Location
    $run = @((($runJson | ConvertFrom-Json) | Where-Object { $_ }) | Select-Object -First 1)
    if ($run.Count -eq 0) {
        Add-Result 'V' 'no personal value in the newest CI log' 'gh run list --workflow ci --limit 1' 'no CI run found' '2' $false
    }
    else {
        $logDir = Join-Path $WorkRoot ('ci-log-' + $run.databaseId)
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        Push-Location $RepoRoot
        $logText = (& gh run view $run.databaseId --log 2>&1 | Out-String)
        $logExit = $LASTEXITCODE
        $slugHere = ((& gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>&1 | Out-String).Trim())
        Pop-Location
        # GitHub writes the repository's own address into every log - the checkout step prints
        # "Syncing repository: <owner>/<repo>", the preamble names the repository too. That
        # address is public by definition (it is where the repository lives) and it contains the
        # owner's account name, which the denylist carries. Scanned as it stands, the check would
        # fail on every run for a line the repository cannot avoid - measured by review 22 (F1)
        # with a fixture. So the address and the owner are replaced before the scan; everything
        # else in the log is scanned as it stands.
        $masked = 0
        $before = $logText
        if ($slugHere -match '^[^/]+/[^/]+$') {
            $ownerHere = $slugHere.Split('/')[0]
            if ($ownerHere) {
                $logText = [regex]::Replace($logText, ('(?<![A-Za-z0-9-])' + [regex]::Escape($ownerHere) + '(?![A-Za-z0-9-])'), 'OWNER')
            }
            $logText = $logText.Replace($slugHere, 'OWNER/REPOSITORY')
        }
        # The runner writes a random _temp folder into the log; its GUID can contain twelve
        # digits and trips the SVNR rule. It is runner state, not a personal value.
        $logText = [regex]::Replace($logText, '([\\/]_temp[\\/])[A-Za-z0-9_-]{8,}', '$1TEMP')
        if ($logText -cne $before) { $masked = 1 }
        $logFile = Join-Path $logDir 'run.log'
        [IO.File]::WriteAllText($logFile, $logText, (New-Object Text.UTF8Encoding($false)))
        # A run that never started has no log: `gh run view --log` then answers with its own error
        # text, and scanning that text measures GitHub's message, not the repository (measured
        # 2026-10-15: "log not found: <job id>" tripped the general number rule and reported a
        # finding). Nothing to scan is not a clean log - it is a check that could not do its job.
        if ($logExit -ne 0) {
            Add-Result 'V' 'no personal value in the newest CI log' ('gh run view ' + $run.databaseId + ' --log, then privacy-scan.ps1 -Path <that folder>') ('run ' + $run.databaseId + ' for ' + ([string]$run.headSha).Substring(0, [Math]::Min(7, ([string]$run.headSha).Length)) + ' (' + $run.status + '/' + $run.conclusion + '); the log could not be downloaded (exit ' + $logExit + '): ' + $logText.Trim() + ' - a job that never started has no log, so nothing was scanned') '2' $false
        }
        else {
        $vOut = (& pwsh -NoProfile -File (Join-Path $RepoRoot 'setup/tools/privacy-scan.ps1') -Path $logDir 2>&1 | Out-String)
        $vExit = $LASTEXITCODE
        $vFindings = @($vOut -split "`r?`n" | Where-Object { $_ -match 'FINDING \[' }).Count
        $ok = ($vExit -eq 0) -and ($vFindings -eq 0) -and $script:toolsOk
        $detail = 'run ' + $run.databaseId + ' for ' + ([string]$run.headSha).Substring(0, [Math]::Min(7, ([string]$run.headSha).Length)) + ' (' + $run.status + '/' + $run.conclusion + '); ' +
                  ([int]((Get-Item -LiteralPath $logFile).Length / 1KB)) + ' KB of log written to the work root and scanned; findings: ' + $vFindings + ' (exit ' + $vExit + ')' +
                  '; the scan loads the personal layer, so its own denylist is part of this' +
                  '; the repository address and the owner are masked before the scan (GitHub writes them into every log): ' + $(if ($masked) { 'yes' } else { 'nothing to mask' })
        Add-Result 'V' 'no personal value in the newest CI log' ('gh run view <id> --log into the work root, mask the repository address, then privacy-scan.ps1 -Path <that folder>') $detail '0' $ok
        }
    }
} catch { Add-Result 'V' 'no personal value in the newest CI log' 'download the CI log and scan it' $_.Exception.Message '2' $false } }

# ----------------------------------------------------------------- summary ---
Write-Both '== Result =='
$bad = @($script:results | Where-Object { -not $_.OK }).Count
if ($bad -eq 0) {
    # A green run prints the count and the one line that is not a list of names; the names are in
    # the log. A failed run prints the table, because a reader has to see which check turned red.
    Write-Host ('{0} of {1} checks passed.' -f $script:results.Count, $script:checkCount)
    Write-Log ('{0} of {1} checks passed.' -f $script:results.Count, $script:checkCount)
    foreach ($r in $script:results) { Write-Log ('{0,2}  {1,-46} PASS' -f $r.Nr, $r.Name) }
}
else {
    foreach ($r in $script:results) { Write-Both ('{0,2}  {1,-46} {2}' -f $r.Nr, $r.Name, $(if ($r.OK) { 'PASS' } else { 'FAIL' })) }
}
# A filtered run must not be able to print the acceptance line: -Only, -HomeRoot or a work root
# of one's own are tools for red proofs, not a way to a green result (review 6 and review 7 both
# showed what a green claim without the work behind it is worth).
# The log line goes BEFORE the verdict: the last line the run prints is the verdict, and the
# acceptance run's last line stays exactly "VERIFY-ALL: ALL CHECKS PASSED".
Write-Both ''
Write-Both ('full output: ' + $script:logPath)
if ($bad -eq 0) {
    if ($isAcceptanceCall -and ($script:results.Count -eq $script:checkCount)) {
        Write-Both 'VERIFY-ALL: ALL CHECKS PASSED'
        Close-Log
        exit 0
    }
    Write-Both ('VERIFY-ALL: ' + $script:results.Count + ' OF ' + $script:checkCount + ' CHECKS PASSED (partial run - not the acceptance run)')
    Close-Log
    exit 3
}
Write-Both ('VERIFY-ALL: ' + $bad + ' CHECK(S) FAILED')
Close-Log
exit 1
