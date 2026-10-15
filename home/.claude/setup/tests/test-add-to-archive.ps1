# test-add-to-archive.ps1 - prove that add-to-archive.ps1 can only ADD.
#
#   powershell -NoProfile -File setup/tests/test-add-to-archive.ps1 [-Script <path>]
#
# Runs the script against a throw-away archive below {{DEV}}\Temp, never the real
# one (the script refuses -ArchiveRoot, -SidecarRoot, -LogPath and -ConfigPath
# that do not lie below {{DEV}}\Temp). Every call also passes -ConfigPath with a
# fixture personal values file this test writes into its own scratch folder; its
# archive_categories list holds invented names only - the real list is personal
# and stands in no test.
# Each case states what must happen: ok (file added), refuse (exit 1, nothing
# written) and, at the end, that no existing file was overwritten and no folder
# was created.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI
# code page).

param(
    [string]$Script = (Join-Path $PSScriptRoot '..\powershell\add-to-archive.ps1')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Script)) { Write-Error "script not found: $Script"; exit 2 }
$scriptPath = (Resolve-Path $Script).Path

$work = '{{DEV}}\Temp\onedrive-add-only\t'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$archive = Join-Path $work 'archive'
$sidecars = Join-Path $work 'sidecars'
$src = Join-Path $work 'src'
$logFile = Join-Path $work 'log\archive-additions.md'
New-Item -ItemType Directory -Force (Join-Path $archive '01_Example\Ordner_Alpha'), (Join-Path $archive '02_Example\Ordner_Beta'), (Join-Path $archive '03_Example\Amt_Beispiel'), $sidecars, $src | Out-Null

# The personal values file the script under test reads its category list from.
# Invented names only, written UTF-8 without BOM, and it lives in this test's own
# scratch folder (wiped at the start, removed at the end).
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$configFile = Join-Path $work 'personal-fixture.yaml'
$configText = @'
# fixture for the test suite - invented values only
archive_categories:
  - "01_Example"
  - "02_Example"
  - "03_Example"
'@
[IO.File]::WriteAllText($configFile, $configText, $utf8NoBom)

function New-Pdf([string]$path, [string]$marker) {
    [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n% $marker`n1 0 obj<<>>endobj`ntrailer<<>>`n%%EOF`n"))
}
$good = Join-Path $src 'good.pdf';     New-Pdf $good 'good'
$other = Join-Path $src 'other.pdf';   New-Pdf $other 'another document with a different length'
$samesize = Join-Path $src 'same.pdf'; New-Pdf $samesize 'good'   # same bytes as good.pdf -> same size
$fake = Join-Path $src 'fake.pdf';     [IO.File]::WriteAllText($fake, 'this is only text')
$empty = Join-Path $src 'empty.pdf';   [IO.File]::WriteAllBytes($empty, [byte[]]@())
$png = Join-Path $src 'pic.png';       [IO.File]::WriteAllBytes($png, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3))
$outside = Join-Path {{TEMP_ENV}} 'add-to-archive-test-outside.pdf'; New-Pdf $outside 'outside'
# a file that already sits in the archive and must stay byte-identical
$existing = Join-Path $archive '01_Example\Ordner_Alpha\Bank_Rechnung_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2025-05-05.pdf'
New-Pdf $existing 'precious original'
$existingHash = (Get-FileHash $existing -Algorithm SHA256).Hash

$errors = 0
$total = 0
function Run-Script([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = & {{PWSH_HOST}} -NoProfile -File $scriptPath @Arguments 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Text = $text.Trim() }
    }
    finally { $ErrorActionPreference = $previous }
}
function Judge([string]$Name, [bool]$Ok, [string]$Detail) {
    $script:total++
    if (-not $Ok) { $script:errors++ }
    $tag = if ($Ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} {1}{2}" -f $tag, $Name, $(if (-not $Ok) { '  ->  ' + $Detail } else { '' }))
}
function Base([string]$Source, [string]$Category, [string]$Sub, [string]$Name, [string]$ConfigPath = $configFile) {
    return @('-Source', $Source, '-Category', $Category, '-SubFolder', $Sub, '-Name', $Name, '-ArchiveRoot', $archive, '-SidecarRoot', $sidecars, '-LogPath', $logFile, '-ConfigPath', $ConfigPath)
}
function Expect-Refuse([string]$Label, [string[]]$Arguments) {
    $r = Run-Script $Arguments
    Judge $Label ($r.Code -eq 1 -and $r.Text -match 'REFUSED') ("exit {0}: {1}" -f $r.Code, $r.Text)
}

$nameA = 'Bank_Rechnung_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-01-02.pdf'
$dirA = Join-Path $archive '01_Example\Ordner_Alpha'

# --- green: dry run writes nothing, a real add writes exactly one file --------
$r = Run-Script ((Base $good '01_Example' 'Ordner_Alpha' $nameA) + '-DryRun')
Judge 'dry run succeeds' ($r.Code -eq 0 -and $r.Text -match 'DRY RUN OK') $r.Text
Judge 'dry run wrote no file and no log' (-not (Test-Path (Join-Path $dirA $nameA)) -and -not (Test-Path $logFile)) 'something was written'

$r = Run-Script (Base $good '01_Example' 'Ordner_Alpha' $nameA)
Judge 'real add succeeds' ($r.Code -eq 0 -and $r.Text -match '^ADDED') $r.Text
$added = Join-Path $dirA $nameA
Judge 'added file is byte-identical to the source' ((Test-Path $added) -and ((Get-FileHash $added -Algorithm SHA256).Hash -eq (Get-FileHash $good -Algorithm SHA256).Hash)) 'hash differs or file missing'
Judge 'the log has one row for it' ((Test-Path $logFile) -and ((Get-Content $logFile -Raw) -match [regex]::Escape($nameA)) -and ((Get-Content $logFile -Raw) -match 'ADDED \|')) 'log row missing'
$addedHash = (Get-FileHash $added -Algorithm SHA256).Hash

# --- red: overwrite attempts --------------------------------------------------
Expect-Refuse 'same name again (would overwrite): refused' (Base $other '01_Example' 'Ordner_Alpha' $nameA)
Judge 'the added file was NOT overwritten' ((Get-FileHash $added -Algorithm SHA256).Hash -eq $addedHash) 'content changed'
Expect-Refuse 'name of a file that was already there: refused' (Base $other '01_Example' 'Ordner_Alpha' 'Bank_Rechnung_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2025-05-05.pdf')
Judge 'the pre-existing file is byte-identical' ((Get-FileHash $existing -Algorithm SHA256).Hash -eq $existingHash) 'content changed'
Expect-Refuse 'same name in another folder: refused' (Base $other '02_Example' 'Ordner_Beta' $nameA)
Expect-Refuse 'same size, other name (possible duplicate): refused' (Base $samesize '02_Example' 'Ordner_Beta' 'Bank_Zeugnis_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-03-03.pdf')
New-Item -ItemType File -Force (Join-Path $sidecars 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-04.md') | Out-Null
Expect-Refuse 'vault note for it already exists: refused' (Base $other '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-04.pdf')

# --- green: the archive's own scheme has names with a single part before the owner
$r = Run-Script ((Base $other '03_Example' 'Amt_Beispiel' 'Reisepass_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-03-11.pdf') + '-DryRun')
Judge 'a name with one part before the owner is accepted (dry run)' ($r.Code -eq 0 -and $r.Text -match 'DRY RUN OK') $r.Text

# --- red: bad names -----------------------------------------------------------
Expect-Refuse 'umlaut in name' (Base $other '03_Example' 'Amt_Beispiel' ('Amt_Bescheid_Pr' + [char]0xFC + 'fung_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-05.pdf'))
Expect-Refuse 'no owner part' (Base $other '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_2026-04-05.pdf')
Expect-Refuse 'impossible date' (Base $other '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-02-30.pdf')
Expect-Refuse 'path in name (..)' (Base $other '03_Example' 'Amt_Beispiel' '..\Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-05.pdf')
Expect-Refuse 'path in name (subfolder)' (Base $other '03_Example' 'Amt_Beispiel' 'x\Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-05.pdf')
Expect-Refuse 'space in name' (Base $other '03_Example' 'Amt_Beispiel' 'Amt Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-05.pdf')
Expect-Refuse 'name too long' (Base $other '03_Example' 'Amt_Beispiel' (('A' * 160) + '_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-05.pdf'))
Expect-Refuse 'executable extension' (Base $other '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-05.exe')

# --- red: bad folders ---------------------------------------------------------
Expect-Refuse 'sub-folder does not exist (never created)' (Base $other '03_Example' 'NichtDa' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-06.pdf')
Judge 'no folder was created' (-not (Test-Path (Join-Path $archive '03_Example\NichtDa'))) 'folder exists'
Expect-Refuse 'sub-folder with ..' (Base $other '03_Example' '..\01_Example' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-06.pdf')
Expect-Refuse 'category not in the list' (Base $other '09_Geheim' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-06.pdf')
# -ConfigPath is a test override: even a valid file outside {{DEV}}\Temp is refused.
$outsideConfig = Join-Path {{TEMP_ENV}} 'add-to-archive-test-config.yaml'
[IO.File]::WriteAllText($outsideConfig, $configText, $utf8NoBom)
$r = Run-Script @('-Source', $other, '-Category', '01_Example', '-SubFolder', 'Ordner_Alpha', '-Name', 'Amt_Config_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-10.pdf', '-ArchiveRoot', $archive, '-SidecarRoot', $sidecars, '-LogPath', $logFile, '-ConfigPath', $outsideConfig)
Judge '-ConfigPath outside {{DEV}}\Temp: refused' ($r.Code -eq 1 -and $r.Text -match '-ConfigPath is for tests') ("exit {0}: {1}" -f $r.Code, $r.Text)
# A block that holds a line other than a comment or a "- value" entry is refused, never guessed.
$badConfig = Join-Path $work 'personal-fixture-bad.yaml'
$badText = @'
# fixture for the test suite - invented values only
archive_categories:
  - "01_Example"
  this line is neither a comment nor a "- value" entry
  - "02_Example"
'@
[IO.File]::WriteAllText($badConfig, $badText, $utf8NoBom)
$r = Run-Script (Base $other '01_Example' 'Ordner_Alpha' 'Amt_Badcfg_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-11.pdf' -ConfigPath $badConfig)
Judge 'a broken archive_categories block: refused instead of guessed' ($r.Code -eq 1 -and $r.Text -match 'REFUSED' -and $r.Text -match 'category list could not be read') ("exit {0}: {1}" -f $r.Code, $r.Text)
# A complete archive outside the allowed test locations: the override must be refused.
$outsideRoot = Join-Path $PSScriptRoot '_rootcheck'
New-Item -ItemType Directory -Force (Join-Path $outsideRoot '03_Example\Amt_Beispiel') | Out-Null
$rootArgs = @('-Source', $other, '-Category', '03_Example', '-SubFolder', 'Amt_Beispiel', '-Name', 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-06.pdf', '-ArchiveRoot', $outsideRoot, '-DryRun', '-ConfigPath', $configFile)
$r = Run-Script $rootArgs
Judge '-ArchiveRoot outside {{DEV}}\Temp: refused' ($r.Code -eq 1 -and $r.Text -match 'ArchiveRoot is for tests') ("exit {0}: {1}" -f $r.Code, $r.Text)
Remove-Item $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue

# --- red: bad sources ---------------------------------------------------------
Expect-Refuse 'source outside Downloads/outbox/Temp' (Base $outside '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-07.pdf')
Expect-Refuse 'source does not exist' (Base (Join-Path $src 'gone.pdf') '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-07.pdf')
Expect-Refuse 'source is a folder' (Base $src '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-07.pdf')
Expect-Refuse 'source is only text named .pdf' (Base $fake '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-07.pdf')
Expect-Refuse 'source is empty' (Base $empty '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-07.pdf')
Expect-Refuse 'source extension differs from the name' (Base $png '03_Example' 'Amt_Beispiel' 'Amt_Bescheid_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-07.pdf')
$r = Run-Script (Base $png '03_Example' 'Amt_Beispiel' 'Amt_Foto_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-07.png')
Judge 'a real png is accepted' ($r.Code -eq 0) $r.Text

# --- red: a link folder below an allowed base, a changed %TEMP% ---------------
$elsewhere = Join-Path {{TEMP_ENV}} 'add-to-archive-test-elsewhere'
New-Item -ItemType Directory -Force $elsewhere | Out-Null
New-Pdf (Join-Path $elsewhere 'ext.pdf') 'reached through a junction'
$junction = Join-Path $src 'jx'
New-Item -ItemType Junction -Path $junction -Target $elsewhere | Out-Null
Expect-Refuse 'source below a junction folder' (Base (Join-Path $junction 'ext.pdf') '03_Example' 'Amt_Beispiel' 'Amt_Junction_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-09.pdf')
[IO.Directory]::Delete($junction)   # removes only the link, not the target
Remove-Item $elsewhere -Recurse -Force -ErrorAction SilentlyContinue
$savedTemp = {{TEMP_ENV}}
{{TEMP_ENV}} = $PSScriptRoot
$outsideRoot2 = Join-Path $PSScriptRoot '_rootcheck2'
New-Item -ItemType Directory -Force (Join-Path $outsideRoot2 '03_Example\Amt_Beispiel') | Out-Null
$r = Run-Script @('-Source', $other, '-Category', '03_Example', '-SubFolder', 'Amt_Beispiel', '-Name', 'Amt_Temp_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-09.pdf', '-ArchiveRoot', $outsideRoot2, '-DryRun', '-ConfigPath', $configFile)
{{TEMP_ENV}} = $savedTemp
Remove-Item $outsideRoot2 -Recurse -Force -ErrorAction SilentlyContinue
Judge '-ArchiveRoot is not allowed by changing %TEMP%' ($r.Code -eq 1 -and $r.Text -match 'ArchiveRoot is for tests') ("exit {0}: {1}" -f $r.Code, $r.Text)
Expect-Refuse 'name with a trailing line break' (Base $other '03_Example' 'Amt_Beispiel' ("Amt_Lf_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-09.pdf" + "`n"))

# --- red: the log cannot take its row -> nothing is added ---------------------
$badLog = Join-Path $work 'logdir-as-file'
New-Item -ItemType Directory -Force $badLog | Out-Null   # a folder where the log file should be
$badLogArgs = @('-Source', $other, '-Category', '03_Example', '-SubFolder', 'Amt_Beispiel', '-Name', 'Amt_Nolog_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-08.pdf', '-ArchiveRoot', $archive, '-SidecarRoot', $sidecars, '-LogPath', $badLog, '-ConfigPath', $configFile)
$r = Run-Script $badLogArgs
Judge 'log not writable: exit is not 0' ($r.Code -ne 0) ("exit {0}: {1}" -f $r.Code, $r.Text)
Judge 'log not writable: no file was added' (-not (Test-Path (Join-Path $archive '03_Example\Amt_Beispiel\Amt_Nolog_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_2026-04-08.pdf'))) 'file exists although it is not logged'

# --- final state: only the two intended additions -----------------------------
$files = @(Get-ChildItem $archive -Recurse -File | ForEach-Object { $_.FullName.Substring($archive.Length + 1) } | Sort-Object)
Judge 'archive holds exactly the original and the two additions' ($files.Count -eq 3) ($files -join '; ')
$rows = @((Get-Content $logFile) | Where-Object { $_ -match '^\| \d{4}-' })
Judge 'log has a PENDING and an ADDED row for each of the two additions' (@($rows | Where-Object { $_ -match '\| PENDING \|$' }).Count -eq 2 -and @($rows | Where-Object { $_ -match '\| ADDED \|$' }).Count -eq 2 -and $rows.Count -eq 4) ("rows: " + $rows.Count)

Remove-Item $outside -Force -ErrorAction SilentlyContinue
Remove-Item $outsideConfig -Force -ErrorAction SilentlyContinue
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output ("{0} checks, {1} failed" -f $total, $errors)
if ($errors -gt 0) { exit 1 }
exit 0
