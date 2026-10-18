# test-fetch-guard.ps1 - prove that the fetch guard blocks what it should.
#
#   powershell -NoProfile -File setup/tests/test-fetch-guard.ps1 [-Hook <path>]
#
# The hook is a PreToolUse hook: it reads the tool call as JSON on stdin and answers with
# hookSpecificOutput.permissionDecision = "deny" (or exit 2 for unreadable input). This script
# feeds it one tool call at a time and compares the answer with the expectation, under
# {{PWSH_HOST}} (the engine the registration in settings.json uses). The hook keeps no state.
#
# The missing-file case is the harness's onFailure: "block". That cannot be simulated from
# inside the hook, so the suite checks the wiring in settings.json for every security guard,
# and runs one real headless Claude Code call when POS_FETCH_GUARD_LIVE_TEST=1 is set (the
# acceptance run does that; a normal check prints SKIP with the reason).
#
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less .ps1 in the ANSI code page).

param(
    [string]$Hook = (Join-Path $PSScriptRoot '..\..\hooks\fetch-guard.ps1')
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $Hook)) { Write-Error "hook not found: $Hook"; exit 2 }
$hookPath = (Resolve-Path $Hook).Path

function Invoke-Guard([string]$Tool, [hashtable]$ToolInput, [hashtable]$ExtraEnv = @{}) {
    $payload = (@{ tool_name = $Tool; session_id = 'fgtest'; cwd = '{{VAULT}}'; tool_input = $ToolInput } |
        ConvertTo-Json -Compress -Depth 6)
    $saved = @{}
    foreach ($key in $ExtraEnv.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$ExtraEnv[$key], 'Process')
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = $payload | & {{PWSH_HOST}} -NoProfile -File $hookPath 2>$null
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        foreach ($key in $ExtraEnv.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
    }
    $text = ($output | Out-String)
    $denied = ($code -eq 2) -or ($text -match '"permissionDecision"\s*:\s*"deny"')
    return [pscustomobject]@{ Denied = $denied; Code = $code; Text = $text }
}

$errors = 0
$total = 0
function Judge([string]$Name, [string]$Expect, $Result) {
    $script:total++
    $got = if ($Result.Denied) { 'block' } else { 'allow' }
    $ok = $got -eq $Expect
    if (-not $ok) { $script:errors++ }
    $tag = if ($ok) { 'OK   ' } else { 'FAIL ' }
    Write-Output ("{0} expected {1,-5} | result {2,-5} | {3}" -f $tag, $Expect, $got, $Name)
}

$cases = @(
    # --- built-in and MCP page readers: block ---------------------------------
    @{ E = 'block'; T = 'WebFetch'; I = @{ url = 'https://example.com'; prompt = 'x' } },
    @{ E = 'block'; T = 'mcp__parallel__web_fetch'; I = @{ urls = @('https://example.com'); objective = 'x' } },
    @{ E = 'block'; T = 'mcp__exa__web_fetch_exa'; I = @{ urls = @('https://example.com') } },
    @{ E = 'block'; T = 'mcp__x__page_fetch'; I = @{ url = 'https://example.com' } },
    @{ E = 'block'; T = 'mcp__firecrawl__firecrawl_scrape'; I = @{ url = 'https://example.com' } },
    @{ E = 'block'; T = 'mcp__firecrawl__firecrawl_crawl'; I = @{ url = 'https://example.com' } },
    @{ E = 'block'; T = 'mcp__firecrawl__firecrawl_extract'; I = @{ urls = @('https://example.com') } },
    @{ E = 'block'; T = 'mcp__tavily__tavily_extract'; I = @{ urls = @('https://example.com') } },
    @{ E = 'block'; T = 'mcp__you__you-contents'; I = @{ urls = @('https://example.com') } },
    @{ E = 'block'; T = 'mcp__x__read_url'; I = @{ url = 'https://example.com' } },
    # a server named like the keyword must not hide the tool name (review 2026-10-18)
    @{ E = 'block'; T = 'mcp__fetch__fetch_page'; I = @{ url = 'https://example.com' } },
    @{ E = 'block'; T = 'mcp__fetch__fetch_url'; I = @{ url = 'https://example.com' } },
    @{ E = 'block'; T = 'mcp__crawl__crawl_url'; I = @{ url = 'https://example.com' } },
    # --- search tools and other MCP tools: allow ------------------------------
    @{ E = 'allow'; T = 'mcp__exa__web_search_exa'; I = @{ query = 'x' } },
    @{ E = 'allow'; T = 'mcp__parallel__web_search'; I = @{ search_queries = @('x') } },
    @{ E = 'allow'; T = 'mcp__tavily__tavily_search'; I = @{ query = 'x' } },
    @{ E = 'allow'; T = 'mcp__firecrawl__firecrawl_search'; I = @{ query = 'x' } },
    @{ E = 'allow'; T = 'mcp__context7__resolve-library-id'; I = @{ libraryName = 'x' } },
    # --- shell fetches that print: block --------------------------------------
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'curl https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'curl -s https://example.com/page' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'curl -o - https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'wget -O - https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'wget https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'curl https://example.com | grep -i title' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'Invoke-WebRequest https://x.example' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'iwr https://x.example' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'Invoke-RestMethod https://example.com/data' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'irm https://example.com/data' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'python -c "import requests; print(requests.get(''https://example.com'').text)"' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'node -e "fetch(''https://example.com'').then(r=>r.text()).then(t=>console.log(t))"' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'if (Test-Path C:\x) { curl https://example.com }' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'powershell -NoProfile -Command "curl https://example.com"' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'crwl https://example.com -o markdown' } },
    # --- the 2026-10-18 review's bypasses: block ------------------------------
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = '$u=''https://example.com''; iwr $u' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'u=https://example.com; curl $u' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = ('curl -s ' + [char]92 + "`n" + 'https://example.com') } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = ('iwr ' + [char]96 + "`n" + 'https://example.com') } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'C:\Windows\System32\curl.exe https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = '/usr/bin/curl https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'bash -lc "curl https://example.com"' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'cmd //c "curl https://example.com"' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'uv run python -c "import requests; print(requests.get(''https://example.com'').text)"' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'uv run crwl https://example.com -o markdown' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'node -e "require(''https'').get(''https://example.com'',r=>r.pipe(process.stdout))"' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'python -c "import os; os.system(''curl https://example.com'')"' } },
    # --- shell fetches with a file sink, API hosts, git/gh: allow -------------
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl -o page.html https://example.com' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl -sL https://example.com -o page.html' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl --output page.html https://example.com' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl https://example.com > page.html' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl https://example.com | Out-File page.html' } },
    @{ E = 'allow'; T = 'PowerShell'; I = @{ command = 'Invoke-WebRequest https://x -OutFile f' } },
    @{ E = 'allow'; T = 'PowerShell'; I = @{ command = 'Invoke-WebRequest https://x -OutFile:f' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'wget -O page.html https://example.com' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'wget -qO page.html https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'wget -qO- https://example.com' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'wget -qO - https://example.com' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'python -c "import requests; open(''x.html'',''wb'').write(requests.get(''https://example.com'').content)"' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl https://api.github.com/repos/a/b' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl https://registry.npmjs.org/left-pad' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl https://pypi.org/pypi/requests/json' } },
    @{ E = 'allow'; T = 'PowerShell'; I = @{ command = 'Invoke-RestMethod https://api.github.com/repos/a/b' } },
    @{ E = 'allow'; T = 'PowerShell'; I = @{ command = 'Invoke-RestMethod -Method Post https://google.serper.dev/search -Body (@{ q = "x"; gl = "at"; hl = "de" } | ConvertTo-Json)' } },
    @{ E = 'allow'; T = 'PowerShell'; I = @{ command = 'Invoke-RestMethod "https://api.search.tinyfish.ai?query=x" -Headers @{ "X-API-Key" = $env:TINYFISH_API_KEY }' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'gh api repos/a/b' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'git clone https://github.com/a/b.git' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'npm install left-pad' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'python -I -X utf8 {{HOME}}\.claude\skills\research\scripts\fetch_page.py https://example.com' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'python -I -X utf8 {{HOME}}\.claude\skills\research\scripts\save_pages.py {{DEV}}\Temp\research\x --max-pages 15' } },
    # --- text that merely names the words: allow ------------------------------
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'git commit -m "use curl https://example.com next time"' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'echo "curl https://example.com"' } },
    @{ E = 'allow'; T = 'PowerShell'; I = @{ command = 'Write-Output "Invoke-WebRequest https://x"' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'grep -rn "web_fetch" docs/' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'python -c "print(''curl https://example.com'')"' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'git commit -m "never write POS_ALLOW_DIRECT_FETCH to ~/.bashrc"' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'git commit -m "setx POS_ALLOW_DIRECT_FETCH 1 is forbidden"' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'echo "setx POS_ALLOW_DIRECT_FETCH 1"' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'grep -rn "setx POS_ALLOW_DIRECT_FETCH" .' } },
    # --- the user-only override and its persistent setting --------------------
    @{ E = 'allow'; T = 'WebFetch'; I = @{ url = 'https://example.com'; prompt = 'x' }; Env = @{ POS_ALLOW_DIRECT_FETCH = '1' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'curl https://example.com' }; Env = @{ POS_ALLOW_DIRECT_FETCH = '1' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'setx POS_ALLOW_DIRECT_FETCH 1' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = '[Environment]::SetEnvironmentVariable(''POS_ALLOW_DIRECT_FETCH'',''1'',''User'')' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'reg add HKCU\Environment /v POS_ALLOW_DIRECT_FETCH /d 1' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'Add-Content -Path $PROFILE -Value "`$env:POS_ALLOW_DIRECT_FETCH=''1''"' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'setx /M POS_ALLOW_DIRECT_FETCH 1' } },
    @{ E = 'block'; T = 'Bash'; I = @{ command = 'python -c "open(''/home/user/.bashrc'',''a'').write(''POS_ALLOW_DIRECT_FETCH=1'')"' } },
    @{ E = 'block'; T = 'PowerShell'; I = @{ command = 'setx POS_ALLOW_DIRECT_FETCH 1' }; Env = @{ POS_ALLOW_DIRECT_FETCH = '1' } },
    # --- other tools are not this guard's job ---------------------------------
    @{ E = 'allow'; T = 'Read'; I = @{ file_path = 'C:\x\page.html' } },
    @{ E = 'allow'; T = 'Grep'; I = @{ pattern = 'curl'; path = 'C:\x' } },
    @{ E = 'allow'; T = 'Bash'; I = @{ command = 'echo hello' } }
)

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('fg-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$realProfile = {{HOME_ENV}}
try {
    foreach ($c in $cases) {
        {{HOME_ENV}} = $scratch
        $extra = if ($c.ContainsKey('Env')) { $c.Env } else { @{} }
        $label = if ($c.ContainsKey('I') -and $c.I.command) { $c.T + ': ' + $c.I.command } elseif ($c.ContainsKey('I') -and $c.I.url) { $c.T + ': ' + $c.I.url } else { $c.T }
        if ($label.Length -gt 130) { $label = $label.Substring(0, 130) + '...' }
        Judge $label $c.E (Invoke-Guard $c.T $c.I $extra)
    }
}
finally {
    {{HOME_ENV}} = $realProfile
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# --- unreadable input: block ------------------------------------------------
foreach ($bad in @('', 'not json at all')) {
    $total++
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $bad | & {{PWSH_HOST}} -NoProfile -File $hookPath 2>$null | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    $ok = ($code -eq 2)
    if (-not $ok) { $errors++ }
    Write-Output ("{0} expected block | result {1,-5} | unreadable input: '{2}'" -f $(if ($ok) { 'OK   ' } else { 'FAIL ' }), $(if ($code -eq 2) { 'block' } else { 'allow' }), $bad)
}

# --- the deny reason is the documented one ----------------------------------
$total++
$result = Invoke-Guard 'WebFetch' @{ url = 'https://example.com'; prompt = 'x' }
$ok = $result.Denied -and ($result.Text -match 'fetch_page\.py') -and ($result.Text -match 'Crawl4AI first')
if (-not $ok) { $errors++ }
Write-Output ("{0} expected block | result {1,-5} | deny reason names fetch_page.py and Crawl4AI" -f $(if ($ok) { 'OK   ' } else { 'FAIL ' }), $(if ($result.Denied) { 'block' } else { 'allow' }))

# --- fail-closed wiring in settings.json ------------------------------------
# A missing or hanging hook can only block when its entry carries onFailure: "block" and a
# timeout. This checks every security guard, not only the fetch guard.
$settingsPath = Join-Path $PSScriptRoot '..\..\settings.json'
$security = @('block-dangerous', 'archive-guard', 'onedrive-guard', 'downloads-guard',
              'trifecta-guard', 'no-license-files', 'fetch-guard')
$total++
$wiringErrors = 0
if (-not (Test-Path -LiteralPath $settingsPath)) {
    $wiringErrors++
    Write-Output 'FAIL  settings.json not found next to the rendered hook tree'
}
else {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    foreach ($name in $security) {
        $hit = $null
        foreach ($entry in @($settings.hooks.PreToolUse)) {
            # NOT "$hook": the parameter above is "$Hook", and PowerShell variables are
            # case-insensitive - a loop variable named $hook is the [string] parameter and
            # coerces every hook object to a string, so $hookDef.args is always empty.
            foreach ($hookDef in @($entry.hooks)) {
                $argsText = (@($hookDef.args) -join ' ')
                if ($argsText -match [regex]::Escape($name + '.ps1')) { $hit = $hookDef }
            }
        }
        if (-not $hit) { $wiringErrors++; Write-Output "FAIL  $name is not registered in settings.json"; continue }
        if ("$($hit.onFailure)" -ne 'block') { $wiringErrors++; Write-Output "FAIL  $name has no onFailure: block" }
        if (-not ($hit.timeout -gt 0)) { $wiringErrors++; Write-Output "FAIL  $name has no timeout" }
        # {{PWSH_HOST}} -File <missing> exits with 0xFFFD0000, whose low byte is 0: Claude Code
        # records exit 0 and onFailure never fires. The Test-Path wrapper makes it exit 1.
        if ((@($hit.args) -join ' ') -notmatch 'Test-Path') { $wiringErrors++; Write-Output "FAIL  $name is registered with -File only (a missing file exits 0 through {{PWSH_HOST}})" }
    }
    # the fetch guard's matcher must be specific, not "*"
    $fetchEntry = $null
    foreach ($entry in @($settings.hooks.PreToolUse)) {
        foreach ($hookDef in @($entry.hooks)) {
            if ((@($hookDef.args) -join ' ') -match 'fetch-guard\.ps1') { $fetchEntry = $entry }
        }
    }
    if (-not $fetchEntry) { $wiringErrors++ }
    elseif ($fetchEntry.matcher -eq '*') { $wiringErrors++; Write-Output 'FAIL  fetch-guard matcher is *' }
    elseif ($fetchEntry.matcher -notmatch 'WebFetch' -or $fetchEntry.matcher -notmatch 'mcp__' -or
            $fetchEntry.matcher -notmatch 'Bash' -or $fetchEntry.matcher -notmatch 'PowerShell') {
        $wiringErrors++; Write-Output ('FAIL  fetch-guard matcher is too narrow: ' + $fetchEntry.matcher)
    }
}
if ($wiringErrors -eq 0) { Write-Output 'OK    expected block | result block | every security guard is fail-closed (onFailure block + timeout), fetch matcher specific' }
else { $errors += $wiringErrors }
$total += $wiringErrors

# --- the live missing-file case (acceptance only) ---------------------------
if ($env:POS_FETCH_GUARD_LIVE_TEST -ne '1') {
    Write-Output 'SKIP  live onFailure test: set POS_FETCH_GUARD_LIVE_TEST=1 in the acceptance run (a headless Claude Code call is needed)'
}
else {
    $total++
    # Rename the LIVE guard, let a fresh headless session run an ALLOWED Bash command, restore
    # it. WebFetch would not prove onFailure: permissions.deny blocks it even when the hook is
    # missing, so the two causes could not be told apart (review 2026-10-18). An echo passes
    # the guard when the file is there and must be blocked by onFailure when it is gone.
    $live = Join-Path {{HOME_ENV}} '.claude/hooks/fetch-guard.ps1'
    $aside = $live + '.disabled'
    $restored = $false
    try {
        if (-not (Test-Path -LiteralPath $live)) { throw "live guard not found: $live" }
        Move-Item -LiteralPath $live -Destination $aside -Force
        $output = & claude -p 'Run exactly this Bash command and report its output: echo fetch-guard-live-test. Use only the Bash tool.' --output-format text --max-turns 2 2>&1 | Out-String
        $blocked = ($output -match 'hook|blocked|denied|fetch-guard|onFailure') -and ($output -notmatch 'fetch-guard-live-test')
        Move-Item -LiteralPath $aside -Destination $live -Force
        $restored = $true
        if ($blocked) { Write-Output 'OK    expected block | result block | missing fetch-guard.ps1 blocked an allowed Bash call (onFailure)' }
        else { $errors++; Write-Output ('FAIL  expected block | result allow | missing fetch-guard.ps1: ' + $output.Substring(0, [Math]::Min(200, $output.Length))) }
    }
    catch {
        $errors++
        Write-Output ('FAIL  expected block | result error | live onFailure test: ' + $_.Exception.Message)
    }
    finally {
        if (-not $restored -and (Test-Path -LiteralPath $aside)) {
            Move-Item -LiteralPath $aside -Destination $live -Force
        }
    }
}

Write-Output ''
Write-Output ("{0} of {1} cases as expected, {2} errors" -f ($total - $errors), $total, $errors)
if ($errors -gt 0) { exit 1 } else { exit 0 }
