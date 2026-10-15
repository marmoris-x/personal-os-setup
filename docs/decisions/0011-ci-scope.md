# ADR 0011 – Scope of the GitHub Actions pipeline

- Date: 2026-10-11
- Status: decided

## Context

Windows runners cost more minutes than Linux (budget: 2000 free minutes/month for private
use). A full system install on the runner (winget programs, Obsidian plugin downloads, model
download) would be slow, flaky and expensive. At the same time the brief requires CI on fresh
Windows with lint, Pester, gitleaks over the whole history, privacy scan, installation with
dummy values and `verify`.

## Decision

Pipeline `ci.yml`, triggers: push to `main` + `workflow_dispatch`. One job on `windows-latest`
with steps:

1. Checkout (`fetch-depth: 0` — gitleaks needs the whole history).
2. Install modules: Pester 5.9.1, PSScriptAnalyzer, powershell-yaml (pinned).
3. PSScriptAnalyzer over all `.ps1` (only errors count).
4. Pester (`tests/`) + the 8 hook suites against the repo copies.
5. gitleaks: the pinned version is downloaded as a release binary (SHA256 check), run over the
   whole history with `.gitleaks.toml`.
6. `setup/tools/privacy-scan.ps1` over the working tree and history (general patterns; the local
   denylist is deliberately missing on the runner — the personal terms do not exist there).
7. Installation check: `install.ps1 -TargetRoot <temp> -NonInteractive -Skip…` with dummy
   values from `tests/fixtures/personal.dummy.yaml`, then `setup/verify.ps1 -TargetRoot` — that is
   the "real installation" in the test target (file level complete, system level deliberately
   not).
8. Not in CI: trufflehog (slow, checks keys online — runs locally in `setup/tools/verify-all.ps1`),
   winget installations, Obsidian downloads, model download.

## Alternatives

- Full system install on the runner: expensive, slow, network-dependent — discarded.
- Linux runner: cannot check Windows paths/registry/tasks — discarded.

## Consequences

- CI proves the file level and all checks honestly; the system level is proven by the local
  `setup/tools/verify-all.ps1` on the real PC. This separation is also stated in the README.
- Since v3.0.0 the repository is public, and standard runners on public repositories do not draw
  on that private-use budget.
