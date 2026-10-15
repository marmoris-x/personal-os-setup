# ADR 0010 – Test strategy

- Date: 2026-10-11
- Status: decided

## Context

The brief requires: "red first, then green" for every new check, Pester tests for all scripts,
PSScriptAnalyzer without errors, the existing hook test suites run from the repo, a test
installation into an empty target plus `verify`, and CI on fresh Windows.

## Decision

- **Language/tooling:** Pester 5.9.1 (pinned via `Import-Module -RequiredVersion`),
  PSScriptAnalyzer 1.25; execution always with `pwsh` (7.x), the `.ps1` files themselves stay
  5.1-compatible (ASCII-only for hook files per existing rule).
- **Levels:**
  1. Unit tests: filter/placeholder logic, manifest schema, scanner patterns (with fixtures).
  2. Integration: `install.ps1 -TargetRoot <temp> -NonInteractive` against a **new empty
     target** → `setup/verify.ps1 -TargetRoot` → green; `setup/restore.ps1` round trip with hash
     comparison.
  3. Guards: the 8 existing suites run with `-Hook <repo path>` against the **repo copies**.
  4. Overall: `setup/tools/verify-all.ps1` (12 checks, section 7 of the brief) is the acceptance.
- **Red proof:** Every new check is shown red once on a deliberately broken copy (fixture with
  sample SVNR/email/key for the scanner; seed secret for gitleaks; broken manifest for schema
  tests) — evidence documented in the respective commit/log.
- **CI:** mirrors the commands that run locally (lint, Pester, gitleaks history, privacy scan,
  install+verify in the test target); CI pins: dummy values only (see ADR 0011).
- **Boundary honestly named:** tests that would need the real user profile, winget or scheduled
  tasks do NOT run against the real system; they are restricted to TargetRoot mode or `-WhatIf`
  and are visibly separated from that in `setup/tools/verify-all.ps1`.

## Consequences

- Every change to scripts: run `setup/tools/check.ps1` (lint + Pester), then commit.
