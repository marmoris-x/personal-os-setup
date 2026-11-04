# Pester 5.9.1 (pinned). The /look script: one picture or video, one question, to the Portkey
# quick pool. No network here: a local HttpListener answers like Portkey, records the request
# and can play wrong model, 429 and a slow target.
#
# Windows only: the script's refusal list is built from Windows folders (the cloud folder, the
# Downloads storage folders, ~/.claude and friends). The other systems are untested by design
# (platforms map, Part 6). On macOS and Linux the whole suite is skipped, so CI stays green.
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:look = Join-Path $repoRoot 'home/.claude/skills/look/scripts/look.ps1'

    $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $script:work = Join-Path $scratchRoot 'look-script'
    if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $script:work | Out-Null

    # A 1x1 PNG and a tiny MP4: the script checks extension, size and media type, not the pixels.
    $script:png = Join-Path $script:work 'tiny.png'
    [IO.File]::WriteAllBytes($script:png, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
    $script:mp4 = Join-Path $script:work 'tiny.mp4'
    [IO.File]::WriteAllBytes($script:mp4, (New-Object byte[] 64))

    $script:fakeKey = 'dummy-portkey-key-A1B2C3D4'
    $script:fakeConfig = 'pc-test-quick'
    $script:defaultAsk = 'Describe exactly what you see: every object, every text verbatim, colours, layout. Say what you cannot read.'

    $script:oldKey = [Environment]::GetEnvironmentVariable('PORTKEY_API_KEY')
    $script:oldQuick = [Environment]::GetEnvironmentVariable('PORTKEY_CONFIG_QUICK')

    # The cloud folder by its Windows known-folder id; used by the junction test below.
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
    function Get-CloudRoot {
        $guid = [guid]'A52BBA46-E9E1-435F-B3D9-28DAA648C0F6'
        $p = [IntPtr]::Zero
        $hr = [LookKnownFolder]::SHGetKnownFolderPath([ref]$guid, 0, [IntPtr]::Zero, [ref]$p)
        if ($hr -ne 0) { return '' }
        $root = [Runtime.InteropServices.Marshal]::PtrToStringUni($p)
        [Runtime.InteropServices.Marshal]::FreeCoTaskMem($p)
        return $root
    }

    function Get-FreePort {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
    }

    # One fake Portkey per scenario, as a process of its own: killing a process is immediate,
    # while Stop-Job can hang on a listener blocked in GetContext() (measured in this task).
    function Start-FakeEndpoint {
        param([string]$Mode, [string]$Dir)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $server = Join-Path $script:work 'fake-portkey.ps1'
        if (-not (Test-Path -LiteralPath $server)) {
            $serverText = @'
param([int]$Port, [string]$Mode, [string]$Dir)
$l = [Net.HttpListener]::new()
$l.Prefixes.Add("http://127.0.0.1:$Port/")
$l.Start()
[IO.File]::WriteAllText((Join-Path $Dir 'ready'), 'ok')
while ($true) {
    $c = $l.GetContext()
    $reader = [IO.StreamReader]::new($c.Request.InputStream, $c.Request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Dispose()
    $h = [ordered]@{}
    foreach ($k in $c.Request.Headers.AllKeys) { $h[$k] = $c.Request.Headers[$k] }
    $req = [ordered]@{ method = $c.Request.HttpMethod; path = $c.Request.Url.AbsolutePath; body = $body; headers = $h }
    [IO.File]::WriteAllText((Join-Path $Dir 'request.json'), ($req | ConvertTo-Json -Depth 8 -Compress))
    switch ($Mode) {
        'ok' {
            $payload = '{"model":"gemini-3.5-flash-lite","choices":[{"message":{"content":"Eyes OK"}}]}'
            $c.Response.Headers['x-portkey-last-used-option-index'] = '$.targets[0]'
            $c.Response.Headers['x-portkey-retry-attempt-count'] = '0'
            $c.Response.StatusCode = 200
        }
        'wrongmodel' {
            $payload = '{"model":"gemini-9.9-ultra","choices":[{"message":{"content":"SECRET ANSWER"}}]}'
            $c.Response.StatusCode = 200
        }
        '429' {
            $payload = '{"error":"rate limited"}'
            $c.Response.StatusCode = 429
        }
        'slow' {
            Start-Sleep -Seconds 10
            $payload = '{"model":"gemini-3.5-flash-lite","choices":[{"message":{"content":"late"}}]}'
            $c.Response.StatusCode = 200
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $c.Response.ContentType = 'application/json'
    $c.Response.ContentLength64 = $bytes.Length
    $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $c.Response.Close()
}
'@
            [IO.File]::WriteAllText($server, $serverText, (New-Object Text.UTF8Encoding($false)))
        }
        $port = Get-FreePort
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $server, '-Port', "$port", '-Mode', $Mode, '-Dir', $Dir) -PassThru -WindowStyle Hidden
        for ($i = 0; $i -lt 100; $i++) {
            if (Test-Path -LiteralPath (Join-Path $Dir 'ready')) { break }
            Start-Sleep -Milliseconds 100
        }
        return @{ Process = $proc; Url = "http://127.0.0.1:$port/v1/chat/completions"; Dir = $Dir }
    }

    function Stop-FakeEndpoint($Endpoint) {
        if ($Endpoint.Process -and -not $Endpoint.Process.HasExited) {
            Stop-Process -Id $Endpoint.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    function Invoke-Look {
        param([string[]]$Arguments)
        $text = & pwsh -NoProfile -NonInteractive -File $script:look @Arguments 2>&1 | Out-String
        return @{ Text = $text; Code = $LASTEXITCODE }
    }

    # Run one scenario with the fake endpoint; any environment override is set for the child only
    # and put back afterwards.
    function Invoke-LookScenario {
        param([string]$Mode, [string[]]$Arguments, [hashtable]$Env = @{})
        $dir = Join-Path $script:work ('endpoint-' + [guid]::NewGuid().ToString('N'))
        $endpoint = Start-FakeEndpoint -Mode $Mode -Dir $dir
        $saved = @{}
        foreach ($k in $Env.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $Env[$k])
        }
        try {
            $r = Invoke-Look @($Arguments + @('-Endpoint', $endpoint.Url))
            $reqPath = Join-Path $dir 'request.json'
            if (Test-Path -LiteralPath $reqPath) {
                $r.Request = [IO.File]::ReadAllText($reqPath) | ConvertFrom-Json
            }
            return $r
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            Stop-FakeEndpoint $endpoint
        }
    }
}

AfterAll {
    [Environment]::SetEnvironmentVariable('PORTKEY_API_KEY', $script:oldKey)
    [Environment]::SetEnvironmentVariable('PORTKEY_CONFIG_QUICK', $script:oldQuick)
    if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force }
}

BeforeDiscovery {
    # -TestCases is read during discovery, before any BeforeAll runs: the case list is built
    # here. The cloud folder comes from its Windows known-folder id (FOLDERID_SkyDrive), never
    # from a path text in this file.
    $cloudRoot = ''
    if ($IsWindows) {
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
        $hr = [LookKnownFolder]::SHGetKnownFolderPath([ref]$guid, 0, [IntPtr]::Zero, [ref]$p)
        if ($hr -eq 0) {
            $cloudRoot = [Runtime.InteropServices.Marshal]::PtrToStringUni($p)
            [Runtime.InteropServices.Marshal]::FreeCoTaskMem($p)
        }
    }

    $script:refusalCases = @(
        @{ Name = '600-archive'; Path = (Join-Path ([IO.Path]::GetTempPath()) 'look-refusal\600-archive\refused.png') }
        @{ Name = '.claude'; Path = (Join-Path $HOME '.claude\refused.png') }
        @{ Name = '.ssh'; Path = (Join-Path $HOME '.ssh\refused.png') }
        @{ Name = '.codex'; Path = (Join-Path $HOME '.codex\refused.png') }
        @{ Name = 'Downloads Compressed'; Path = (Join-Path $HOME 'Downloads\Compressed\refused.png') }
        @{ Name = 'Downloads Documents'; Path = (Join-Path $HOME 'Downloads\Documents\refused.png') }
        @{ Name = 'Downloads Images'; Path = (Join-Path $HOME 'Downloads\Images\refused.png') }
        @{ Name = 'Downloads Music'; Path = (Join-Path $HOME 'Downloads\Music\refused.png') }
        @{ Name = 'Downloads Programs'; Path = (Join-Path $HOME 'Downloads\Programs\refused.png') }
        @{ Name = 'Downloads Videos'; Path = (Join-Path $HOME 'Downloads\Videos\refused.png') }
    )
    if ($cloudRoot) {
        $script:refusalCases += @{ Name = 'OneDrive'; Path = (Join-Path $cloudRoot 'refused.png') }
        $script:refusalCases += @{ Name = 'OneDrive parent with a trailing dot'; Path = ($cloudRoot + '.\refused.png') }
    }
    $script:refusalCases += @{ Name = 'long path prefix'; Path = ('\\?\' + (Join-Path ([IO.Path]::GetTempPath()) 'look-refusal\name-ausweis.png')) }
    foreach ($word in @('ausweis', 'pass', 'svnr', 'versicherung', 'bank', 'konto', 'iban', 'befund', 'arzt', 'bescheid')) {
        $script:refusalCases += @{ Name = "name contains $word"; Path = (Join-Path ([IO.Path]::GetTempPath()) ('look-refusal\name-' + $word + '.png')) }
    }
}

Describe 'look.ps1' -Skip:(-not $IsWindows) {
    BeforeEach {
        $env:PORTKEY_API_KEY = $script:fakeKey
        $env:PORTKEY_CONFIG_QUICK = $script:fakeConfig
    }
    AfterEach {
        $env:PORTKEY_API_KEY = $script:fakeKey
        $env:PORTKEY_CONFIG_QUICK = $script:fakeConfig
    }

    It 'exists in the mirror' {
        $script:look | Should -Exist
    }

    Context 'refused paths' {
        It 'refuses <Name>' -TestCases $script:refusalCases {
            param($Name, $Path)
            $r = Invoke-Look @('-Path', $Path)
            $r.Code | Should -Be 3 -Because $r.Text
            $r.Text | Should -Match 'verweigert'
        }

        It 'refuses a path that reaches the cloud folder through a junction' {
            $cloudRoot = Get-CloudRoot
            if (-not $cloudRoot) { Set-ItResult -Skipped -Because 'no cloud folder on this machine'; return }
            $link = Join-Path $script:work 'junction-to-cloud'
            $made = $false
            try {
                New-Item -ItemType Junction -Path $link -Target $cloudRoot | Out-Null
                $made = $true
                $r = Invoke-Look @('-Path', (Join-Path $link 'refused.png'))
                $r.Code | Should -Be 3 -Because $r.Text
                $r.Text | Should -Match 'verweigert'
            }
            catch {
                if (-not $made) { Set-ItResult -Skipped -Because $_.Exception.Message }
                else { throw }
            }
            finally {
                if ($made) { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'rejects a wrong extension with exit 2' {
        $path = Join-Path $script:work 'note.txt'
        [IO.File]::WriteAllText($path, 'text')
        $r = Invoke-Look @('-Path', $path)
        $r.Code | Should -Be 2 -Because $r.Text
    }

    It 'rejects a missing file with exit 2' {
        $r = Invoke-Look @('-Path', (Join-Path $script:work 'missing.png'))
        $r.Code | Should -Be 2 -Because $r.Text
        $r.Text | Should -Match 'nicht gefunden'
    }

    It 'refuses a request over 18 MB after base64 and never shrinks the file' {
        $path = Join-Path $script:work 'huge.png'
        [IO.File]::WriteAllBytes($path, (New-Object byte[] (14 * 1024 * 1024)))
        $before = (Get-Item -LiteralPath $path).Length
        $r = Invoke-Look @('-Path', $path)
        $r.Code | Should -Be 4 -Because $r.Text
        $r.Text | Should -Match '18 MB'
        (Get-Item -LiteralPath $path).Length | Should -Be $before
    }

    It 'names the missing variable and the key script with exit 5' {
        $r = Invoke-LookScenario -Mode 'ok' -Arguments @('-Path', $script:png) -Env @{ PORTKEY_API_KEY = '' }
        $r.Code | Should -Be 5 -Because $r.Text
        $r.Text | Should -Match 'PORTKEY_API_KEY'
        $r.Text | Should -Match 'set-research-keys\.ps1'
    }

    It 'names a missing quick config the same way' {
        $r = Invoke-LookScenario -Mode 'ok' -Arguments @('-Path', $script:png) -Env @{ PORTKEY_CONFIG_QUICK = '' }
        $r.Code | Should -Be 5 -Because $r.Text
        $r.Text | Should -Match 'PORTKEY_CONFIG_QUICK'
        $r.Text | Should -Match 'set-research-keys\.ps1'
    }

    It 'never prints the key in a success, a 429, an error message or a timeout' {
        $ok = Invoke-LookScenario -Mode 'ok' -Arguments @('-Path', $script:png)
        $limited = Invoke-LookScenario -Mode '429' -Arguments @('-Path', $script:png)
        $wrong = Invoke-LookScenario -Mode 'wrongmodel' -Arguments @('-Path', $script:png)
        $slow = Invoke-LookScenario -Mode 'slow' -Arguments @('-Path', $script:png, '-TimeoutSec', '2')
        $all = $ok.Text + $limited.Text + $wrong.Text + $slow.Text
        $all | Should -Not -Match [regex]::Escape($script:fakeKey)
    }

    It 'does not print the answer when another model replied (exit 7)' {
        $r = Invoke-LookScenario -Mode 'wrongmodel' -Arguments @('-Path', $script:png)
        $r.Code | Should -Be 7 -Because $r.Text
        $r.Text | Should -Match 'anderes Modell geantwortet: gemini-9\.9-ultra'
        $r.Text | Should -Not -Match 'SECRET ANSWER'
    }

    It 'maps a local timeout to exit 6 with 408 and the trace id' {
        $r = Invoke-LookScenario -Mode 'slow' -Arguments @('-Path', $script:png, '-TimeoutSec', '2')
        $r.Code | Should -Be 6 -Because $r.Text
        $r.Text | Should -Match '408'
        $r.Text | Should -Match 'trace [0-9a-fA-F-]{36}'
    }

    It 'maps HTTP 429 to exit 6 with a German message, the status and the trace id' {
        $r = Invoke-LookScenario -Mode '429' -Arguments @('-Path', $script:png)
        $r.Code | Should -Be 6 -Because $r.Text
        $r.Text | Should -Match 'Portkey-Fehler'
        $r.Text | Should -Match '429'
        $r.Text | Should -Match 'trace [0-9a-fA-F-]{36}'
    }

    It 'prints the answer and the success line in the agreed form' {
        $r = Invoke-LookScenario -Mode 'ok' -Arguments @('-Path', $script:png)
        $r.Code | Should -Be 0 -Because $r.Text
        $lines = @($r.Text -split "`r?`n" | Where-Object { $_.Trim() })
        $lines[0] | Should -Be 'Eyes OK'
        $lines[-1] | Should -Match '^model=gemini-3\.5-flash-lite target=\$\.targets\[0\] retries=0 seconds=\d+ trace=[0-9a-fA-F-]{36}$'
        $trace = [regex]::Match($lines[-1], 'trace=([0-9a-fA-F-]{36})').Groups[1].Value
        $r.Request.headers.'x-portkey-trace-id' | Should -Be $trace
    }

    It 'sends the quick config, the key header and one media part before the text' {
        $r = Invoke-LookScenario -Mode 'ok' -Arguments @('-Path', $script:png)
        $r.Code | Should -Be 0 -Because $r.Text
        $r.Request.method | Should -Be 'POST'
        $r.Request.headers.'x-portkey-config' | Should -Be $script:fakeConfig
        $r.Request.headers.'x-portkey-api-key' | Should -Be $script:fakeKey
        $body = $r.Request.body | ConvertFrom-Json
        $body.model | Should -Be 'gemini-3.5-flash-lite'
        $body.stream | Should -BeFalse
        $body.messages.Count | Should -Be 1
        $body.messages[0].role | Should -Be 'user'
        $body.messages[0].content[0].type | Should -Be 'image_url'
        $body.messages[0].content[0].image_url.url | Should -Match '^data:image/png;base64,[A-Za-z0-9+/=]+$'
        $body.messages[0].content[0].image_url.media_resolution | Should -Be 'MEDIA_RESOLUTION_HIGH'
        $body.messages[0].content[1].type | Should -Be 'text'
        $body.messages[0].content[1].text | Should -Be $script:defaultAsk
    }

    It 'switches the media resolution to ultra_high on request' {
        $r = Invoke-LookScenario -Mode 'ok' -Arguments @('-Path', $script:png, '-Resolution', 'ultra_high')
        $r.Code | Should -Be 0 -Because $r.Text
        ($r.Request.body | ConvertFrom-Json).messages[0].content[0].image_url.media_resolution | Should -Be 'MEDIA_RESOLUTION_ULTRA_HIGH'
    }

    It 'accepts an mp4 as a video data URI' {
        $r = Invoke-LookScenario -Mode 'ok' -Arguments @('-Path', $script:mp4, '-Ask', 'What moves?')
        $r.Code | Should -Be 0 -Because $r.Text
        $body = $r.Request.body | ConvertFrom-Json
        $body.messages[0].content[0].image_url.url | Should -Match '^data:video/mp4;base64,'
        $body.messages[0].content[1].text | Should -Be 'What moves?'
    }
}
