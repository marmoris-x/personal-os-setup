# Claude Code Statusline - original layout, PS5.1 compatible
$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$raw = @($Input) -join "`n"
if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output "ctx: waiting..."; exit 0 }
try { $j = $raw | ConvertFrom-Json } catch { Write-Output "ctx: parse error"; exit 0 }

$homeDir = {{HOME_ENV}}

$PL = [char]0xE0B0       # Powerline separator
$e  = [char]27; $R = "$e[0m"; $D = "$e[2m"

# --- Colors (Catppuccin Mocha, subtle) ---
$cModel  = "$e[38;2;148;226;213m"   # Mint
$cEffMax = "$e[38;2;243;139;168m"   # Red (max effort)
$cEffXhi = "$e[38;2;250;179;135m"   # Orange (xhigh)
$cEffHi  = "$e[38;2;249;226;175m"   # Yellow (high)
$cEffMed = "$e[38;2;166;227;161m"   # Green (medium)
$cEffLow = "$e[38;2;147;153;178m"   # Gray (low)
$cBranch = "$e[38;2;245;194;231m"   # Pink
$cGreen  = "$e[38;2;166;227;161m"
$cRed    = "$e[38;2;243;139;168m"
$cCost   = "$e[38;2;235;160;172m"   # Rose
$cMuted  = "$e[38;2;108;112;134m"   # Muted labels
$cGray   = "$e[38;2;69;71;90m"      # Separator dim
$cCwd    = "$e[38;2;200;165;90m"    # Dark yellow/gold (cwd)

# --- Helpers: usage / rate-limit lookup -----------------------------------
# Claude Code's status JSON only carries rate_limits for some account types;
# for OAuth/Pro sessions it's null, so we fall back to the same
# /api/oauth/usage endpoint Claude Code itself uses, with a short file cache.
function ConvertFrom-UsageApiResponse {
    param($resp)
    [PSCustomObject]@{
        five_hour = if ($resp.five_hour) {
            [PSCustomObject]@{
                used_percentage = $resp.five_hour.utilization
                resets_at       = if ($resp.five_hour.resets_at) { [DateTime]$resp.five_hour.resets_at } else { $null }
            }
        } else { $null }
        seven_day = if ($resp.seven_day) {
            [PSCustomObject]@{
                used_percentage = $resp.seven_day.utilization
                resets_at       = if ($resp.seven_day.resets_at) { [DateTime]$resp.seven_day.resets_at } else { $null }
            }
        } else { $null }
    }
}

function Get-UsageData {
    param($data)

    $cacheFile = "$homeDir\.claude\statusline-usage-cache.json"
    $lockFile  = "$homeDir\.claude\statusline-usage-cache.lock"
    $now = Get-Date

    # 1. stdin rate_limits (cheap, used if Claude Code ever populates it)
    $rl = $data.rate_limits
    if ($rl -and (($rl.five_hour -and $null -ne $rl.five_hour.resets_at) -or ($rl.seven_day -and $null -ne $rl.seven_day.resets_at))) {
        return [PSCustomObject]@{
            five_hour = if ($rl.five_hour) {
                [PSCustomObject]@{
                    used_percentage = $rl.five_hour.used_percentage
                    resets_at       = if ($null -ne $rl.five_hour.resets_at) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$rl.five_hour.resets_at).UtcDateTime } else { $null }
                }
            } else { $null }
            seven_day = if ($rl.seven_day) {
                [PSCustomObject]@{
                    used_percentage = $rl.seven_day.used_percentage
                    resets_at       = if ($null -ne $rl.seven_day.resets_at) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$rl.seven_day.resets_at).UtcDateTime } else { $null }
                }
            } else { $null }
        }
    }

    # 2. fresh cache (<3 min old)?
    if (Test-Path $cacheFile) {
        $age = ($now - (Get-Item $cacheFile).LastWriteTime).TotalSeconds
        if ($age -lt 180) {
            try { return ConvertFrom-UsageApiResponse (Get-Content $cacheFile -Raw | ConvertFrom-Json) } catch {}
        }
    }

    # 3. fetch from the usage API, unless another invocation is already doing so
    $lockFresh = $false
    if (Test-Path $lockFile) {
        $lockAge = ($now - (Get-Item $lockFile).LastWriteTime).TotalSeconds
        if ($lockAge -lt 10) { $lockFresh = $true }
    }

    if (-not $lockFresh) {
        try {
            New-Item -Path $lockFile -ItemType File -Force | Out-Null
            $credPath = "$homeDir\.claude\.credentials.json"
            $token = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
            if ($token) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $headers = @{ "Authorization" = "Bearer $token"; "anthropic-beta" = "oauth-2025-04-20" }
                $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -TimeoutSec 5 -Method Get
                if ($resp) {
                    $resp | ConvertTo-Json -Depth 5 | Set-Content -Path $cacheFile -Encoding UTF8
                    return ConvertFrom-UsageApiResponse $resp
                }
            }
        } catch {}
    }

    # 4. stale cache as last resort
    if (Test-Path $cacheFile) {
        try { return ConvertFrom-UsageApiResponse (Get-Content $cacheFile -Raw | ConvertFrom-Json) } catch {}
    }

    return $null
}

function Format-ResetCountdown {
    param($resetTime)
    if (-not $resetTime) { return "-" }
    $diff = $resetTime.ToUniversalTime() - [DateTime]::UtcNow
    $totalMin = [math]::Max(0, [math]::Floor($diff.TotalMinutes))
    if ($totalMin -ge 1440) {
        return "$([math]::Floor($totalMin / 1440))d $([math]::Floor(($totalMin % 1440) / 60))h"
    } elseif ($totalMin -ge 60) {
        return "$([math]::Floor($totalMin / 60))hr $($totalMin % 60)m"
    } else {
        return "${totalMin}m"
    }
}

function Format-UsagePct {
    param($pct)
    if ($null -eq $pct) { return "0.0%" }
    return ([math]::Round([double]$pct, 1).ToString("F1", [CultureInfo]::InvariantCulture)) + "%"
}

# --- Data extraction --------------------------------------------------------

# Model: the field can be a plain string OR { id, display_name }
$model = if ($j.model -is [string]) { $j.model }
         elseif ($j.model.display_name) { $j.model.display_name }
         elseif ($j.model.id) { $j.model.id }
         else { "?" }

# Effort: not part of the status JSON - read from settings.json, then env, then "?"
$eff = $null
if ($j.effort.level) { $eff = "$($j.effort.level)" }
if (-not $eff) {
    try {
        $cfg = Get-Content "$homeDir\.claude\settings.json" -Raw | ConvertFrom-Json
        if ($cfg.effortLevel) { $eff = "$($cfg.effortLevel)" }
    } catch {}
}
if (-not $eff -and $env:CLAUDE_CODE_EFFORT_LEVEL) { $eff = $env:CLAUDE_CODE_EFFORT_LEVEL }
if (-not $eff) { $eff = "?" } else { $eff = $eff.ToLower() }

$effCol = $cMuted
if    ($eff -eq "max")    { $effCol = $cEffMax }
elseif($eff -eq "xhigh")  { $effCol = $cEffXhi }
elseif($eff -eq "high")   { $effCol = $cEffHi }
elseif($eff -eq "medium") { $effCol = $cEffMed }
elseif($eff -eq "low")    { $effCol = $cEffLow }

# --no-optional-locks: a read command skips git's optional index lock, so the status line
# cannot collide with Obsidian Git's auto-commit (git docs, GIT_OPTIONAL_LOCKS).
$branch = try { git --no-optional-locks -C $j.cwd branch --show-current 2>$null } catch { $null }
if (-not $branch) { $branch = "?" }

$added   = if ($null -ne $j.cost.total_lines_added)   { $j.cost.total_lines_added }   else { 0 }
$removed = if ($null -ne $j.cost.total_lines_removed) { $j.cost.total_lines_removed } else { 0 }

$costVal = if ($null -ne $j.cost.total_cost_usd) { $j.cost.total_cost_usd } else { 0 }
$costStr  = if ($costVal -gt 0) { [math]::Round($costVal, 2).ToString("F2", [CultureInfo]::InvariantCulture) } else { "0.00" }

$tokVal  = if ($j.context_window.total_input_tokens) { $j.context_window.total_input_tokens } else { 0 }
$tokStr  = if ($tokVal -ge 1000) { ([math]::Round($tokVal/1000, 1).ToString("F1", [CultureInfo]::InvariantCulture)) + "k" } else { "$tokVal" }

$pctVal  = if ($null -ne $j.context_window.used_percentage) { $j.context_window.used_percentage } else { 0 }
# A short field, as the owner asked: "ctx 42%", not a decimal.
$pctStr  = ([math]::Round($pctVal, 0).ToString("F0", [CultureInfo]::InvariantCulture)) + "%"
# Colour it: normal below 40%, yellow from 40%, red from 60%. The 40/60 guideline is a rule
# of thumb quoted by Dex Horthy in the best-practice repo, not a measured limit; the real
# lever is clearing at task boundaries. Early in a session the field is null: show nothing.
$ctxCol  = $R
if ($null -ne $j.context_window.used_percentage) {
    if ($pctVal -ge 60) { $ctxCol = $cRed }
    elseif ($pctVal -ge 40) { $ctxCol = $cEffHi }
}
$ctxPart = ""
if ($null -ne $j.context_window.used_percentage) { $ctxPart = "  $ctxCol" + "ctx $pctStr" + $R }

# Skill: was tracked by a PreToolUse hook that wrote skill-log.jsonl (keyed by
# session_id). That hook no longer exists, so this field stays empty.
$skill = "none"
try {
    $skillLogPath = "$homeDir\.claude\skill-log.jsonl"
    if ($j.session_id -and (Test-Path $skillLogPath)) {
        $lines = @(Get-Content -Path $skillLogPath -Tail 50)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $entry = $null
            try { $entry = $lines[$i] | ConvertFrom-Json } catch {}
            if ($entry -and $entry.session_id -eq $j.session_id -and $entry.skill) {
                $skill = $entry.skill
                break
            }
        }
    }
} catch {}

$durMs  = if ($null -ne $j.cost.total_duration_ms) { $j.cost.total_duration_ms } else { 0 }
$durMin = [math]::Floor($durMs / 60000)
$durStr = if ($durMin -ge 60) { ([math]::Floor($durMin/60)).ToString() + "h " + ($durMin%60).ToString() + "m" } else { "${durMin}m" }

# Reset: 5h session window (primary), 7d weekly window as fallback
$usage = $null
try { $usage = Get-UsageData -data $j } catch {}

$resetSrc = $null
if ($usage -and $usage.five_hour -and $usage.five_hour.resets_at) { $resetSrc = $usage.five_hour }
elseif ($usage -and $usage.seven_day -and $usage.seven_day.resets_at) { $resetSrc = $usage.seven_day }

$resetStr = "-"; $resetPct = "0.0%"
if ($resetSrc) {
    $resetStr = Format-ResetCountdown $resetSrc.resets_at
    $resetPct = Format-UsagePct $resetSrc.used_percentage
}

$cwdStr = if ($j.cwd) { $j.cwd } else { "?" }
$maxLen = 36
if ($cwdStr.Length -gt $maxLen) {
    $cwdStr = "..." + $cwdStr.Substring($cwdStr.Length - ($maxLen - 3))
}

# --- Build rows with subtle Powerline separators ---
# Separator: dim gray PL char, then space
$s = " $cGray$PL$R "

$row1 = "$cModel$model$R$s$effCol$eff$R$s$cBranch$branch$R ($cGreen+$added$R,$cRed-$removed$R)"
$row2 = " $cCost`$$costStr$R$s$tokStr$ctxPart$s$D Skill: $skill$R"
$row3 = " Session: $durStr$s$D Reset: $resetStr  $resetPct$R"
$row4 = " $cCwd$cwdStr$R"

Write-Output "$row1`n$row2`n$row3`n$row4"
exit 0
