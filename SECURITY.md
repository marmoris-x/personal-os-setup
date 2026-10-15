# Security policy

## What this repository is

A construction kit that rebuilds one person's working environment on Windows, macOS and Linux:
Claude Code with its guard hooks, an Obsidian vault skeleton, Life OS, PowerShell profiles, a
Git and gitleaks chain, scheduled jobs, backup and sync.

**It is one person's setup.** You adapt the personal layer for your own machine; you do not
adopt it as it stands. Read what a stage does before you run it.

## What it does with your machine

- `install.ps1` writes into the target you name. It copies files, registers scheduled jobs and
  writes the personal values it is given. Without `-TargetRoot` it acts on the machine you are
  sitting on. Start it with `-WhatIf` first, or into an empty folder.
- The guard hooks under `home/.claude/hooks/` run before tool calls of a Claude Code session.
  They are fail-closed: input they cannot read is refused. Read them before you register them.
- No component of this repository sends anything anywhere by itself. There is no telemetry and
  no update check.

## Reporting a problem

Use GitHub's **private vulnerability reporting** for this repository: open the *Security* tab
and choose *Report a vulnerability*. That report is visible to the maintainer alone. It is
switched on as part of the release - it cannot be enabled while the repository is private, so
the acceptance run's check S demands it, together with secret scanning and push protection,
from the moment `setup/config/repo.yaml` says the release happened.

Please do not open a public issue for a security problem.

What helps a report:

- which file and which version (the tag, or the commit),
- what happens, and what you expected instead,
- the smallest way to reproduce it,
- for a guard hook: the exact tool call that got through or was wrongly refused.

There is no bug bounty and no response-time promise. This is a personal project, maintained in
its author's spare time.

## What is out of scope

- **The personal layer.** `~/.personal-os/` belongs to whoever runs this, not to the
  repository. A leak of your own values there is not a defect of this project.
- **Secrets you put into the tree.** The scans (`privacy-scan.ps1`, gitleaks, trufflehog) and
  GitHub's push protection are there to catch it, but they find known shapes, never everything.
- Anything that requires the machine of the maintainer to reproduce.
