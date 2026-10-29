# Rebuilding the local ComfyUI setup

The way back for `/image` and `/video`: the two skills share one ComfyUI on this PC, and this
page records how that install was built and how to build it again from nothing. Written on
2026-10-29 from the working install (ComfyUI 0.42.0); no download, install or test run was made
to write it. The model files are re-downloadable and are not in the backup.

Related: ADR 0019 (image, `comfy-cli` instead of an MCP server), ADR 0022 (video, LTX-2.3),
skill `~/.claude/skills/image/SKILL.md`, skill `~/.claude/skills/video/SKILL.md`.

## What is installed

Recorded from the live install on 2026-10-29:

| Part | Version | Where |
|---|---|---|
| Windows | 11 Education, 10.0.26300 | this PC |
| NVIDIA driver | 617.42, RTX 5060 Ti 16 GB | this PC |
| RAM | 31.06 GiB usable (2 x 16 GiB installed) | this PC |
| comfy-cli | 1.23.0 | `C:\Users\<name>\.local\bin\comfy.exe`, installed as a `uv` tool |
| ComfyUI | 0.42.0, commit `bc5f880dbdd43e426077f42ccec53bb577ffee9f` (2026-10-23) | `C:\Dev\External\ComfyUI` |
| Python | 3.13.15 | `C:\Dev\External\ComfyUI\.venv` |
| PyTorch | 2.14.1+cu130 | the same `.venv` |
| CUDA | 13.0 | the same `.venv` (device capability `(12, 0)`) |

The workspace is the folder itself (`comfy install --workspace=C:\Dev\External\ComfyUI` uses it
as the target, not a `ComfyUI` child of it). The `.venv` lives inside it. Results go to
`C:\Dev\Temp\media`; the job copies and contact sheets sit in its `.comfy-jobs` folder.

## Prerequisites

- Windows 11 on x64 with an NVIDIA GPU. The recorded card has 16 GB VRAM; `/video` was measured
  on it (peak 15,875 MiB). A smaller card is not covered by these measurements.
- An NVIDIA driver that supports CUDA 13; 617.42 was the version on 2026-10-29.
- `git` and `uv` on `PATH`. `uv` installs its own Python 3.13; a separate Python install is not
  needed.
- Free disk: 63.65 GB for the eight model files plus the 30 GB reserve of the restore script,
  so about 94 GB free before the first download. The models are not in the backup.
- 32 GB RAM is recommended. `/video` refuses to start below 15.9 GiB free RAM.

## Install in order

Run every command in a PowerShell window. The order matters: comfy-cli first, then the
workspace, then the defaults, then the models.

### 1. comfy-cli

```powershell
uv tool install comfy-cli --python 3.13
comfy --version
```

`comfy --version` must answer; `1.23.0` was the recorded version. `uv tool install` keeps
comfy-cli in its own tool environment, separate from the ComfyUI `.venv`.

### 2. ComfyUI and PyTorch

Run this from `C:\Dev\Temp`, never from a repository: `--fast-deps` writes `override.txt` and
`requirements.compiled` into the current folder.

```powershell
cd C:\Dev\Temp
comfy --skip-prompt --workspace=C:\Dev\External\ComfyUI install --nvidia --cuda-version 13.0 --skip-manager --fast-deps
```

- `--workspace` is the target folder itself. `comfy-cli` 1.23.0 does not append `ComfyUI` to it.
- `--nvidia --cuda-version 13.0` installs the CUDA 13.0 build of PyTorch.
- `--skip-manager` keeps ComfyUI-Manager out; the setup has no manager and no custom nodes.
- The command clones ComfyUI and creates `.venv` inside the workspace. The install of
  2026-10-23 produced ComfyUI 0.42.0 at commit `bc5f880dbdd43e426077f42ccec53bb577ffee9f`.
  For exactly that version add `--version 0.42.0`; the recorded run did not pin it and took
  the latest master at the time.
- The ComfyUI `.gitignore` lists `/models/`, so a later `comfy update` (a git pull) never
  touches the model files.

Check the result:

```powershell
C:\Dev\External\ComfyUI\.venv\Scripts\python.exe --version
C:\Dev\External\ComfyUI\.venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.version.cuda)"
```

Expected: `Python 3.13.15` and `2.14.1+cu130 13.0` (the versions measured here; a later
comfy-cli may install newer ones).

### 3. Start defaults

These are saved once and used by every `comfy launch`:

```powershell
comfy set-default C:\Dev\External\ComfyUI --launch-extras="--output-directory C:\Dev\Temp\media --disable-partner-nodes --disable-auto-launch --port 8188"
comfy tracking disable
```

The first command also makes the workspace the default. The flags are explained under
"Start flags".

### 4. The eight model files

The restore script downloads only the missing files, resumes a `.part` file, and checks byte
size and SHA-256 against the pinned Hugging Face revision. It needs no Hugging Face login and
no key. List the plan first, then run it:

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\image\scripts\restore-models.ps1" -WhatIf
pwsh -NoProfile -File "$HOME\.claude\skills\image\scripts\restore-models.ps1"
```

The copy in this repository is `home/.claude/skills/image/scripts/restore-models.ps1`. It reads
`dev_root` from `%USERPROFILE%\.personal-os\personal.yaml` when it still carries the
`{{DEV}}` placeholder, so it also runs from the repository:

```powershell
pwsh -NoProfile -File "C:\Dev\Projects\personal-os-setup\home\.claude\skills\image\scripts\restore-models.ps1" -WhatIf
```

A wrong size or hash stops the run in German and nothing else is downloaded. If the target
drive has less free space than the missing files plus 30 GB, it refuses before the first byte.

### 5. Start the server

```powershell
comfy launch --background
```

Open `http://127.0.0.1:8188` in the browser. `comfy stop` stops the server; it also ends a
running job, so use it only when nothing is running.

## The eight model files

All eight sit in `C:\Dev\External\ComfyUI\models`. Every URL is pinned to the Hugging Face
revision that was downloaded and verified on 2026-10-28/29. SHA-256 is the value Hugging Face
shows for the file (the LFS OID); the local hash of every file was computed once on 2026-10-29
and all eight matched.

### /image: Z-Image-Turbo, three files

| File | Folder | Bytes | GiB | SHA-256 | Hugging Face |
|---|---|---|---|---|---|
| `z_image_turbo_bf16.safetensors` | `diffusion_models` | 12,309,866,400 | 11.46 | `2407613050b809ffdff18a4ac99af83ea6b95443ecebdf80e064a79c825574a6` | [Comfy-Org/Z-Image-Turbo @ 6fc90a3](https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/split_files/diffusion_models/z_image_turbo_bf16.safetensors) |
| `qwen_3_4b.safetensors` | `text_encoders` | 8,044,982,048 | 7.49 | `6c671498573ac2f7a5501502ccce8d2b08ea6ca2f661c458e708f36b36edfc5a` | [Comfy-Org/Z-Image-Turbo @ 6fc90a3](https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/split_files/text_encoders/qwen_3_4b.safetensors) |
| `ae.safetensors` | `vae` | 335,304,388 | 0.31 | `afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38` | [Comfy-Org/Z-Image-Turbo @ 6fc90a3](https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/split_files/vae/ae.safetensors) |

### /video: LTX-2.3, five files

| File | Folder | Bytes | GiB | SHA-256 | Hugging Face |
|---|---|---|---|---|---|
| `ltx-2.3-22b-dev-fp8.safetensors` | `checkpoints` | 29,145,431,166 | 27.14 | `28606c5b5a06ce56f896d4dfcb20f212739e07a68fbe48e53638188449d26450` | [Lightricks/LTX-2.3-fp8 @ 91eda21](https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/91eda216f820e5ecb3d17dc9fe3b7cdaf56b587d/ltx-2.3-22b-dev-fp8.safetensors) |
| `ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors` | `loras` | 2,741,024,390 | 2.55 | `31e0c0195fb841bf31af78e8b60858f489e87ddcea4a5239abc80943da65e3ac` | [Comfy-Org/ltx-2.3 @ f20f3a5](https://huggingface.co/Comfy-Org/ltx-2.3/resolve/f20f3a54378001e5e6d642acc84719cc78addf4b/split_files/loras/ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors) |
| `gemma-3-12b-it-abliterated_lora_rank64_bf16.safetensors` | `loras` | 628,203,616 | 0.59 | `87bcabeac9bec9f374232b5122d6511c2b2112d479e50176149e944b3712eb4a` | [Comfy-Org/ltx-2 @ ccde4ba](https://huggingface.co/Comfy-Org/ltx-2/resolve/ccde4ba417d7900669fd56dd292a883cee11ff37/split_files/loras/gemma-3-12b-it-abliterated_lora_rank64_bf16.safetensors) |
| `gemma_3_12B_it_fp4_mixed.safetensors` | `text_encoders` | 9,447,702,218 | 8.80 | `aaca463d11e6d8d2a4bdb0d6299214c15ef78a3f73e0ef8113d5a9d0219b3f6d` | [Comfy-Org/ltx-2 @ ccde4ba](https://huggingface.co/Comfy-Org/ltx-2/resolve/ccde4ba417d7900669fd56dd292a883cee11ff37/split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors) |
| `ltx-2.3-spatial-upscaler-x2-1.1.safetensors` | `latent_upscale_models` | 995,743,560 | 0.93 | `5f416311fa8172b65af67530758964708d29a317b830d689a51143b7f91913ed` | [Lightricks/LTX-2.3 @ c152117](https://huggingface.co/Lightricks/LTX-2.3/resolve/c1521179de480464f366a98a9d9b2acc4cc097b9/ltx-2.3-spatial-upscaler-x2-1.1.safetensors) |

Totals: image 20,690,152,836 bytes (20.69 GB, 19.27 GiB); video 42,958,104,950 bytes (42.96 GB,
40.01 GiB); together 63,648,257,786 bytes (63.65 GB, 59.28 GiB).

- All eight come from official repositories: `Comfy-Org/Z-Image-Turbo`, `Comfy-Org/ltx-2.3`,
  `Comfy-Org/ltx-2` and `Lightricks/LTX-2.3-fp8`, `Lightricks/LTX-2.3`. No file from an
  unofficial repo is used.
- Each file is loaded by exactly one skill. Deleting any file breaks only the skill that loads
  it and leaves the other skill working: the image files can go while `/video` keeps working,
  and the five video files can go while `/image` keeps working. Deleting all eight removes both
  skills' models; `restore-models.ps1` brings them back.
- The single `ltx-2.3-22b-distilled-fp8.safetensors` in the same repo is **not** used by the
  `/video` templates; do not download it for this setup.
- The Z-Image repo also offers `z_image_turbo_int8_convrot.safetensors` and
  `z_image_turbo_nvfp4.safetensors`. They are not downloaded: the measured setup uses the bf16
  file above.

## Start flags

The flags live in comfy-cli's default launch extras, so `comfy launch --background` applies
them without repeating them:

| Flag | Why |
|---|---|
| `--output-directory C:\Dev\Temp\media` | results land in the shared media scratch; `C:\Dev\Temp\media` is never deleted during a task's cleanup |
| `--disable-partner-nodes` | the local install never offers the paid partner model nodes |
| `--disable-auto-launch` | launching the server does not open a browser window by itself |
| `--port 8188` | the skills check `127.0.0.1:8188` before they start a server |

ComfyUI binds to `127.0.0.1` only. Never pass `--listen` without a value and never
`--highvram`. The skills start the server only when nothing answers on the port; `/video` stops
it after the clip when that run started it (`-KeepRunning` keeps it).

## Check that it works

Two small jobs prove the whole chain (models, templates, server, output folder). Run them in a
Claude Code session, or call the scripts directly.

Image, 512x512 (the skill's script starts the server if needed):

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\image\scripts\new-image.ps1" -Prompt "a red apple on a wooden table, soft window light, photorealistic" -Width 512 -Height 512
```

Expected: the full path of a PNG and a seed. The first picture took about 35 s including the
model load, later ones about 15 s at 1024x1024.

Video, 1 s at 768x512:

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\video\scripts\new-video.ps1" -Prompt "a paper boat drifting down a small forest stream, close-up, soft afternoon light, gentle water sounds" -Seconds 1 -Width 768 -Height 512
```

Expected: the full path of an mp4, a 2x2 contact sheet and a seed. A 5 s 1280x720 clip took
100-108 s cold and 82-96 s warm; a 1 s clip is shorter. The script stops the server it started.

In a normal session the same jobs are `/image <wish>` and `/video <wish>`. If a script exits 1,
it prints a German sentence for the owner; pass that sentence on and do not retry with another
model.

## Known problems and their fixes

These are the measured problems of this setup, with the fix that worked.

### `/video` and RAM

- The script refuses below **15.9 GiB free RAM** before it starts anything, names the five
  programs with the largest working set and starts nothing. That floor is the lowest free RAM a
  clean run was measured at (15.94 GiB, 2026-10-29); the ComfyUI working-set peak is 16.81 GiB.
- Close Chrome, Discord, Obsidian and other memory-heavy programs first. The script never
  closes a program itself.
- Commit charge is the second limit: a clean LTX run peaked at **57.69 GiB committed of a
  61.06 GiB limit**, with a system-managed page file of 30,720 MB. The page file absorbed it and
  the run finished. Do not shrink or disable the page file, and keep disk space free; if the
  commit limit is lower or the page file cannot grow, the job fails even when free RAM looks
  sufficient.
- If another model program holds the GPU (LM Studio, Ollama, VoiceStudio, OBS), the video
  script refuses and names it. Close that program; do not stop it from inside the script.

### Graphics memory

- The card has 16 GB. The measured LTX peak was 15,875 MiB; the image model fits in 16 GB
  according to its docs. A CUDA out-of-memory error ends in a German message and no model
  switch. Close GPU programs and try the same model again.
- A lost progress line (`ws_disconnected`) does not stop the job; the local server keeps it.
  Cancel a hung job with `comfy jobs cancel <prompt_id> --where local`.

### INT8 and black pictures

No black-output problem was seen in this setup, and no INT8 variant was used: the table pins
the bf16 file for Z-Image-Turbo and the fp8/LoRA combination the LTX templates load. If a
picture or clip comes out black, first check the file against the table (`restore-models.ps1`
hashes it), then look at `C:\Dev\External\ComfyUI\user\comfyui_8188.log`. Do not swap in the
`int8_convrot` or `nvfp4` Z-Image files as a quick fix; they were not measured here.

### Templates

The three official templates are not kept in this repository. Each script fetches them from a
pinned commit of `Comfy-Org/workflow_templates` and checks the SHA-256 on every use; a template
that does not match is refused. That is a guard, not a defect. If a fetch fails, check the
network; the script never falls back to an unpinned template.

### Downloads

`restore-models.ps1` resumes a `.part` file after an interruption, checks the byte size and the
SHA-256, and only then renames the file. A wrong hash deletes the `.part` and stops in German.
An existing final file with the wrong size or hash stops the run; the script never overwrites
it. Delete such a file by hand only with the owner's yes, then run the script again.

## How long a rebuild takes (estimate)

The download dominates. On this line the eight files were measured at **88.7-97 MB/s**
(`C:\Dev\Temp\video\download.log`, 2026-10-28): 63.65 GB takes about **12 minutes**. At a
100 Mbit/s line (about 12.5 MB/s) the same download takes about **85 minutes**. Both are
estimates; the actual speed depends on the line and on Hugging Face.

The ComfyUI and PyTorch install adds about 5-15 minutes (estimate; the recorded install was not
timed). The first image takes about 35 s including model load, a 5 s video about 100-108 s. A
full rebuild from an empty disk is therefore roughly **20-30 minutes on the measured line**,
about **1.5-2 hours at 100 Mbit/s**.

## Sources

- ADR 0019: `docs/decisions/0019-local-image-generation-comfy-cli.md` (image model, comfy-cli,
  install command, measured versions).
- ADR 0022: `docs/decisions/0022-local-video-generation.md` (video model, memory measurements,
  template pins).
- Skills: `home/.claude/skills/image/SKILL.md`, `home/.claude/skills/video/SKILL.md`.
- comfy-cli: https://github.com/Comfy-Org/comfy-cli (1.23.0).
- ComfyUI: https://github.com/comfyanonymous/ComfyUI (0.42.0).
- Model pages: https://huggingface.co/Comfy-Org/Z-Image-Turbo,
  https://huggingface.co/Comfy-Org/ltx-2.3, https://huggingface.co/Comfy-Org/ltx-2,
  https://huggingface.co/Lightricks/LTX-2.3-fp8, https://huggingface.co/Lightricks/LTX-2.3.
