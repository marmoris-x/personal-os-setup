# life-os-common.ps1 - shared helpers for the Life OS scripts. Dot-source, do not run.
# ASCII only (Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page).

function Write-Utf8([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Append-Utf8([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::AppendAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Get-LifeOsLogPath([string]$logDir, [string]$name) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    return (Join-Path $logDir ("{0}-{1}.log" -f $name, $stamp))
}

function Acquire-LifeOsLock([string]$path, [int]$staleMinutes = 90) {
    # Take the lock atomically (CreateNew). A lock whose process is gone or that is older
    # than $staleMinutes is stale and gets replaced. Returns $true when the lock is ours.
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew,
                                         [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $sw = New-Object System.IO.StreamWriter($fs, (New-Object Text.UTF8Encoding($false)))
            $sw.Write((Get-Date).ToString('s') + ' pid=' + $PID)
            $sw.Close(); $fs.Close()
            return $true
        } catch [System.IO.IOException] {
            $owner = ''
            $age = [int]::MaxValue
            try {
                $owner = [IO.File]::ReadAllText($path)
                $age = ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalMinutes
            } catch { }
            $pidMatch = [regex]::Match($owner, 'pid=(\d+)')
            $alive = $false
            if ($pidMatch.Success) {
                $alive = [bool](Get-Process -Id ([int]$pidMatch.Groups[1].Value) -ErrorAction SilentlyContinue)
            }
            if ($alive -and $age -lt $staleMinutes) { return $false }
            Write-Host ("stale lock taken over (age " + [int]$age + " min, owner: " + $owner + ")")
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    return $false
}

function Release-LifeOsLock([string]$path) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Send-ToRecycleBin([string]$path) {
    # Recoverable "delete" (the vault's delete protection): the Windows recycle bin,
    # no dialog. Used for audio older than 30 days.
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}
