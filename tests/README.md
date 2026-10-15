# Tests

Two kinds of tests live here, plus the guard suites that are checked from the repo:

- `Manifest.Tests.ps1` — `setup/manifest.yaml` against the schema (`setup/lib/manifest.ps1`).
  The deliberately broken fixture `fixtures/manifest-broken.yaml` must be rejected.
- `Install.Tests.ps1` — end-to-end on a test target under `_tmp/`: install -> verify ->
  second run is a no-op -> a local edit is backed up and `setup/restore.ps1` brings it back
  (hash-checked). Runs everywhere, CI included.
- `Roundtrip.Tests.ps1` — the placeholder round trip. The strong part needs the live
  machine and `personal.yaml` and is SKIPPED in CI (reported, not hidden): it renders
  every exported repo file with the real values and compares it to the live original,
  byte for byte. Entries with `append`/`drop_lines` intentionally diverge and are counted
  as skipped.
- `Structure.Tests.ps1` — the two rules that keep this repo readable: the tree matches the
  block in `docs/structure.md` (`setup/tools/check-structure.ps1`), and the mirror folders
  hold only what may be installed (the skeleton rule, task section 3.2).
- `Privacy-Scan.Tests.ps1` — the scan's worktree scope stays what it is.
- `Format-Strings.Tests.ps1` — every `-f` template that stands in the source as a string
  literal or an expandable string has to parse. A `{0,>2}` in `setup/tools/verify-all.ps1` made
  the acceptance run throw on its first check line while CI stayed green for two commits.
  A template assembled at runtime is out of reach here — the test says so in its own header.
- The guard suites (`test-block-dangerous.ps1` and friends) are NOT copies here: they live
  in `home/.claude/setup/tests/` and are run from a rendered copy of the tree by
  `setup/tools/check.ps1`.

Run everything the way CI does:

```powershell
pwsh setup/tools/check.ps1
```

## Two Pester 5 pitfalls met in this repo (write tests accordingly)

1. Code at the top level of a test file runs during DISCOVERY only. Variables it sets are
   NOT visible in `It` blocks at run time — setup used by tests belongs in `BeforeAll`.
2. `-Skip:` conditions are evaluated during DISCOVERY as well. A flag that must control
   `-Skip` has to be computed at top level too (see `Roundtrip.Tests.ps1`), because
   `BeforeAll` has not run yet.
