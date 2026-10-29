# restore-models.ps1 - download the model files of the /image and /video skills, verified.
#
# One script for both skills: it reads the table below, downloads only the files that are
# missing (resumable), then checks byte size and SHA-256 against the pinned Hugging Face
# revisions. A mismatch stops the run in German and nothing else is downloaded. The target
# drive must hold the missing bytes plus a 30 GiB reserve, or the script refuses before it
# starts. No Hugging Face login, no token, no key: all eight repositories are public.
#
# Usage:  pwsh -NoProfile -File restore-models.ps1 [-WhatIf] [-ModelsRoot <path>] [-ModelList <json>]
#
#   -WhatIf       list what would be downloaded and stop; nothing is written
#   -ModelsRoot   the ComfyUI models folder (default {{DEV}}\External\ComfyUI\models)
#   -ModelList    a JSON file with the same fields as the table, for the fake-list test only
#
# The script is based on {{DEV}}\Temp\video\download-models.ps1, which downloaded these eight
# files on 2026-10-28 and checked every one of them against Hugging Face (see ADR 0022).
[CmdletBinding()]
param(
    [string]$ModelsRoot = '{{DEV}}\External\ComfyUI\models',
    [string]$ModelList,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$SpaceReserveBytes = 30GB

# skill: which SKILL.md loads the file. The table is also in docs/restore-comfyui.md.
$DefaultModels = @(
    [pscustomobject]@{
        Skill  = 'image'
        Folder = 'diffusion_models'
        File   = 'z_image_turbo_bf16.safetensors'
        Size   = 12309866400
        Sha256 = '2407613050b809ffdff18a4ac99af83ea6b95443ecebdf80e064a79c825574a6'
        Url    = 'https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/split_files/diffusion_models/z_image_turbo_bf16.safetensors'
    },
    [pscustomobject]@{
        Skill  = 'image'
        Folder = 'text_encoders'
        File   = 'qwen_3_4b.safetensors'
        Size   = 8044982048
        Sha256 = '6c671498573ac2f7a5501502ccce8d2b08ea6ca2f661c458e708f36b36edfc5a'
        Url    = 'https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/split_files/text_encoders/qwen_3_4b.safetensors'
    },
    [pscustomobject]@{
        Skill  = 'image'
        Folder = 'vae'
        File   = 'ae.safetensors'
        Size   = 335304388
        Sha256 = 'afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38'
        Url    = 'https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/split_files/vae/ae.safetensors'
    },
    [pscustomobject]@{
        Skill  = 'video'
        Folder = 'checkpoints'
        File   = 'ltx-2.3-22b-dev-fp8.safetensors'
        Size   = 29145431166
        Sha256 = '28606c5b5a06ce56f896d4dfcb20f212739e07a68fbe48e53638188449d26450'
        Url    = 'https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/91eda216f820e5ecb3d17dc9fe3b7cdaf56b587d/ltx-2.3-22b-dev-fp8.safetensors'
    },
    [pscustomobject]@{
        Skill  = 'video'
        Folder = 'loras'
        File   = 'ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors'
        Size   = 2741024390
        Sha256 = '31e0c0195fb841bf31af78e8b60858f489e87ddcea4a5239abc80943da65e3ac'
        Url    = 'https://huggingface.co/Comfy-Org/ltx-2.3/resolve/f20f3a54378001e5e6d642acc84719cc78addf4b/split_files/loras/ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors'
    },
    [pscustomobject]@{
        Skill  = 'video'
        Folder = 'loras'
        File   = 'gemma-3-12b-it-abliterated_lora_rank64_bf16.safetensors'
        Size   = 628203616
        Sha256 = '87bcabeac9bec9f374232b5122d6511c2b2112d479e50176149e944b3712eb4a'
        Url    = 'https://huggingface.co/Comfy-Org/ltx-2/resolve/ccde4ba417d7900669fd56dd292a883cee11ff37/split_files/loras/gemma-3-12b-it-abliterated_lora_rank64_bf16.safetensors'
    },
    [pscustomobject]@{
        Skill  = 'video'
        Folder = 'text_encoders'
        File   = 'gemma_3_12B_it_fp4_mixed.safetensors'
        Size   = 9447702218
        Sha256 = 'aaca463d11e6d8d2a4bdb0d6299214c15ef78a3f73e0ef8113d5a9d0219b3f6d'
        Url    = 'https://huggingface.co/Comfy-Org/ltx-2/resolve/ccde4ba417d7900669fd56dd292a883cee11ff37/split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors'
    },
    [pscustomobject]@{
        Skill  = 'video'
        Folder = 'latent_upscale_models'
        File   = 'ltx-2.3-spatial-upscaler-x2-1.1.safetensors'
        Size   = 995743560
        Sha256 = '5f416311fa8172b65af67530758964708d29a317b830d689a51143b7f91913ed'
        Url    = 'https://huggingface.co/Lightricks/LTX-2.3/resolve/c1521179de480464f366a98a9d9b2acc4cc097b9/ltx-2.3-spatial-upscaler-x2-1.1.safetensors'
    }
)

function Fail([string]$Message) {
    Write-Output $Message
    exit 1
}

# {{DEV}} is the repository placeholder; on the live machine it is {{DEV}}. When this file
# runs from the repository itself, read the real Dev root from the personal values file.
function Resolve-DevPlaceholder([string]$Path) {
    if ($Path -notmatch '\{\{DEV\}\}') { return $Path }
    $cfg = Join-Path $HOME '.personal-os\personal.yaml'
    if (Test-Path -LiteralPath $cfg) {
        $line = Select-String -LiteralPath $cfg -Pattern '^dev_root:\s*(.+?)\s*$' | Select-Object -First 1
        if ($line) {
            $dev = $line.Matches[0].Groups[1].Value.Trim().Trim("'").Trim('"')
            if ($dev) { return $Path.Replace('{{DEV}}', $dev) }
        }
    }
    return $null
}

$ModelsRoot = Resolve-DevPlaceholder $ModelsRoot
if (-not $ModelsRoot) {
    Fail ('Der Pfad enthaelt noch den Platzhalter {{DEV}}, und ' + (Join-Path $HOME '.personal-os\personal.yaml') +
        ' nennt kein dev_root. Bitte den Ordner mit -ModelsRoot angeben, zum Beispiel {{DEV}}\External\ComfyUI\models.')
}

$models = if ($ModelList) {
    if (-not (Test-Path -LiteralPath $ModelList -PathType Leaf)) {
        Fail "Die Modellliste gibt es nicht: $ModelList"
    }
    try { Get-Content -LiteralPath $ModelList -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { Fail "Die Modellliste ist kein lesbares JSON: $ModelList" }
}
else { $DefaultModels }

$models = @($models)
if ($models.Count -eq 0) { Fail 'Die Modellliste ist leer. Es wird nichts geladen.' }

foreach ($m in $models) {
    foreach ($p in @('Skill', 'Folder', 'File', 'Size', 'Sha256', 'Url')) {
        $v = $m.PSObject.Properties[$p]
        if (-not $v -or $null -eq $v.Value -or "$($v.Value)" -eq '') {
            Fail "Ein Eintrag der Modellliste hat kein Feld '$p'. Es wird nichts geladen."
        }
    }
    $m.Sha256 = "$($m.Sha256)".ToLowerInvariant()
}

$missing = New-Object System.Collections.Generic.List[object]
$present = 0
foreach ($m in $models) {
    $dir = Join-Path $ModelsRoot $m.Folder
    $dest = Join-Path $dir $m.File
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
        $missing.Add([pscustomobject]@{ Item = $m; Dest = $dest })
        continue
    }
    $len = (Get-Item -LiteralPath $dest).Length
    if ($len -ne [long]$m.Size) {
        Fail ("Die Datei ist schon da, hat aber die falsche Groesse: $dest (ist $len Byte, erwartet $($m.Size) Byte). " +
            'Sie wird nicht ueberschrieben. Bitte von Hand pruefen.')
    }
    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $m.Sha256) {
        Fail ("Die Datei hat den falschen Pruefwert: $dest (gefunden $hash, erwartet $($m.Sha256)). " +
            'Sie wird nicht benutzt. Bitte von Hand pruefen.')
    }
    $present++
}

$missingBytes = [long]0
foreach ($x in $missing) { $missingBytes += [long]$x.Item.Size }
$needBytes = $missingBytes + $SpaceReserveBytes

$rootFull = [IO.Path]::GetFullPath($ModelsRoot)
$driveRoot = [IO.Path]::GetPathRoot($rootFull)
try { $freeBytes = [IO.DriveInfo]::new($driveRoot).AvailableFreeSpace }
catch { Fail "Der freie Speicher von Laufwerk $driveRoot liess sich nicht lesen. Es wird nichts geladen." }

if ($missing.Count -eq 0) {
    Write-Output ("Alle {0} Modell-Dateien sind schon da und stimmen (Groesse und SHA-256). Es wurde nichts geladen." -f $models.Count)
    exit 0
}

$missingGiB = [math]::Round($missingBytes / 1GB, 1)
$needGiB = [math]::Round($needBytes / 1GB, 1)
$freeGiB = [math]::Round($freeBytes / 1GB, 1)
$takenGiB = [math]::Round(($needBytes - $missingBytes) / 1GB, 1)

if ($WhatIf) {
    Write-Output ("Es wuerden {0} von {1} Dateien geladen, zusammen {2} GiB:" -f $missing.Count, $models.Count, $missingGiB)
    foreach ($x in $missing) {
        $gib = [math]::Round([long]$x.Item.Size / 1GB, 1)
        Write-Output ("  - {0}\{1}  ({2} GiB, fuer /{3})" -f $x.Item.Folder, $x.Item.File, $gib, $x.Item.Skill)
    }
    Write-Output ("Frei auf {0}: {1} GiB. Noetig mit {2} GiB Reserve: {3} GiB." -f $driveRoot, $freeGiB, $takenGiB, $needGiB)
    Write-Output 'Es wurde nichts geladen (-WhatIf).'
    exit 0
}

if ($freeBytes -lt $needBytes) {
    Fail ("Zu wenig freier Speicher auf ${driveRoot}: ${freeGiB} GiB frei, noetig sind ${needGiB} GiB fuer die " +
        "fehlenden Modelle zusammen mit 30 GiB Reserve (${takenGiB} GiB). Es wird nichts geladen. " +
        'Bitte Platz schaffen und noch einmal starten.')
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Fail 'curl.exe wurde nicht gefunden. Es wird nichts geladen. Windows 11 bringt curl mit; bitte pruefen, ob es im PATH liegt.'
}

function Invoke-Curl([string]$Url, [string]$Part, [bool]$Resume) {
    $curlArgs = @('-L', '--fail', '--retry', '5', '--retry-delay', '10', '--silent', '--show-error', '-A', 'Mozilla/5.0')
    if ($Resume) { $curlArgs += @('-C', '-') }
    $curlArgs += @('-o', $Part, $Url)
    & curl.exe @curlArgs
    return $LASTEXITCODE
}

$loaded = 0
foreach ($x in $missing) {
    $m = $x.Item
    $dest = $x.Dest
    $part = "$dest.part"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null

    $resume = $false
    if (Test-Path -LiteralPath $part) {
        $partLen = (Get-Item -LiteralPath $part).Length
        if ($partLen -ge [long]$m.Size) {
            Remove-Item -LiteralPath $part -Force
        }
        elseif ($partLen -gt 0) {
            $resume = $true
        }
        else {
            Remove-Item -LiteralPath $part -Force
        }
    }

    $code = Invoke-Curl $m.Url $part $resume
    if ($code -eq 33 -and (Test-Path -LiteralPath $part)) {
        Remove-Item -LiteralPath $part -Force
        $code = Invoke-Curl $m.Url $part $false
    }
    if ($code -ne 0) {
        Fail ("Der Download ist fehlgeschlagen (curl meldet Code $code): $($m.Url). " +
            "Der Teil-Download bleibt liegen und wird beim naechsten Start fortgesetzt: $part")
    }

    $len = (Get-Item -LiteralPath $part).Length
    if ($len -ne [long]$m.Size) {
        Fail ("Die geladene Datei hat die falsche Groesse: $part (ist $len Byte, erwartet $($m.Size) Byte). " +
            'Der Teil-Download bleibt liegen und wird beim naechsten Start fortgesetzt.')
    }
    $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $m.Sha256) {
        Remove-Item -LiteralPath $part -Force
        Fail ("Die geladene Datei hat den falschen Pruefwert: $($m.Url) (gefunden $hash, erwartet $($m.Sha256)). " +
            'Der Teil-Download wurde geloescht. Es wird nichts weiter geladen; bitte noch einmal starten.')
    }
    Move-Item -LiteralPath $part -Destination $dest -Force
    $loaded++
    Write-Output ("Geladen und geprueft: {0}\{1} ({2} GiB, fuer /{3})" -f $m.Folder, $m.File, [math]::Round([long]$m.Size / 1GB, 1), $m.Skill)
}

Write-Output ("Fertig: {0} Datei(en) geladen, {1} waren schon da und stimmen. Alle Pruefwerte stimmen." -f $loaded, $present)
exit 0
