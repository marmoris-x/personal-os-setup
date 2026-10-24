# fetch-guard.ps1  --  Version 1 (2026-10-18)
#
# PreToolUse hook for WebFetch, the MCP page-reading tools, Bash and PowerShell.
# One rule: the full text of a web page is fetched by fetch_page.py and saved as a file, never
# loaded into the context in one piece.
#
#   DENIED: the built-in WebFetch; every mcp__<server>__<tool> whose TOOL name contains
#           fetch, scrape, extract, crawl, contents or read_url (a pattern, not a fixed list,
#           so a future provider is caught too); shell fetches that print a page: curl, wget,
#           Invoke-WebRequest/iwr, Invoke-RestMethod/irm and python -c / node -e one-liners
#           that request an http(s) URL and print the answer, and crwl.
#   ALLOWED: search tools (web_search_*, tavily_search, firecrawl_search, you-search,
#           Context7), gh, git, package managers, the research scripts themselves, a fetch
#           that writes to a file (-o, -O, --output, -OutFile, > file, Out-File, Set-Content),
#           and JSON calls to API hosts (api.*, *.api.*, api.github.com, registry.npmjs.org,
#           pypi.org/pypi/*/json).
#
#   ONLINE IMAGE SERVICES (2026-10-24): URLs of picture-making services (pollinations.ai and the
#   like, see $script:ImageHosts), image endpoints such as /v1/images/generations, and MCP tools
#   that generate images are denied for every sink and also under the override below. Pictures
#   are made only by the /image skill (local ComfyUI).
#
#   THE USER-ONLY OVERRIDE: if POS_ALLOW_DIRECT_FETCH=1 is set in the Claude Code process
#   environment, the guard allows and appends one line to state/fetch-guard.log. A command
#   that would set the variable persistently (setx, [Environment]::SetEnvironmentVariable,
#   reg add ...\Environment, a write into a profile or an environment file) is always denied,
#   even while the override is active.
#
#   FAIL CLOSED: input that cannot be read, and any unexpected error, exit 2 (block). The
#   missing-file case is the harness's onFailure: "block" in settings.json.
#
#   TEXT IS NOT A COMMAND: the command line is split outside quotes only, and the command word
#   of each statement is judged - "git commit -m 'use curl'", echo, grep and Write-Output are
#   not fetches. This is the same lesson as block-dangerous.ps1.
#
#   OUTPUT: a deny is the documented PreToolUse JSON on stdout
#   (hookSpecificOutput.permissionDecision = "deny") with one reason. Exit 0 otherwise.
#   ASCII ONLY: Windows PowerShell 5.1 reads BOM-less .ps1 files in the ANSI code page; a
#   non-ASCII character can crash the hook, and a crashed hook lets the call through.

$ErrorActionPreference = 'SilentlyContinue'

$script:DenyReason = 'Use fetch_page.py (~/.claude/skills/research/scripts/fetch_page.py): Crawl4AI first, page saved as a file.'
$script:OverrideReason = 'The POS_ALLOW_DIRECT_FETCH override belongs to the user. This command would set it persistently; ask the user instead of writing it yourself.'

function Send-Deny([string]$reason) {
    $payload = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Compress -Depth 5
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload + [Environment]::NewLine)
        $out = [Console]::OpenStandardOutput()
        $out.Write($bytes, 0, $bytes.Length)
        $out.Flush()
    }
    catch {
        # If the decision cannot be written, exit 2 still blocks.
        Send-Block $reason
    }
    exit 0
}

function Send-Block([string]$reason) {
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($reason + [Environment]::NewLine)
        $err = [Console]::OpenStandardError()
        $err.Write($bytes, 0, $bytes.Length)
        $err.Flush()
    }
    catch { }
    exit 2
}

trap {
    Send-Block 'BLOCKED: the fetch guard hit an unexpected error and cannot judge this call. Tell the user; do not work around it.'
}

# --- read the tool call (byte handling identical to block-dangerous.ps1) ----
$stdinStream = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($stdinStream)
$stdinBytes = $stdinStream.ToArray()
$skip = 0
while ($stdinBytes.Length -ge ($skip + 3) -and $stdinBytes[$skip] -eq 0xEF -and $stdinBytes[$skip + 1] -eq 0xBB -and $stdinBytes[$skip + 2] -eq 0xBF) { $skip += 3 }
$raw = [System.Text.Encoding]::UTF8.GetString($stdinBytes, $skip, $stdinBytes.Length - $skip).TrimStart([char]0xFEFF)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Send-Block 'BLOCKED: the fetch guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.'
}
try { $call = $raw | ConvertFrom-Json -ErrorAction Stop }
catch { Send-Block 'BLOCKED: the fetch guard cannot read the tool call it was given (input is empty or not valid JSON), so it refuses to let it through. Tell the user.' }

$toolName = [string]$call.tool_name
$command = [string]$call.tool_input.command

function Strip-Quotes([string]$text) {
    return $text.Trim('"', "'")
}

function Get-Statements([string]$text) {
    # Split on newline, ;, &&, ||, | and braces/parentheses, but only OUTSIDE quotes:
    # a commit message or a quoted URL stays one piece and is never read as commands.
    $out = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    $quote = [char]0
    $i = 0
    while ($i -lt $text.Length) {
        $ch = $text[$i]
        if ($quote -ne [char]0) {
            [void]$cur.Append($ch)
            if ($ch -eq $quote) { $quote = [char]0 }
            elseif ($ch -eq '`' -and $i + 1 -lt $text.Length) { $i++; [void]$cur.Append($text[$i]) }
            $i++
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; [void]$cur.Append($ch); $i++; continue }
        # A line continuation joins the next line: backslash-newline in Bash, backtick-newline
        # in PowerShell. Without this, "curl \" + newline + URL looked like two statements and
        # the URL sat in a piece that was never judged as a fetch.
        if (($ch -eq '\' -or $ch -eq '`') -and ($i + 1) -lt $text.Length -and
            ($text[$i + 1] -eq "`n" -or $text[$i + 1] -eq "`r")) {
            $i++
            if ($text[$i] -eq "`r" -and ($i + 1) -lt $text.Length -and $text[$i + 1] -eq "`n") { $i++ }
            [void]$cur.Append(' ')
            $i++
            continue
        }
        $pair = if ($i + 1 -lt $text.Length) { [string]$ch + [string]$text[$i + 1] } else { '' }
        if ($ch -eq "`n" -or $ch -eq "`r" -or $ch -eq ';' -or $ch -eq '|' -or
            $ch -eq '{' -or $ch -eq '}' -or $ch -eq '(' -or $ch -eq ')') {
            $out.Add($cur.ToString())
            [void]$cur.Clear()
            if ($pair -eq '&&' -or $pair -eq '||') { $i++ }
            $i++
            continue
        }
        [void]$cur.Append($ch)
        $i++
    }
    $out.Add($cur.ToString())
    # A pipe into a file writer belongs to the statement that produces the text: keep it
    # together, so "curl ... | Out-File f" is one fetch WITH a sink, while "curl ... | grep x"
    # stays two statements and the first one is still judged as printing.
    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $out) {
        if ($merged.Count -gt 0 -and $segment.Trim() -imatch '^(Out-File|Set-Content|Add-Content)\b') {
            $merged[$merged.Count - 1] = $merged[$merged.Count - 1] + ' | ' + $segment
        }
        else { $merged.Add($segment) }
    }
    return $merged
}

function Get-SegmentTokens([string]$segment) {
    return [regex]::Matches($segment, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value }
}

function Get-CommandWord([string[]]$tokens) {
    # The command word of a statement, after leading assignments ($env:X=..., X=...) and shell
    # prefixes (sudo, command, exec, time, &, .). The leaf is taken so a path-qualified call
    # ("C:\Windows\System32\curl.exe", "/usr/bin/curl") is judged as the command it is.
    $index = 0
    while ($index -lt $tokens.Count -and (Strip-Quotes $tokens[$index]) -match '^(\$[A-Za-z_][\w:]*=|[A-Za-z_][\w]*=)') { $index++ }
    while ($index -lt $tokens.Count -and (Strip-Quotes $tokens[$index]) -imatch '^(sudo|command|exec|time|&|\.)$') { $index++ }
    if ($index -ge $tokens.Count) { return $null }
    $raw = (Strip-Quotes $tokens[$index]).ToLower()
    $leaf = ($raw -split '[\\/]')[-1]
    return [pscustomobject]@{ Index = $index; Word = ($leaf -replace '\.exe$', '') }
}

function Get-InnerShellText([string[]]$tokens, $start) {
    # The text a nested shell would run: everything after -Command/-c/-lc/... or /c, //c.
    for ($j = $start.Index + 1; $j -lt $tokens.Count; $j++) {
        $flag = (Strip-Quotes $tokens[$j]).ToLower()
        if ($flag -in @('-command', '-encodedcommand', '-enc', '/c', '//c') -or $flag -match '^-[a-z]*c$') {
            if ($j + 1 -lt $tokens.Count) {
                # Raw tokens, quotes kept: a quoted inner command with a semicolon in it stays
                # one quoted argument until Test-ShellFetch strips the outer pair.
                return (@($tokens[($j + 1)..($tokens.Count - 1)]) -join ' ')
            }
            return ''
        }
    }
    return ''
}

function Expand-UrlVariables([string]$text, [hashtable]$map) {
    # A URL bound to a variable in an earlier statement ("$u='https://...'; iwr $u") is still a
    # URL the fetch command requests. Only the $name form is replaced; a bare word is not.
    foreach ($name in $map.Keys) {
        $repl = ([string]$map[$name]).Replace('$', '$$')
        $text = $text -replace ('\$' + [regex]::Escape([string]$name) + '\b'), $repl
        $text = $text -replace ('\$\{' + [regex]::Escape([string]$name) + '\}'), $repl
    }
    return $text
}

function Test-ApiUrl([string]$url) {
    try { $hostName = ([Uri]$url).Host.ToLower() } catch { return $false }
    if ($hostName -eq 'api.github.com' -or $hostName -eq 'registry.npmjs.org') { return $true }
    # Serper is a SEARCH service the research standard uses through the shell.
    if ($hostName -eq 'google.serper.dev') { return $true }
    if ($hostName -match '^api\.' -or $hostName -match '\.api\.') { return $true }
    if ($hostName -eq 'pypi.org' -and $url -match '/pypi/[^/]+/json') { return $true }
    return $false
}

function Test-StdoutRedirect([string]$statement) {
    # A > outside quotes that is not 2> writes the page into a file, not into the context.
    $quote = [char]0
    for ($i = 0; $i -lt $statement.Length; $i++) {
        $ch = $statement[$i]
        if ($quote -ne [char]0) { if ($ch -eq $quote) { $quote = [char]0 }; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq '>') {
            $prev = if ($i -gt 0) { $statement[$i - 1] } else { ' ' }
            if ($prev -ne '2') { return $true }
        }
    }
    return $false
}

function Test-OutputSink([string]$statement, [string]$commandWord) {
    if (Test-StdoutRedirect $statement) { return $true }
    # "curl -o -" and "wget -O -" write to STDOUT, not to a file.
    if ($commandWord -ne 'crwl' -and $statement -imatch '(\s--output(=|\s+)-(\s|$)|\s-[oO]\s+-(\s|$))') { return $false }
    if ($statement -imatch '\|\s*(Out-File|Set-Content|Add-Content)\b') { return $true }
    # wget combines its flags: -qO page.html and -qOpage.html both name an output file,
    # -qO - does not.
    if ($commandWord -eq 'wget') {
        $wgetTokens = @(Get-SegmentTokens $statement)
        for ($wi = 0; $wi -lt $wgetTokens.Count; $wi++) {
            $mO = [regex]::Match((Strip-Quotes $wgetTokens[$wi]), '^-([A-Za-z]*)O(.*)$')
            if (-not $mO.Success) { continue }
            $attached = $mO.Groups[2].Value
            if ($attached -ne '' -and $attached -ne '-') { return $true }
            if ($attached -eq '' -and ($wi + 1) -lt $wgetTokens.Count) {
                $nextToken = Strip-Quotes $wgetTokens[$wi + 1]
                if ($nextToken -ne '' -and $nextToken -ne '-') { return $true }
            }
        }
    }
    foreach ($token in @(Get-SegmentTokens $statement)) {
        $bare = Strip-Quotes $token
        # crwl's --output names the FORMAT; only a redirection is a real sink for it.
        if ($commandWord -ne 'crwl' -and $bare -imatch '^--output(-document)?(=|$)') { return $true }
        if ($bare -imatch '^-OutFile(:|$)') { return $true }
        # crwl uses -o for the output FORMAT, not a file; only its redirection counts.
        if ($commandWord -ne 'crwl' -and $bare -match '^-o(:|$)') { return $true }
        if ($commandWord -ne 'crwl' -and $bare -match '^-O$') { return $true }
    }
    return $false
}

function Get-Urls([string]$text) {
    $urls = @()
    foreach ($match in [regex]::Matches($text, 'https?://[^\s"''<>)\]]+')) {
        $urls += $match.Value.TrimEnd('.', ',', ';')
    }
    return $urls
}

function Test-AllApi([string[]]$urls) {
    if ($urls.Count -eq 0) { return $false }
    foreach ($url in $urls) {
        if (-not (Test-ApiUrl $url)) { return $false }
    }
    return $true
}

function Test-PersistentOverride([string]$statement, [string[]]$tokens, $start) {
    if ($statement -notmatch 'POS_ALLOW_DIRECT_FETCH') { return $false }
    $word = $start.Word
    $first = Strip-Quotes $tokens[$start.Index]
    # The command word decides, not a word inside a quoted message: a commit message, echo or
    # grep pattern that merely names setx stays allowed (task Part 3.2).
    if ($word -eq 'setx') { return $true }
    if ($word -eq 'reg' -and $statement -imatch '\\Environment') {
        $rest = @($tokens[$start.Index..($tokens.Count - 1)])
        if ($rest.Count -ge 2 -and (Strip-Quotes $rest[1]) -ieq 'add') { return $true }
    }
    if ($word -eq 'set-item' -and $statement -imatch 'Env:') { return $true }
    if ($first -imatch '^\[(System\.)?Environment\]::SetEnvironmentVariable') { return $true }
    # A write into a profile or environment file: judged only when the statement really writes
    # (a writer command or a redirect outside quotes).
    $writesProfile = ($statement -imatch '(?i)(\$PROFILE|profile\.ps1|microsoft\.powershell_profile|\.bashrc|\.zshrc|\.profile|/etc/environment)') -and
                     ($statement -imatch '(?i)(>>|>|Set-Content|Add-Content|Out-File|WriteAllText|AppendAllText|SetEnvironmentVariable|write_text|writeFile|open\s*\()')
    if ($writesProfile) {
        $writers = @('set-content', 'add-content', 'out-file', 'python', 'python3', 'py', 'node',
                     'pwsh', 'powershell', 'bash', 'sh', 'echo', 'printf', 'tee')
        if (($writers -contains $word) -or (Test-StdoutRedirect $statement)) { return $true }
    }
    return $false
}

function Test-ShellPersistent([string]$text, [int]$depth = 0) {
    # The statement splitter breaks at "(", so the [Environment]:: call is checked on the whole
    # text first. Quoted text is stripped for the method name only: echo and commit messages
    # that merely quote it stay allowed.
    if ($text -imatch 'POS_ALLOW_DIRECT_FETCH') {
        $bareText = $text -replace '"[^"]*"', ' ' -replace "'[^']*'", ' '
        if ($bareText -imatch '\[(System\.)?Environment\]::SetEnvironmentVariable\s*\(') { return $true }
    }
    foreach ($statement in @(Get-Statements $text)) {
        $tokens = @(Get-SegmentTokens $statement)
        if ($tokens.Count -eq 0) { continue }
        $start = Get-CommandWord $tokens
        if ($null -eq $start) { continue }
        if (Test-PersistentOverride $statement $tokens $start) { return $true }
        if ($start.Word -in @('powershell', 'pwsh', 'cmd', 'bash', 'sh', 'zsh') -and $depth -lt 3) {
            $inner = Get-InnerShellText $tokens $start
            if (-not [string]::IsNullOrWhiteSpace($inner)) {
                if (Test-ShellPersistent $inner ($depth + 1)) { return $true }
            }
        }
    }
    return $false
}

function Test-FetchStatement([string]$statement, [int]$depth) {
    $tokens = @(Get-SegmentTokens $statement)
    if ($tokens.Count -eq 0) { return $false }

    # Command word: skip leading assignments ($env:X=..., X=...) and shell prefixes.
    $start = Get-CommandWord $tokens
    if ($null -eq $start) { return $false }
    $index = $start.Index
    $word = $start.Word
    $rest = @($tokens[$index..($tokens.Count - 1)])

    # A nested shell: judge the inner command, never the wrapper.
    if ($word -in @('powershell', 'pwsh', 'cmd', 'bash', 'sh', 'zsh')) {
        $innerText = Get-InnerShellText $tokens $start
        if (-not [string]::IsNullOrWhiteSpace($innerText) -and $depth -lt 3) {
            return Test-ShellFetch $innerText ($depth + 1)
        }
        return $false
    }

    # The research scripts fetch and save by design.
    if ($word -in @('python', 'python3', 'py', 'uv')) {
        $inline = $false
        foreach ($token in $rest) {
            $bare = Strip-Quotes $token
            if ($bare -in @('-c', '-e', '--eval')) { $inline = $true }
            if ($bare -match '(?i)(fetch_page|save_pages|crawl4ai_fetch|verify_evidence|check_services|store_results|build_references|check_article|check_note|check_note)\.py$') {
                if (-not $inline) { return $false }
            }
        }
    }

    # uv run <tool> ...: the launcher is not the command; judge what it runs.
    if ($word -eq 'uv') {
        $k = 1
        while ($k -lt $rest.Count -and (Strip-Quotes $rest[$k]) -match '^-') { $k++ }
        if ($k -lt $rest.Count -and (Strip-Quotes $rest[$k]) -ieq 'run') {
            $k++
            while ($k -lt $rest.Count -and (Strip-Quotes $rest[$k]) -match '^-') { $k++ }
        }
        if ($k -lt $rest.Count -and $depth -lt 3) {
            $nextWord = ((Strip-Quotes $rest[$k]).ToLower() -replace '\.exe$', '')
            if ($nextWord -in @('python', 'python3', 'py', 'node', 'crwl', 'curl', 'wget',
                                'iwr', 'irm', 'invoke-webrequest', 'invoke-restmethod', 'sh', 'bash')) {
                $innerText = (@($rest[$k..($rest.Count - 1)]) -join ' ')
                return Test-ShellFetch $innerText ($depth + 1)
            }
        }
        return $false
    }

    if ($word -in @('gh', 'git', 'npm', 'npx', 'pnpm', 'yarn', 'pip', 'pip3',
                    'pipx', 'winget', 'brew', 'choco', 'apt', 'apt-get', 'dnf', 'yum',
                    'pacman', 'cargo', 'go', 'dotnet', 'gem', 'composer')) {
        return $false
    }

    # python -c / node -e that requests a URL and prints the answer.
    if ($word -in @('python', 'python3', 'py', 'node')) {
        $inline = $false
        foreach ($token in $rest) {
            if ((Strip-Quotes $token) -in @('-c', '-e', '--eval', '-p', '--print')) { $inline = $true; break }
        }
        if (-not $inline) { return $false }
        if ($statement -notmatch 'https?://') { return $false }
        if ($statement -inotmatch '(requests\.|urlopen|urllib|httpx|fetch\s*\(|axios|https?\.(get|request)|\.request\s*\(|require\s*\(\s*[''"]https?|os\.system|subprocess|child_process|execSync|spawnSync)') { return $false }
        if (Test-StdoutRedirect $statement) { return $false }
        if ($statement -imatch '(open\s*\([^)]*[''"]w|write_text|write_bytes|writeFile|createWriteStream)') { return $false }
        if ($statement -imatch '(print\s*\(|console\.log|process\.stdout|sys\.stdout|os\.system|subprocess|child_process|execSync|spawnSync)') {
            $urls = @(Get-Urls $statement)
            if (Test-AllApi $urls) { return $false }
            return $true
        }
        return $false
    }

    if ($word -in @('curl', 'wget', 'invoke-webrequest', 'iwr',
                    'invoke-restmethod', 'irm', 'crwl')) {
        $urls = @(Get-Urls $statement)
        if ($urls.Count -eq 0) { return $false }
        if (Test-OutputSink $statement $word) { return $false }
        if (Test-AllApi $urls) { return $false }
        return $true
    }

    return $false
}

function Test-ShellFetch([string]$text, [int]$depth = 0) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $t = $text.Trim()
    # bash -c "curl ..." hands one quoted argument: strip the outer pair so it is parsed.
    if ($t.Length -ge 2 -and (($t[0] -eq '"' -and $t[$t.Length - 1] -eq '"') -or
                              ($t[0] -eq "'" -and $t[$t.Length - 1] -eq "'"))) {
        $t = $t.Substring(1, $t.Length - 2)
    }
    # A URL bound to a variable in an earlier statement ("$u='https://...'; iwr $u") is still
    # the URL the fetch requests.
    $urlVars = @{}
    foreach ($m in [regex]::Matches($t, '(?m)(?:^|[;\r\n])\s*\$?([A-Za-z_][\w:]*)\s*=\s*[''"]?(https?://[^\s''";|)]+)')) {
        $name = $m.Groups[1].Value
        if (-not $urlVars.ContainsKey($name)) { $urlVars[$name] = $m.Groups[2].Value.TrimEnd('.', ',', ';') }
    }
    foreach ($statement in @(Get-Statements $t)) {
        if ([string]::IsNullOrWhiteSpace($statement)) { continue }
        $expanded = if ($urlVars.Count -gt 0) { Expand-UrlVariables $statement $urlVars } else { $statement }
        if (Test-FetchStatement $expanded $depth) { return $true }
    }
    return $false
}

# --- online image services (2026-10-24) -------------------------------------
# Pictures are made only by the /image skill (local ComfyUI). A download WITH a file sink passes
# the fetch rules above, which is how a session got a picture from pollinations.ai. So these
# hosts are denied for every sink, for every tool that hands a URL to the guard, and also while
# POS_ALLOW_DIRECT_FETCH=1 is set (that override is about reading pages, not about pictures).

$script:ImageReason = 'Online image services are blocked: pictures are made only with the /image skill (local ComfyUI). Tell the user if a picture is wanted.'

# A host matches when it is one of these or a subdomain of one.
$script:ImageHosts = @(
    'pollinations.ai', 'stability.ai', 'midjourney.com', 'leonardo.ai', 'ideogram.ai',
    'replicate.com', 'replicate.delivery', 'fal.ai', 'fal.run', 'bfl.ai', 'bfl.ml',
    'runwayml.com', 'craiyon.com', 'lexica.art', 'getimg.ai', 'clipdrop.co', 'openart.ai',
    'nightcafe.studio', 'playground.com', 'imagine.art', 'novita.ai', 'segmind.com',
    'krea.ai', 'recraft.ai', 'dezgo.com', 'deepai.org'
)
# Image endpoints of general API hosts, judged by the path of the URL.
$script:ImagePathPattern = '/(images/(generations|edits|variations)|text-?to-?image|txt2img)(/|\?|$)'

function Test-ImageServiceUrl([string]$url) {
    try { $uri = [Uri]$url } catch { return $false }
    $hostName = $uri.Host.ToLower()
    if ([string]::IsNullOrEmpty($hostName)) { return $false }
    foreach ($h in $script:ImageHosts) {
        if ($hostName -eq $h -or $hostName.EndsWith('.' + $h)) { return $true }
    }
    if ($uri.AbsolutePath.ToLower() -match $script:ImagePathPattern) { return $true }
    # Google's image models are named in the path of the generic API host.
    if ($hostName -eq 'generativelanguage.googleapis.com' -and $uri.AbsolutePath -imatch '(imagen|-image|generateImages)') { return $true }
    return $false
}

function Test-AnyImageServiceUrl([string]$text) {
    foreach ($url in @(Get-Urls $text)) {
        if (Test-ImageServiceUrl $url) { return $true }
    }
    return $false
}

function Test-ShellImageService([string]$text, [int]$depth = 0) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $t = $text.Trim()
    if ($t.Length -ge 2 -and (($t[0] -eq '"' -and $t[$t.Length - 1] -eq '"') -or
                              ($t[0] -eq "'" -and $t[$t.Length - 1] -eq "'"))) {
        $t = $t.Substring(1, $t.Length - 2)
    }
    $urlVars = @{}
    foreach ($m in [regex]::Matches($t, '(?m)(?:^|[;\r\n])\s*\$?([A-Za-z_][\w:]*)\s*=\s*[''"]?(https?://[^\s''";|)]+)')) {
        $name = $m.Groups[1].Value
        if (-not $urlVars.ContainsKey($name)) { $urlVars[$name] = $m.Groups[2].Value.TrimEnd('.', ',', ';') }
    }
    foreach ($statement in @(Get-Statements $t)) {
        if ([string]::IsNullOrWhiteSpace($statement)) { continue }
        $expanded = if ($urlVars.Count -gt 0) { Expand-UrlVariables $statement $urlVars } else { $statement }
        $tokens = @(Get-SegmentTokens $expanded)
        if ($tokens.Count -eq 0) { continue }
        $start = Get-CommandWord $tokens
        if ($null -eq $start) { continue }
        $word = $start.Word
        if ($word -in @('powershell', 'pwsh', 'cmd', 'bash', 'sh', 'zsh')) {
            $inner = Get-InnerShellText $tokens $start
            if (-not [string]::IsNullOrWhiteSpace($inner) -and $depth -lt 3) {
                if (Test-ShellImageService $inner ($depth + 1)) { return $true }
            }
            continue
        }
        # Only a program that can request a URL is judged; echo, grep, git commit are text.
        if ($word -notin @('curl', 'wget', 'invoke-webrequest', 'iwr', 'invoke-restmethod', 'irm', 'crwl',
                           'python', 'python3', 'py', 'node', 'uv', 'start', 'start-process', 'explorer', 'open', 'xdg-open')) { continue }
        if (Test-AnyImageServiceUrl $expanded) { return $true }
        # curl and wget also take an address without the scheme
        if ($word -in @('curl', 'wget', 'invoke-webrequest', 'iwr', 'invoke-restmethod', 'irm')) {
            foreach ($token in $tokens) {
                $bare = Strip-Quotes $token
                if ($bare -match '^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:[/:?]|$)' -and (Test-ImageServiceUrl ('http://' + $bare))) { return $true }
            }
        }
    }
    return $false
}

function Test-ImageServiceCall {
    # Any tool that carries a URL (WebFetch, a browser's navigate, a batch of browser actions).
    $inputText = ''
    try { $inputText = ($call.tool_input | ConvertTo-Json -Compress -Depth 10) } catch { $inputText = '' }
    if ($toolName -ine 'Bash' -and $toolName -ine 'PowerShell') {
        if ($inputText -and (Test-AnyImageServiceUrl $inputText)) { return $true }
    }
    # An MCP tool that makes pictures.
    if ($toolName -match '^mcp__(.+?)__(.+)$') {
        $verb = $Matches[2]
        if ($verb -imatch '(generate|create|make|text[-_]?to|txt2)[-_]?image|image[-_]?(generat|creat|gen($|[-_]))|imagine') { return $true }
    }
    if (($toolName -ieq 'Bash' -or $toolName -ieq 'PowerShell') -and -not [string]::IsNullOrWhiteSpace($command)) {
        if (Test-ShellImageService $command) { return $true }
    }
    return $false
}

function Write-OverrideLog([string]$name) {
    try {
        $state = Join-Path {{HOME_ENV}} '.claude/state'
        if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Force -Path $state | Out-Null }
        $line = '{0} | POS_ALLOW_DIRECT_FETCH=1 allows {1}{2}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $name, [Environment]::NewLine
        [IO.File]::AppendAllText((Join-Path $state 'fetch-guard.log'), $line, (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
}

# --- the decision -----------------------------------------------------------

# A persistent setting of the user-only override is denied even while the override is active.
if (($toolName -ieq 'Bash' -or $toolName -ieq 'PowerShell') -and (Test-ShellPersistent $command)) {
    Send-Deny $script:OverrideReason
}

# Online image services are denied before the override is looked at.
if (Test-ImageServiceCall) { Send-Deny $script:ImageReason }

if ($env:POS_ALLOW_DIRECT_FETCH -eq '1') {
    Write-OverrideLog $toolName
    exit 0
}

if ($toolName -ieq 'WebFetch') { Send-Deny $script:DenyReason }

if ($toolName -match '^mcp__(.+?)__(.+)$') {
    $verb = $Matches[2]
    # Search tools stay allowed (web_search_exa, firecrawl_search, you-search) even though the
    # provider name may contain a reading keyword. Everything else whose TOOL name carries a
    # page-reading keyword is denied - including a server named fetch or crawl
    # (mcp__fetch__fetch_page), which stripping the provider prefix used to hide.
    if ($verb -notmatch '(^|[-_])search($|[-_])' -and
        $verb -imatch '(fetch|scrape|extract|crawl|contents|read[_-]?url)') {
        Send-Deny $script:DenyReason
    }
}

if ($toolName -ieq 'Bash' -or $toolName -ieq 'PowerShell') {
    if (-not [string]::IsNullOrWhiteSpace($command) -and (Test-ShellFetch $command)) {
        Send-Deny $script:DenyReason
    }
}

exit 0
