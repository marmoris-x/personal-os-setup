# ADR 0005 – Secrets: only names, never values

- Date: 2026-10-11
- Status: decided

## Context

Part of the system are API keys (provider profiles, six research services), tokens (gh, Codex),
Syncthing keys, Kopia/B2 access. None of it may go into the repo, into logs or into CI output.

## Decision

- The repo names secrets **only as names**: `setup/config/secrets.example.md` describes per key what
  it is for, where it lives today, how it is loaded and where to get it.
- Values are set exclusively by the user's existing procedure (taken over unchanged): provider
  keys in `~/.claude/profiles/*.json` (locked files, only via script), research keys as Windows
  environment variables via `setup/powershell/set-research-keys.ps1`
  (`Read-Host -AsSecureString`), gh sign-in via `gh auth login`, Kopia/Syncthing via GUI when
  pairing.
- `install.ps1` **never shows values**, registers MCP servers via
  `claude mcp add-json --scope user` with `${ENV}` placeholders and calls the existing scripts
  for keys.
- `-NonInteractive` (CI) uses only dummy values.
- Two scanners guard the boundary: gitleaks (patterns/history) and `setup/tools/privacy-scan.ps1`
  (local denylist). Both run before every commit (pre-commit hook) and in `setup/tools/verify-all.ps1`.

## Alternatives

- Encrypted secrets in the repo (SOPS/age): key management back with the user, more mechanics
  than benefit for a one-person system.

## Consequences

- On a fresh PC sign-ins remain manual work (see `README.md`, "What stays manual afterwards").
- CI runs are guaranteed to contain no real values; dummy values are in `tests/fixtures/`.
