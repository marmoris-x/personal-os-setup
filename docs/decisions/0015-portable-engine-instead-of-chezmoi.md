# 15. Keep the own engine and make it portable, instead of moving to chezmoi

Date: 2026-10-14

## Status

Accepted.

## Context

The repository started as a Windows-only construction kit: one manifest, one installer, a
verifier, a restore path, guard hooks with test suites, and an acceptance run of twenty checks.
Task "make it installable from zero on Windows, macOS and Linux" asked, among other things,
whether the engine should stay or be replaced by the textbook tool for the job.

The candidates:

- **chezmoi** — the reference tool for dotfiles. One binary, Go, templates with a real
  templating language, `.chezmoi.os` for machine-to-machine differences, `run_once` /
  `run_onchange` scripts, works on Windows, macOS and Linux. `twpayne/dotfiles` is the reference
  repository, and the "testable dotfiles with chezmoi" pattern (CI matrix plus a weekly real
  run) is what the cross-platform task asks for in its phase 6.
- **yadm** — a git wrapper around `$HOME`; simplest of all, but it manages exactly one
  destination.
- **Ansible / Nix** — declarative and powerful, and both want a much larger vocabulary than a
  single person's machine needs.

## Decision

The own engine stays, and it becomes portable. Concretely:

- `setup/lib/platform.ps1` answers "which system is this" and "what does the platform map say",
  and nothing else in the engine asks the operating system anything.
- `setup/platform/windows.ps1`, `macos.ps1` and `linux.ps1` hold what only that system can do
  (WinGet and Task Scheduler; Homebrew and launchd; apt/dnf, Flatpak and systemd). These three
  files are the only allowed home of operating-system literals, together with the mirror folders
  `windows/`, `macos/` and `linux/`. Acceptance check I enforces exactly that.
- `setup/platforms.yaml` maps every manifest component to all three systems, with a mandatory
  reason where a component does not exist there.
- PowerShell 7 is the one script language on all three systems (decision D2 of the task). The
  single shell script is `bootstrap.sh`, and it only installs the tools and hands over.

## Why not chezmoi

1. **The system writes outside the home folder.** The vault and the Dev root are separate
   destinations the person chooses, on every system. chezmoi manages one destination (`$HOME`);
   two more would be `run_`-scripts or three separate source states, which is the complexity this
   repository exists to avoid.
2. **The engine is the tested part.** Twenty acceptance checks, eight guard suites, a restore
   journal with SHA256 verification, a red proof for every check. A migration would rewrite the
   layer that holds that proof, and every live path with it.
3. **The guards are Pester-tested PowerShell** and must keep working on Windows unchanged.
   chezmoi would not run them; it would only copy them.
4. **The Windows behaviour is frozen.** The live machine is not to be touched by this task, and
   the export round trip (`export` → repo → `install` → live, byte for byte) is what proves it.
   The engine already has that property; a new engine would have to be given it.

## Triggers to revisit

Move to chezmoi (or another engine) when one of these becomes true:

- the engine needs a real templating language — conditions, loops, per-file logic beyond
  placeholder substitution;
- a fourth destination appears, or the number of per-machine differences grows past what
  `setup/platforms.yaml` can express;
- the maintenance cost of the platform modules exceeds the cost of learning and migrating;
- the engine has to run somewhere PowerShell 7 does not (a NAS, a container without pwsh).

Until then the ADR stands, and the reasoning above is the answer to "why not chezmoi".
