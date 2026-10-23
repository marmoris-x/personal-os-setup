# new-image.ps1 - make a picture with ComfyUI on this PC's GPU, local only.
#
# Usage:  pwsh -NoProfile -File new-image.ps1 -Prompt "<English text>" [-Width 1024] [-Height 1024]
#                                              [-Seed N] [-Count 1]
#         pwsh -NoProfile -File new-image.ps1 -Stop
#
# It copies the Z-Image-Turbo template (image_z_image_turbo.json, next to the SKILL.md), sets the
# prompt, the size and the seed in the copy, starts ComfyUI with `comfy launch --background` when
# nothing answers on 127.0.0.1:8188, submits the copy with `comfy run --where local --wait` and
# prints the full path of every new image, then the seed. ComfyUI keeps running afterwards
# (the next picture is faster); -Stop runs `comfy stop`.
#
# The launch options (output folder, --disable-partner-nodes, port) are saved once with
# `comfy set-default`, so they are not repeated here. This script never calls `comfy setup`,
# `comfy generate` or anything that talks to Comfy Cloud.
[CmdletBinding(DefaultParameterSetName = 'Make')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Make')]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 2000)]
    [string]$Prompt,
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(256, 2048)]
    [int]$Width = 1024,
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(256, 2048)]
    [int]$Height = 1024,
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(0, 2147483000)]
    [long]$Seed = -1,
    [Parameter(ParameterSetName = 'Make')]
    [ValidateRange(1, 8)]
    [int]$Count = 1,
    [Parameter(Mandatory = $true, ParameterSetName = 'Stop')]
    [switch]$Stop,

    # Everything below exists so the tests can point the script at a stand-in.
    [string]$Template = (Join-Path (Split-Path -Parent $PSScriptRoot) 'image_z_image_turbo.json'),
    # The official template is not kept in the setup repo (see ADR 0019); when it is missing it is
    # fetched from this pinned commit and must match the hash, or nothing is used.
    [string]$TemplateUrl = 'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/e7cd011d4ded3411c2f481200544f0be6fdc962e/templates/image_z_image_turbo.json',
    [string]$TemplateSha256 = 'BAAF937FF071970CC6B1E2FA0093A4DD664A4CC734D38ADC4C7810E535C1F1D3',
    [string]$OutputDir = '{{DEV}}\Temp\media',
    [string]$JobsDir = (Join-Path $OutputDir '.comfy-jobs'),
    [string]$Comfy = 'comfy',
    [int]$Port = 8188,
    [int]$StartupTimeoutSec = 120
)

$ErrorActionPreference = 'Stop'

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

# --- the copy of the template: the node ids come from the JSON, found by node type -------------
function Get-OnlyNode($Nodes, [string]$Type) {
    $hit = @($Nodes | Where-Object { $_.type -eq $Type })
    if ($hit.Count -ne 1) { throw "The template must hold exactly one $Type node, found $($hit.Count)." }
    return $hit[0]
}

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
$workflow = Get-Content -LiteralPath $Template -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
# The Z-Image template keeps its sampler graph inside a subgraph; other templates keep it flat.
$nodes = @($workflow.nodes)
foreach ($sg in @($workflow.definitions.subgraphs)) { if ($sg) { $nodes += @($sg.nodes) } }
$textNode = Get-OnlyNode $nodes 'CLIPTextEncode'
$sizeNode = Get-OnlyNode $nodes 'EmptySD3LatentImage'
$samplerNode = Get-OnlyNode $nodes 'KSampler'

if ($Seed -lt 0) { $Seed = [long](Get-Random -Minimum 0 -Maximum 2147483000) }

New-Item -ItemType Directory -Force -Path $JobsDir | Out-Null

# --- the server -----------------------------------------------------------------------------------
if (-not (Test-ServerUp $Port)) {
    & $Comfy launch --background | Out-Null
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    while (-not (Test-ServerUp $Port)) {
        if ((Get-Date) -gt $deadline) {
            Write-Output "ComfyUI antwortet nach $StartupTimeoutSec Sekunden nicht auf 127.0.0.1:$Port."
            exit 1
        }
        Start-Sleep -Seconds 2
    }
}

function Get-ImagePath([string]$Url) {
    $q = [Uri]$Url
    $params = [Web.HttpUtility]::ParseQueryString($q.Query)
    $sub = $params['subfolder']
    $name = $params['filename']
    if ($sub) { return (Join-Path (Join-Path $OutputDir $sub) $name) }
    return (Join-Path $OutputDir $name)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
for ($i = 0; $i -lt $Count; $i++) {
    $thisSeed = $Seed + $i
    $textNode.widgets_values[0] = $Prompt
    $sizeNode.widgets_values[0] = $Width
    $sizeNode.widgets_values[1] = $Height
    $samplerNode.widgets_values[0] = $thisSeed
    $copy = Join-Path $JobsDir ('z-image-{0}-{1}.json' -f $stamp, $thisSeed)
    $json = $workflow | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($copy, $json, (New-Object Text.UTF8Encoding($false)))

    $lines = @(& $Comfy run --workflow $copy --where local --wait --json 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $all = $lines -join "`n"
    if ($code -ne 0) {
        # case-sensitive on purpose: "room", "zoom" or "Bloom" in a path or node name is not OOM
        if ($all -cmatch '(?i:out of memory)|OutOfMemory|\bOOM\b') {
            Write-Output 'Der Grafikspeicher (GPU) ist voll. Schliesse bitte diese Programme und versuche es dann noch einmal:'
            Write-Output '  VoiceStudio, LM Studio, Ollama, OBS'
            Write-Output '(Danach: das Bild-Skript mit -Stop beenden, falls ComfyUI noch laeuft.)'
        }
        else {
            Write-Output 'ComfyUI hat das Bild nicht fertig gemacht. Letzte Zeilen der Antwort:'
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
    foreach ($url in @($result.data.outputs)) { Write-Output (Get-ImagePath $url) }
    Write-Output "Seed: $thisSeed"
}
exit 0
