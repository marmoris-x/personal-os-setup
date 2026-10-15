# ADR 0014 – Final folder layout, the two naming rules and the skeleton rule

- Date: 2026-10-12
- Status: decided

## Context

The repo worked, but a visitor could not tell in ten seconds what it is or which command to
run. The root held eleven folders and thirteen files, three of which were scripts next to seven
more in `tools/`. The mirror tree hid under `targets/HOME`, `targets/VAULT`, `targets/DEV`,
`targets/DOCUMENTS` — upper-case, abstract, and one folder (`DOCUMENTS`) that is not a
directory of its own on the machine but a Windows known folder. Two different `.githooks`
(the repo's own and the installed one) were easy to confuse, two folders (`winget/`,
`scheduled-tasks/`) held machine setup apart from each other, and one script lived in
`life-os/` at the root for no better reason than history.

Worse, the mirror folders had slowly filled with the owner's own material: his task files, his
research results, run records, and three vault working notes. The repo is supposed to install a
**system**, not to carry a copy of his data — and anything that sits in it also sits in the git
history and on GitHub.

Models for the target layout (read 2026-10-12): `twpayne/dotfiles` (a `home/` folder plus four
files at the root), `thoughtbot/dotfiles` (config files stored without the leading dot),
`kepano/obsidian-skills`, `ballred/obsidian-claude-pkm`, the chezmoi source-state model
("the source tree is the desired target state"), GitHub's "Scripts to Rule Them All" (one
obvious command per job) and the MADR convention for the decision records in
`docs/decisions/`.

## Decision

1. **A small, self-explaining root**: eight folders (`.github/`, `dev/`, `docs/`, `home/`,
   `setup/`, `tests/`, `vault/`, `windows/`) and eight files, of which `install.ps1` is the only
   entry point for a human. `setup/tools/check-structure.ps1` compares the tree with the block
   in `docs/structure.md`, and `setup/tools/verify-all.ps1` check B compares the root with the
   documented list, so neither can drift.

2. **The mirror folders are named after where they install to**: `home/` → `%USERPROFILE%`,
   `home/Documents/` → the Windows Documents folder, `vault/` → the vault path, `dev/` → the dev
   root. Lower-case, no abstract tokens.

3. **The two naming rules live in exactly one place**, `setup/lib/manifest.ps1`:
   - `Get-RepoRelPath` maps the manifest root token to the repo folder
     (`HOME`→`home`, `DOCUMENTS`→`home/Documents`, `VAULT`→`vault`, `DEV`→`dev`).
   - `Get-StoredLeaf` strips the dot of `.gitignore`, `.gitattributes`, `.gitleaksignore`,
     `.kopiaignore` and `.stignore`; `Get-RepoFileRel` combines both and honours `store_as`.
   Every caller — export, install, verify, the docs generator, the tests — goes through those
   functions. No script spells a mirror path out by hand any more. This replaces the per-entry
   `store_as: "gitignore"` of ADR 0001 with one rule that cannot be forgotten on a new entry.

4. **`store_as` keeps exactly one job**: a starter template is stored as `<name>.tmpl` and
   installed without the suffix (`vault/000-meta/index.md.tmpl` → `000-meta/index.md`). The dot
   rule is automatic and must not be repeated in the manifest.

5. **The skeleton rule.** A mirror folder holds rules, settings, templates, scripts, skills and
   hooks. A working file whose structure matters but whose content is the owner's becomes an
   empty starter template. Everything that records his own situation — task files, notes,
   research results, recordings, transcripts, run records, session state, live provider
   profiles — stays out of the repo and stays on his PC. `tests/Structure.Tests.ps1` states the
   allowed kinds and fails on anything else; the rules are written as "what is allowed", never
   as a blocklist of file names, so a new kind of personal file is caught too.

6. **`setup/` is the tooling's home**: manifest, export, verify, restore, `lib/`, `tools/`,
   `config/` (the two examples a human reads) and `githooks/` (this repo's own pre-commit hook,
   which the installer points `core.hooksPath` at). The root keeps only `install.ps1`, because a
   stranger has to find one command.

7. **`windows/` holds machine setup that is configured, not copied**: the two winget lists (no
   longer two files in one folder of their own) and the scheduled-task template.

8. **The run state of the export leaves the repo**: `.export-state.json` became
   `%USERPROFILE%\.personal-os\state\export-state.json`. It names every file the last export
   wrote; that is local state, not content. It was gitignored before; now it cannot be committed
   by accident either. `VERSION` was dropped: no file read it, and the version comes from the
   git tag and `CHANGELOG.md`.

9. **Names that are data stay German.** The repo is English, but a folder inside the owner's
   vault (`inbox/audio/erledigt`), the name of his archive folder (`Dokumentenarchiv`, from
   `personal.yaml`), the phrases that trigger a skill ("Morgenroutine", "hol die Doku") and the
   German sample text the research tooling matches on are *his* data, not the repo's prose.
   Renaming them would restructure his vault or weaken a skill. `setup/tools/check-language.ps1`
   lists every tolerated file with its reason and never tolerates one silently.

### Deviation from the target layout of the task

The task's tree writes `docs/install-with-an-agent.md` under `docs/`; that is what it is.
It also lists `sandbox/ultimate-setup.wsb` → `tests/sandbox/personal-os.wsb`, which is done.

One point deliberately deviates: the task names the file `vault/stignore` (stored without the
dot for consistency with the other four). That is what the dot rule produces, so no deviation
remains there. The only real deviation is that `home/Documents/` had to stay inside `home/`
rather than becoming a fifth mirror folder at the root: the Windows Documents folder *is* under
the user profile, and two separate mirror folders would render the same subtree twice.

## Consequences

- A reader sees in one table which folder installs where; `docs/structure.md` prints the whole
  tree and a check keeps it true.
- Renaming an installed file (as with `morgen.ps1` → `morning.ps1`) is a change to the live
  system, not just to the repo: export reads the live name. Every such rename is therefore a
  logged live change, applied through the installer, and the scheduled task has to be
  re-registered with it.
- 196 KB of the owner's own material left the repo (task files, research results, run records).
  It stays on his PC; only the repo copy is gone, and with it the GitHub copy.
- The language rule now has a machine check with a written, visible exception list. Adding an
  exception is a visible edit, not a silent one.
- `docs/decisions/0001-repo-layout.md` is superseded by this record where the two disagree about
  the layout; its reasoning about the manifest and the mirror idea still holds.
