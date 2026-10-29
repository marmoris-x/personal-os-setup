# Pester 5.9.1 (pinned). The /video skill script: new-video.ps1 drives ComfyUI through the
# comfy command (comfy-cli), local only, LTX-2.3 the one model (ADR 0022).
#
# What is measured here, with a stand-in for `comfy` (a small script that records every call and
# answers like the real one did on 2026-10-28): the workflow copy gets the prompt, the size, the
# duration and the seed in the right nodes of the pinned LTX template and nothing else changes;
# the server is started only when nothing answers on the port; every run goes out with
# `--where local`; a CUDA out-of-memory answer ends in a German message with exit 1 and no
# second model; the free-RAM guard refuses before anything is started; ComfyUI is stopped after
# the clip only when this run started it; `-Stop` stops and nothing more. The real GPU run is
# the acceptance proof, not a unit test.
#
# The repo copies of the templates are not kept (the privacy scan reads a decimal number in them
# as a 12-digit id), so the fixtures are trimmed copies with the same node structure, and every
# test hands the paths over explicitly.
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:newVideo = Join-Path $repoRoot 'home/.claude/skills/video/scripts/new-video.ps1'
    $script:templateT2V = Join-Path $PSScriptRoot 'fixtures/video-ltx-t2v-minimal.json'
    $script:templateI2V = Join-Path $PSScriptRoot 'fixtures/video-ltx-i2v-minimal.json'

    $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
    $script:work = Join-Path $scratchRoot 'video-script'
    if (Test-Path -LiteralPath $script:work) { Remove-Item -LiteralPath $script:work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $script:work | Out-Null

    # The stand-in for `comfy`. It logs its arguments, keeps the last submitted workflow, and,
    # for `run`, writes a stand-in mp4 where the script expects the output and answers with the
    # event lines and the final envelope of the real tool. Mode `serve` lets `launch` start a
    # detached TCP listener, so a script that launched the server really finds it up.
    $fake = @'
$log = Join-Path $env:FAKE_COMFY_DIR 'calls.log'
Add-Content -LiteralPath $log -Value ($args -join ' ')
switch ($args[0]) {
    'launch' {
        if ($env:FAKE_COMFY_SERVE -eq '1') {
            $exe = (Get-Process -Id $PID).Path
            $p = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-File', (Join-Path $env:FAKE_COMFY_DIR 'listener.ps1'), '-Port', $env:FAKE_COMFY_PORT) -WindowStyle Hidden -PassThru
            Set-Content -LiteralPath (Join-Path $env:FAKE_COMFY_DIR 'listener.pid') -Value $p.Id
        }
        '{"ok": true}'; exit 0
    }
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
        if ($env:FAKE_COMFY_MODE -eq 'noenvelope') {
            '{"schema":"event/1","type":"progress","completed":8,"total":8}'
            exit 0
        }
        $sub = 'video'
        $name = 'clip_{0:D5}_.mp4' -f $n
        $dir = Join-Path $env:FAKE_COMFY_OUT $sub
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir $name) -Value 'not a real mp4'
        $url = 'http://127.0.0.1:8188/view?filename=' + $name + '&subfolder=' + $sub + '&type=output'
        '{"schema": "event/1", "type": "progress", "node": "75", "completed": 8, "total": 8}'
        '{"schema": "event/1", "type": "output", "url": "' + $url + '"}'
        '{"schema": "envelope/1", "type": "envelope", "ok": true, "command": "run", "data": {"status": "completed", "outputs": ["' + $url + '"]}, "error": null}'
        exit 0
    }
    default { '{"ok": false}'; exit 1 }
}
'@
    $script:fakeComfy = Join-Path $script:work 'fake-comfy.ps1'
    [IO.File]::WriteAllText($script:fakeComfy, $fake, (New-Object Text.UTF8Encoding($false)))

    $listener = @'
param([int]$Port)
$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$l.Start()
while ($true) { try { $c = $l.AcceptTcpClient(); $c.Close() } catch { break } }
'@
    [IO.File]::WriteAllText((Join-Path $script:work 'listener.ps1'), $listener, (New-Object Text.UTF8Encoding($false)))

    # The stand-in for nvidia-smi. On Windows the real command lists EVERY graphics process,
    # desktop apps included, and reports [N/A] instead of MiB. `busy` is a model program holding
    # the card; `desktop` is the normal desktop noise that must not block a clip.
    $gpu = @'
if ($env:FAKE_GPU_MODE -eq 'busy') { '4242, C:\Program Files\LM Studio\LM Studio.exe, [N/A]'; exit 0 }
if ($env:FAKE_GPU_MODE -eq 'desktop') { '100, C:\Windows\explorer.exe, [N/A]'; '101, C:\Windows\SystemApps\StartMenuExperienceHost.exe, [N/A]'; exit 0 }
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $script:work 'fake-gpu.ps1'), $gpu, (New-Object Text.UTF8Encoding($false)))

    function Get-FreePort {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
    }
    function Start-Listener {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $l.Start(); return $l
    }
    function Stop-FakeListener($Run) {
        $pidFile = Join-Path $Run.dir 'listener.pid'
        if (Test-Path -LiteralPath $pidFile) {
            $id = [int](Get-Content -LiteralPath $pidFile)
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
    }
    # One run of the script in a fresh pwsh, with its own state folder. Returns text, code and
    # the folders, so a test can read the calls and the workflow copy.
    function Invoke-Video {
        param([string[]]$Arguments, [int]$Port, [string]$Mode = '', [switch]$Serve,
            [string]$Name = ([guid]::NewGuid().ToString('N').Substring(0, 8)),
            [string[]]$TemplateArgs = $null, [int]$Timeout = 8)
        $dir = Join-Path $script:work $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:work 'listener.ps1') -Destination $dir -Force
        $out = Join-Path $dir 'out'
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        $env:FAKE_COMFY_DIR = $dir
        $env:FAKE_COMFY_MODE = $Mode
        $env:FAKE_COMFY_OUT = $out
        $env:FAKE_COMFY_PORT = [string]$Port
        $env:FAKE_COMFY_SERVE = if ($Serve) { '1' } else { '' }
        if (-not $TemplateArgs) { $TemplateArgs = @('-Template', $script:templateT2V) }
        # Every test fixture is not the pinned official template, so the script's hash check of
        # an existing template needs the fixture's own hash unless the test passes one.
        if (-not ($TemplateArgs -contains '-TemplateSha256')) {
            $tplPath = $script:templateT2V
            $at = [array]::IndexOf($TemplateArgs, '-Template')
            if ($at -ge 0) { $tplPath = $TemplateArgs[$at + 1] }
            if (Test-Path -LiteralPath $tplPath) {
                $TemplateArgs += @('-TemplateSha256', (Get-FileHash -LiteralPath $tplPath -Algorithm SHA256).Hash)
            }
        }
        $a = @('-NoProfile', '-NonInteractive', '-File', $script:newVideo) + $Arguments + $TemplateArgs + @(
            '-OutputDir', $out, '-JobsDir', (Join-Path $dir 'jobs'), '-InputDir', (Join-Path $dir 'input'),
            '-Comfy', $script:fakeComfy, '-NvidiaSmi', (Join-Path $script:work 'fake-gpu.ps1'),
            '-Port', $Port, '-StartupTimeoutSec', $Timeout, '-MinFreeGiB', 0)
        $text = & pwsh @a 2>&1 | Out-String
        $code = $LASTEXITCODE
        $env:FAKE_COMFY_DIR = $null; $env:FAKE_COMFY_MODE = $null; $env:FAKE_COMFY_OUT = $null
        $env:FAKE_COMFY_PORT = $null; $env:FAKE_COMFY_SERVE = $null
        $calls = @()
        $callLog = Join-Path $dir 'calls.log'
        if (Test-Path -LiteralPath $callLog) { $calls = @(Get-Content -LiteralPath $callLog) }
        return @{ text = $text; code = $code; dir = $dir; out = $out; calls = $calls; jobs = (Join-Path $dir 'jobs') }
    }
    function Read-Template([string]$Path) {
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
        $nodes = @($j.definitions.subgraphs[0].nodes)
        $inst = @($j.nodes | Where-Object { $_.type -match '^[0-9a-f]{8}-' })[0]
        return @{
            inst    = @($inst.widgets_values)
            text    = ($nodes | Where-Object type -eq 'PrimitiveStringMultiline').widgets_values[0]
            width   = ($nodes | Where-Object { $_.type -eq 'PrimitiveInt' -and $_.title -eq 'Width' }).widgets_values[0]
            height  = ($nodes | Where-Object { $_.type -eq 'PrimitiveInt' -and $_.title -eq 'Height' }).widgets_values[0]
            seconds = ($nodes | Where-Object { $_.type -eq 'PrimitiveInt' -and $_.title -eq 'Duration' }).widgets_values[0]
            fps     = ($nodes | Where-Object { $_.type -eq 'PrimitiveInt' -and $_.title -eq 'Frame Rate' }).widgets_values[0]
            seed    = @(($nodes | Where-Object type -eq 'RandomNoise').widgets_values)
            enhance = @(($nodes | Where-Object { $_.type -eq 'PrimitiveBoolean' -and $_.title -match 'Enhance' }).widgets_values)
            image   = @(($j.nodes | Where-Object type -eq 'LoadImage'))
            save    = @(($j.nodes | Where-Object type -eq 'SaveVideo').widgets_values)
            json    = $j
        }
    }
}

Describe 'new-video.ps1' {
    BeforeAll {
        $script:listener = Start-Listener
        $script:upPort = $script:listener.LocalEndpoint.Port
        # A tiny web server that hands out a fixture, for the "fetch the missing template" cases.
        $script:httpPort = Get-FreePort
        $script:httpJob = Start-Job -ArgumentList $script:httpPort, $script:templateT2V -ScriptBlock {
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

    It 'exists next to the templates it copies' {
        $script:newVideo | Should -Exist
        $script:templateT2V | Should -Exist
        $script:templateI2V | Should -Exist
    }

    It 'refuses to run without a prompt' {
        $r = Invoke-Video -Arguments @() -Port $script:upPort
        $r.code | Should -Not -Be 0
        $r.calls | Should -BeNullOrEmpty
    }

    It 'sets prompt, size, duration and seed in the copy and changes nothing else' {
        $before = (Get-FileHash -LiteralPath $script:templateT2V).Hash
        $r = Invoke-Video -Arguments @('-Prompt', 'a fox walks through snow', '-Width', '1280', '-Height', '704', '-Seconds', '5', '-Seed', '4242') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        (Get-FileHash -LiteralPath $script:templateT2V).Hash | Should -Be $before
        $copies = @(Get-ChildItem -LiteralPath $r.jobs -Filter '*.json')
        $copies.Count | Should -Be 1
        $orig = Read-Template $script:templateT2V
        $copy = Read-Template $copies[0].FullName
        $copy.inst[0] | Should -Be 'a fox walks through snow'
        $copy.inst[1] | Should -BeFalse
        $copy.inst[2] | Should -Be 1280
        $copy.inst[3] | Should -Be 704
        $copy.inst[4] | Should -Be 5
        $copy.inst[5] | Should -Be 24
        $copy.inst[6] | Should -Be 4242
        $copy.text | Should -Be 'a fox walks through snow'
        $copy.width | Should -Be 1280
        $copy.height | Should -Be 704
        $copy.seconds | Should -Be 5
        $copy.fps | Should -Be 24
        $copy.seed[0] | Should -Be 4242
        $copy.seed[1] | Should -Be 'fixed'
        $copy.enhance[0] | Should -BeFalse
        # the model file names are untouched
        ($copy.inst[7..($copy.inst.Count - 1)] -join ',') | Should -Be ($orig.inst[7..($orig.inst.Count - 1)] -join ',')
        $copy.save[0] | Should -Match '^video/'
        # the submitted workflow is the copy
        (Read-Template (Join-Path $r.dir 'last-workflow.json')).text | Should -Be 'a fox walks through snow'
    }

    It 'prints the full clip path and then the seed' {
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '77') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        $lines = @($r.text -split "`r?`n" | Where-Object { $_.Trim() })
        $lines | Should -Contain (Join-Path (Join-Path $r.out 'video') 'clip_00001_.mp4')
        $lines[-1] | Should -Match '^Seed:? 77$'
    }

    It 'starts nothing when the server already answers, and always submits with --where local' {
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        @($r.calls | Where-Object { $_ -like 'launch*' }).Count | Should -Be 0
        @($r.calls | Where-Object { $_ -like 'stop*' }).Count | Should -Be 0
        $run = @($r.calls | Where-Object { $_ -like 'run *' })
        $run.Count | Should -Be 1
        $run[0] | Should -Match '--where local'
        $run[0] | Should -Match '--wait'
    }

    It 'never calls setup, generate or cloud, whatever happens' {
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort
        @($r.calls | Where-Object { $_ -match '^(setup|generate|cloud)' }).Count | Should -Be 0
    }

    It 'draws a random seed when none is given, and prints it' {
        $a = Invoke-Video -Arguments @('-Prompt', 'a red fox') -Port $script:upPort
        $b = Invoke-Video -Arguments @('-Prompt', 'a red fox') -Port $script:upPort
        $sa = [regex]::Match($a.text, 'Seed:? (\d+)').Groups[1].Value
        $sb = [regex]::Match($b.text, 'Seed:? (\d+)').Groups[1].Value
        $sa | Should -Not -BeNullOrEmpty
        $sa | Should -Not -Be $sb
    }

    It 'hands a hostile prompt over as data, not as a command' {
        $evil = 'Katze "Mond" ' + [char]0x00E4 + '; $(Get-Date); `whoami` & del *'
        $r = Invoke-Video -Arguments @('-Prompt', $evil, '-Seed', '5') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        $copy = Read-Template (Join-Path $r.dir 'last-workflow.json')
        $copy.text | Should -Be $evil
        $copy.inst[0] | Should -Be $evil
    }

    It 'rejects a size outside the measured range' {
        foreach ($args in @(@('-Width', '4096'), @('-Height', '1080'), @('-Width', '128'))) {
            $r = Invoke-Video -Arguments (@('-Prompt', 'x') + $args) -Port $script:upPort
            $r.code | Should -Not -Be 0 -Because ($args -join ' ')
            $r.calls | Should -BeNullOrEmpty
        }
    }

    It 'rejects an odd width or height the half-size first stage cannot use' {
        foreach ($args in @(@('-Width', '1279'), @('-Height', '719'))) {
            $r = Invoke-Video -Arguments (@('-Prompt', 'x') + $args) -Port $script:upPort
            $r.code | Should -Not -Be 0 -Because ($args -join ' ')
            $r.text | Should -Match 'gerade'
            $r.calls | Should -BeNullOrEmpty
        }
    }

    It 'refuses while another program holds the GPU, and names it' {
        $dir = Join-Path $script:work ('gpu-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:work 'listener.ps1') -Destination $dir -Force
        $out = Join-Path $dir 'out'; New-Item -ItemType Directory -Force -Path $out | Out-Null
        $env:FAKE_COMFY_DIR = $dir; $env:FAKE_GPU_MODE = 'busy'
        $hash = (Get-FileHash -LiteralPath $script:templateT2V -Algorithm SHA256).Hash
        $a = @('-NoProfile', '-NonInteractive', '-File', $script:newVideo, '-Prompt', 'a red fox',
            '-Template', $script:templateT2V, '-TemplateSha256', $hash, '-OutputDir', $out,
            '-JobsDir', (Join-Path $dir 'jobs'), '-InputDir', (Join-Path $dir 'input'),
            '-Comfy', $script:fakeComfy, '-NvidiaSmi', (Join-Path $script:work 'fake-gpu.ps1'),
            '-Port', (Get-FreePort), '-StartupTimeoutSec', 2, '-MinFreeGiB', 0)
        $text = & pwsh @a 2>&1 | Out-String
        $code = $LASTEXITCODE
        $env:FAKE_COMFY_DIR = $null; $env:FAKE_GPU_MODE = $null
        $code | Should -Be 1
        $text | Should -Match 'LM Studio'
        Join-Path $dir 'calls.log' | Should -Not -Exist
    }

    It 'does not mistake a desktop program on the GPU list for a model holding the card' {
        $dir = Join-Path $script:work ('gpu-desktop-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:work 'listener.ps1') -Destination $dir -Force
        $out = Join-Path $dir 'out'; New-Item -ItemType Directory -Force -Path $out | Out-Null
        $env:FAKE_COMFY_DIR = $dir; $env:FAKE_GPU_MODE = 'desktop'; $env:FAKE_COMFY_OUT = $out
        $hash = (Get-FileHash -LiteralPath $script:templateT2V -Algorithm SHA256).Hash
        $a = @('-NoProfile', '-NonInteractive', '-File', $script:newVideo, '-Prompt', 'a red fox',
            '-Template', $script:templateT2V, '-TemplateSha256', $hash, '-OutputDir', $out,
            '-JobsDir', (Join-Path $dir 'jobs'), '-InputDir', (Join-Path $dir 'input'),
            '-Comfy', $script:fakeComfy, '-NvidiaSmi', (Join-Path $script:work 'fake-gpu.ps1'),
            '-Port', $script:upPort, '-StartupTimeoutSec', 2, '-MinFreeGiB', 0)
        $text = & pwsh @a 2>&1 | Out-String
        $code = $LASTEXITCODE
        $env:FAKE_COMFY_DIR = $null; $env:FAKE_GPU_MODE = $null; $env:FAKE_COMFY_OUT = $null
        $code | Should -Be 0 -Because $text
        @(Get-Content -LiteralPath (Join-Path $dir 'calls.log') | Where-Object { $_ -like 'run *' }).Count | Should -Be 1
    }

    It 'refuses an existing template whose bytes no longer match the pinned hash' {
        $bad = Join-Path $script:work 'tampered-template.json'
        $good = [IO.File]::ReadAllText($script:templateT2V)
        [IO.File]::WriteAllText($bad, $good.Replace('1280', '1024'), (New-Object Text.UTF8Encoding($false)))
        $goodHash = (Get-FileHash -LiteralPath $script:templateT2V -Algorithm SHA256).Hash
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '3') -Port $script:upPort -TemplateArgs @('-Template', $bad, '-TemplateSha256', $goodHash)
        $r.code | Should -Be 1
        $r.text | Should -Match 'Pruefwert'
        $r.calls | Should -BeNullOrEmpty
    }

    It 'rejects a duration outside the measured range' {
        foreach ($s in @('0', '12')) {
            $r = Invoke-Video -Arguments @('-Prompt', 'x', '-Seconds', $s) -Port $script:upPort
            $r.code | Should -Not -Be 0 -Because $s
            $r.calls | Should -BeNullOrEmpty
        }
    }

    It 'refuses a RAM level below the measured ComfyUI peak plus 4 GiB, in German, naming programs' {
        $dir = Join-Path $script:work 'ramguard'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $out = Join-Path $dir 'out'; New-Item -ItemType Directory -Force -Path $out | Out-Null
        $env:FAKE_COMFY_DIR = $dir
        $a = @('-NoProfile', '-NonInteractive', '-File', $script:newVideo, '-Prompt', 'a red fox',
            '-Template', $script:templateT2V, '-OutputDir', $out, '-JobsDir', (Join-Path $dir 'jobs'),
            '-InputDir', (Join-Path $dir 'input'), '-Comfy', $script:fakeComfy, '-Port', $script:upPort,
            '-StartupTimeoutSec', 2, '-MinFreeGiB', 9999)
        $text = & pwsh @a 2>&1 | Out-String
        $code = $LASTEXITCODE
        $env:FAKE_COMFY_DIR = $null
        $code | Should -Be 1
        $text | Should -Match 'Arbeitsspeicher'
        $text | Should -Match 'GiB'
        $text | Should -Match 'Schliesse'
        @($text -split "`r?`n" | Where-Object { $_ -match '^\s+- \S' }).Count | Should -BeGreaterThan 0
        Join-Path $dir 'calls.log' | Should -Not -Exist
    }

    It 'starts ComfyUI in the background when nothing answers, and gives up with exit 1 if it never does' {
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port (Get-FreePort)
        $r.code | Should -Be 1
        $r.calls[0] | Should -Be 'launch --background'
        @($r.calls | Where-Object { $_ -like 'run *' }).Count | Should -Be 0
    }

    It 'stops ComfyUI after the clip when this run started it' {
        $port = Get-FreePort
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $port -Serve -Timeout 15
        $r.code | Should -Be 0 -Because $r.text
        @($r.calls | Where-Object { $_ -like 'launch*' }).Count | Should -Be 1
        @($r.calls | Where-Object { $_ -like 'stop*' }).Count | Should -Be 1
        Stop-FakeListener $r
    }

    It 'leaves ComfyUI running with -KeepRunning' {
        $port = Get-FreePort
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '1', '-KeepRunning') -Port $port -Serve -Timeout 15
        $r.code | Should -Be 0 -Because $r.text
        @($r.calls | Where-Object { $_ -like 'stop*' }).Count | Should -Be 0
        Stop-FakeListener $r
    }

    It 'explains a CUDA out-of-memory error in German and exits 1 without another model' {
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort -Mode 'oom'
        $r.code | Should -Be 1
        $r.text | Should -Match 'Grafikspeicher'
        $r.text | Should -Match 'Arbeitsspeicher'
        @($r.calls | Where-Object { $_ -like 'run *' }).Count | Should -Be 1 -Because 'no silent retry with another model'
        @($r.calls | Where-Object { $_ -match 'wan' }).Count | Should -Be 0
    }

    It 'says so in German when the tool ends without its final answer, instead of crashing' {
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '1') -Port $script:upPort -Mode 'noenvelope'
        $r.code | Should -Be 1
        $r.text | Should -Match 'Antwort'
        $r.text | Should -Not -Match 'ParameterBinding|ConvertFrom-Json'
    }

    It 'fetches a missing template from the pinned address and checks its hash' {
        $target = Join-Path $script:work 'fetched-template.json'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        $url = "http://127.0.0.1:$($script:httpPort)/video_ltx2_3_t2v.json"
        $hash = (Get-FileHash -LiteralPath $script:templateT2V -Algorithm SHA256).Hash
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '3') -Port $script:upPort -TemplateArgs @('-Template', $target, '-TemplateUrl', $url, '-TemplateSha256', $hash)
        $r.code | Should -Be 0 -Because $r.text
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should -Be $hash
        @($r.calls | Where-Object { $_ -like 'run *' }).Count | Should -Be 1
    }

    It 'refuses a fetched template whose hash is wrong, and keeps nothing' {
        $target = Join-Path $script:work 'wrong-hash-template.json'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        $url = "http://127.0.0.1:$($script:httpPort)/video_ltx2_3_t2v.json"
        $r = Invoke-Video -Arguments @('-Prompt', 'a red fox', '-Seed', '3') -Port $script:upPort -TemplateArgs @('-Template', $target, '-TemplateUrl', $url, '-TemplateSha256', ('0' * 64))
        $r.code | Should -Be 1
        $target | Should -Not -Exist
        $r.calls | Should -BeNullOrEmpty
    }

    It 'makes an image-to-video clip from the one named picture and copies it under a safe name' {
        $pic = Join-Path $script:work 'start.png'
        [IO.File]::WriteAllBytes($pic, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
        $r = Invoke-Video -Arguments @('-Prompt', 'she walks toward the camera', '-Image', $pic, '-Seed', '9') -Port $script:upPort -TemplateArgs @('-Template', $script:templateI2V)
        $r.code | Should -Be 0 -Because $r.text
        $copy = Read-Template (Join-Path $r.dir 'last-workflow.json')
        $copy.image.Count | Should -Be 1
        $copiedName = [string]$copy.image[0].widgets_values[0]
        $copiedName | Should -Not -Match '\\|/'
        $copiedName | Should -Match '\.png$'
        Join-Path (Join-Path $r.dir 'input') $copiedName | Should -Exist
        $copy.image[0].mode | Should -Be 0
    }

    It 'refuses an image path that is not a picture or does not exist' {
        $txt = Join-Path $script:work 'note.txt'
        Set-Content -LiteralPath $txt -Value 'x'
        foreach ($p in @($txt, (Join-Path $script:work 'missing.png'))) {
            $r = Invoke-Video -Arguments @('-Prompt', 'x', '-Image', $p) -Port $script:upPort -TemplateArgs @('-Template', $script:templateI2V)
            $r.code | Should -Not -Be 0 -Because $p
            $r.calls | Should -BeNullOrEmpty
        }
    }

    It '-Stop stops ComfyUI and needs no prompt' {
        $r = Invoke-Video -Arguments @('-Stop') -Port $script:upPort
        $r.code | Should -Be 0 -Because $r.text
        $r.calls | Should -Be @('stop')
    }
}
