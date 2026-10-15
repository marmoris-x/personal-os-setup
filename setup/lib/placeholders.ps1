<#
setup/lib/placeholders.ps1 - the shared placeholder vocabulary (see docs/decisions/0003).

One definition, two directions:
  export.ps1   live value   -> {{PLACEHOLDER}}   (Convert-PathStyle builds the 4 styles)
  install.ps1  {{PLACEHOLDER}} -> live value      (Get-PlaceholderMap + Expand-Placeholders)

The vocabulary is FIXED: only the placeholders produced below are ever touched, so
runtime placeholders of other systems (for example {{N_SOURCES}} of the research skill)
survive both directions untouched.

Two halves (cross-platform task, decisions D2/A6):
  1. the values of THIS machine - paths, names, times. Anything the live system says.
  2. the values of the PLATFORM - which PowerShell host an exec-form hook starts, which
     variable holds the home folder, where the per-user state folder is. They come from
     Get-PlatformPlaceholderMap (setup/lib/platform.ps1) and render to the Windows text on
     Windows, so the mirror round trip (export -> repo -> install) is an identity there.

Load order: manifest.ps1, platform.ps1, then this file - Get-PlaceholderMap asks the
platform for half of its values.

ASCII-only: Windows PowerShell 5.1 reads BOM-less files in the ANSI code page.
#>

function Convert-PathStyle {
    # the four representations a path can have inside files
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('back', 'fwd', 'json', 'bash')][string]$Style
    )
    switch ($Style) {
        'back' { return $Path }
        'fwd'  { return $Path.Replace('\', '/') }
        'json' { return $Path.Replace('\', '\\') }
        'bash' {
            if ($Path -match '^[A-Za-z]:[\\/]') {
                # Substring(2) keeps the drive separator; only the drive letter is lowercased
                return '/' + $Path.Substring(0, 1).ToLowerInvariant() + $Path.Substring(2).Replace('\', '/')
            }
            # Every rooted path without a drive letter is its own bash spelling. Measured
            # 2026-10-14 in the ubuntu CI job: without this branch a root like /home/runner/Dev
            # produced NO bash form, so {{DEV_BASH}} and {{HOME_BASH}} never entered the map and
            # the installed files kept the raw token (verify: "unknown placeholders:
            # {{DEV_BASH}}"). A local test install could not see it - in test mode the roots are
            # Windows paths, so the token existed.
            # Which separator the string carries depends on the host that built it: a test or a
            # check on Windows assembles "/Users/check" + "Dokumentenarchiv" into a backslash
            # path, and Join-Path never asks who is looking. Both spellings mean the same folder,
            # so both get the forward-slash form. A UNC path (\\server\share) lands here too and
            # gets "//server/share", which is what Git Bash calls it.
            # Windows has no shape that changes: its roots are drive paths (first branch), and a
            # live file never contained the forward-slash spelling of a UNC path.
            if ($Path -match '^[\\/]') { return ($Path -replace '\\', '/') }
            return $null
        }
    }
    return $null
}

function Get-PlaceholderMap {
    # placeholder -> rendered value, for install.ps1, verify.ps1 and the tests.
    #   Roots:        hashtable HOME, DOCUMENTS, VAULT, DEV
    #   ConfigValues: hashtable from personal.yaml (user_name, ..., archive_dir_name, ...)
    #   Os:           windows | macos | linux - decides the platform half of the vocabulary
    #                 (setup/lib/platform.ps1, Get-PlatformPlaceholderMap). Without it the
    #                 system this process runs on answers.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Roots,
        [Parameter(Mandatory)][hashtable]$ConfigValues,
        [string]$Os = ''
    )
    $map = [ordered]@{}
    $archiveDir = [string]$ConfigValues['archive_dir_name']
    if ([string]::IsNullOrWhiteSpace($archiveDir)) { throw 'personal.yaml is missing archive_dir_name' }
    # the archive folder sits BESIDE the documents folder (same synced parent), never inside it
    $archiveRoot = Join-Path (Split-Path $Roots['DOCUMENTS'] -Parent) $archiveDir
    $allRoots = @{ ARCHIVE = $archiveRoot }
    foreach ($k in $Roots.Keys) { $allRoots[$k] = $Roots[$k] }
    foreach ($style in @('back', 'fwd', 'json', 'bash')) {
        foreach ($name in @('ARCHIVE', 'DOCUMENTS', 'VAULT', 'DEV', 'HOME')) {
            $val = [string]$allRoots[$name]
            if ([string]::IsNullOrWhiteSpace($val)) { continue }
            $rendered = Convert-PathStyle $val $style
            if ($null -eq $rendered) { continue }
            $ph = if ($style -eq 'back') { '{{' + $name + '}}' } else { '{{' + $name + '_' + $style.ToUpperInvariant() + '}}' }
            $map[$ph] = $rendered
        }
    }
    $given = [string]$ConfigValues['user_given']
    $family = [string]$ConfigValues['user_family']
    if ($ConfigValues['user_name']) { $map['{{USER_NAME}}'] = [string]$ConfigValues['user_name'] }
    if ($given) { $map['{{USER_GIVEN}}'] = $given }
    if ($family) {
        $map['{{USER_FAMILY}}'] = $family
        $map['{{USER_FAMILY_UPPER}}'] = $family.ToUpperInvariant()
    }
    $varPairs = @(
        @('github_account', '{{GITHUB_ACCOUNT}}'),
        @('b2_bucket', '{{B2_BUCKET}}'),
        @('morning_time', '{{MORNING_TIME}}'),
        @('backup_time', '{{BACKUP_TIME}}')
    )
    foreach ($pair in $varPairs) {
        if ($ConfigValues[$pair[0]]) { $map[$pair[1]] = [string]$ConfigValues[$pair[0]] }
    }
    # The two schedulers that are not the Windows one want the hour and the minute as numbers
    # (launchd's StartCalendarInterval) and the platform half of the vocabulary answers the
    # "which PowerShell host, which home variable, which temp folder" questions.
    $morning = if ($ConfigValues['morning_time']) { [string]$ConfigValues['morning_time'] } else { '07:00' }
    $mm = [regex]::Match($morning, '^\s*(\d{1,2}):(\d{2})')
    if ($mm.Success) {
        $map['{{MORNING_HOUR}}'] = ([int]$mm.Groups[1].Value).ToString()
        $map['{{MORNING_MINUTE}}'] = ([int]$mm.Groups[2].Value).ToString()
    }
    if (-not $Os) { $Os = Get-PlatformId }
    foreach ($kv in (Get-PlatformPlaceholderMap -Os $Os).GetEnumerator()) { $map[$kv.Key] = $kv.Value }
    return $map
}

function Expand-Placeholders {
    # replaces exactly the tokens of the map; unknown {{...}} tokens stay (verify reports them)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Map
    )
    $out = $Text
    $keys = @($Map.Keys) | Sort-Object -Property Length -Descending
    foreach ($ph in $keys) {
        $out = $out.Replace($ph, [string]$Map[$ph])
    }
    return $out
}
