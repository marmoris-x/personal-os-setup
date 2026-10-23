# Pester 5.9.1 (pinned). The /image skill script: new-image.ps1 drives ComfyUI through the
# comfy command (comfy-cli), local only.
#
# What is measured here, with a stand-in for `comfy` (a small script that records every call and
# answers like the real one did on 2026-10-23): the workflow copy gets the prompt, the size and
# the seed in the right nodes of the Z-Image-Turbo template and nothing else changes; the server is
# started only when nothing answers on the port; every run goes out with `--where local`; a CUDA
# out-of-memory answer ends in a German message with exit 1; `-Stop` stops and nothing more.
# The real GPU run is the acceptance proof (Part 5), not a unit test.
#
# The repo copy of the script carries {{DEV}} placeholders in its default paths, so every test
# hands the paths over explicitly.
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:newImage = Join-Path $repoRoot 'home/.claude/skills/image/scripts/new-image.ps1'
    # A trimmed copy of the official template, same structure (a subgraph holds the sampler graph).
    # The original is NOT in this repo: it carries a decimal number the privacy scan reads as a
    # 12-digit id, so the skill fetches it from a pinned commit instead (tests below).
    $script:template = Join-Path $PSScriptRoot 'fixtures/image-template-minimal.json'

    $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $script:work = Join-Path $scratchRoot 'image-script'
    if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $script:work | Out-Null

    # The stand-in for `comfy`. It logs its arguments, keeps the last submitted workflow and
    # answers `run` with the event lines and the final envelope of the real tool.
    $fake = @'
$log = Join-Path $env:FAKE_COMFY_DIR 'calls.log'
Add-Content -LiteralPath $log -Value ($args -join ' ')
switch ($args[0]) {
    'launch' { '{"ok": true}'; exit 0 }
    'stop' { '{"ok": true}'; exit 0 }
    'run' {
        $at = [array]::IndexOf($args, '--workflow')
        $wf = $args[$at + 1]
        Copy-Item -LiteralPath $wf -Destination (Join-Path $env:FAKE_COMFY_DIR 'last-workflow.json') -Force
        $counterFile = Join-Path $env:FAKE_COMFY_DIR 'counter.txt'
        $n = 1
        if (Test-Path -LiteralPath $counterFile) { $n = [int](Get-Content -LiteralPath $counterFile) + 1 }
        Set-Content -LiteralPath $counterFile -Value $n
        if ($env:FAKE_COMFY_MODE -eq 'oom') {
            '{"schema": "event/1", "type": "execution_error", "message": "CUDA out of memory. Tried to allocate 2.00 GiB"}'
            '{"schema": "envelope/1", "type": "envelope", "ok": false, "command": "run", "data": null, "error": {"code": "execution_error", "message": "torch.OutOfMemoryError: CUDA out of memory", "details": null}}'
            exit 1
        }
        if ($env:FAKE_COMFY_MODE -eq 'bloom') {
            '{"schema": "envelope/1", "type": "envelope", "ok": false, "command": "run", "data": null, "error": {"code": "missing_node", "message": "node BloomFilter not found in zoom/room.json", "details": null}}'
            exit 1
        }
        if ($env:FAKE_COMFY_MODE -eq 'noenvelope') {
            '{"schema":"event/1","type":"progress","completed":8,"total":8}'
            exit 0
        }
        $name = 'z-image-turbo_{0:D5}_.png' -f $n
        $url = "http://127.0.0.1:8188/view?filename=$name&subfolder=&type=output"
        '{"schema": "event/1", "type": "progress", "node": "57:3", "completed": 8, "total": 8}'
        '{"schema": "event/1", "type": "output", "url": "' + $url + '"}'
        '{"schema": "envelope/1", "type": "envelope", "ok": true, "command": "run", "data": {"status": "completed", "outputs": ["' + $url + '"]}, "error": null}'
        exit 0
    }
    default { '{"ok": false}'; exit 1 }
}
'@
    $script:fakeComfy = Join-Path $script:work 'fake-comfy.ps1'
    [IO.File]::WriteAllText($script:fakeComfy, $fake, (New-Object Text.UTF8Encoding($false)))

    function Get-FreePort {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
    }
    function Start-Listener {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $l.Start(); return $l
    }
    # One run of the script in a fresh pwsh, with its own state folder. Returns text, code and
    # the folders, so a test can read the calls and the workflow copy.
    function Invoke-Image {
        param([string[]]$Arguments, [int]$Port, [string]$Mode = '', [string]$Name = ([guid]::NewGuid().ToString('N').Substring(0, 8)), [string[]]$TemplateArgs = $null)
        $dir = Join-Path $script:work $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $out = Join-Path $dir 'out'
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        $env:FAKE_COMFY_DIR = $dir
        $env:FAKE_COMFY_MODE = $Mode
        if (-not $TemplateArgs) { $TemplateArgs = @('-Template', $script:template) }
        $a = @('-NoProfile', '-File', $script:newImage) + $Arguments + $TemplateArgs + @(
            '-OutputDir', $out, '-JobsDir', (Join-Path $dir 'jobs'),
            '-Comfy', $script:fakeComfy, '-Port', $Port, '-StartupTimeoutSec', 2)
        $text = & pwsh @a 2>&1 | Out-String
        $code = $LASTEXITCODE
        $env:FAKE_COMFY_DIR = $null; $env:FAKE_COMFY_MODE = $null
        $calls = @()
        $callLog = Join-Path $dir 'calls.log'
        if (Test-Path -LiteralPath $callLog) { $calls = @(Get-Content -LiteralPath $callLog) }
        return @{ text = $text; code = $code; dir = $dir; out = $out; calls = $calls; jobs = (Join-Path $dir 'jobs') }
    }
    function Read-Subgraph([string]$Path) {
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
        $nodes = @($j.definitions.subgraphs[0].nodes)
        return @{
            text = ($nodes | Where-Object type -eq 'CLIPTextEncode').widgets_values[0]
            size = @(($nodes | Where-Object type -eq 'EmptySD3LatentImage').widgets_values)
            ks   = @(($nodes | Where-Object type -eq 'KSampler').widgets_values)
            unet = ($nodes | Where-Object type -eq 'UNETLoader').widgets_values[0]
            json = $j
        }
    }
}

Describe 'new-image.ps1' {
    BeforeAll {
        $script:listener = Start-Listener
        $script:upPort = $script:listener.LocalEndpoint.Port
        # A tiny web server that hands out the fixture, for the "fetch the missing template" cases.
        $script:httpPort = Get-FreePort
        $script:httpJob = Start-Job -ArgumentList $script:httpPort, $script:template -ScriptBlock {
            param($port, $file)
            $l = [Net.HttpListener]::new()
            $l.Prefixes.Add("http://127.0.0.1:$port/")
            $l.Start()
            while ($true) {
                $c = $l.GetContext()
                $b = [IO.File]::ReadAllBytes($file)
                $c.Response.OutputStream.Write($b, 0, $b.Length)
                $c.Response.Close()
            }
        }
        $up = $false
        foreach ($i in 1..50) {
            $t = [Net.Sockets.TcpClient]::new()
            try { $t.Connect('127.0.0.1', $script:httpPort); $up = $true; break } catch { Start-Sleep -Milliseconds 200 } finally { $t.Dispose() }
        }
        if (-not $up) { throw 'the test web server did not start' }
    }
    AfterAll {
        $script:listener.Stop()
        Stop-Job $script:httpJob -ErrorAction SilentlyContinue
        Remove-Job $script:httpJob -Force -ErrorAction SilentlyContinue
    }

    It 'exists next to the template it copies' {
        $script:newImage | Should -Exist
        $script:template | Should -Exist
    }

    It 'refuses to run without a prompt' {
        $r = Invoke-Image -Arguments @() -Port $script:upPort
        $r.code | Should -Not -Be 0
        $r.calls | Should -BeNullOrEmpty
    }

    It 'sets prompt, size and seed in the copy and changes nothing else' {
        $before = (Get-FileHash -LiteralPath $script:template).Hash
        $r = Invoke-Image -Arguments @('-Prompt', 'a cat watching the moon at night', '-Width', '768', '-Height', '512', '-Seed', '4242') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        (Get-FileHash -LiteralPath $script:template).Hash | Should -Be $before
        $copies = @(Get-ChildItem -LiteralPath $r.jobs -Filter '*.json')
        $copies.Count | Should -Be 1
        $orig = Read-Subgraph $script:template
        $copy = Read-Subgraph $copies[0].FullName
        $copy.text | Should -Be 'a cat watching the moon at night'
        $copy.size[0] | Should -Be 768
        $copy.size[1] | Should -Be 512
        $copy.size[2] | Should -Be $orig.size[2]
        $copy.ks[0] | Should -Be 4242
        # steps, cfg, sampler, model name: untouched
        ($copy.ks[1..($copy.ks.Count - 1)] -join ',') | Should -Be ($orig.ks[1..($orig.ks.Count - 1)] -join ',')
        $copy.unet | Should -Be $orig.unet
        # the submitted workflow is the copy
        (Read-Subgraph (Join-Path $r.dir 'last-workflow.json')).text | Should -Be 'a cat watching the moon at night'
    }

    It 'prints the full image path and then the seed' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '77') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        $lines = @($r.text -split "`r?`n" | Where-Object { $_.Trim() })
        $lines[-2] | Should -Be (Join-Path $r.out 'z-image-turbo_00001_.png')
        $lines[-1] | Should -Match '^Seed:? 77$'
    }

    It 'starts nothing when the server already answers, and always submits with --where local' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        @($r.calls | Where-Object { $_ -like 'launch*' }).Count | Should -Be 0
        $run = @($r.calls | Where-Object { $_ -like 'run *' })
        $run.Count | Should -Be 1
        $run[0] | Should -Match '--where local'
        $run[0] | Should -Match '--wait'
    }

    It 'never calls setup, generate or cloud, whatever happens' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Count', '2', '-Seed', '1') -Port $script:upPort
        @($r.calls | Where-Object { $_ -match '^(setup|generate|cloud)' }).Count | Should -Be 0
    }

    It 'makes -Count images with consecutive seeds' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Count', '2', '-Seed', '10') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        @($r.calls | Where-Object { $_ -like 'run *' }).Count | Should -Be 2
        $r.text | Should -Match 'z-image-turbo_00001_\.png'
        $r.text | Should -Match 'z-image-turbo_00002_\.png'
        $r.text | Should -Match 'Seed:? 10'
        $r.text | Should -Match 'Seed:? 11'
    }

    It 'draws a random seed when none is given, and prints it' {
        $a = Invoke-Image -Arguments @('-Prompt', 'a red fox') -Port $script:upPort
        $b = Invoke-Image -Arguments @('-Prompt', 'a red fox') -Port $script:upPort
        $sa = [regex]::Match($a.text, 'Seed:? (\d+)').Groups[1].Value
        $sb = [regex]::Match($b.text, 'Seed:? (\d+)').Groups[1].Value
        $sa | Should -Not -BeNullOrEmpty
        $sa | Should -Not -Be $sb
    }

    It 'hands a hostile prompt over as data, not as a command' {
        $evil = 'Katze "Mond" ' + [char]0x00E4 + '; $(Get-Date); `whoami` & del *'
        $r = Invoke-Image -Arguments @('-Prompt', $evil, '-Seed', '5') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        (Read-Subgraph (Join-Path $r.dir 'last-workflow.json')).text | Should -Be $evil
    }

    It 'rejects a size outside the allowed range' {
        $r = Invoke-Image -Arguments @('-Prompt', 'x', '-Width', '50') -Port $script:upPort
        $r.code | Should -Not -Be 0
        $r.calls | Should -BeNullOrEmpty
    }

    It 'starts ComfyUI in the background when nothing answers, and gives up with exit 1 if it never does' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port (Get-FreePort)
        $r.code | Should -Be 1
        $r.calls[0] | Should -Be 'launch --background'
        @($r.calls | Where-Object { $_ -like 'run *' }).Count | Should -Be 0
    }

    It 'explains a CUDA out-of-memory error in German and exits 1' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort -Mode 'oom'
        $r.code | Should -Be 1
        $r.text | Should -Match 'Grafikspeicher'
        foreach ($p in 'VoiceStudio', 'LM Studio', 'Ollama', 'OBS') { $r.text | Should -Match $p }
        @($r.calls | Where-Object { $_ -like 'run *' }).Count | Should -Be 1 -Because 'no silent retry with another model'
    }

    It 'does not call an error "memory" because a word contains room, zoom or Bloom' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort -Mode 'bloom'
        $r.code | Should -Be 1
        $r.text | Should -Not -Match 'Grafikspeicher'
        $r.text | Should -Match 'BloomFilter' -Because 'the real error is shown'
    }

    It 'says so in German when the tool ends without its final answer, instead of crashing' {
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort -Mode 'noenvelope'
        $r.code | Should -Be 1
        $r.text | Should -Match 'Antwort'
        $r.text | Should -Not -Match 'ParameterBinding|ConvertFrom-Json'
    }

    It 'fetches a missing template from the pinned address and checks its hash' {
        $target = Join-Path $script:work 'fetched-template.json'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        $url = "http://127.0.0.1:$($script:httpPort)/image_z_image_turbo.json"
        $hash = (Get-FileHash -LiteralPath $script:template -Algorithm SHA256).Hash
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '3') -Port $script:upPort -TemplateArgs @('-Template', $target, '-TemplateUrl', $url, '-TemplateSha256', $hash)
        $r.code | Should -Be 0 -Because $r.text
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should -Be $hash
        @($r.calls | Where-Object { $_ -like 'run *' }).Count | Should -Be 1
    }

    It 'refuses a fetched template whose hash is wrong, and keeps nothing' {
        $target = Join-Path $script:work 'wrong-hash-template.json'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        $url = "http://127.0.0.1:$($script:httpPort)/image_z_image_turbo.json"
        $r = Invoke-Image -Arguments @('-Prompt', 'a red fox', '-Seed', '3') -Port $script:upPort -TemplateArgs @('-Template', $target, '-TemplateUrl', $url, '-TemplateSha256', ('0' * 64))
        $r.code | Should -Be 1
        $target | Should -Not -Exist
        $r.calls | Should -BeNullOrEmpty
    }

    It '-Stop stops ComfyUI and needs no prompt' {
        $r = Invoke-Image -Arguments @('-Stop') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        $r.calls | Should -Be @('stop')
    }
}
