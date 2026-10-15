# ADR 0013 – Installer stages beyond the manifest, journal and backup

- Date: 2026-10-11
- Status: decided

## Context

The manifest (ADR 0002) knows nine types. Some core steps fit into none of them: Git global
config (`core.hooksPath`, `longpaths`, `defaultbranch`), the firewall rule for Syncthing,
`LongPathsEnabled` in the registry, PowerShell modules, the Life-OS venv and the tool
downloads (uv, gh, trufflehog). Nevertheless it holds: a component that nobody checks does
not exist.

## Decision

1. `install.ps1` runs **fixed stages** in this order; each is idempotent ("already present" is
   success, not an error) and writes one line to the journal after success:
   preflight → backup → files (copy/template/doc-only) → dirs → git-config → winget →
   task → mcp → obsidian-plugins → life-os-venv → own-tools → firewall/longpaths → summary.
2. **Journal + resume:** `.install-journal.json` next to the journal location of the target;
   `-Resume` skips completed stages. No state that lives only in memory.
3. **Backup before overwriting:** every file that would be replaced first goes into the backup
   folder; `restore-index.json` (created, root, entries with path/stored/SHA256) is the basis for
   `setup/restore.ps1`. Nothing is
   **ever** deleted or moved — only written or replaced.
4. **Test mode:** with `-TargetRoot` all file stages run against an empty root; the OS stages
   (winget, task, mcp, venv, firewalls) are **only rendered** (preview files under
   `<TargetRoot>\.install-state\preview\`) and not executed. That way no test changes the live system.
5. **Admin stages** (task, firewall, longpaths) detect missing rights, skip themselves with a
   clear message and end up in the final report as manual steps — no abort in the middle of
   the run, no silent continuation.
6. **Transcript:** every run writes a log (`-TranscriptPath`, default under the journal
   folder). The final report lists per stage: ok / skipped / preview / error.
7. These stages are listed in the BERICHT and explained in `docs/structure.md`; they are the
   only deviation from the "everything in the manifest" principle and deliberately documented
   as such.

## Alternatives

- New manifest types (`git-config`, `firewall`, …): would bloat the schema without any
  repetition per entry being needed — there is exactly one such stage in each case.
- Leaving everything to the human: contradicts the goal "fresh PC in a few steps".

## Consequences

- `setup/verify.ps1` checks file stages at the target and OS stages only in live operation
  (Get-ScheduledTask, `git config --global --get`, `Get-NetFirewallRule`, registry).
- `-WhatIf` shows the stages including estimated changes, without writing.
