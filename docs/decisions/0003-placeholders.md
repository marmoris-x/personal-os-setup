# ADR 0003 – Placeholder syntax `{{NAME}}`

- Date: 2026-10-11
- Status: decided

## Context

Files contain machine-dependent values (user path, vault path, real name, GitHub account).
They are never allowed into the repo with real values, but they must be put back in during
installation.

## Decision

- Placeholders look like this: `{{NAME}}` (double curly braces, uppercase letters).
- Built-in placeholders: `{{HOME}}`, `{{DOCUMENTS}}`, `{{VAULT}}`, `{{DEV}}` – filled at runtime
  from `[Environment]` or `personal.yaml`, never hard-wired.
- Personal placeholders: `{{USER_NAME}}`, `{{GITHUB_ACCOUNT}}` and more – values live **only**
  locally in `%USERPROFILE%\.personal-os\personal.yaml` (see ADR 0004).
- The export replaces the live values **with** the placeholders (never implement it the other
  way round: the repo never contains real values at any point in time).
- Replacements in the manifest name only the variable (`var: USER_NAME`), never the value.
- Files that Git itself would interpret (`.gitignore`) are stored with `store_as`
  (e.g. `gitignore`) and renamed during installation – otherwise the target `.gitignore` in the
  repo would hide all neighboring files.

## Alternatives

- `${NAME}`: collides with PowerShell variables in `.ps1` files.
- `<NAME>`: collides with HTML/XML tags.

## Consequences

- `install.ps1` fills placeholders and fails when a needed value is missing (no silent empty).
- `setup/verify.ps1` checks that no `{{…}}` are left over after installation.

## Addition after the first full export (2026-10-11)

Practice showed four **representation styles** of the same path and additional placeholders.
The complete, fixed list (only these are replaced — runtime placeholders of other systems
like `{{N_SOURCES}}` of the research system remain untouched):

| Family | Styles | Example (style) |
|---|---|---|
| `HOME` | `{{HOME}}` `{{HOME_FWD}}` `{{HOME_JSON}}` `{{HOME_BASH}}` | `C:\Users\…` / `C:/Users/…` / `C:\\Users\\…` / `/c/Users/…` |
| `DOCUMENTS` | the same four styles | Documents folder (OneDrive can redirect it) |
| `ARCHIVE` | the same four styles | folder **next to** `DOCUMENTS` (sibling, not child!) |
| `VAULT` | `{{VAULT}}` `{{VAULT_JSON}}` `{{VAULT_BASH}}` | only the styles that actually occur are in use |
| `DEV` | `{{DEV}}` `{{DEV_FWD}}` `{{DEV_JSON}}` `{{DEV_BASH}}` | |
| Names | `{{USER_NAME}}` `{{USER_GIVEN}}` `{{USER_FAMILY}}` `{{USER_FAMILY_UPPER}}` | |
| Other | `{{GITHUB_ACCOUNT}}` `{{B2_BUCKET}}` `{{MORNING_TIME}}` `{{BACKUP_TIME}}` | values only in `personal.yaml` |
| Install machine | `{{INSTALL_DATE}}` `{{USER_SID}}` `{{START_BOUNDARY}}` | computed during installation |

Rationale for the styles: JSON files escape backslashes (`\\`), Git Bash scripts use
`/c/Users/…`, Markdown partly forward slashes. Within a style the longer path is replaced
first (`ARCHIVE` before `DOCUMENTS` before `HOME`), otherwise the shorter one eats the prefix
of the longer one.

`type: doc-only` (skeletons) is rendered like a template, but only created when the file is
missing at the target — an existing personal document is never overwritten.

## Addendum 2026-10-11 (after the independent review, review-1)

The review found a gap: `copy` files were copied byte-exact, although the export also replaces
paths in them with placeholders (25 of 54 entries affected, among them the morning-run code).
Since the fix the **content** decides: if a `copy` file carries known placeholders,
`install.ps1` renders it like a `template`; otherwise it stays byte-exact. `setup/verify.ps1`
compares such files with the rendered expected value and reports every placeholder form left
behind (only `{{N_SOURCES}}` is allowed). Proven red with the old version: 389 placeholder
lines in 47 files in the fresh test target (replication review-2; own first run 395 lines),
`verify` nevertheless reported `VERIFY-OK` exit 0.

## Addendum 2026-10-13 – render-time placeholders stay out of mirrored files

A file the export mirrors (`type: copy` or `template`) must not carry a placeholder that is
computed at render time (`{{INSTALL_DATE}}`, `{{USER_SID}}`, `{{START_BOUNDARY}}`): the export
cannot reverse a value it does not know. `{{INSTALL_DATE}}` had a pair that read the install
journal, and a partial install run (`install.ps1 -Components`) moves the journal's date without
re-rendering every file - on 2026-10-13 that made `drift-check.ps1` report the live
`vault/000-meta/backup.md` as changed. The date in that mirrored note is content now; the
placeholder stays in the install-once skeletons (`type: doc-only`), which the export never
mirrors. `tests/Roundtrip.Tests.ps1` enforces the rule (it fails on any mirrored file carrying
one of the three).

## Addendum 2026-10-14 – the `_BASH` style of a path without a drive letter

`Convert-PathStyle -Style bash` answered only for a path that starts with a drive letter and
returned nothing otherwise. On macOS and Linux the roots are `/home/…` and `/Users/…`, so
`{{HOME_BASH}}`, `{{DEV_BASH}}` and `{{ARCHIVE_BASH}}` never entered the map, the mirrored
files kept the raw token, and `verify.ps1` reported `unknown placeholders` in the ubuntu job
(measured 2026-10-14). A rooted path without a drive letter is now its own bash spelling, in
whichever separator the host that built the string used (a Windows test that joins
`/Users/check` and `Dokumentenarchiv` produces a backslash path, and `Join-Path` does not ask
who is looking); a UNC path becomes `//server/share`, which is what Git Bash calls it. Windows
keeps every answer it had: its roots are drive paths, and the first branch is unchanged.
`tests/Platforms.Tests.ps1` renders every text file of the mirror with the roots each system
really has and fails on any token left behind, which is the check that would have seen this on
Windows.
