# ADR 0001 – Repo layout: mirror tree in `home/`, `vault/` and `dev/`

- Date: 2026-10-11
- Status: decided

## Context

The repo describes the complete construction of a Windows workstation (Claude Code, vault,
Life OS, guards, profiles, programs) and is to make it reproducible on a fresh PC.
Models: `microsoft/WindowsDeveloperConfig` (manifest + generated copies), `chezmoi`
(source folder mirrors the target locations).

## Decision

The repo mirrors the target structure of the PC in the mirror folders `home/`, `vault/` and
`dev/` with one root per target location:

- `home/` → user profile (`%USERPROFILE%`)
- `home/Documents/` → Documents folder (determined via the Windows API, OneDrive redirection does not matter)
- `vault/` → Obsidian vault (path from `personal.yaml`)
- `dev/` → dev folder structure (path from `personal.yaml`)

In addition the hand-made folders `setup/` (manifest, check scripts, config), `tests/` (Pester),
`windows/` (winget lists, scheduled-task template), `docs/` and `tests/sandbox/`; the Life OS
requirements live next to the code that needs them (`home/.claude/life-os/requirements.txt`).
Everything English: code, file names and documentation for humans.

**Addendum after the first full export:** There is **no** separate `templates/` directory.
Files with `{{placeholders}}` (types `template` and `doc-only`) live in the mirror folders as
well — one file tree, one place to look. The type in the manifest names the intent; what is binding
is the **content**: a `copy` entry whose file carries known placeholders is rendered like a
`template` during installation (the export replaces paths in every live file, also in
`copy`-classified ones). `setup/verify.ps1` checks both — content equal to the rendered expected
value, and no known placeholder left anywhere in the target. Reason for the addendum: the
independent review (review-1) found the gap on 2026-10-11; red proof in
`docs/decisions/0003-placeholders.md`.

## Alternatives

- `src/` style like WindowsDeveloperConfig (sources ≠ target names): more indirection, two names per file.
- Dotfile manager format like chezmoi (`dot_` prefixes): its own ecosystem would be needed.
- Distribution as a Claude Code plugin: see ADR 0007 (rejected).

## Consequences

- A look into the mirror folders `home/`, `vault/` and `dev/` shows directly where a file lands.
- A file name like `.gitignore` would influence Git itself in the repo; such files are stored
  renamed with `store_as` (see ADR 0002/0003) and renamed back during installation.
