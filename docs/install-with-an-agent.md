# docs/install-with-an-agent.md — instructions for an AI agent setting up this machine

This file is the runbook for an agent (Claude Code or similar) that installs or extends this
setup on a **Windows, macOS or Linux** machine. Read `CLAUDE.md` (repo rules),
`setup/manifest.yaml` (the single source of truth), `setup/platforms.yaml` (which component
works on which system) and `docs/components.md` (generated component list) first.

## Hard rules (do not violate)

1. Never delete or move user files. The installer only writes and replaces; a replaced file
   was backed up first (`setup/restore.ps1` undoes it).
2. On the machine that BUILD the setup (the source machine), never run `install.ps1` without
   `-TargetRoot`. Live installs are for fresh machines only.
3. Test installs go into a NEW EMPTY directory: `-TargetRoot C:\some\empty\dir`, or
   `/home/you/empty-dir` on macOS and Linux. Both spellings work on every system.
4. Nothing personal (names, accounts, keys, device IDs) may ever be written into the repo or
   into a commit message. Personal values live in `~/.personal-os/personal.yaml`
   (`%USERPROFILE%\.personal-os\personal.yaml` on Windows), on that machine only.
5. If a guard hook on the machine blocks an action, do not work around it. Report what was
   blocked. Temporarily pausing a guard is a documented, owner-approved exception only.

## Installing on a fresh machine

The short way is `bootstrap.ps1` (Windows) or `bootstrap.sh` (macOS, Linux): it installs git,
the GitHub CLI and PowerShell 7 with the system's own package manager, signs in, clones the
repository and runs the installer. The long way, step by step:

1. Clone the repository and enter it.
2. Ask the human for the personal values or let `install.ps1` ask interactively; in unattended
   runs pass `-ConfigPath` pointing at a personal.yaml you prepared.
3. Run the installer. Windows, where PowerShell 5.1 is enough to start:
   `powershell -ExecutionPolicy Bypass -File install.ps1` (it brings PowerShell 7 along by
   itself, with or without winget). macOS and Linux:
   `pwsh -File install.ps1 -NonInteractive` once a personal.yaml exists — `bootstrap.sh`
   installs PowerShell 7 first, because the installer needs it.
   Useful switches, the same on every system: `-Profile minimal` (core only),
   `-Components <ids>` (only the named components), `-Force` (replace an existing differing
   file after backup - without it the file stays and the summary lists it), `-DryRun`/`-WhatIf`
   (show; writes nothing outside its own `.install-state` folder), `-WithOptional`, `-SkipWinget`, `-Resume`.
4. Read the summary: every stage prints OK / PREVIEW / SKIP / WARN / ERROR, then a manual-
   steps list. Stages that need more rights than the run has skip themselves and appear in the
   manual list; rerun `install.ps1 -Resume` with those rights afterwards. Which ones those are
   depends on the system: Windows needs an elevated PowerShell for the scheduled task's logon
   trigger, the firewall rule and `LongPathsEnabled`; Linux needs `sudo` for `apt-get`/`dnf`
   and the Flatpak apps; on macOS the launch agent and the Homebrew packages need none of that.
5. Run `pwsh setup/verify.ps1` and confirm `VERIFY-OK`. Fix nothing by hand before reading the
   failing component's line and its reason.
6. Walk the human through the manual steps printed at the end (sign-ins, keys, Kopia/Syncthing
   pairing, Obsidian first start). Details: `README.md` ("After install"), `docs/updating.md`.

## Verifying a test installation (CI does the same)

```powershell
pwsh -File install.ps1 -TargetRoot /tmp/empty-dir -ConfigPath tests/fixtures/personal.dummy.yaml -NonInteractive
pwsh -File setup/verify.ps1 -TargetRoot /tmp/empty-dir -ConfigPath tests/fixtures/personal.dummy.yaml
```

`C:\empty\dir` in place of `/tmp/empty-dir` is the same thing on Windows. A second identical
install run must report `new 0, replaced 0` (idempotent). `setup/restore.ps1 -TargetRoot <dir>`
brings back anything a run replaced.

## Running the checks

```powershell
pwsh setup/tools/check.ps1  # analyzer (0 errors), Pester, guard suites from a rendered tree
pwsh setup/tools/privacy-scan.ps1 # worktree; -History for the whole history; -Staged for the hook
```

The same commands run in CI on Windows, Linux and (on releases, weekly and on request) macOS.
Three guard suites are Windows-only because the cases and the guards under test are Windows
text; `check.ps1` prints a `SKIP` line with that reason on the other two systems instead of
leaving them out silently. Before committing anything, `pwsh setup/export.ps1` must finish with
`EXPORT-OK` and the privacy scan must stay clean.

## Adding or changing a component

1. Add or edit the entry in `setup/manifest.yaml` first (types: copy, template, doc-only, dir,
   winget, task, mcp, obsidian-plugin, generated; see `docs/decisions/0002-manifest.md`).
2. Answer for all three systems in `setup/platforms.yaml` — `files`, a verb of the vocabulary
   listed at the top of that file, or `unsupported: <reason>`. `docs/platforms.md` is generated
   from it, and the acceptance run (check H) fails when an entry is missing or when a promised
   file is not in the repo.
3. For copy/template: run `pwsh setup/export.ps1` on the source machine to pull the live file into
   the mirror folders `home/`, `vault/` and `dev/`. Never write personal values into the mirror
   folders by hand. A file that only another system uses has no live counterpart on the source
   machine and is written in the repo by hand; the manifest refuses a component whose content is
   missing, so this cannot be forgotten silently.
4. Regenerate the docs: `pwsh setup/tools/generate-docs.ps1`.
5. Run `pwsh setup/tools/check.ps1`, then commit (one step per commit, Conventional Commits).
   The acceptance run `pwsh setup/tools/verify-all.ps1` is the wider net: it checks the platform
   map, the package files, the scheduler units and the CI jobs as well.

## Update flow on a running machine

`git pull` → `pwsh -File install.ps1 -Resume` → `pwsh setup/verify.ps1`. The installer backs up any
file it replaces; `setup/restore.ps1` undoes the last run. Never `git push --force`, never rewrite
published history.

## When something fails

- `personal.yaml is missing` → run without `-NonInteractive` once, or write the file from
  `setup/config/personal.example.yaml`.
- `TargetRoot is not empty` → the safety check; use a new empty directory (or the same
  directory that carries an earlier `.install-state/install-journal.json`).
- `pwsh is missing` → Windows: `powershell -ExecutionPolicy Bypass -File bootstrap.ps1`;
  macOS and Linux: `./bootstrap.sh`. Both install PowerShell 7 first.
- `manifest.yaml invalid: … the file it promises is missing in the repo` → a component installs
  content nobody wrote. Write that file (or drop the component); never point the entry somewhere
  else to silence it.
- Packages `WARN unknown distribution` (Linux) → not one of the tested distributions; install the
  printed list with its own tool, then `-Resume`. `WARN Homebrew is missing` (macOS) → install it
  from <https://brew.sh>, then `-Resume`.
- A guard blocks a tool call → read the block message; it names the allowed alternatives.
  Report to the human; do not retry variants to slip past it.
- A verify FAIL names the component; inspect that file/stage, fix the manifest or the local
  value, rerun export (source machine) or install (target machine).
- More: `docs/troubleshooting.md`.
