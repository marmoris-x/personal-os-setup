# Updating

Two directions, two flows. Mnemonic: **Changes come into being live, travel into the repo via
export and from there onto every other machine via install.**

## The system was changed (on the source machine)

1. Make the change as usual (edit a file, a new script, a new guard).
2. If it is a **new component**: first enter it in `setup/manifest.yaml`
   (choose the type, see `docs/components.md` for the existing ones).
3. `pwsh setup/export.ps1` — pulls everything into the repo, replaces personal things with placeholders, at
   the end runs through the privacy scanner. With "EXPORT: ABORTED by privacy scan findings" first
   look at the reported places (the output is masked).
4. `pwsh setup\tools\generate-docs.ps1` — regenerate `docs/components.md`.
5. `pwsh setup\tools\check.ps1` — analyzer, Pester, guard suites, docs freshness.
6. Commit (one change, one commit) and push. CI checks the same thing once more on a
   fresh Windows.
7. Doubts whether live system and repo still agree? `pwsh setup\tools\drift-check.ps1` says it
   in one sentence ("DRIFT: none" or the list of deviations; nothing is written).

None of this happens automatically — the export is deliberately a conscious step.

## A machine should get the new state

```powershell
git pull
pwsh -File install.ps1 -Resume      # jumps what the journal has already done
pwsh -File setup/verify.ps1        # must show VERIFY-OK
```

The installer **backs up every file it replaces** into `.install-state\backup\…` and writes
`restore-index.json`. After an unexpected result:

```powershell
pwsh -File setup/restore.ps1 -ListOnly # show what the last run replaced
pwsh -File setup/restore.ps1        # reset exactly these files (SHA256-checked)
```

`setup/restore.ps1` is the emergency brake for the last run; nothing is ever deleted, which is why there
is also no "undo for new things" — new files remain and can simply be deleted if one does not want
them.

## A new program or a new version

- **Programs:** add in `windows/winget-core.json` (belongs to the basic framework) or `windows/winget-optional.json`;
  installing runs via `winget import` and is repeatable
  (`--no-upgrade`: what exists stays, what is missing gets added).
- **Obsidian plugins:** change the version in `setup/manifest.yaml` at the `obsidian-plugin-…` entry;
  the installer loads `main.js`, `manifest.json`, `styles.css` from the GitHub release of the
  pinned version when the version in the vault does not match yet.
- **Tools with their own chain:** trufflehog the installer fetches as the newest GitHub release
  with SHA256 check; uv and gh come via winget.

## What the export deliberately does not do

It **never** changes the live files: exporting means reading and copying. And it commits
nothing — the scanner gate only aborts, the human decides.
