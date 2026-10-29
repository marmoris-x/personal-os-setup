# new-video.ps1 - make a clip with ComfyUI on this PC's GPU, local only, LTX-2.3 (ADR 0022).
#
# Usage:  pwsh -NoProfile -File new-video.ps1 -Prompt "<English text>" [-Width 1280] [-Height 720]
#                                               [-Seconds 5] [-Image <path>] [-Seed N] [-KeepRunning]
#         pwsh -NoProfile -File new-video.ps1 -Stop
#
# It copies the pinned LTX-2.3 template (text to video, or image to video when -Image is given,
# next to the SKILL.md), sets the prompt, the size, the duration, the frame rate (24) and the
# seed in the copy, starts ComfyUI with `comfy launch --background` when nothing answers on
# 127.0.0.1:8188, submits the copy with `comfy run --where local --wait` and prints the full path
# of the clip and the seed, then a 2x2 contact sheet. ComfyUI is stopped afterwards when this run
# started it (-KeepRunning keeps it); a server that was already running is never touched.
#
# Before anything starts, the free RAM is compared with the floor of 2026-10-29: the ComfyUI peak
# working set is 17,214.6 MiB (16.81 GiB), and the two clean 5 s runs started at 15.94 and
# 16.19 GiB free, so the guard sits at 15.9 GiB - the lowest value a clean run was measured at.
# Below that the script refuses in German and names the programs to close. The launch options
# (output folder,
# --disable-partner-nodes, port) are saved once with `comfy set-default`. This script never calls
# `comfy setup`, `comfy generate` or anything that talks to Comfy Cloud.
[CmdletBinding(DefaultParameterSetName = 'Make')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Make')]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 3000)]
    [string]$Prompt,
    # The measured range: 1280x720 with 121 frames was the largest clip of the test set
    # (2026-10-28/29). Width and height are even numbers, as the template's half-size first stage
    # needs them.
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(256, 1280)]
    [int]$Width = 1280,
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(256, 720)]
    [int]$Height = 720,
    # Whole seconds at 24 fps. LTX-2.3 needs 8n+1 frames; 24 s + 1 is always a multiple of 8, so
    # every whole second obeys the rule. Five seconds (121 frames) is the measured maximum.
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(1, 5)]
    [int]$Seconds = 5,
    [Parameter(ParameterSetName = 'Make')]
    [string]$Image,
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(0, 2147483000)]
    [long]$Seed = -1,
    [Parameter(ParameterSetName = 'Make')]
    [switch]$KeepRunning,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stop')]
    [switch]$Stop,

    # Everything below exists so the tests can point the script at a stand-in.
    [string]$Template,
    [string]$TemplateUrl,
    [string]$TemplateSha256,
    [string]$OutputDir = '{{DEV}}\Temp\media',
    [string]$JobsDir = (Join-Path $OutputDir '.comfy-jobs'),
    [string]$InputDir = '{{DEV}}\External\ComfyUI\input',
    [string]$Comfy = 'comfy',
    [string]$NvidiaSmi = 'nvidia-smi',
    [int]$Port = 8188,
    [int]$StartupTimeoutSec = 120,
    # 15.94 GiB was the lowest free RAM of a clean run (LTX-2.3, 5 s 1280x720, 2026-10-29).
    [double]$MinFreeGiB = 15.9
)

$ErrorActionPreference = 'Stop'
$Fps = 24
$T2VName = 'video_ltx2_3_t2v.json'
$I2VName = 'video_ltx2_3_i2v.json'
$T2VUrl = 'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/67984637eefcd4825dcf5c134e39034785be1682/templates/video_ltx2_3_t2v.json'
$I2VUrl = 'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/67984637eefcd4825dcf5c134e39034785be1682/templates/video_ltx2_3_i2v.json'
$T2VSha = '7A6C13E24754C2525D176F439A4E1CE230B15D13928F6C303A62C643281A2DA9'
$I2VSha = '860A9CEA831E5C49E25CE91C6A4FE9E932FFA9A2A0666C911C094651F15E0528'

function Test-ServerUp([int]$P) {
    $c = [Net.Sockets.TcpClient]::new()
    try {
        $t = $c.ConnectAsync('127.0.0.1', $P)
        return ($t.Wait(1000) -and $c.Connected)
    }
    catch { return $false }
    finally { $c.Dispose() }
}

if ($Stop) {
    & $Comfy stop | Out-Null
    exit $LASTEXITCODE
}

$skillDir = Split-Path -Parent $PSScriptRoot
if (-not $Template) { $Template = Join-Path $skillDir $(if ($Image) { $I2VName } else { $T2VName }) }
if (-not $TemplateUrl) { $TemplateUrl = $(if ($Image) { $I2VUrl } else { $T2VUrl }) }
if (-not $TemplateSha256) { $TemplateSha256 = $(if ($Image) { $I2VSha } else { $T2VSha }) }

# The template's first stage works on half the requested size, so an odd value would produce a
# fractional dimension. Refuse it clearly instead of letting the graph round silently.
if (($Width % 2) -ne 0 -or ($Height % 2) -ne 0) {
    Write-Output "Breite und Hoehe muessen gerade Zahlen sein (die erste Stufe des LTX-Templates rechnet mit der halben Groesse): $Width x $Height."
    exit 1
}

# --- the free-RAM guard: measured peak + 4 GiB, refuse in German before anything starts --------
$osMem = Get-CimInstance Win32_OperatingSystem
$freeGiB = [math]::Round($osMem.FreePhysicalMemory / 1MB, 2)
if ($freeGiB -lt $MinFreeGiB) {
    Write-Output (('Zu wenig freier Arbeitsspeicher: {0} GiB frei, noetig sind {1} GiB ' +
        '(gemessene ComfyUI-Spitze 16.8 GiB; niedrigster sauberer Lauf 15.94 GiB frei, ' +
        '2026-10-29). Der Clip wird nicht gestartet, damit der Rechner nicht einfriert. ' +
        'Schliesse bitte diese Programme:') -f $freeGiB, $MinFreeGiB)
    $top = @(Get-Process | Where-Object { $_.ProcessName -ne 'Memory Compression' } |
        Group-Object ProcessName |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                GB   = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1GB, 1)
            }
        } | Sort-Object GB -Descending | Select-Object -First 5)
    foreach ($t in $top) { Write-Output ('  - {0} ({1} GB)' -f $t.Name, $t.GB) }
    Write-Output 'Danach das Video-Skript noch einmal starten.'
    exit 1
}

# --- the picture for image to video: only the named file, copied under a name this script picks -
if ($Image) {
    $ext = [IO.Path]::GetExtension($Image).ToLowerInvariant()
    if ($ext -notin @('.png', '.jpg', '.jpeg', '.webp')) {
        Write-Output "Das Startbild muss eine PNG-, JPG- oder WebP-Datei sein: $Image"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $Image -PathType Leaf)) {
        Write-Output "Das Startbild gibt es nicht: $Image"
        exit 1
    }
}

# --- the copy of the template: the node ids come from the JSON, found by node type -------------
function Get-OnlyNode($Nodes, [string]$Type, [string]$Title) {
    $hit = @($Nodes | Where-Object {
        $_.type -eq $Type -and ((-not $Title) -or ($_.title -eq $Title))
    })
    if ($hit.Count -ne 1) { throw "The template must hold exactly one $Type node$(if ($Title) { " titled $Title" }), found $($hit.Count)." }
    return $hit[0]
}

$startedServer = $false
try {
    if (-not (Test-Path -LiteralPath $Template)) {
        $part = $Template + '.part'
        try {
            Invoke-WebRequest -Uri $TemplateUrl -OutFile $part -ErrorAction Stop
            $got = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
            if ($got -ne $TemplateSha256) {
                Write-Output "Die geladene Vorlage hat den falschen Pruefwert (erwartet $TemplateSha256, gefunden $got). Sie wird nicht benutzt."
                exit 1
            }
            Move-Item -LiteralPath $part -Destination $Template
        }
        catch {
            Write-Output "Die Vorlage fehlt und konnte nicht von $TemplateUrl geladen werden: $($_.Exception.Message)"
            exit 1
        }
        finally {
            if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        }
    }
    # The pinned hash also protects an existing file: the settings go into the subgraph instance
    # by position, and a changed promoted-widget order would silently write them into the wrong
    # slots. A template that no longer matches its pinned bytes is never used.
    $gotHash = (Get-FileHash -LiteralPath $Template -Algorithm SHA256).Hash
    if ($gotHash -ne $TemplateSha256) {
        Write-Output "Die Vorlage hat den falschen Pruefwert (erwartet $TemplateSha256, gefunden $gotHash). Sie wird nicht benutzt."
        exit 1
    }

    $workflow = Get-Content -LiteralPath $Template -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $nodes = @($workflow.nodes)
    $subNodes = @()
    foreach ($sg in @($workflow.definitions.subgraphs)) { if ($sg) { $subNodes += @($sg.nodes) } }
    $all = @($nodes + $subNodes)

    # The top-level LTX template is one subgraph instance carrying the promoted settings:
    # prompt, enhance, width, height, duration, frame rate, seed, then the model file names.
    $instance = @($nodes | Where-Object { $_.type -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-' })
    if ($instance.Count -ne 1) { throw "The template must hold exactly one subgraph instance, found $($instance.Count)." }
    $inst = $instance[0]

    $textNode = Get-OnlyNode $all 'PrimitiveStringMultiline' 'Prompt'
    $widthNode = Get-OnlyNode $all 'PrimitiveInt' 'Width'
    $heightNode = Get-OnlyNode $all 'PrimitiveInt' 'Height'
    $secondsNode = Get-OnlyNode $all 'PrimitiveInt' 'Duration'
    $fpsNode = Get-OnlyNode $all 'PrimitiveInt' 'Frame Rate'
    $enhanceNode = @($all | Where-Object { $_.type -eq 'PrimitiveBoolean' -and $_.title -match 'Enhance' })
    if ($enhanceNode.Count -ne 1) { throw "The template must hold exactly one Enchance prompt switch, found $($enhanceNode.Count)." }
    $noiseNode = @($all | Where-Object { $_.type -eq 'RandomNoise' -and $_.widgets_values[1] -ne 'fixed' })
    if ($noiseNode.Count -ne 1) { throw "The template must hold exactly one RandomNoise node in random mode, found $($noiseNode.Count)." }
    $videoNode = Get-OnlyNode $nodes 'SaveVideo' ''

    if ($Seed -lt 0) { $Seed = [long](Get-Random -Minimum 0 -Maximum 2147483000) }

    New-Item -ItemType Directory -Force -Path $JobsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    # --- the server ---------------------------------------------------------------------------
    if (-not (Test-ServerUp $Port)) {
        # Another model program on the card (LM Studio, Ollama, VoiceStudio) would leave ComfyUI
        # no VRAM on this 16 GB card. Name it and start nothing; never stop it ourselves.
        # On Windows nvidia-smi lists EVERY graphics process, desktop apps included, and reports
        # [N/A] instead of MiB (measured 2026-10-29: 24 lines, explorer.exe among them). So the
        # rule is: a known model program by name, or a real reported use of 1 GiB and more.
        $holders = @()
        try {
            foreach ($line in @(& $NvidiaSmi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>$null)) {
                $parts = "$line".Trim() -split ','
                if ($parts.Count -lt 2) { continue }
                $exe = [IO.Path]::GetFileNameWithoutExtension($parts[1].Trim()).ToLowerInvariant()
                $mem = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
                $known = $exe -match '^(voicestudio|lm studio|lms|ollama|ollama_llama_server|koboldcpp|obs|obs64|comfyui)$'
                $big = (($mem -match '^\d+$') -and ([int]$mem -ge 1024))
                if ($known -or $big) {
                    $shown = if ($mem -match '^\d+$') { $mem } else { 'unbekannt' }
                    $holders += [pscustomobject]@{ Name = $parts[1].Trim(); MiB = $shown }
                }
            }
        }
        catch { }
        if ($holders.Count -gt 0) {
            Write-Output 'Der Grafikspeicher ist von einem anderen Programm belegt. Der Clip wird nicht gestartet. Beende bitte:'
            foreach ($h in $holders) { Write-Output ("  - {0} ({1} MiB)" -f $h.Name, $h.MiB) }
            exit 1
        }
        & $Comfy launch --background | Out-Null
        $startedServer = $true
        $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
        while (-not (Test-ServerUp $Port)) {
            if ((Get-Date) -gt $deadline) {
                Write-Output "ComfyUI antwortet nach $StartupTimeoutSec Sekunden nicht auf 127.0.0.1:$Port."
                exit 1
            }
            Start-Sleep -Milliseconds 500
        }
    }

    function Get-VideoPath([string]$Url) {
        $q = [Uri]$Url
        $params = [Web.HttpUtility]::ParseQueryString($q.Query)
        $sub = $params['subfolder']
        $name = $params['filename']
        if ($sub) { return (Join-Path (Join-Path $OutputDir $sub) $name) }
        return (Join-Path $OutputDir $name)
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $inst.widgets_values[0] = $Prompt
    $inst.widgets_values[1] = $false
    $inst.widgets_values[2] = $Width
    $inst.widgets_values[3] = $Height
    $inst.widgets_values[4] = $Seconds
    $inst.widgets_values[5] = $Fps
    $inst.widgets_values[6] = $Seed
    $textNode.widgets_values[0] = $Prompt
    $enhanceNode[0].widgets_values[0] = $false
    $widthNode.widgets_values[0] = $Width
    $heightNode.widgets_values[0] = $Height
    $secondsNode.widgets_values[0] = $Seconds
    $fpsNode.widgets_values[0] = $Fps
    $noiseNode[0].widgets_values[0] = $Seed
    $noiseNode[0].widgets_values[1] = 'fixed'
    $videoNode.widgets_values[0] = "video/clip-$stamp"

    if ($Image) {
        $loadNode = Get-OnlyNode $nodes 'LoadImage' ''
        $safeName = 'video-start-{0}{1}' -f $stamp, ([IO.Path]::GetExtension($Image).ToLowerInvariant())
        New-Item -ItemType Directory -Force -Path $InputDir | Out-Null
        Copy-Item -LiteralPath $Image -Destination (Join-Path $InputDir $safeName) -Force
        $loadNode.widgets_values[0] = $safeName
        $loadNode.mode = 0
    }

    $copy = Join-Path $JobsDir ('ltx-video-{0}-{1}.json' -f $stamp, $Seed)
    $json = $workflow | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($copy, $json, (New-Object Text.UTF8Encoding($false)))

    $lines = @(& $Comfy run --workflow $copy --where local --wait --json 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $allText = $lines -join "`n"
    if ($code -ne 0) {
        # case-insensitive on purpose: "room", "zoom" or "Bloom" in a path or node name is not OOM
        if ($allText -match '(?i:out of memory)|OutOfMemory|\bOOM\b') {
            Write-Output 'Der Grafikspeicher (GPU) oder der Arbeitsspeicher ist voll. Schliesse bitte diese Programme und versuche es dann noch einmal:'
            Write-Output '  Chrome, Discord, Obsidian, VoiceStudio, LM Studio, Ollama, OBS'
            Write-Output '(Es wird kein anderes Modell versucht. -Stop beendet ComfyUI, falls es noch laeuft.)'
        }
        else {
            Write-Output 'ComfyUI hat den Clip nicht fertig gemacht. Letzte Zeilen der Antwort:'
            $lines | Select-Object -Last 5 | ForEach-Object { Write-Output $_ }
        }
        exit 1
    }
    $envelope = $lines | Where-Object { $_ -match '"type"\s*:\s*"envelope"' } | Select-Object -Last 1
    if (-not $envelope) {
        Write-Output 'ComfyUI hat keine Antwort mit dem Ergebnis geliefert. Letzte Zeilen der Ausgabe:'
        $lines | Select-Object -Last 5 | ForEach-Object { Write-Output $_ }
        exit 1
    }
    $result = $envelope | ConvertFrom-Json
    $printed = 0
    foreach ($url in @($result.data.outputs)) {
        $path = Get-VideoPath $url
        if (Test-Path -LiteralPath $path) {
            Write-Output $path
            $printed++
            $sheet = Join-Path $OutputDir ("clip-{0}-sheet.png" -f $stamp)
            try {
                # Four frames spread over the whole clip. A fixed step of 30 frames left two
                # black tiles on a 2 s clip (49 frames), measured 2026-10-29.
                $frameCount = 0
                try {
                    $probe = & ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 $path 2>$null | Select-Object -First 1
                    if ($probe -match '^\d+$') { $frameCount = [int]$probe }
                }
                catch { }
                if ($frameCount -lt 4) { $frameCount = $Seconds * $Fps }
                $i1 = [int][math]::Floor($frameCount / 3)
                $i2 = [int][math]::Floor(2 * $frameCount / 3)
                $i3 = $frameCount - 1
                & ffmpeg -y -loglevel error -i $path -vf "select='eq(n\,0)+eq(n\,$i1)+eq(n\,$i2)+eq(n\,$i3)',scale=640:-1,tile=2x2" -frames:v 1 $sheet 2>&1 | Out-Null
                if (Test-Path -LiteralPath $sheet) { Write-Output "Kontaktbogen: $sheet" }
            }
            catch { }
        }
    }
    if ($printed -eq 0) {
        Write-Output 'ComfyUI meldete ein Ergebnis, aber die Datei ist nicht im Ausgabeordner angekommen.'
        exit 1
    }
    Write-Output "Seed: $Seed"
    exit 0
}
finally {
    if ($startedServer -and -not $KeepRunning) { & $Comfy stop | Out-Null }
}
