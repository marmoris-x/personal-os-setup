# ADR 0009 – Python environments

- Date: 2026-10-11
- Status: decided
- Amended (2026-10-16): the venv is built with the pinned interpreter through
  `Get-PlatformLifeOsPython` (`python3.13` on macOS and Linux, `py -3.13` on Windows), not with
  a bare `python`/`python3` from PATH - Python 3.15.0 (2026-10-09) has no ctranslate2 wheel, so
  a fresh Mac failed the whole venv on "No matching distribution found for ctranslate2". The
  installer aborts with a named cause when the only interpreter found is newer than the newest
  wheel (3.14); the pins are `python@3.13` in macos/Brewfile and `Python.Python.3.13` in
  windows/winget-core.json.

## Context

Part of the system are: system Python 3.13 (for the research check scripts, invocation
`python -I -X utf8 …`), a dedicated venv for the transcription under `%LOCALAPPDATA%\life-os\venv`
(faster-whisper 1.2.1, ctranslate2 4.8.2, av 18.1.0, CUDA libraries; it was created with
`python -m venv`, not with uv) and `uv` as a fast helper (installed via winget,
`astral-sh.uv`; lands in `~\.local\bin`).

## Decision

- The setup repo contains **no** venvs and no model weights (recoverable, large).
- `install.ps1` creates the Life-OS venv with `python -m venv` (today's procedure kept) and
  installs the pinned packages from `home/.claude/life-os/requirements.txt` (versions with measurement
  date).
- The faster-whisper model `large-v3-turbo` downloads into the HuggingFace cache on first run
  (optional install step `-WithWhisperModel`, ~1.6 GB; not in CI).
- `uv` and `gh` are installed from `windows/winget-core.json` (winget stage); only trufflehog is
  fetched directly from the official GitHub release (SHA256-checked).
- Research scripts run with system Python (`python -I`), no dedicated venv — kept.

## Alternatives

- uv for everything: would reinvent venv; today's procedure is proven and the brief says
  "keep the procedure, do not change it".

## Consequences

- `home/.claude/life-os/requirements.txt` carries the date it was frozen from the live venv; updating is its
  own step.
