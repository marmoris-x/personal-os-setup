# 19. Local image generation via comfy-cli, no MCP

Date: 2026-10-23

## Status

Accepted.

## Context

The owner wants to type `/image <what the picture shows>` in any session and get a picture from
their own GPU, without opening a ComfyUI window, and wants every session that makes no picture to
carry none of it. ComfyUI Desktop is uninstalled and stays so: its FAQ says it "does not support
headless, server-only, or remote operation modes" (https://docs.comfy.org/installation/desktop/faq).

## Decision

| What | Where | Why |
|---|---|---|
| The program (other people's code) | `<Dev>\External\ComfyUI` | The Dev folder `External` is for other people's repositories: read and run them, do not modify. |
| The instructions | personal skill `~/.claude/skills/image/` with `disable-model-invocation: true`; no CLAUDE.md line, no CLAUDE.md in the ComfyUI folder | With that flag the description is not in context and the skill loads only when invoked (https://code.claude.com/docs/en/skills). Zero tokens in every session, usable everywhere as `/image ...`. CLAUDE.md is for what applies broadly (https://code.claude.com/docs/en/best-practices); a CLAUDE.md inside the ComfyUI folder would load only in sessions started there. |
| How the agent drives ComfyUI | the `comfy` command (comfy-cli), **no MCP server** | "CLI tools are the most context-efficient way to interact with external services" (https://code.claude.com/docs/en/best-practices). comfy-cli installs, launches, stops, runs local workflows and downloads outputs (https://github.com/Comfy-Org/comfy-cli). The official `comfy-mcp` is beta with 40 tools (https://github.com/Comfy-Org/comfy-local-mcp). |
| Models (about 19 GB) | ComfyUI's own `models` folder | No other program reads these files, so a shared models folder would remove no duplicate. ComfyUI's `.gitignore` lists `/models/`, so `comfy update` (git pull) never touches them. If a second program needs the same files, move the folder then and point both at it with `extra_model_paths.yaml`. |
| Results | `<Dev>\Temp\media` | The same rule as all media scratch; keeping a file moves it as usual. |

Rules that hold for the skill and its script:

- Local only: never `comfy setup`, never sign in to Comfy Cloud, never `COMFY_API_KEY`, never
  `comfy generate` (beta, routes to partner models). Every `comfy run`, `jobs` and `download`
  call carries `--where local`.
- ComfyUI starts with `--disable-partner-nodes` and listens on `127.0.0.1:8188` only; both are
  saved once with `comfy set-default`.
- No custom nodes, no ComfyUI-Manager, no second model, no video model without the owner's yes.
  Exactly one ComfyUI on the machine. Tracking off (`comfy tracking disable`).
- One model: Z-Image-Turbo (template `image_z_image_turbo`, three files: diffusion model 11.5 GB,
  text encoder 7.5 GB, VAE 0.3 GB; "fits within 16GB VRAM consumer devices",
  https://docs.comfy.org/tutorials/image/z-image/z-image-turbo.md).
- `scripts/new-image.ps1` finds the nodes it edits by type (the template keeps its sampler graph
  in a subgraph), starts the server only when nothing answers, and explains a CUDA out-of-memory
  error in German without falling back to another model. Its Pester suite is `tests/Image.Tests.ps1`.
- The official template is **not** kept in this repository. One decimal number in it
  (twelve digits after the point, line 439) matches the privacy scan's 12-digit rule, and the owner chose to leave the
  guard unchanged and the template out. `new-image.ps1` fetches the file from a pinned commit of
  `Comfy-Org/workflow_templates` the first time it is missing and refuses it unless its SHA-256
  matches. The manifest entry `claude-skills` excludes the file from the export.
- The portable copy `~/.agents/skills/image-portable/` is manual-only in OpenCode
  (`metadata`: `opencode/autoinvoke: "false"`, `opencode/slash: "true"`,
  https://opencode.ai/docs/skills/) and in Codex (`agents/openai.yaml`,
  `policy.allow_implicit_invocation: false`, https://learn.chatgpt.com/docs/build-skills.md).
- comfy-cli is recorded as the manifest component `comfy-cli` (a manual step, like the models: not
  installed by `install.ps1`, about 20 GB and an NVIDIA GPU).

## Measured on 2026-10-23 (RTX 5060 Ti 16 GB, driver 617.42, comfy-cli 1.23.0, ComfyUI 0.42.0)

- GPU proof inside the workspace `.venv`: Python 3.13.15, torch 2.14.1+cu130, capability `(12, 0)`.
- First picture 35.9 s including model load, later pictures about 15 s at 1024 x 1024.
- Three fresh `claude-ds` sessions (vault, a project, the Temp folder) each made and saw a picture
  (session times 64.3 s cold including the server start, then 30.3 s and 28.9 s).
- Zero cost when unused: the Skills row of `/context all` is 4.5k with and without the skill, and
  `image` is not listed.
- A plain sentence asking for a picture of a dog, without `/image`, does not start the skill. The session
  then improvised with an online image service; the local-only rule exists only inside the skill.
- After `-Stop`, no ComfyUI process remains and the port is closed.

## Consequences

- Nothing about images is in any session that does not call `/image`.
- A reinstall or uninstall is two recipes in the skill (`comfy stop`, move the models away,
  delete with the owner's yes, install again).
- `comfy install --workspace=<dir>` uses `<dir>` itself as the target (comfy-cli 1.23.0), not
  `<dir>/ComfyUI` as its README says, and `--fast-deps` writes `override.txt` and
  `requirements.compiled` into the current folder: run it from a scratch folder.
