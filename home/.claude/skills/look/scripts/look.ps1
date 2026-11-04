# look.ps1 - one picture or video, one question, to the Portkey quick pool.
#
#   pwsh look.ps1 -Path <file> [-Ask "<question>"] [-Resolution high|ultra_high]
#
# Exits: 0 ok, 2 bad input, 3 refused path, 4 request over 18 MB after base64,
#        5 missing environment variable, 6 HTTP/timeout error, 7 another model answered.
#
# One OpenAI-compatible chat completion through a Portkey config (x-portkey-config). The
# media part comes first, the question second. The key is read from the environment and is
# never printed, written or logged.
#
# -Endpoint and -TimeoutSec are for the tests; the live call uses the Portkey endpoint and
# the 120 s client limit.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Ask = 'Describe exactly what you see: every object, every text verbatim, colours, layout. Say what you cannot read.',
    [ValidateSet('high', 'ultra_high')][string]$Resolution = 'high',
    [string]$Endpoint = 'https://api.portkey.ai/v1/chat/completions',
    [ValidateRange(1, 600)][int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'

$Model = 'gemini-3.5-flash-lite'
$MaxBase64Bytes = 18 * 1024 * 1024

# ---------------------------------------------------------------- refusals
# One line each. Checked on the full resolved path before anything is read (exit 3).
$RefusedRoots = @(
    @{ Reason = '.claude'; Path = (Join-Path $HOME '.claude') }
    @{ Reason = '.ssh'; Path = (Join-Path $HOME '.ssh') }
    @{ Reason = '.codex'; Path = (Join-Path $HOME '.codex') }
    @{ Reason = 'Downloads Compressed'; Path = (Join-Path $HOME 'Downloads\Compressed') }
    @{ Reason = 'Downloads Documents'; Path = (Join-Path $HOME 'Downloads\Documents') }
    @{ Reason = 'Downloads Images'; Path = (Join-Path $HOME 'Downloads\Images') }
    @{ Reason = 'Downloads Music'; Path = (Join-Path $HOME 'Downloads\Music') }
    @{ Reason = 'Downloads Programs'; Path = (Join-Path $HOME 'Downloads\Programs') }
    @{ Reason = 'Downloads Videos'; Path = (Join-Path $HOME 'Downloads\Videos') }
)
$RefusedSegments = @('600-archive')
$RefusedWords = @('ausweis', 'pass', 'svnr', 'versicherung', 'bank', 'konto', 'iban', 'befund', 'arzt', 'bescheid')
$AllowedExtensions = @('.png', '.jpg', '.jpeg', '.webp', '.mp4')

# The cloud folder (OneDrive) comes from its Windows known-folder id, never from a path text
# in this script: the local personal setup must not carry the folder location.
function Get-CloudRoot {
    if (-not ('LookKnownFolder' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LookKnownFolder {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHGetKnownFolderPath(ref Guid rfid, uint dwFlags, IntPtr hToken, out IntPtr ppszPath);
}
'@
    }
    $guid = [guid]'A52BBA46-E9E1-435F-B3D9-28DAA648C0F6'
    $p = [IntPtr]::Zero
    try { $hr = [LookKnownFolder]::SHGetKnownFolderPath([ref]$guid, 0, [IntPtr]::Zero, [ref]$p) } catch { return '' }
    if ($hr -ne 0 -or $p -eq [IntPtr]::Zero) { return '' }
    try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($p) }
    finally { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($p) }
}

# The path Windows really opens: junctions, symlinks, 8.3 short names and trailing dots are
# resolved through the file handle, so the refusal check cannot be walked around with a link
# or a short name. CreateFileW asks for attributes only; no file content is read for this.
if (-not ('LookNativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LookNativePath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetFinalPathNameByHandleW(IntPtr hFile, StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@
}

function Get-FinalPathOfExisting([string]$ExistingPath) {
    $h = [LookNativePath]::CreateFileW($ExistingPath, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero -or $h.ToInt64() -eq -1) { return '' }
    try {
        $sb = [Text.StringBuilder]::new(32768)
        $n = [LookNativePath]::GetFinalPathNameByHandleW($h, $sb, [uint32]$sb.Capacity, 0)
        if ($n -eq 0 -or $n -ge $sb.Capacity) { return '' }
        $p = $sb.ToString()
        if ($p.StartsWith('\\?\UNC\')) { return '\\' + $p.Substring(8) }
        if ($p.StartsWith('\\?\')) { return $p.Substring(4) }
        return $p
    }
    finally { [void][LookNativePath]::CloseHandle($h) }
}

function Get-RealPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\UNC\')) { $full = '\\' + $full.Substring(8) }
    elseif ($full.StartsWith('\\?\')) { $full = $full.Substring(4) }
    $tail = [System.Collections.Generic.List[string]]::new()
    $probe = $full
    while (-not (Test-Path -LiteralPath $probe)) {
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $probe) { return $full }
        $tail.Insert(0, (Split-Path -Leaf $probe))
        $probe = $parent
    }
    # Windows ignores a trailing dot or space in a name; the handle wants the real name.
    $probe = (($probe -split '\\') | ForEach-Object { $_.TrimEnd('.', ' ') }) -join '\'
    $real = Get-FinalPathOfExisting $probe
    if ([string]::IsNullOrEmpty($real)) { return $full }
    foreach ($part in $tail) { $real = Join-Path $real $part }
    return $real
}

function Test-UnderRoot([string]$FullPath, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    $r = $Root.TrimEnd('\', '/')
    if ($FullPath.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $sep = [IO.Path]::DirectorySeparatorChar
    return $FullPath.StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)
}

function Write-Fail([string]$Message, [int]$Code) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

# ---------------------------------------------------------------- the path
$lexical = [IO.Path]::GetFullPath($Path)
if ($lexical.StartsWith('\\?\UNC\')) { $lexical = '\\' + $lexical.Substring(8) }
elseif ($lexical.StartsWith('\\?\')) { $lexical = $lexical.Substring(4) }
$full = Get-RealPath $lexical
$pathChecks = @($lexical, $full) | Select-Object -Unique

$roots = @($RefusedRoots)
$cloud = Get-CloudRoot
if ($cloud) { $roots += @{ Reason = 'OneDrive'; Path = $cloud } }
foreach ($candidate in $pathChecks) {
    foreach ($r in $roots) {
        if (Test-UnderRoot $candidate ([string]$r.Path)) {
            Write-Fail ("Pfad verweigert ($($r.Reason)): $candidate") 3
        }
    }
}

foreach ($candidate in $pathChecks) {
    $segments = @($candidate -split '[\\/]' | Where-Object { $_ -ne '' -and $_ -notmatch '^[A-Za-z]:$' })
    foreach ($seg in $segments) {
        foreach ($s in $RefusedSegments) {
            if ($seg.Equals($s, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Fail ("Pfad verweigert (Ordner $s): $candidate") 3
            }
        }
        foreach ($w in $RefusedWords) {
            if ($seg.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Write-Fail ("Pfad verweigert (Name enthaelt '$w'): $candidate") 3
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    Write-Fail ("Datei nicht gefunden oder keine Datei: $full") 2
}
$ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
if ($AllowedExtensions -notcontains $ext) {
    Write-Fail ("Dateityp nicht erlaubt: $ext. Erlaubt: .png .jpg .jpeg .webp .mp4") 2
}

# ---------------------------------------------------------------- the request
# Length first: a huge video is refused before it is loaded into memory.
$length = (Get-Item -LiteralPath $full).Length
$estimated = 4 * [Math]::Ceiling($length / 3.0)
if ($estimated -gt $MaxBase64Bytes) {
    $mb = ([Math]::Round($estimated / 1MB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture)
    Write-Fail ("Anfrage zu gross: $mb MB nach Base64, Grenze 18 MB. Die Datei wird nicht verkleinert.") 4
}
try { $bytes = [IO.File]::ReadAllBytes($full) }
catch { Write-Fail ("Datei nicht lesbar: $($_.Exception.Message)") 4 }
$b64 = [Convert]::ToBase64String($bytes)
if ($b64.Length -gt $MaxBase64Bytes) {
    $mb = ([Math]::Round($b64.Length / 1MB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture)
    Write-Fail ("Anfrage zu gross: $mb MB nach Base64, Grenze 18 MB. Die Datei wird nicht verkleinert.") 4
}

$key = $env:PORTKEY_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Fail ("PORTKEY_API_KEY fehlt. Setze ihn mit $HOME\.claude\setup\powershell\set-research-keys.ps1 und starte das Terminal neu.") 5
}
$config = $env:PORTKEY_CONFIG_QUICK
if ([string]::IsNullOrWhiteSpace($config)) {
    Write-Fail ("PORTKEY_CONFIG_QUICK fehlt. Setze ihn mit $HOME\.claude\setup\powershell\set-research-keys.ps1 und starte das Terminal neu.") 5
}

$mediaType = switch ($ext) {
    '.png' { 'image/png' }
    '.jpg' { 'image/jpeg' }
    '.jpeg' { 'image/jpeg' }
    '.webp' { 'image/webp' }
    '.mp4' { 'video/mp4' }
}
$mediaResolution = 'MEDIA_RESOLUTION_HIGH'
if ($Resolution -eq 'ultra_high') { $mediaResolution = 'MEDIA_RESOLUTION_ULTRA_HIGH' }

$payload = [ordered]@{
    model    = $Model
    messages = @(
        [ordered]@{
            role    = 'user'
            content = @(
                [ordered]@{
                    type        = 'image_url'
                    image_url   = [ordered]@{
                        url              = "data:$mediaType;base64,$b64"
                        media_resolution = $mediaResolution
                    }
                }
                [ordered]@{ type = 'text'; text = $Ask }
            )
        }
    )
    stream   = $false
}
$body = $payload | ConvertTo-Json -Depth 8 -Compress

$trace = [guid]::NewGuid().ToString()
$headers = @{
    'x-portkey-api-key' = $key
    'x-portkey-config'  = $config
    'x-portkey-trace-id' = $trace
}

$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $resp = Invoke-WebRequest -Uri $Endpoint -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
} catch {
    $sw.Stop()
    $msg = $_.Exception.Message
    if ($msg -match '(?i)timed?\s*out|timeout|canceled|cancelled|abort') {
        Write-Fail ("Zeitueberschreitung nach $TimeoutSec s (HTTP 408, trace $trace)") 6
    }
    Write-Fail ("Netzwerkfehler: $msg (trace $trace)") 6
}
$sw.Stop()

$status = [int]$resp.StatusCode
if ($status -eq 408) {
    Write-Fail ("Zeitueberschreitung (HTTP 408, trace $trace)") 6
}
if ($status -lt 200 -or $status -ge 300) {
    Write-Fail ("Portkey-Fehler: HTTP $status (trace $trace)") 6
}

try { $json = $resp.Content | ConvertFrom-Json -Depth 20 }
catch { Write-Fail ("Antwort ist kein JSON (HTTP $status, trace $trace)") 6 }

$respModel = [string]$json.model
if ($respModel -notmatch [regex]::Escape($Model)) {
    Write-Fail ("anderes Modell geantwortet: $respModel") 7
}

$content = $json.choices[0].message.content
if ($content -is [string]) { $answer = $content }
else { $answer = (@($content) | ForEach-Object { [string]$_.text }) -join "`n" }
$answer = ([string]$answer).TrimEnd()
if ([string]::IsNullOrWhiteSpace($answer)) {
    Write-Fail ("Leere Antwort vom Modell (HTTP $status, trace $trace)") 6
}

$target = ''
$tv = $resp.Headers['x-portkey-last-used-option-index']
if ($tv) { $target = [string](@($tv)[0]) }
if ([string]::IsNullOrWhiteSpace($target)) { $target = '-' }
$retries = ''
$rv = $resp.Headers['x-portkey-retry-attempt-count']
if ($rv) { $retries = [string](@($rv)[0]) }
if ([string]::IsNullOrWhiteSpace($retries)) { $retries = '0' }
$seconds = [int][Math]::Round($sw.Elapsed.TotalSeconds)

Write-Output $answer
Write-Output ("model={0} target={1} retries={2} seconds={3} trace={4}" -f $respModel, $target, $retries, $seconds, $trace)
exit 0
