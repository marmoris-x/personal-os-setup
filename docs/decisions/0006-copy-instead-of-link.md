# ADR 0006 – Copying instead of linking

- Date: 2026-10-11
- Status: decided

## Context

In 2026 Claude Code had several bugs with links under Windows (skills via junctions are not
loaded, the desktop app ignores linked skills, `CLAUDE_CONFIG_DIR` is partly ignored).
Symlinks need admin rights or developer mode under Windows (not active here).

## Decision

- The installer **copies** files to their target locations, there are no junctions/symlinks.
- For target files that already exist: back up (timestamp backup + `setup/restore.ps1` index), show
  differences, replace only with `-Force`. **Implemented on 2026-10-11:** Without `-Force` a
  differing file stays as it is (message per file + manual-step note, counter
  `different-without-Force`); with `-Force` the installer replaces after backup.
- Deviations between live system and repo are found by `setup/tools/drift-check.ps1` (reporting
  only), not by a link system at runtime.

## Alternatives

- Junctions to the repo: known to be error-prone (see context), discarded.
- Symlinks: admin rights/developer mode needed, discarded.

## Consequences

- Two copies (repo and live) can drift; exactly for that reason there are `setup/export.ps1` (one
  direction, live → repo) and `setup/tools/drift-check.ps1` (report, no auto-fix).
