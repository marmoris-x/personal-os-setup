# cleanup.ps1 - Life OS "script after": everything that must not need a language model.
#
# What it does, in order:
#   1. recordings that were processed (they have a .txt) move from <vault>\inbox\audio
#      to <vault>\inbox\audio\erledigt\ - unless -SkipInbox is set (a failed agent run:
#      nothing may leave the inbox, the next run picks the transcripts up again)
#   2. every path in <vault>\000-meta\trash-queue.txt moves into <vault>\trash\ (the
#      vault's delete protection: never a hard delete), then the list is emptied
#   3. recordings in erledigt\ older than 30 days go to the Windows recycle bin
#      (recoverable), logs older than 14 days are deleted (scratch)
#   4. one line into <vault>\000-meta\life-os-runs.log
#
# The runner holds morning.lock around this script; it takes no lock of its own.
# NOTE: the folder name "erledigt" below is the OWNER's vault folder (inbox\audio\erledigt,
# his word for "done"). It is data, not a name of this repo - do not translate it.

param(
    [string]$VaultPath = '{{VAULT}}',
    [string]$LogDir = '{{DEV}}\Temp\life-os-logs',
    [switch]$SkipInbox,
    [int]$LogRetentionDays = 14,
    [int]$AudioKeepDays = 30
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\life-os-common.ps1"

function Move-WithCollision([string]$source, [string]$targetDir) {
    # Moves one file; on a name collision the target gets a timestamp suffix.
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    $leaf = Split-Path -Leaf $source
    $target = Join-Path $targetDir $leaf
    if (Test-Path -LiteralPath $target) {
        $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
        $ext = [IO.Path]::GetExtension($leaf)
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $target = Join-Path $targetDir ("{0} ({1}){2}" -f $base, $stamp, $ext)
    }
    Move-Item -LiteralPath $source -Destination $target
    return $target
}

$moved = 0; $queued = 0; $recycled = 0; $logsRemoved = 0
$state = 'ok'
try {
    $audioDir = Join-Path $VaultPath 'inbox\audio'
    $erledigt = Join-Path $audioDir 'erledigt'
    $extensions = @('.m4a', '.wav', '.mp3', '.ogg', '.opus', '.flac', '.3gp', '.mp4')

    # 1. inbox -> erledigt (only pairs that were transcribed; audio without .txt stays)
    if (-not $SkipInbox) {
        if (Test-Path -LiteralPath $audioDir) {
            foreach ($txt in (Get-ChildItem -LiteralPath $audioDir -File -Filter '*.txt')) {
                $base = [IO.Path]::GetFileNameWithoutExtension($txt.Name)
                $audio = $null
                foreach ($ext in $extensions) {
                    $candidate = Join-Path $audioDir ($base + $ext)
                    if (Test-Path -LiteralPath $candidate) { $audio = $candidate; break }
                }
                if ($audio) { [void](Move-WithCollision $audio $erledigt); $moved++ }
                [void](Move-WithCollision $txt.FullName $erledigt); $moved++
            }
        }
    } else {
        Write-Host 'inbox step skipped (agent run failed)'
    }

    # 2. trash queue
    $queuePath = Join-Path $VaultPath '000-meta\trash-queue.txt'
    if (Test-Path -LiteralPath $queuePath) {
        $trashDir = Join-Path $VaultPath 'trash'
        $lines = Get-Content -LiteralPath $queuePath -Encoding UTF8
        foreach ($line in $lines) {
            $rel = ([string]$line).Trim()
            if (-not $rel) { continue }
            if ($rel.StartsWith('#') -or $rel.StartsWith('\') -or $rel.Contains(':') -or
                $rel.Split('/') -contains '..' -or $rel.Split('\') -contains '..') {
                Write-Host ('trash-queue: refused unsafe path: ' + $rel)
                continue
            }
            $full = Join-Path $VaultPath ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                [void](Move-WithCollision $full $trashDir)
                $queued++
            } else {
                Write-Host ('trash-queue: not found, skipped: ' + $rel)
            }
        }
        Write-Utf8 $queuePath ''
    }

    # 3. old recordings -> recycle bin, old logs -> gone
    if (Test-Path -LiteralPath $erledigt) {
        $limit = (Get-Date).AddDays(-$AudioKeepDays)
        foreach ($f in (Get-ChildItem -LiteralPath $erledigt -File -Recurse)) {
            if ($f.LastWriteTime -lt $limit) { Send-ToRecycleBin $f.FullName; $recycled++ }
        }
    }
    if (Test-Path -LiteralPath $LogDir) {
        $limit = (Get-Date).AddDays(-$LogRetentionDays)
        foreach ($f in (Get-ChildItem -LiteralPath $LogDir -File)) {
            if ($f.LastWriteTime -lt $limit) { Remove-Item -LiteralPath $f.FullName -Force; $logsRemoved++ }
        }
    }

    $detail = 'moved=' + $moved + ' trashed=' + $queued + ' recycled=' + $recycled + ' logs=' + $logsRemoved
    if ($SkipInbox) { $detail = 'skip-inbox ' + $detail }
    Append-Utf8 (Join-Path $VaultPath '000-meta\life-os-runs.log') `
        ((Get-Date).ToString('s') + ' | cleanup | ok | ' + $detail + "`n")
    Write-Host ('cleanup: ' + $detail)
    exit 0
} catch {
    Append-Utf8 (Join-Path $VaultPath '000-meta\life-os-runs.log') `
        ((Get-Date).ToString('s') + ' | cleanup | fail | ' + $_.Exception.Message + "`n")
    Write-Host ('cleanup failed: ' + $_.Exception.Message)
    exit 1
}
