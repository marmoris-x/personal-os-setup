# setup

How the system is exported, checked and restored. This folder is tooling — nothing in it is
copied onto a target machine. The one exception is `config/`, which holds the two example files
a human reads before the first install.

## The commands

Run them from the repo root:

| Command | What it does |
|---|---|
| `pwsh install.ps1` | repo → PC. Renders the placeholders and writes every component to its place. The only entry point for humans. |
| `pwsh setup/verify.ps1` | Compares every manifest component with the installed reality. Add `-TargetRoot <dir>` for a test install. |
| `pwsh setup/export.ps1` | PC → repo. Writes every changed system file back into the mirror folders, then runs the privacy scan. |
| `pwsh setup/restore.ps1` | Puts back the files the last install run replaced (index with SHA256). |
| `pwsh setup/tools/check.ps1` | The repo's check command: PSScriptAnalyzer, Pester, the guard suites, docs freshness. CI runs exactly this. |
| `pwsh setup/tools/drift-check.ps1` | One line: does the live system still match the repo? |
| `pwsh setup/tools/privacy-scan.ps1` | Personal patterns in the worktree, the history or the staged changes. |
| `pwsh setup/tools/check-structure.ps1` | The repo tree against the block in `docs/structure.md`. |
| `pwsh setup/tools/check-language.ps1` | Every tracked file against the language rule (English). |
| `pwsh setup/tools/verify-all.ps1` | The acceptance run: twelve points plus A–H, each with command, output and exit code. |
| `pwsh setup/tools/generate-docs.ps1` | Rewrites `docs/components.md` from the manifest. |

## The manifest

`setup/manifest.yaml` lists every component of the system exactly once. Nothing else decides
what gets installed: a component that is not in the manifest does not exist for any of the
tools. Its own header comment explains the types (`copy`, `template`, `doc-only`, `dir`,
`winget`, `task`, `mcp`, `obsidian-plugin`, `generated`).

Fixed stages that deliberately do **not** stand in the manifest — git config, firewall rule,
`LongPathsEnabled`, the PowerShell modules — are described in
`docs/decisions/0013-install-stages.md`.

## The naming conventions

Two rules decide where a target lives in this repo and how it is stored. Both are written down
in exactly one place, `setup/lib/manifest.ps1`:

1. **Repo folder per target root.** Manifest targets start with a root token:

   | Token | Repo folder | Installs to |
   |---|---|---|
   | `HOME/` | `home/` | `%USERPROFILE%` |
   | `DOCUMENTS/` | `home/Documents/` | the Windows Documents folder (known-folder API) |
   | `VAULT/` | `vault/` | the vault path from `personal.yaml` |
   | `DEV/` | `dev/` | the dev root from `personal.yaml` |

2. **Stored without the dot.** A target file whose dotted name git itself would interpret
   inside this repo is stored without the dot and installed with it: `.gitignore`,
   `.gitattributes`, `.gitleaksignore`, `.kopiaignore`, `.stignore`. Hidden *folders*
   (`.claude`, `.obsidian`, `.config`, `.githooks`) keep their dot — git does not interpret
   those. `store_as:` is the one exception: a starter template is stored as `<name>.tmpl` and
   installed as `<name>`.

Further conventions:

- `*.tmpl` marks a file with `{{placeholders}}` that is rendered at install time.
- A `README.md` at the top of `home/`, `dev/`, `windows/` or `setup/` is documentation and is
  never installed. `vault/README.md` **is** installed.
- Names are lower-case with dashes, except where the target tool requires otherwise
  (`Microsoft.PowerShell_profile.ps1`, `CLAUDE.md`, `AGENTS.md`, `README.md`,
  `TROUBLESHOOTING.md`, `*.Tests.ps1`).
- The mirror folders hold only what may be installed. What that means is written in
  `docs/structure.md` and enforced by `tests/Structure.Tests.ps1`.

## What lives here

```
setup/
├── config/            personal.example.yaml, secrets.example.md  (examples a human reads)
├── githooks/          this repo's OWN pre-commit hook (fail-closed; install sets core.hooksPath)
├── lib/               manifest.ps1 (the two naming rules), placeholders.ps1
├── tools/             check, drift-check, check-structure, check-language, generate-docs,
│                      privacy-scan, verify-all
├── export.ps1         PC -> repo
├── restore.ps1        put back what the last install replaced
├── verify.ps1         compare the manifest with an installed target
└── manifest.yaml      the single source of truth
```
