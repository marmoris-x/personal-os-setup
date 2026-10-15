# add-to-archive.ps1 - add ONE new file to the document archive in OneDrive.
#
#   powershell -NoProfile -File add-to-archive.ps1 -Source <file> -Category <folder> `
#       -SubFolder <existing sub-folder> -Name <final file name> [-DryRun]
#
# -Category must be one of the folder names the personal values file lists under
# archive_categories (default: <home>/.personal-os/personal.yaml). That list is
# personal - it says what the owner keeps - so it stands in no repository and this
# script carries none of it; docs/decisions/0004-personal-layer.md. A category that
# is not in the list is refused, and the refusal does not print the list.
#
# This is the only way the agent adds a file to OneDrive\Dokumentenarchiv
# (rule 2 of the vault's AGENTS.md; the onedrive-guard hook blocks every other
# way). The script can add and nothing else:
#   - it copies with FileMode.CreateNew: if the target name exists, the copy
#     fails. It cannot overwrite. It has no delete, move or rename code.
#   - the folder must already exist (it never creates folders)
#   - the name must follow the archive scheme
#       Sender_DocumentType_Details_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_YYYY-MM-DD.ext
#   - the source must lie in Downloads, PersonalOS\outbox or {{DEV}}\Temp and
#     must look like what its extension says (magic bytes)
#   - double check before anything is written (name, size, vault sidecar)
#   - every added file is logged in 000-meta\archive-additions.md (git-ignored:
#     the names are personal): a PENDING row before the copy, the result row
#     (ADDED or HASH-MISMATCH) after it. A PENDING row without a result row
#     means the copy broke off: tell the user.
#   -DryRun runs every check and writes nothing.
#
# Exit codes: 0 added (or dry run ok), 1 refused (nothing written), 2 error.
#
# -ArchiveRoot, -SidecarRoot, -LogPath and -ConfigPath exist for the test suite.
# They are refused unless they point below {{DEV}}\Temp.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI
# code page).

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Category,
    [Parameter(Mandatory = $true)][string]$SubFolder,
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$DryRun,
    [string]$ArchiveRoot,
    [string]$SidecarRoot,
    [string]$LogPath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

function Stop-Refused([string]$why) {
    Write-Output ('REFUSED: ' + $why)
    exit 1
}

function Test-BelowTemp([string]$path) {
    # Hard-coded on purpose: %TEMP% can be changed by whoever starts the script.
    $full = [IO.Path]::GetFullPath($path)
    return $full.StartsWith('{{DEV}}\Temp\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-ArchiveCategories([string]$path) {
    # Reads the archive_categories block of a personal values file. Deliberately without a
    # YAML module: this script also runs in Windows PowerShell 5.1, and powershell-yaml is
    # installed for PowerShell 7 only (measured 2026-10-15), so a module-bound reader would
    # refuse every category there. The shape is the one setup/config/personal.example.yaml
    # shows and install.ps1 writes:
    #     archive_categories:
    #       - "01_Example"
    # Anything else inside the block is refused, never guessed. An inline comment after a value
    # IS stripped: YAML means it that way, a person writing the file expects it, and review 22
    # (F4) measured what the earlier reader did with `- "01_Example" # note` - it handed back the
    # quotes and the comment as part of the name, so the real category was refused and every
    # scan that reads the same list hunted a term that does not exist.
    # setup/lib/personal.ps1 holds the same reader for the repository tools, and
    # tests/PersonalLayer.Tests.ps1 feeds both the same file and requires the same answer.
    $cats = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $seen = $false
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if (-not $inBlock) {
            if ($line -match '^archive_categories\s*:(?:\s*#.*)?$') { $inBlock = $true; $seen = $true }
            continue
        }
        if ($line.Trim() -eq '' -or $line -match '^\s*#') { continue }
        if ($line -match '^\s*-\s*(?<v>.+?)\s*$') {
            $v = $Matches['v']
            $q = if ($v.Length -ge 1) { $v.Substring(0, 1) } else { '' }
            if ($q -eq '"' -or $q -eq "'") {
                $close = $v.IndexOf($q, 1)
                if ($close -lt 1) { throw ('the archive_categories block of ' + $path + ' holds a quoted value that never closes') }
                $rest = $v.Substring($close + 1).Trim()
                if ($rest -ne '' -and -not $rest.StartsWith('#')) { throw ('the archive_categories block of ' + $path + ' holds text after a quoted value that is not a comment') }
                $v = $v.Substring(1, $close - 1)
            }
            else {
                # A bare value ends where a comment starts: YAML begins one at ' #'.
                $h = $v.IndexOf(' #')
                if ($h -ge 0) { $v = $v.Substring(0, $h).Trim() }
            }
            if ($v.Trim() -eq '') { throw ('the archive_categories block of ' + $path + ' holds an entry without a value') }
            $cats.Add($v)
            continue
        }
        if ($line -match '^\S') { break }        # the next key at column 0 ends the block
        throw ('the archive_categories block of ' + $path + ' holds a line that is neither a comment nor a "- value" entry')
    }
    if (-not $seen) { throw ('no archive_categories block in ' + $path) }
    # NO unary comma here: `return , $x` keeps an array from being unrolled by the pipeline,
    # and the caller already wraps the call in @(...). Measured 2026-10-15: with the comma
    # @(Get-ArchiveCategories ...) saw ONE element (the array) instead of its values, so a
    # list of eight names looked like a list of one.
    return $cats.ToArray()
}

try {
    # --- the category must be one of the personal folder names ---------------
    # This was a ValidateSet until v3.0.0. A ValidateSet is a build-time constant, and the
    # real folder names must not stand in this file: they say what the owner keeps. They
    # live in the personal layer and this script reads them there
    # (docs/decisions/0004-personal-layer.md). A category outside the list is refused, and
    # the refusal names no category - otherwise a log or a session would learn them, which
    # is exactly what moving the list out of the repository prevents.
    if ($ConfigPath -and (-not (Test-BelowTemp $ConfigPath))) { Stop-Refused '-ConfigPath is for tests and must be below {{DEV}}\Temp.' }
    if (-not $ConfigPath) { $ConfigPath = Join-Path {{HOME_ENV}} '.personal-os\personal.yaml' }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Stop-Refused ('the personal values file is missing: ' + $ConfigPath) }
    try { $categories = @(Get-ArchiveCategories $ConfigPath) }
    catch { Stop-Refused ('the category list could not be read: ' + $_.Exception.Message) }
    if ($categories.Count -eq 0) { Stop-Refused ('the personal values file lists no archive_categories: ' + $ConfigPath) }
    if ($categories -notcontains $Category) {
        Stop-Refused ('"' + $Category + '" is not one of the ' + $categories.Count + ' categories in ' + $ConfigPath + '. The list is personal and is not printed here - open the file, or ask the user for a folder name.')
    }

    # --- test overrides ------------------------------------------------------
    $root = Join-Path {{HOME_ENV}} 'OneDrive\Dokumentenarchiv'
    $sidecars = '{{VAULT}}\600-archive'
    $log = '{{VAULT}}\000-meta\archive-additions.md'
    if ($ArchiveRoot) { if (-not (Test-BelowTemp $ArchiveRoot)) { Stop-Refused '-ArchiveRoot is for tests and must be below {{DEV}}\Temp.' }; $root = [IO.Path]::GetFullPath($ArchiveRoot) }
    if ($SidecarRoot) { if (-not (Test-BelowTemp $SidecarRoot)) { Stop-Refused '-SidecarRoot is for tests and must be below {{DEV}}\Temp.' }; $sidecars = [IO.Path]::GetFullPath($SidecarRoot) }
    if ($LogPath) { if (-not (Test-BelowTemp $LogPath)) { Stop-Refused '-LogPath is for tests and must be below {{DEV}}\Temp.' }; $log = [IO.Path]::GetFullPath($LogPath) }

    # --- name ----------------------------------------------------------------
    if ($Name.Length -gt 150) { Stop-Refused 'name is longer than 150 characters.' }
    $m = [regex]::Match($Name, '^[A-Za-z0-9-]+(_[A-Za-z0-9-]+)*_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_(\d{4}-\d{2}-\d{2})\.(pdf|docx|doc|xlsx|xls|jpg|jpeg|png|odt)\z')
    if (-not $m.Success) { Stop-Refused 'name does not follow Sender_DocumentType_Details_{{USER_FAMILY_UPPER}}_{{USER_GIVEN}}_YYYY-MM-DD.ext (letters, digits, hyphen, underscore; no umlauts).' }
    $dateText = $m.Groups[2].Value
    if ($dateText -ne '0000-00-00') {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($dateText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { Stop-Refused ('the date in the name is not a real date: ' + $dateText) }
    }
    $ext = $m.Groups[3].Value.ToLower()
    $baseName = [IO.Path]::GetFileNameWithoutExtension($Name)

    if ($SubFolder -notmatch '^[A-Za-z0-9_-]+\z') { Stop-Refused 'sub-folder may contain only letters, digits, underscore and hyphen.' }

    # --- source --------------------------------------------------------------
    $srcFull = [IO.Path]::GetFullPath($Source)
    $okSource = $false
    $usedBase = ''
    foreach ($base in @(((Join-Path {{HOME_ENV}} 'Downloads') + '\'), '{{VAULT}}\outbox\', '{{DEV}}\Temp\')) {
        if ($srcFull.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $okSource = $true; $usedBase = $base.TrimEnd('\') }
    }
    if (-not $okSource) { Stop-Refused 'source must lie in Downloads, {{VAULT}}\outbox or {{DEV}}\Temp.' }
    # A junction or symlink folder below the allowed base could point anywhere.
    $up = Split-Path -Parent $srcFull
    while ($up -and $up.Length -gt $usedBase.Length) {
        if ((Get-Item -LiteralPath $up -Force).LinkType) { Stop-Refused ('source lies below a link (junction or symlink): ' + $up) }
        $up = Split-Path -Parent $up
    }
    if (-not (Test-Path -LiteralPath $srcFull -PathType Leaf)) { Stop-Refused ('source file not found: ' + $srcFull) }
    $srcItem = Get-Item -LiteralPath $srcFull -Force
    if ($srcItem.LinkType -in @('SymbolicLink', 'Junction')) { Stop-Refused 'source is a link, not a real file.' }
    if ($srcItem.Extension.TrimStart('.').ToLower() -ne $ext) { Stop-Refused ('source extension .' + $srcItem.Extension.TrimStart('.') + ' differs from the target name extension .' + $ext) }
    if ($srcItem.Length -le 0) { Stop-Refused 'source file is empty.' }
    if ($srcItem.Length -gt 100MB) { Stop-Refused 'source file is larger than 100 MB.' }

    $head = New-Object byte[] 8
    $fs = [IO.File]::Open($srcFull, 'Open', 'Read', 'Read')
    try { [void]$fs.Read($head, 0, 8) } finally { $fs.Close() }
    $magicOk = switch ($ext) {
        'pdf'  { $head[0] -eq 0x25 -and $head[1] -eq 0x50 -and $head[2] -eq 0x44 -and $head[3] -eq 0x46 }
        { $_ -in 'jpg', 'jpeg' } { $head[0] -eq 0xFF -and $head[1] -eq 0xD8 -and $head[2] -eq 0xFF }
        'png'  { $head[0] -eq 0x89 -and $head[1] -eq 0x50 -and $head[2] -eq 0x4E -and $head[3] -eq 0x47 }
        { $_ -in 'docx', 'xlsx', 'odt' } { $head[0] -eq 0x50 -and $head[1] -eq 0x4B }
        { $_ -in 'doc', 'xls' } { $head[0] -eq 0xD0 -and $head[1] -eq 0xCF -and $head[2] -eq 0x11 -and $head[3] -eq 0xE0 }
        default { $false }
    }
    if (-not $magicOk) { Stop-Refused ('the content does not look like a .' + $ext + ' file (file header check).') }

    # --- target folder: must exist, is never created ------------------------
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Stop-Refused ('archive root not found: ' + $root) }
    $catDir = Join-Path $root $Category
    $targetDir = Join-Path $catDir $SubFolder
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) { Stop-Refused ('folder does not exist (this script never creates folders): ' + $Category + '\' + $SubFolder) }
    # OneDrive marks its own folders with a reparse flag (cloud placeholder); only a
    # real junction or symlink has a LinkType.
    foreach ($dir in @($catDir, $targetDir)) {
        if ((Get-Item -LiteralPath $dir -Force).LinkType) { Stop-Refused 'target folder is a link.' }
    }
    $target = Join-Path $targetDir $Name

    # --- double check (names and sizes only, no content of archive files) ----
    if (Test-Path -LiteralPath $target) { Stop-Refused ('a file with this name already exists there: ' + $Category + '\' + $SubFolder + '\' + $Name) }
    # A folder that cannot be read would silently weaken the check, so an
    # enumeration error refuses the add instead of being skipped.
    try {
        $sameName = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $Name -ErrorAction Stop)
        $sameSize = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter ('*.' + $ext) -ErrorAction Stop | Where-Object { $_.Length -eq $srcItem.Length })
    }
    catch { Stop-Refused ('the archive could not be read completely, so the duplicate check is not trustworthy: ' + $_.Exception.Message) }
    if ($sameName.Count -gt 0) { Stop-Refused ('a file with this name exists elsewhere in the archive: ' + $sameName[0].FullName.Substring($root.Length + 1)) }
    if ($sameSize.Count -gt 0) { Stop-Refused ('POSSIBLE DUPLICATE: a .' + $ext + ' file of exactly ' + $srcItem.Length + ' bytes is already in the archive: ' + $sameSize[0].FullName.Substring($root.Length + 1) + '. Ask the user.') }
    if (Test-Path -LiteralPath $sidecars -PathType Container) {
        $sidecar = @(Get-ChildItem -LiteralPath $sidecars -Recurse -File -Filter ($baseName + '.md') -ErrorAction SilentlyContinue)
        if ($sidecar.Count -gt 0) { Stop-Refused ('the vault already has a note for this document: ' + $sidecar[0].FullName.Substring($sidecars.Length + 1)) }
    }

    $srcHash = (Get-FileHash -LiteralPath $srcFull -Algorithm SHA256).Hash
    $rel = $Category + '\' + $SubFolder + '\' + $Name
    if ($DryRun) {
        Write-Output ('DRY RUN OK: would add ' + $rel + ' | ' + $srcItem.Length + ' bytes | sha256 ' + $srcHash)
        exit 0
    }

    # --- log first: no file is added unless the log can take its row --------
    $utf8 = New-Object Text.UTF8Encoding($false)
    $logDir = Split-Path -Parent $log
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        if (-not $LogPath) { Stop-Refused ('log folder not found: ' + $logDir) }
        New-Item -ItemType Directory -Force $logDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $log)) {
        $header = "---`ntype: note`nstatus: active`ndate: " + (Get-Date -Format 'yyyy-MM-dd') + "`n---`n`n# Archive additions`n`nEvery file the agent added to the OneDrive document archive with add-to-archive.ps1 (rule 2). Append-only; the script writes it. Git-ignored: the names are personal.`n`n| Time | Folder | File | Bytes | SHA256 | Source file | Result |`n|---|---|---|---|---|---|---|`n"
        [IO.File]::WriteAllText($log, $header, $utf8)
    }
    $probe = [IO.File]::Open($log, 'Append', 'Write', 'Read')   # throws now, not after the copy
    $probe.Close()
    # A PENDING row goes in before the copy, so a crash or a locked file after
    # it still leaves a trace; the result row follows when the copy is done.
    $pending = '| ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' | ' + $Category + '\' + $SubFolder + ' | ' + $Name + ' | ' + $srcItem.Length + ' | ' + $srcHash + ' | ' + $srcItem.Name + " | PENDING |`n"
    [IO.File]::AppendAllText($log, $pending, $utf8)

    # --- copy: CreateNew cannot overwrite -----------------------------------
    $in = [IO.File]::Open($srcFull, 'Open', 'Read', 'Read')
    try {
        try { $out = [IO.File]::Open($target, 'CreateNew', 'Write', 'None') }
        catch [IO.IOException] { Stop-Refused ('the target appeared in the meantime or cannot be created: ' + $rel) }
        try { $in.CopyTo($out); $out.Flush() }
        catch {
            $out.Close()
            Write-Output ('ERROR: copy broke off. A partial file may be at ' + $rel + '. The agent must not delete it. Tell the user.')
            exit 2
        }
        $out.Close()
    }
    finally { $in.Close() }

    $dstHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $status = if ($dstHash -eq $srcHash) { 'ADDED' } else { 'HASH-MISMATCH' }

    # --- log row -------------------------------------------------------------
    $row = '| ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' | ' + $Category + '\' + $SubFolder + ' | ' + $Name + ' | ' + $srcItem.Length + ' | ' + $dstHash + ' | ' + $srcItem.Name + ' | ' + $status + " |`n"
    [IO.File]::AppendAllText($log, $row, $utf8)

    if ($status -ne 'ADDED') {
        Write-Output ('ERROR: the copy at ' + $rel + ' differs from the source (sha256 ' + $dstHash + ' vs ' + $srcHash + '). The agent must not delete it. Tell the user.')
        exit 2
    }
    Write-Output ('ADDED: ' + $rel + ' | ' + $srcItem.Length + ' bytes | sha256 ' + $dstHash)
    exit 0
}
catch {
    Write-Output ('ERROR: ' + $_.Exception.Message)
    exit 2
}
