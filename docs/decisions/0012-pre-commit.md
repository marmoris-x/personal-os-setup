# ADR 0012 – Pre-commit protection in the repo

- Date: 2026-10-11
- Status: decided

## Context

The user's global pre-commit (`core.hooksPath = ~/.githooks`) runs with gitleaks but has a
known, documented gap: if `gitleaks` is missing, it **lets everything through** (exit 0). The
brief requires a pre-commit hook with gitleaks **and** privacy scan for this repo.

## Decision

- The repo ships `setup/githooks/pre-commit`; it is set **repo-locally**
  (`git config core.hooksPath setup/githooks`), not globally.
- The hook runs **fail-closed**: if gitleaks or pwsh is missing, it ends with an error and
  blocks the commit (put positively: protection only counts when the tool is there — here that
  is enforced).
- Content: 1) `gitleaks git --pre-commit --staged --redact --config .gitleaks.toml`,
  2) `pwsh setup/tools/privacy-scan.ps1 -Staged` (only the staged files, fast).
- Red proof is mandatory and documented: a commit with a seed secret and with a sample SVNR
  must fail.

## Alternatives

- Extending the global hook: would affect all the user's other repos — not our brief.
- No hook, CI only: too late (a secret in the history is expensive).

## Consequences

- `--no-verify` remains technically possible (self-declaration, as usual with the existing
  guards); the hook protects against accidents, not against intent.
