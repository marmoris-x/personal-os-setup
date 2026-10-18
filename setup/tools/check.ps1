<#
setup/tools/check.ps1 - the repo's own check command. CI runs exactly this.

Parts:
  1. PSScriptAnalyzer (severity ParseError and Error) over the repo-authored PowerShell:
     setup/**, install.ps1, tests/**.
     The mirror folders (home/, vault/, dev/) are EXCLUDED: they hold exported live content,
     and "fixing" style there would change the live system - the hook suites check that
     content instead.
     ParseError is asked for explicitly: it is a severity of its own and "-Severity Error"
     alone leaves a file that does not parse unreported (measured 2026-10-14).
  2. Pester (pinned 5.9.1) over tests/.
  3. The guard test suites from the rendered tree: the mirror folders are rendered into
     tests/_tmp with fixed DUMMY values (no personal data in the repo; HOME and the documents
     parent come from the RUNNING user at check time, because the onedrive guard computes its
     exemption list from the real user profile - a static dummy would fail one case).
     Every suite then runs against the rendered hook copies.
     test-add-to-archive.ps1 is NOT run here: it needs the real archive machine and runs
     in the acceptance run (verify-all) against the live system.

  pwsh setup/tools/check.ps1
  switches for debugging: -SkipAnalyzer -SkipPester -SkipHooks

Output: one line per part on the console, plus the detail of anything that failed; the full
output (every Pester test, every guard suite case) goes to -LogPath, by default
<WorkDir>\check.log. -Verbose restores the long output. Last line CHECK-OK or CHECK: ERRORS.
Exit 0/1.
ASCII-only on purpose (same reason as install.ps1).
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipPester,
    [switch]$SkipHooks,
    [string]$WorkDir,
    # where the full output goes; the default sits in the same per-run folder as the render, and
    # the acceptance run points it at the task folder so a report can find it
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$setupDir = Split-Path -Parent $PSScriptRoot          # setup/
$repoRoot = Split-Path -Parent $setupDir              # the repo
if (-not $WorkDir) { $WorkDir = Join-Path $repoRoot 'tests\_tmp\check' }
if (-not $LogPath) { $LogPath = Join-Path $WorkDir 'check.log' }
$errorCount = 0

# --- output: one summary line per part on the console, everything in the log ------------------
# Owner's order (agent-upgrade-task.md, Part 4.1), the same rule as verify-all.ps1: a green run
# prints one line per part and the detail of what failed; the full output - every part, every
# Pester test, every guard suite - goes to -LogPath. `-Verbose` restores the old output, and with
# it Pester's own per-test listing.
$verboseOutput = ($VerbosePreference -ne 'SilentlyContinue')
$log = $null
try {
    # the folder may not exist yet: -WorkDir is created by the first check that needs it, and a
    # StreamWriter on a missing folder throws (measured: the first run of this version wrote no
    # log at all, and only the "full output:" line said where one was expected)
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $log = New-Object System.IO.StreamWriter($LogPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $log.AutoFlush = $true
} catch { $log = $null }
function Write-Log([string]$line) { if ($null -ne $script:log) { try { $script:log.WriteLine($line) } catch { } } }
function Write-Both([string]$line) { Write-Log $line; Write-Host $line }
function Close-Log { if ($null -ne $script:log) { try { $script:log.Flush(); $script:log.Close() } catch { }; $script:log = $null } }

. (Join-Path $setupDir 'lib/manifest.ps1')
. (Join-Path $setupDir 'lib/platform.ps1')
. (Join-Path $setupDir 'lib/placeholders.ps1')
$checkOs = Get-PlatformId

# --- 1. PSScriptAnalyzer -----------------------------------------------------
if (-not $SkipAnalyzer) {
    Write-Both '== PSScriptAnalyzer (severity ParseError and Error) =='
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -Repository PSGallery }
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    # the mirror folders hold exported live content, not repo-authored code (see the header)
    $mirrorDirs = @(Get-MirrorFolder | ForEach-Object { (Join-Path $repoRoot ($_.RepoRel -replace '/', '\')) })
    $files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.ps1' |
        Where-Object { $f = $_; -not ($mirrorDirs | Where-Object { $f.FullName -like ($_ + '\*') }) } |
        Where-Object { $_.FullName -notlike (Join-Path $repoRoot 'tests\_tmp\*') } |
        Where-Object { $_.FullName -notlike '*\.git\*' }
    $issues = @()
    # ParseError is a severity of its own, and "-Severity Error" alone does NOT include it.
    # Measured 2026-10-14: a hash literal missing its "=" in setup/platform/linux.ps1 stayed
    # invisible to this step (severity ParseError) and only CI on Linux noticed, because only
    # Linux loads that file. Parse errors belong in the list a check calls an error.
    foreach ($f in $files) { $issues += @(Invoke-ScriptAnalyzer -Path $f.FullName -Severity ParseError, Error) }
    foreach ($i in $issues) { Write-Both ('  ' + $i.ScriptName + ':' + $i.Line + '  ' + $i.RuleName + '  ' + $i.Message) }
    if ($issues.Count -eq 0) { Write-Host '  ANALYZER-OK (0 errors)' -ForegroundColor Green; Write-Log '  ANALYZER-OK (0 errors)' }
    else { Write-Host ('  ANALYZER: ' + $issues.Count + ' errors') -ForegroundColor Red; Write-Log ('  ANALYZER: ' + $issues.Count + ' errors'); $errorCount += $issues.Count }
}

# --- 2. Pester ---------------------------------------------------------------
if (-not $SkipPester) {
    Write-Both '== Pester (tests/) =='
    if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq '5.9.1' })) {
        Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser -Force -Repository PSGallery -SkipPublisherCheck
    }
    Import-Module Pester -RequiredVersion 5.9.1
    # the suites that need scratch space read this: with the default they would all use one fixed
    # folder under tests\_tmp, and two runs at the same time (a reviewer and the worker, say) would
    # delete each other's target while the other suite is installing into it (review 5, finding 7)
    $env:PERSONAL_OS_CHECK_WORKDIR = $WorkDir
    # Pester's own listing is the longest part of this output and says "passed" 100 times. It goes
    # to the log one line per test; the console gets the count and, for a failure, the message.
    # The `6>&1` is what keeps the console clean: several test files print their own warnings with
    # Write-Host, and Write-Host is not silenceable through a preference - it writes to the
    # information stream, so the stream is captured here and the lines go to the log instead.
    if ($verboseOutput) {
        $r = Invoke-Pester (Join-Path $repoRoot 'tests') -Output Normal -PassThru
    }
    else {
        $pesterItems = @(Invoke-Pester (Join-Path $repoRoot 'tests') -Output None -PassThru 6>&1)
        foreach ($it in $pesterItems) {
            if ($it -is [System.Management.Automation.InformationRecord]) { Write-Log ('  ' + [string]$it.MessageData) }
        }
        $r = @($pesterItems | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[-1]
    }
    if (-not $r) { Write-Host '  PESTER: the run returned no result object' -ForegroundColor Red; $errorCount++; $r = [pscustomobject]@{ PassedCount = 0; FailedCount = 0; SkippedCount = 0; Tests = @(); Failed = @() } }
    foreach ($t in @($r.Tests)) { Write-Log ('  ' + $(if ($t.Result -eq 'Passed') { 'PASS' } else { 'FAIL' }) + '  ' + [string]$t.ExpandedPath) }
    foreach ($f in @($r.Failed)) {
        $msg = ([string]$f.FailureMessage -split "`r?`n")[0]
        Write-Log ('  FAILURE ' + [string]$f.ExpandedPath + ': ' + $msg)
        Write-Host ('  FAILED  ' + [string]$f.ExpandedPath + ': ' + $msg) -ForegroundColor Red
    }
    Write-Host ('  PESTER: ' + $r.PassedCount + ' passed, ' + $r.FailedCount + ' failed, ' + $r.SkippedCount + ' skipped') -ForegroundColor $(if ($r.FailedCount -gt 0) { 'Red' } else { 'Green' })
    Write-Log ('  PESTER: ' + $r.PassedCount + ' passed, ' + $r.FailedCount + ' failed, ' + $r.SkippedCount + ' skipped')
    $errorCount += $r.FailedCount
    if ($r.PassedCount -eq 0) { Write-Host '  PESTER: no test ran - that counts as an error' -ForegroundColor Red; $errorCount++ }
}

# --- 3. docs freshness --------------------------------------------------------
Write-Both '== docs current (components.md from the manifest) =='
$null = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'generate-docs.ps1') -Check
if ($LASTEXITCODE -ne 0) { Write-Both '  docs/components.md is outdated - run setup/tools/generate-docs.ps1'; $errorCount++ }
else { Write-Both '  COMPONENTS-OK' }

# --- 4. guard suites from the rendered tree ----------------------------------
if (-not $SkipHooks) {
    Write-Both '== guard suites (from the rendered tree, dummy values) =='
    $renderDir = Join-Path $WorkDir 'render'
    if (Test-Path -LiteralPath $renderDir) { Remove-Item -LiteralPath $renderDir -Recurse -Force }
    # folder names only, joined at runtime - never a literal path in the repo
    $syncDirName = 'OneDrive'
    $docsDirName = 'Dokumente'
    # HOME is the RUNNING user, not a literal: the onedrive guard computes its exemption list
    # from the real profile, and a static dummy would fail one of its cases.
    # VAULT and DEV keep a fixed, drive-root shape because the guards under test carry path
    # patterns written for it (onedrive-guard.ps1 matches "<drive>:/PersonalOS/outbox"). They
    # are strings the render is fed with, not an assumption of this script - the platform
    # rules live in setup/lib/platform.ps1 and the mirror folders.
    $dummyRoots = @{
        HOME      = Get-PlatformHome
        DOCUMENTS = Join-Path (Get-PlatformHome) (Join-Path $syncDirName $docsDirName)
        VAULT     = 'C:\PersonalOS'
        DEV       = 'C:\Dev'
    }
    $dummyCfg = @{
        user_name        = 'Vera Beispiel'
        user_given       = 'Vera'
        user_family      = 'Beispiel'
        github_account   = 'example-user'
        b2_bucket        = 'example-kopia-backup'
        archive_dir_name = 'Dokumentenarchiv'
        morning_time     = '07:00'
        backup_time      = '12:30'
    }
    # the placeholder map of the system this check runs on: the rendered tree must be what
    # install.ps1 would write here, so {{PWSH_HOST}} is pwsh on macOS/Linux
    $map = Get-PlaceholderMap -Roots $dummyRoots -ConfigValues $dummyCfg -Os $checkOs
    $map['{{INSTALL_DATE}}'] = '2026-01-01'
    $map['{{USER_SID}}'] = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    $map['{{START_BOUNDARY}}'] = '2026-01-01T07:00:00+01:00'
    $binExt = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.pyc')
    # every mirror folder is rendered into a tree shaped like the TARGET (HOME/, DOCUMENTS/,
    # VAULT/, DEV/) - that is what the guard suites expect next to themselves.
    foreach ($mirror in (Get-MirrorFolder)) {
        $src = Join-Path $repoRoot ($mirror.RepoRel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $src -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/')
            if ($mirror.Skip.Count -gt 0) {
                $top = ($rel -split '\\')[0]
                if ($mirror.Skip -contains $top) { continue }
            }
            $dest = Join-Path (Join-Path $renderDir $mirror.Target) $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
            if ($binExt -contains $f.Extension.ToLowerInvariant()) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force; continue }
            $text = Expand-Placeholders ([IO.File]::ReadAllText($f.FullName)) $map
            [IO.File]::WriteAllText($dest, $text, (New-Object Text.UTF8Encoding($false)))
        }
    }
    Write-Host ('  rendered to ' + $renderDir)
    # Which suites can run on which system (task decision D10: "Windows-specific cases are
    # tagged and skipped elsewhere with a reason"). The reason is printed, so a skipped suite
    # is visible in the output instead of quietly missing.
    $suites = @(
        [pscustomobject]@{ Name = 'test-block-dangerous.ps1';    Os = @('windows'); Why = 'its cases are Windows command lines (cmd /c, %TEMP%, C:\...\Temp) and the guard under test is the live Windows text - measured 2026-10-14 in CI: 9 of 120 cases cannot hold on Linux' }
        [pscustomobject]@{ Name = 'test-block-dangerous-51.ps1'; Os = @('windows'); Why = 'it starts Windows PowerShell 5.1, which exists on Windows only' }
        [pscustomobject]@{ Name = 'test-downloads-guard.ps1';    Os = @('windows'); Why = 'its cases build <home>\Downloads\... paths, which are Windows text; the guard under test is the live Windows file (measured 2026-10-14 in CI: 27 cases cannot hold on Linux)' }
        [pscustomobject]@{ Name = 'test-archive-guard.ps1';      Os = @('windows', 'macos', 'linux'); Why = '' }
        [pscustomobject]@{ Name = 'test-onedrive-guard.ps1';     Os = @('windows'); Why = 'the guard recognizes the wide globs of a Windows profile; on macOS/Linux its detection is stricter and blocks cases its suite expects to pass (measured 2026-10-14 in CI: 40 of 191 cases)' }
        [pscustomobject]@{ Name = 'test-trifecta-guard.ps1';     Os = @('windows', 'macos', 'linux'); Why = '' }
        [pscustomobject]@{ Name = 'test-session-check.ps1';      Os = @('windows', 'macos', 'linux'); Why = '' }
        [pscustomobject]@{ Name = 'test-no-license-files.ps1';   Os = @('windows', 'macos', 'linux'); Why = '' }
        [pscustomobject]@{ Name = 'test-fetch-guard.ps1';        Os = @('windows'); Why = 'it starts powershell.exe (Windows PowerShell 5.1), the host the live hook registration uses' }
    )
    foreach ($suite in $suites) {
        if ($suite.Os -notcontains $checkOs) {
            Write-Host ('  SKIP  ' + $suite.Name + '  (not for ' + $checkOs + ': ' + $suite.Why + ')') -ForegroundColor DarkGray
            continue
        }
        $path = Join-Path $renderDir ('HOME/.claude/setup/tests/' + $suite.Name)
        if (-not (Test-Path -LiteralPath $path)) { Write-Host ('  ' + $suite.Name + ': MISSING') -ForegroundColor Red; $errorCount++; continue }
        $out = & pwsh -NoProfile -File $path 2>&1 | Out-String
        # measured formats: "Errors: 0 of 120" / "0 errors" / "0 failed" - exit code decides too.
        # The number and its word stay on ONE line: with \s+ a case name ending in a digit ("...UTF-8")
        # plus the blank line before the summary read as "8 ... errors", so a suite that passed was
        # reported as an error (measured 2026-10-16 against the umlaut case in test-block-dangerous).
        $ok = ($LASTEXITCODE -eq 0) -and ($out -match '(?m)(Errors:[^\S\r\n]*0\b|\b0 (failed|errors)\b)') -and ($out -notmatch '(?m)(Errors:[^\S\r\n]*[1-9]\d*\b|[1-9]\d*[^\S\r\n]+(failed|errors)\b)')
        # The suite prints one line per case. The log keeps all of them; the console keeps the
        # suite's own count line, and for a failure the failing cases.
        Write-Log ('  == ' + $suite.Name)
        foreach ($l in ($out -split "`r?`n")) { if ($l.Trim() -ne '') { Write-Log ('     ' + $l) } }
        if ($ok) {
            $line = ($out -split "`n" | Where-Object { $_ -match '(errors|failed)' } | Select-Object -Last 1).Trim()
            Write-Host ('  OK    ' + $suite.Name + '  ' + $line) -ForegroundColor Green
            Write-Log ('  OK    ' + $suite.Name + '  ' + $line)
        }
        else {
            Write-Host ('  ERROR ' + $suite.Name) -ForegroundColor Red
            Write-Host ($out -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 8 | ForEach-Object { '    ' + $_ }) -ForegroundColor Red
            Write-Host ($out -split "`n" | Select-Object -Last 4 | ForEach-Object { '    ' + $_ }) -ForegroundColor Red
            Write-Log ('  ERROR ' + $suite.Name)
            $errorCount++
        }
    }
}

Write-Host ''
Write-Both ('full output: ' + $LogPath)
# The verdict stays the LAST line, so a reader (and verify-all's check 5) can take the tail.
if ($errorCount -gt 0) { Write-Host ('CHECK: ' + $errorCount + ' errors') -ForegroundColor Red; Write-Log ('CHECK: ' + $errorCount + ' errors'); Close-Log; exit 1 }
Write-Host 'CHECK-OK' -ForegroundColor Green
Write-Log 'CHECK-OK'
Close-Log
exit 0
