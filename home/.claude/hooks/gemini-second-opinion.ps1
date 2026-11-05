# gemini-second-opinion.ps1 - PostToolUse hook on Read for picture files, DeepSeek profile only.
#
#   Registered in profiles/deepseek.json (template: profiles-template/deepseek.json) on
#   PostToolUse with matcher "Read", timeout 70 s. It is never in the global settings.json:
#   sessions of other profiles must not call Gemini.
#
#   When the Read tool has read a .png/.jpg/.jpeg/.webp file, the hook asks the quick pool
#   through look.ps1 (same script, same refusals) and adds the answer as one additionalContext
#   marked "Gemini (second opinion)". The session stays the judge: Gemini describes, it does
#   not decide (owner's rule, 2026-11-05).
#
#   It cannot block: the Read has already run; every path exits 0 and prints nothing except
#   the one JSON object on success. A refused path (look.ps1 exit 3) is skipped before any
#   network call. The whole child run is capped at 60 s; after that it is stopped silently.
#   The look script gets a 50 s client timeout so it usually ends by itself before the cap.
#
#   The answer is pure ASCII in the JSON (non-ASCII becomes \uXXXX), like the orientation hook.
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [string]$LookPath = '',
    [int]$BudgetSeconds = 60,
    [int]$LookTimeoutSec = 50
)

$ErrorActionPreference = 'SilentlyContinue'

function ConvertTo-AsciiJson($obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 5
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

trap { exit 0 }

# ---------------------------------------------------------------- the tool call
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
try { $call = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }

if ([string]$call.hook_event_name -ne 'PostToolUse') { exit 0 }
if ([string]$call.tool_name -ne 'Read') { exit 0 }
$filePath = [string]$call.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }

$ext = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
if (@('.png', '.jpg', '.jpeg', '.webp') -notcontains $ext) { exit 0 }
if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { exit 0 }

if (-not $LookPath) { $LookPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/look/scripts/look.ps1' }
if (-not (Test-Path -LiteralPath $LookPath -PathType Leaf)) { exit 0 }

# ---------------------------------------------------------------- the second opinion
$context = ''
$outFile = [IO.Path]::GetTempFileName()
$errFile = [IO.Path]::GetTempFileName()
try {
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = Join-Path $PSHOME '{{PWSH_EXE}}' }
    $argList = @('-NoProfile', '-NonInteractive', '-File', ('"' + $LookPath + '"'),
        '-Path', ('"' + $filePath + '"'), '-TimeoutSec', [string]$LookTimeoutSec)
    $p = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if ($p -and $p.WaitForExit($BudgetSeconds * 1000) -and ($p.ExitCode -eq 0)) {
        $lines = @([IO.File]::ReadAllLines($outFile) | Where-Object { $_.Trim().Length -gt 0 })
        if ($lines.Count -ge 2) {
            $last = $lines[$lines.Count - 1]
            if ($last -match '^model=') {
                $answer = (@($lines[0..($lines.Count - 2)]) -join "`n").Trim()
                if ($answer) { $context = 'Gemini (second opinion): ' + $answer }
            }
        }
    }
    elseif ($p -and -not $p.HasExited) {
        try { $p.Kill() } catch { }
    }
}
catch { }
finally {
    try { if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force } } catch { }
    try { if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force } } catch { }
}

if ($context) {
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $context } }
    Write-Output (ConvertTo-AsciiJson $out)
}

exit 0
