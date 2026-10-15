# personal-os-setup — instructions for agents working ON this repo

This repo is a manifest-driven construction kit that rebuilds a personal working environment
on **Windows, macOS and Linux**: Claude Code with its guard hooks, an Obsidian vault skeleton,
Life OS (voice-note transcription), PowerShell profiles, Git/gitleaks chains, scheduled jobs
and backup/sync. The original system stays where it is; this repo holds the general, reusable
construction — never the personal content.

`setup/manifest.yaml` is the single source of truth for *what* is installed.
`setup/platforms.yaml` is the single source of truth for *where and how* — which component
exists on which system, which package source, which scheduler. `setup/export.ps1`,
`install.ps1`, `setup/verify.ps1`, `setup/restore.ps1`, the docs generator and
`setup/tools/verify-all.ps1` all read both. A component that is not in the manifest does not
exist for any tool; add components there first, then its platform entries.

## Platform first

These rules are binding for every agent that installs, exports, verifies or restores:

1. **Detect the system before you touch anything.** `pwsh -c '$IsWindows; $IsMacOS; $IsLinux'`
   (or `uname -s` when pwsh is missing) and, on Linux, read `/etc/os-release`. Write the
   result at the top of your notes. Never assume Windows because the repository was written
   there.
2. **Use only what the maps give you for that system.** `setup/platforms.yaml` and
   `docs/platforms.md` name the paths, package sources and schedulers per operating system.
   Never use Windows paths, `winget`, Task Scheduler or registry commands on macOS or Linux,
   and never Homebrew, launchd or systemd on Windows.
3. **A component marked `unsupported` is skipped and reported**, with the reason from the map.
   Do not invent a replacement for it.
4. **Locations are the person's decision.** The vault and Dev folders are asked at install and
   stored in `~/.personal-os/personal.yaml`. Never choose or change them yourself.
5. **Logins, keys and passwords are typed by the person.** Never ask anyone to paste a secret
   into the chat, and never write one into a file.
6. **Finish with `pwsh setup/verify.ps1`** and report its result — on a test target with
   `-TargetRoot`, on a live machine without it.

## Hard rules

1. **Nothing personal, ever** — not in files, commit messages, branch names, CI logs or history.
   Personal values live in `%USERPROFILE%\.personal-os\personal.yaml` (outside the repo).
   Secrets appear only as names (`setup/config/secrets.example.md`), never as values.
2. **Directions are fixed:** `setup/export.ps1` is live → repo. `install.ps1` is repo → target
   and always backs up before overwriting (`setup/restore.ps1` brings the original back).
3. **Red before green:** every new check fails once on a seeded, deliberately broken fixture
   before it is trusted. Show it, then make it pass.
4. **Encoding:** hook `.ps1` files stay ASCII-only (Windows PowerShell 5.1 reads BOM-less files
   in the ANSI code page; a crash lets calls through). JSON/Markdown as UTF-8 without BOM.
5. **The pre-commit hook stays fail-closed:** missing gitleaks/pwsh blocks the commit instead
   of passing it silently.
6. **Two naming rules, one place.** Where a target lives in the repo and how a target file is
   stored are decided only in `setup/lib/manifest.ps1`. Never spell a mirror path out by hand
   in a script; call `Get-RepoFileRel`. See `docs/structure.md`.

## Check commands

```powershell
pwsh setup/tools/check.ps1                # PSScriptAnalyzer + Pester + hook suites (same as CI)
pwsh setup/tools/drift-check.ps1          # live vs repo in one line; exit 1 when they drifted apart
pwsh setup/export.ps1                     # live -> repo; afterwards `git status` must be clean
pwsh install.ps1 -TargetRoot <empty dir> -NonInteractive   # install into a test target
pwsh setup/verify.ps1 -TargetRoot <empty dir>   # verify an installed target
pwsh setup/tools/privacy-scan.ps1         # denylist + general patterns; exit 1 on findings
pwsh setup/tools/check-structure.ps1      # repo tree vs the block in docs/structure.md
pwsh setup/tools/check-language.ps1       # every tracked file must be in English
pwsh setup/tools/verify-all.ps1           # the acceptance run (twelve points plus A-P)
```

The acceptance run ends with a **live** `install.ps1 -WhatIf` (check P). The test install covers
only the file stages; the OS stages and the summary block run on a real machine alone, and a
helper that only they call is invisible to every other check. That is how a missing `Add-Manual`
survived in `install.ps1` for months. The cross-platform checks H to O sit before it: the
platform map and every file it promises, no Windows literals in the portable engine, a Windows
install byte-identical to v2.1.2, the hook wiring, the agent instructions, the two bootstrap
files, and the CI run itself.

## Layout

- `home/`, `vault/`, `dev/` — the mirror folders: files exactly as they land on a target
  machine. Nothing else lives there (the skeleton rule, `docs/structure.md`).
- `home/Documents/` is the Windows Documents folder, resolved through the known-folder API.
- `windows/` — machine-level setup that is configured, not copied (winget lists, task template).
- `setup/` — the tooling: manifest, export, install support, check scripts, `setup/lib/` with
  the shared naming rules, `setup/githooks/` with this repo's own pre-commit hook.
- `tests/` — Pester (`*.Tests.ps1`), fixtures, the Windows sandbox description.
- `docs/` — English docs for humans, plus `docs/decisions/` (MADR).
- `install.ps1` at the root — the only entry point for humans.

## Style

Everything in English (this repo is meant to be published): docs for humans in plain words;
code, comments, filenames and commit messages likewise. Keep changes small and in the existing
style; one commit per finished step, Conventional Commits. When the tree changes, update
`docs/structure.md` (`pwsh setup/tools/check-structure.ps1 -Write`) in the same commit.
