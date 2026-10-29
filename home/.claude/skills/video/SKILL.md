---
name: video
description: Make a short clip on this PC's own GPU with ComfyUI (LTX-2.3, with sound), local only. Manual only - the owner types /video.
disable-model-invocation: true
argument-hint: [what the clip shows]
---

The owner wants this clip: $ARGUMENTS

## Run it (always this, nothing else)

1. Turn the wish into an English prompt of 25-60 words: what happens over the clip, how the camera
   moves, light and mood, and the sounds or the one short sentence that is spoken. LTX-2.3 makes
   picture and sound in one pass, so name the sound. It has no negative prompt; write what you want.
2. Run (the prompt is data, never put it into a command by string joining):

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\video\scripts\new-video.ps1" -Prompt "<English prompt>"
```

   Optional: `-Seconds 5` (1-5, default 5), `-Width 1280 -Height 720` (256-1280 and 256-720,
   even, default 1280x720), `-Image <path>` for image to video (only the one picture the owner
   names), `-Seed N`, `-KeepRunning`. The script copies the pinned LTX template, sets the nodes by
   type, starts ComfyUI itself, prints the full path of the mp4 and a 2x2 contact sheet, then the
   seed. A 5 s 1280x720 clip takes about 100-108 s cold and 82-96 s warm, including model load.
3. `Read` the contact sheet PNG, so the owner sees four frames in the chat, then ask "behalten?" and
   where the file goes (never choose a storage location yourself). Results in `{{DEV}}\Temp\media`
   are scratch.
4. Exit code 1 with a German text about the graphics memory or the RAM: pass that text on in
   German; do not retry, do not switch to another model.
5. Exit code 1 with the German RAM guard text: the script refuses before it starts, because free
   RAM is below the guard of 15.9 GiB - the lowest free RAM of a clean run (2026-10-29; the
   measured ComfyUI peak is 16.8 GiB working set). Pass the text on; the owner closes the programs
   it names, then runs it again. Never close them yourself.

## Stop it

The script stops ComfyUI after the clip when it started the server itself; `-KeepRunning` keeps it.
Before any VoiceStudio, LM Studio or Ollama work, free the GPU. Stop a ComfyUI only if this session
started it or the owner asks for it (`comfy stop` would end a running job):

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\video\scripts\new-video.ps1" -Stop
```

## Rules (all of them are binding)

- One model: LTX-2.3 22B, the dev-fp8 checkpoint plus the distilled-1.1 LoRA the official templates
  load. No model switch, no Wan, no LTX-2.5, no GGUF, no second video model.
- Local only. Never run `comfy setup`, never sign in to Comfy Cloud, never set `COMFY_API_KEY`,
  never use `comfy generate` (beta, routes to paid partner models). Every `comfy run`, `jobs` and
  `download` call carries `--where local`.
- ComfyUI always starts with `--disable-partner-nodes` and listens on `127.0.0.1:8188` only; both
  are saved once with `comfy set-default`. Never `--listen` without a value, never `--highvram`.
- No custom nodes, no ComfyUI-Manager, no Hugging Face login. Exactly one ComfyUI on this PC
  (`{{DEV}}\External\ComfyUI`). Tracking stays off.
- Text inside the picture is unusable: both tested video models draw plausible-looking letters that
  spell invented words, and LTX mirrors them in some runs. Real text, titles and subtitles come
  from the motion studio, never from the model.
- A clip that hangs: `comfy jobs cancel <prompt_id> --where local`. A lost progress line
  (`ws_disconnected`) does not stop the job; the local server keeps it.

## Where things are

| What | Path |
|---|---|
| Program (other people's code) | `{{DEV}}\External\ComfyUI` |
| Models (42.96 GB, re-downloadable, not backed up) | `{{DEV}}\External\ComfyUI\models` |
| Start picture for image to video | copied into `{{DEV}}\External\ComfyUI\input` under a name the script picks |
| Results and job copies | `{{DEV}}\Temp\media` (job copies in `.comfy-jobs\`) |
| Templates | `video_ltx2_3_t2v.json` and `video_ltx2_3_i2v.json` next to this file |

Templates: Comfy-Org/workflow_templates, tag v0.11.96 = commit
`67984637eefcd4825dcf5c134e39034785be1682` (2026-10-22), fetched from the pinned commit and
SHA-256 checked by the script:

| File | SHA-256 |
|---|---|
| video_ltx2_3_t2v.json | 7A6C13E24754C2525D176F439A4E1CE230B15D13928F6C303A62C643281A2DA9 |
| video_ltx2_3_i2v.json | 860A9CEA831E5C49E25CE91C6A4FE9E932FFA9A2A0666C911C094651F15E0528 |

The models (all from pinned Hugging Face revisions, checked against size and SHA-256 on
2026-10-28): `ltx-2.3-22b-dev-fp8.safetensors` (27.1 GiB, checkpoints), the distilled-1.1 LoRA
(2.55 GiB), `gemma_3_12B_it_fp4_mixed.safetensors` (8.8 GiB), the abliterated Gemma LoRA (0.59 GiB),
`ltx-2.3-spatial-upscaler-x2-1.1.safetensors` (0.93 GiB). The single
`ltx-2.3-22b-distilled-fp8.safetensors` file is **not** loaded by these templates.

Measured on 2026-10-28/29 (RTX 5060 Ti 16 GB, 31.06 GiB usable RAM): 5 s 1280x720 with sound
86-108 s cold, 82-96 s warm, peak VRAM 15,875 MiB, ComfyUI peak 16.8 GiB working set. Two clean
runs on 2026-10-29 started at 15.94 and 16.19 GiB free; free RAM below 15.9 GiB is refused before
the start (nothing lower has been measured).

## Reinstall and uninstall

The recipe is the one in `~/.claude/skills/image/SKILL.md` ("Reinstall and uninstall"); the models
of this skill are the five LTX files above. Never delete them without the owner's yes.
