# ADR 0002 – `setup/manifest.yaml` is the single source of truth

- Date: 2026-10-11
- Status: decided

## Context

Export (live → repo), install (repo → PC), verify and the documentation must know the same
list of components; otherwise they drift apart (main weakness of the old blueprint approach,
see `inventar-c` section 3.9).

## Decision

Every component appears exactly once in `setup/manifest.yaml`. Fields per entry:

| Field | Meaning |
|---|---|
| `id` | unique, lowercase, hyphens |
| `area` | `claude` \| `vault` \| `life-os` \| `research` \| `backup` \| `guards` \| `powershell` \| `windows` \| `dev` \| `git` |
| `type` | `copy` \| `template` \| `dir` \| `generated` \| `winget` \| `task` \| `mcp` \| `obsidian-plugin` \| `doc-only` |
| `source` | live path with root token `{HOME} {DOCUMENTS} {VAULT} {DEV}` (only for `copy`/`template`) |
| `target` | target in the mirror tree, root token `HOME/ DOCUMENTS/ VAULT/ DEV/` |
| `store_as` | optional: deviating file name in the repo (e.g. `gitignore` → target `.gitignore`) |
| `core` | `true`/`false` – core or deselectable (`-Profile minimal` takes only the core) |
| `vars` | names of the `personal.yaml` values that are filled into the template |
| `replace` | replacement rules of the export: `root` (path root → placeholder) or `var` (value from personal.yaml → placeholder) |
| `test` | optional note on the intended check (informational; `setup/verify.ps1` derives its check from `type`) |

`setup/export.ps1`, `install.ps1`, `setup/verify.ps1` and the docs generator read exclusively this file.
YAML is read with the `powershell-yaml` module.

## Alternatives

- JSON manifest: harder for humans to read, no comments.
- One list per script: exactly the drifting apart that is to be avoided.

## Consequences

- New components go into the manifest first, then into the scripts' effect.
- A Pester test checks the schema (IDs unique, types known, targets under known roots).
