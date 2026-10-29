# 22. Local video generation with LTX-2.3 via comfy-cli

Date: 2026-10-29

## Status

Accepted. The owner's yes of 2026-10-28 covers only the two models named there (Wan 2.2 TI2V 5B
and LTX-2.3 22B distilled FP8); this ADR records that the comparison kept LTX-2.3 and that Wan
was removed with the owner's explicit yes.

## Context

The owner wants `/video <what the clip shows>` next to `/image`: a short clip from this PC's own
GPU, local only, in a skill that a session without the call never carries. ADR 0019 allowed no
video model without the owner's yes. The yes of 2026-10-28 granted exactly two downloads: Wan 2.2
TI2V 5B and LTX-2.3 22B (the distilled FP8 checkpoint with its text encoder and upscaler), with no
custom node, no ComfyUI-Manager, no GGUF loader, no Hugging Face login and no LTX-2.5.

The first report (`video-skill-task.md`, Parts 0-3, `C:\Dev\Temp\video\BERICHT.md`) measured both
models. A second task (`video-compare-task.md`) re-measured memory cleanly and ran a blind A/B on
the same size, frame count and seed for both models, so the quality verdict no longer mixed
prompts and resolutions. The owner watched the eight blind clips, answered in the chat, the
mapping was revealed, and the decision rule kept LTX-2.3. Wan was deleted on 2026-10-29 with the
owner's explicit yes (three files, 18,144,966,705 bytes); nothing of it is left on disk.

## Decision

| What | Where | Why |
|---|---|---|
| The model | LTX-2.3 22B: `ltx-2.3-22b-dev-fp8.safetensors` plus the distilled-1.1 LoRA at strength 0.5, exactly what the official templates load | The blind test preferred it in 2 of 4 pairs clearly and Wan in none; about 6x faster; sound in the same pass; free for private use under the LTX-2 Community License |
| The instructions | personal skill `~/.claude/skills/video/` with `disable-model-invocation: true` | Zero tokens in every session that does not call it, the same rule as `/image` (ADR 0019) |
| How the agent drives ComfyUI | the `comfy` command (comfy-cli), no MCP server | The same choice as ADR 0019: the CLI is the context-cheap route |
| The script | `scripts/new-video.ps1`: finds nodes by type, starts the server only when nothing answers, prompt is data, `-Image` for image to video, `-Seconds`, `-Width/-Height`, `-Seed`, `-KeepRunning`, `-Stop`, pinned template with SHA-256 | Mirrors `new-image.ps1`, so nothing new has to be learned |
| The portable copy | `~/.agents/skills/video-portable/` with `agents/openai.yaml` (`allow_implicit_invocation: false`) and OpenCode `metadata` (`autoinvoke: false`, `slash: true`) | `@video-portable <wish>` in OpenCode, `$video-portable <wish>` in Codex, no `$ARGUMENTS` |
| The tests | `tests/Video.Tests.ps1` with stand-ins for `comfy` and `nvidia-smi` | Red first (16 of 21 failing against the missing script); the review added four cases (GPU holder, desktop noise on the Windows GPU list, odd size, hash of an existing template), red first too. 25 of 25 green after |
| The templates | fetched from the pinned commit, checked by SHA-256, **not** in the repository | A decimal number in the templates matches the privacy scan's 12-digit rule; the guard stays unchanged |

Rules that hold for the skill and its script:

- One model. No model switch, no Wan, no LTX-2.5, no GGUF, no second video model. A CUDA or RAM
  out-of-memory answer ends in a German text and exit 1; nothing retries with another model.
- Local only: never `comfy setup`, never Comfy Cloud, never `COMFY_API_KEY`, never `comfy generate`.
  Every `comfy run`, `jobs` and `download` call carries `--where local`. ComfyUI starts with
  `--disable-partner-nodes` and listens on `127.0.0.1:8188` only; tracking stays off.
- Free-RAM guard before every start: the measured ComfyUI working-set peak of the clean re-measure
  (17,214.6 MiB = 16.81 GiB) plus 4 GiB = **20.8 GiB free**. Below that the script refuses in
  German, names the five programs using the most memory and starts nothing. It never closes a
  program itself and never starts a job that can freeze the PC.
- ComfyUI is stopped after the clip when this run started it; a server that already answered is
  never touched. `-KeepRunning` keeps it.
- Before it starts a server, the script asks `nvidia-smi` for compute apps. While another model
  program holds the card (LM Studio, Ollama, VoiceStudio), it refuses, names the program and its
  MiB and starts nothing; it never stops that program itself.
- The pinned SHA-256 is checked on an existing template too, not only on a fetch: the settings go
  into the subgraph instance by position, so a template whose promoted-widget order changed would
  otherwise take the prompt in the wrong slot. A template that no longer matches is never used.
- Frame rule: LTX-2.3 wants 8n+1 frames. The templates work in whole seconds at 24 fps
  (24 s + 1), so every allowed duration obeys the rule; measured sizes are 49 frames (drafts) and
  121 frames (5 s).
- Text inside the picture is unusable: the sign tests drew plausible-looking Arabic that spells
  invented words, and LTX mirrored it in one warm run. Real text, titles and subtitles come from
  the motion studio, never from the model. SKILL.md says so.

## Measured on this PC (RTX 5060 Ti 16 GB, driver 617.42, 31.06 GiB usable RAM, ComfyUI 0.42.0)

### Part 3 test set, 2026-10-28

| Id | Model | Job | Cold (s) | Warm (s) | Peak VRAM (MiB) | Peak RAM (GB) | Result |
|---|---|---|---|---|---|---|---|
| W2a/W2b | Wan 5B | 1280x704, 121 frames | 557.7 / 562.1 | 567.8 / 532.8 | 14,616 / 14,556 | 29 | ok, no audio |
| L2a/L2b | LTX-2.3 | 1280x720, 121 frames | 107.9 / 100.6 | 86.0 / 89.1 | 15,632 / 15,875 | 30 | ok, audio present |
| L1a/L1b | LTX-2.3 | 768x512, 49 frames | 70.5 / 63.0 | 52.0 / 46.5 | 15,559 | 29 | ok, audio present |
| L3 | LTX-2.3 | 768x512 i2v | 50.4 | 34.7 | 15,555 | 29 | ok |

No out-of-memory, no time limit. Wall clock includes model load.

### Clean memory re-measure, 2026-10-29

| Value | LTX-2.3 (P1) |
|---|---|
| Free RAM before the start | 18.47 GiB |
| ComfyUI working set, peak | 17,214.6 MiB (16.81 GiB) |
| ComfyUI private bytes, peak | 35,967.2 MiB (35.12 GiB) |
| System used, peak | 29.74 GiB |
| Free RAM, minimum | 1.32 GiB |
| Committed, peak | 57.69 GiB |
| VRAM, peak | 15,758 MiB |

The private-bytes peak is commit charge, not resident memory. The guard uses the working-set peak,
which is what physically competes with other programs.

### Blind A/B, 2026-10-29

Eight clips, 1280x704, 121 frames, 24 fps, same seed, sound removed (`-an`) and identical
re-encode. Mapping: P1 A=LTX/B=Wan, P2 A=LTX/B=Wan, P3 A=Wan/B=LTX, P4 A=LTX/B=Wan.

| Question | LTX-2.3 | Wan 2.2 5B | equal | unclear |
|---|---|---|---|---|
| Looks more real | 3 (P2, P3, P4) | 0 | 1 (P1) | 0 |
| Motion looks natural | 2 (P3, P4) | 0 | 1 (P1) | 1 (P2) |
| Matches the description / the start picture | 1 (P3) | 0 | 1 (P1) | 2 (P2, P4) |
| Better overall | 2 (P3, P4) | 0 | 1 (P1) | 1 (P2) |

Pair wins: LTX clear in P3 and P4, tendency in P2, equal in P1; Wan in none. Even if P2 counted for
Wan, the rule needs 3 of 4 and finds 1. **Result: keep LTX-2.3.** Why Wan was not kept: about
6x slower per clip (mean 522.4 s against 87.9 s for 5 s at the same size), no sound, and the
image-to-video face was "completely distorted" while LTX stayed close to the start picture.

### Proof of the built skill, 2026-10-29

- Three fresh `claude-ds` sessions (the vault, a project folder, the Temp folder) each made one
  clip and read its contact sheet (122.4 s, 129.3 s, 134.8 s; the `Read` calls are in the
  session transcripts). A fourth session ran the final script after the review fixes (130.7 s,
  clip read, port closed). A direct text-to-video run at 5 s 1280x720 and a direct
  image-to-video run at 2 s 768x512 (68 s including the server start) worked with the real
  templates.
- The RAM guard refused live at 20.58 GiB and at 20.54 GiB free (German text, the five programs
  named, nothing started) and let the three sessions run at 22.1-23.3 GiB.
- The contact sheet first used fixed 30-frame steps and left two black tiles on a 49-frame clip;
  it now spreads four frames over the clip with ffprobe (n/3, 2n/3, last), re-checked on the
  same clip.
- The review of the same day found and fixed: the GPU-holder refusal was missing, an odd
  width/height was accepted, and an existing (not fetched) template was used without its hash
  check; tests for all three came first. The first GPU check was wrong in the other direction:
  on Windows `nvidia-smi` lists every graphics process (24 lines, desktop apps, `[N/A]` MiB), so
  the rule is now a known model program by name or a reported use of 1 GiB and more, with a
  test that a desktop process on that list does not block a clip.
- `/context all` lists neither `image` nor `video`; a plain sentence in an empty folder did not
  start the skill (the session fetched an online clip instead). One honest limit: a session
  started inside the evidence folder found the script by searching the disk and ran it; the
  skill description itself is not in any context.

## The claims table, measured

| Claim | Measured result |
|---|---|
| LTX-2.3 fits the 16 GB card fully, no offload, 5 s clip in 60-80 s | **False in two points.** The checkpoint is 27.14 GiB and does not fit in 16 GB; ComfyUI loads it with dynamic VRAM and offload (12.7 GB pinned memory, peak 15.9 of 16.3 GB VRAM, 30 GB RAM). A 5 s 1280x720 clip with sound took **86-108 s**, not 60-80 s |
| Wan 2.2 5B needs 24-27 GB, so hours on 16 GB | **False.** A 5 s 1280x704 clip took **532.8-567.8 s (about 9 min)**, no OOM; peak 14.2-14.6 GB VRAM, 29 GB RAM. The 24-27 GB belong to the model card's command line without offload |
| LTX makes 20 s clips up to 4K | **Not measured and not confirmed.** A vendor claim without a consumer-card reference; NVIDIA's guide asks for 5 s (121 frames) in this class. Only 2 s and 5 s clips were tested |
| This PC has 32 GB RAM | **Confirmed with a caveat.** 2 x 16 GiB Kingston installed = 32 GB; Windows reports 31.06 GiB usable (33,346,736,128 bytes) |
| Licence of LTX-2.3 | **Not Apache-2.0, the "LTX-2 Community License Agreement"** (model card license_name, licence date 5 January 2026). See the quotes below |
| Text in the picture (from the task) | **Unusable.** Both models drew plausible-looking letters that spell invented words; LTX mirrored them in one warm run |

## Licence of the chosen model

Source: `LICENSE` of the pinned model repository `Lightricks/LTX-2.3-fp8`
(revision `91eda216f820e5ecb3d17dc9fe3b7cdaf56b587d`), saved in
`C:\Dev\Temp\video\licenses\LICENSE-2.txt`, 19,196 bytes. Quoted word for word:

> limited license under Licensor's intellectual property or other rights owned by Licensor embodied
> in LTX-2 to use, reproduce, prepare, distribute, publicly display, publicly perform, sublicense,
> copy, create derivative works of, and make modifications to LTX-2, for any purpose, subject to the
> restrictions set forth in Attachment A; provided however, that Entities with annual revenues of at
> least $10,000,000 (the "Commercial Entities") are required to obtain a paid commercial use license
> in order to use LTX-2 and Derivatives of LTX-2, subject to the terms and provisions of a different
> license (the "Commercial Use Agreement"), as will be provided by the Licensor.

> Any commercial use of LTX-2 or Derivatives of LTX-2 by the Commercial Entities not in accordance
> with this Agreement and/or the Commercial Use Agreement is strictly prohibited and shall be deemed
> a material breach of this Agreement.

Attachment A restricts, among others, commercial use "to train, improve, or fine-tune any other
machine learning model, artificial intelligence system, or competing model, except for Derivatives
of LTX-2 as expressly permitted under this Agreement".

For this owner (private use, revenue below the threshold) the licence grants use for any purpose
royalty-free. The threshold is a fact of the licence, not a legal opinion.

## Rejected options

- **LTX-2.5** (August 2026): on 16 GB it runs only as GGUF through the ComfyUI-GGUF custom node,
  and its Hugging Face repositories are gated. Both are outside the owner's yes; it stays an option
  for a later decision, not a part of this skill.
- **Wan 14B**: not covered by the yes, two files of about 14.3 GB each, slower than the measured
  5B, and the 5B already lost the blind test. No test was run.
- **HunyuanVideo**: not covered by the yes and never downloaded or run. After LTX met the goal
  (5 s with sound in under two minutes on this card) there was no reason to widen the yes.
- **Wan 2.2 TI2V 5B**: measured, compared, and removed with the owner's explicit yes on
  2026-10-29 (three files, 18.14 GB; free space rose from 256.34 GB to 261.65 GB, the rest of the
  difference is the system-managed page file growing in the same window).

## Consequences

- No session that does not call `/video` carries the skill or its template; the Skills row of
  `/context all` stays unchanged.
- With a browser open, free RAM often sits below 20.8 GiB; the script then refuses and names the
  programs to close. That is intended: the clean re-measure showed only 1.32 GiB free at the
  deepest point of a run.
- The five model files (42.96 GB) are re-downloadable and not backed up. Deleting them needs the
  owner's yes.
- A reinstall follows the recipe in `~/.claude/skills/image/SKILL.md`; the video skill adds no
  separate ComfyUI.
