<#
setup/lib/releases.ps1 - the one place that knows how a GitHub release names its files.

install.ps1 dot-sources it before the platform module; the platform modules call it when a
program has no package at all (trufflehog on Linux and Windows, uv on Linux). Both shapes below
were measured on 2026-10-14 against the releases of that day, because a name written down by
hand goes stale silently:

  * The asset name CARRIES the version: trufflehog_3.99.2_linux_amd64.tar.gz. The value in
    linux/packages.yaml is therefore the END of the name ("linux_amd64.tar.gz"), not the whole
    name. The old exact comparison found nothing in that release and the program stayed
    missing - the first full-setup CI run reported "trufflehog: linux_amd64.tar.gz is not part
    of release v3.99.2" and the live verify then failed on "not in PATH: uv, trufflehog".
  * The checksums come in two shapes: trufflehog publishes ONE file with a line per asset
    (trufflehog_3.99.2_checksums.txt), uv publishes <asset>.sha256 next to each asset. A
    release with neither is NOT installed: an unverified download is not an installation.
  * An archive may carry its own top-level folder (uv: uv-x86_64-unknown-linux-gnu/uv). The
    `strip_components` field of a release entry says how many leading path parts to drop; a
    release without it unpacks as it is (trufflehog puts its binary at the top level).

The pure functions here (asset, checksum asset, checksum line, the text of a response) are
tested in tests/Releases.Tests.ps1 without any network access.

ASCII-only on purpose (Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page).
#>

function Get-GitHubApiHeaders {
    # Headers for api.github.com. Measured 2026-10-14 in the third full-setup run: the Windows
    # runner answered "403 (rate limit exceeded)". Unauthenticated calls are limited per IP, and
    # a CI runner shares its address with everyone else on that machine pool - the same limit
    # hits a person behind a NAT. A token raises it, so one is used when the environment carries
    # it (GH_TOKEN, or GITHUB_TOKEN as CI names it); without one the call stays unauthenticated,
    # exactly as before. The token VALUE never reaches a report - only header names are ever
    # printed, and nothing here writes the headers anywhere.
    [CmdletBinding()]
    param()
    $headers = @{ 'User-Agent' = 'personal-os-setup' }
    foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN')) {
        $token = [Environment]::GetEnvironmentVariable($name)
        if ($token) { $headers['Authorization'] = 'Bearer ' + $token; break }
    }
    return $headers
}

function Convert-ReleaseText {
    # The text of an HTTP response, whatever shape it arrives in. Measured 2026-10-14 on
    # ubuntu-latest: Invoke-WebRequest hands back a BYTE ARRAY when the server does not type the
    # answer as text (GitHub serves a checksum file as application/octet-stream), and feeding
    # that into a [string] parameter fails the parameter binding - "Cannot convert value to type
    # System.String" - which ended the whole live install, so the stages after it never ran and
    # the verify only reported the consequences. The bytes are UTF-8 (the files are ASCII), so
    # that is how they are read back.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()]$Content)
    if ($Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($Content) }
    return [string]$Content
}

function Select-ReleaseAsset {
    # The asset whose name ENDS with the given text. Returns $null when the release has none.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Assets,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Suffix
    )
    if (-not $Suffix) { return $null }
    $rx = [regex]::Escape($Suffix) + '$'
    foreach ($a in @($Assets)) {
        if ([string]$a.name -match $rx) { return $a }
    }
    return $null
}

function Get-ReleaseChecksumAsset {
    # Which asset of the release carries the checksums. Measured order: the asset's own
    # "<name>.sha256" first (uv), then a file whose name ends in "checksums.txt" (trufflehog).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Assets,
        [Parameter(Mandatory)][string]$AssetName
    )
    $own = Select-ReleaseAsset -Assets $Assets -Suffix ($AssetName + '.sha256')
    if ($own) { return $own }
    return (Select-ReleaseAsset -Assets $Assets -Suffix 'checksums.txt')
}

function Find-ReleaseChecksum {
    # The expected SHA256 for one asset out of the text of a checksum file, or '' when the text
    # carries none. Three shapes, all measured: a file with nothing but the hash, the usual
    # "<hash>  <name>" lines, and the same with a leading "*" (binary marker) or a path.
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$AssetName
    )
    if (-not $Text) { return '' }
    $bare = [regex]::Match($Text.Trim(), '^[0-9a-fA-F]{64}$')
    if ($bare.Success) { return $bare.Value.ToLowerInvariant() }
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $m = [regex]::Match($line, '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$')
        if (-not $m.Success) { continue }
        $name = $m.Groups[2].Value.Trim()
        if (($name -eq $AssetName) -or $name.EndsWith('/' + $AssetName) -or $name.EndsWith('\' + $AssetName)) {
            return $m.Groups[1].Value.ToLowerInvariant()
        }
    }
    return ''
}
