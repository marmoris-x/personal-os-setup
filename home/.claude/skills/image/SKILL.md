---
name: image
description: Make a picture on this PC's own GPU with ComfyUI (Z-Image-Turbo), local only. Manual only - the owner types /image.
disable-model-invocation: true
argument-hint: [what the image shows]
---

The owner wants this picture: $ARGUMENTS

## Run it (always this, nothing else)

1. Turn the wish into an English prompt of 20-40 words (subject, place, light, mood, style). Z-Image
   Turbo ignores negative prompts, so write what you want, never what you do not want.
2. Run (the prompt is data, never put it into a command by string joining):

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\image\scripts\new-image.ps1" -Prompt "<English prompt>"
```

   Optional: `-Width 1024 -Height 1024` (256-2048, default 1024), `-Seed N` (same seed + same prompt =
   same picture), `-Count 2` (consecutive seeds). The script starts ComfyUI itself, prints the full
   path of every image and then the seed. First picture about 35 s (model load), the next ones about
   15 s. ComfyUI stays running afterwards.
3. `Read` every PNG it printed, so the owner sees it in the chat, then ask: "behalten?"
   - "behalten": ask where the file goes (never choose a storage location yourself); the owner's
     `Downloads\Images` folder is permanent storage, so nothing is moved there or out of it without a yes.
   - not wanted: leave it, results in `{{DEV}}\Temp\media` are scratch.
4. Exit code 1 with a German text about the graphics memory: pass that text on in German; do not
   retry, do not switch to another model.

## Stop it

When the owner is done, or before any VoiceStudio, LM Studio or Ollama work, free the GPU. Stop a
ComfyUI only if this session started it or the owner asks for it; one the owner started by hand or
in an earlier session is theirs (`comfy stop` would end a running job):

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\image\scripts\new-image.ps1" -Stop
```

## "/image zeig mir ComfyUI"

Run `comfy launch --background`, then give the owner `http://127.0.0.1:8188` to open in the browser
(the same interface as the old Desktop app). No picture is made. Stop it afterwards as above.

## Rules (all of them are binding)

- Local only. Never run `comfy setup`, never sign in to Comfy Cloud, never set `COMFY_API_KEY`,
  never use `comfy generate` (beta, routes to paid partner models). Every `comfy run`, `jobs` and
  `download` call carries `--where local`.
- ComfyUI always starts with `--disable-partner-nodes` and listens on `127.0.0.1:8188` only; both
  are saved once with `comfy set-default`. Never `--listen` without a value, never `--highvram`.
- Never add a ComfyUI MCP server (the CLI is cheaper in context and enough), no custom nodes, no
  ComfyUI-Manager, no second image model, no video model without the owner's yes.
- Exactly one ComfyUI on this PC (`{{DEV}}\External\ComfyUI`). Never install the Desktop app, a
  portable build or a Pinokio ComfyUI.
- Tracking stays off (`comfy tracking disable`).
- `comfy install --fast-deps` writes `override.txt` and `requirements.compiled` into the current
  folder: run it from `{{DEV}}\Temp`, never from a repository.
- `comfy update` only when the owner asks or a template needs it.
- A picture that hangs: `comfy jobs cancel <prompt_id> --where local`. A lost progress line
  (`ws_disconnected`) does not stop the job; the local server keeps it.

## Where things are

| What | Path |
|---|---|
| Program (other people's code) | `{{DEV}}\External\ComfyUI` |
| Models (about 19 GB, re-downloadable, not backed up) | `{{DEV}}\External\ComfyUI\models` |
| Results and job copies | `{{DEV}}\Temp\media` (job copies in `.comfy-jobs\`) |
| Template | `image_z_image_turbo.json` next to this file |

Template source: https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_z_image_turbo.json
(commit e7cd011d4ded3411c2f481200544f0be6fdc962e, 2026-09-28; copied verbatim 2026-10-23). Model page:
https://docs.comfy.org/tutorials/image/z-image/z-image-turbo.md ("fits within 16GB VRAM"). The sampler
graph is a subgraph inside the template; the script finds the nodes by type, not by id.

The models: `z_image_turbo_bf16.safetensors` (11.5 GB, diffusion_models), `qwen_3_4b.safetensors`
(7.5 GB, text_encoders), `ae.safetensors` (0.3 GB, vae), all from
https://huggingface.co/Comfy-Org/z_image_turbo (`resolve/main/split_files/...`).

## Video

Short clips with sound come from the separate skill `/video` (LTX-2.3, same ComfyUI, ADR 0022).
It has its own script and its own measured RAM guard; this skill never starts it.

## Reinstall and uninstall

- Reinstall: `comfy stop`; move `{{DEV}}\External\ComfyUI\models` to `{{DEV}}\Temp\comfyui-models`;
  delete `{{DEV}}\External\ComfyUI` (only with the owner's yes); from `{{DEV}}\Temp` run
  `comfy --skip-prompt --workspace={{DEV}}\External\ComfyUI install --nvidia --cuda-version 13.0 --skip-manager --fast-deps`
  (`--workspace` is the target folder itself, not its parent); `comfy set-default` with
  `--launch-extras="--output-directory {{DEV}}\Temp\media --disable-partner-nodes --disable-auto-launch --port 8188"`;
  move `models` back.
- Uninstall: `comfy stop`; delete `{{DEV}}\External\ComfyUI` with the owner's yes (models included);
  then `uv tool uninstall comfy-cli`.

## Sources of the lines taken from comfy-cli's own skills

The bundled skills (`comfy skills show comfy`, `comfy-relay`, `comfy-debug`, comfy-cli 1.23.0) say:
show the image itself by reading the file, not its path (comfy-relay, rule 1); `comfy jobs cancel`
works on local jobs; `ws_disconnected` leaves the job on the local server (comfy-debug). Their
cloud, `generate` and `setup` parts do not apply here and are not copied. Do not run
`comfy skills install`: it writes files outside the setup repo.
