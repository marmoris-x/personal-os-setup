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

Output: per part a summary; last line CHECK-OK or CHECK: ERRORS. Exit 0/1.
ASCII-only on purpose (same reason as install.ps1).
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipPester,
    [switch]$SkipHooks,
    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'
$setupDir = Split-Path -Parent $PSScriptRoot          # setup/
$repoRoot = Split-Path -Parent $setupDir              # the repo
if (-not $WorkDir) { $WorkDir = Join-Path $repoRoot 'tests\_tmp\check' }
$errorCount = 0

. (Join-Path $setupDir 'lib/manifest.ps1')
. (Join-Path $setupDir 'lib/platform.ps1')
. (Join-Path $setupDir 'lib/placeholders.ps1')
$checkOs = Get-PlatformId

# --- 1. PSScriptAnalyzer -----------------------------------------------------
if (-not $SkipAnalyzer) {
    Write-Host '== PSScriptAnalyzer (severity ParseError and Error) ==' -ForegroundColor Cyan
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
    foreach ($i in $issues) { Write-Host ('  ' + $i.ScriptName + ':' + $i.Line + '  ' + $i.RuleName + '  ' + $i.Message) -ForegroundColor Red }
    if ($issues.Count -eq 0) { Write-Host '  ANALYZER-OK (0 errors)' -ForegroundColor Green }
    else { Write-Host ('  ANALYZER: ' + $issues.Count + ' errors') -ForegroundColor Red; $errorCount += $issues.Count }
}

# --- 2. Pester ---------------------------------------------------------------
if (-not $SkipPester) {
    Write-Host '== Pester ' -NoNewline -ForegroundColor Cyan
    Write-Host '(tests/) ==' -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq '5.9.1' })) {
        Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser -Force -Repository PSGallery -SkipPublisherCheck
    }
    Import-Module Pester -RequiredVersion 5.9.1
    # the suites that need scratch space read this: with the default they would all use one fixed
    # folder under tests\_tmp, and two runs at the same time (a reviewer and the worker, say) would
    # delete each other's target while the other suite is installing into it (review 5, finding 7)
    $env:PERSONAL_OS_CHECK_WORKDIR = $WorkDir
    $r = Invoke-Pester (Join-Path $repoRoot 'tests') -Output Normal -PassThru
    Write-Host ('  PESTER: ' + $r.PassedCount + ' passed, ' + $r.FailedCount + ' failed, ' + $r.SkippedCount + ' skipped') -ForegroundColor $(if ($r.FailedCount -gt 0) { 'Red' } else { 'Green' })
    $errorCount += $r.FailedCount
    if ($r.PassedCount -eq 0) { Write-Host '  PESTER: no test ran - that counts as an error' -ForegroundColor Red; $errorCount++ }
}

# --- 3. docs freshness --------------------------------------------------------
Write-Host '== docs current (components.md from the manifest) ==' -ForegroundColor Cyan
$null = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'generate-docs.ps1') -Check
if ($LASTEXITCODE -ne 0) { Write-Host '  docs/components.md is outdated - run setup/tools/generate-docs.ps1' -ForegroundColor Red; $errorCount++ }
else { Write-Host '  COMPONENTS-OK' -ForegroundColor Green }

# --- 4. guard suites from the rendered tree ----------------------------------
if (-not $SkipHooks) {
    Write-Host '== guard suites (from the rendered tree, dummy values) ==' -ForegroundColor Cyan
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
    )
    foreach ($suite in $suites) {
        if ($suite.Os -notcontains $checkOs) {
            Write-Host ('  SKIP  ' + $suite.Name + '  (not for ' + $checkOs + ': ' + $suite.Why + ')') -ForegroundColor DarkGray
            continue
        }
        $path = Join-Path $renderDir ('HOME/.claude/setup/tests/' + $suite.Name)
        if (-not (Test-Path -LiteralPath $path)) { Write-Host ('  ' + $suite.Name + ': MISSING') -ForegroundColor Red; $errorCount++; continue }
        $out = & pwsh -NoProfile -File $path 2>&1 | Out-String
        # measured formats: "Errors: 0 of 120" / "0 errors" / "0 failed" - exit code decides too
        $ok = ($LASTEXITCODE -eq 0) -and ($out -match '(?m)(Errors:\s*0\b|\b0 (failed|errors)\b)') -and ($out -notmatch '(?m)(Errors:\s*[1-9]\d*\b|[1-9]\d*\s+(failed|errors)\b)')
        if ($ok) {
            $line = ($out -split "`n" | Where-Object { $_ -match '(errors|failed)' } | Select-Object -Last 1).Trim()
            Write-Host ('  OK    ' + $suite.Name + '  ' + $line) -ForegroundColor Green
        }
        else {
            Write-Host ('  ERROR ' + $suite.Name) -ForegroundColor Red
            Write-Host ($out -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 8 | ForEach-Object { '    ' + $_ }) -ForegroundColor Red
            Write-Host ($out -split "`n" | Select-Object -Last 4 | ForEach-Object { '    ' + $_ }) -ForegroundColor Red
            $errorCount++
        }
    }
}

Write-Host ''
if ($errorCount -gt 0) { Write-Host ('CHECK: ' + $errorCount + ' errors') -ForegroundColor Red; exit 1 }
Write-Host 'CHECK-OK' -ForegroundColor Green
exit 0
