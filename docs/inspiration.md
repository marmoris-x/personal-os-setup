# Role models — and what we adopted from them

Research from 2026-10-11 (web/GitHub only, every statement with a source URL; the long version with all
45 sources lay before the session as a working note). This document names per role model: what it is,
what **this repo** adopted (with location) and what deliberately not.

## 1. microsoft/WindowsDeveloperConfig

Manifest-driven Windows setup by Microsoft itself (3,105 stars, MIT).

- **Adopted:** "manifest as the single truth" (ADR 0002) and the CI structure
  (install → test → summary) in simplified form (`.github/workflows/ci.yml`).
- **Not adopted:** signature pipeline and C# command palette (pointless without signature
  infrastructure); their reboot-resume mechanics (scheduled task + `shutdown.exe /r`) — our setup
  has no stages requiring a restart, `-Resume` is enough. Honestly noted: WDC has **no
  `-WhatIf`** (it says so under "Known limitations"); our `install.ps1` has one.
- Source: https://github.com/microsoft/WindowsDeveloperConfig

## 2. WinGet Configuration (`winget configure`)

Declarative YAML for machine state (schema v2: `.config/configuration.winget`; v3: dscv3).

- **Not adopted as a backbone:** Microsoft is currently migrating **away** from the
  DSC model in its own CI; elevation and non-interactivity are immature (open issues #5243,
  #5871). With us, programs come from `windows/winget-core.json` + `windows/winget-optional.json` via
  `winget import` (JSON with `SourceDetails`, checked on 2026-10-11).
- Sources: https://learn.microsoft.com/en-us/windows/package-manager/configuration/ ·
  https://github.com/microsoft/winget-cli/issues/5243

## 3. chezmoi

Dotfile manager (21,889 stars, MIT). Source folder mirrors target locations.

- **Adopted:** the basic idea "repo mirrors target structure" (ADR 0001) and the
  secret principle "only the **reference** into the repo, never the value" (ADR 0005 + `setup/tools/privacy-scan.ps1`
  as a safety net during export — chezmoi's `add --secrets warning` as the model).
- **Not adopted:** chezmoi itself. It synchronizes files; packages, tasks and
  registry are not its assignment — two systems side by side cost more than they bring.
- Source: https://chezmoi.io/

## 4. johncwaters/claude-setup (archived)

`~/.claude` as a repo with profiles; the README itself says "Do not use it to bootstrap a machine".

- **Adopted:** the idea "rendered instead of tracked live files" (with us:
  the mirror folders `home/`, `vault/` and `dev/` + placeholders + `install.ps1`). The idea of a "no longer wanted" list
  (convergence) is noted as an extension in BERICHT, v1 does not have it.
- **Not adopted:** the overhead structure (eval harness, dashboards); no license, no fork.
- Source: https://github.com/johncwaters/claude-setup

## 5. ballred/obsidian-claude-pkm

Vault template with skills (1,877 stars, MIT).

- **Adopted:** folder names as variables instead of hard-wired (with us `personal.yaml`),
  and "safe updates": backups with timestamp before every overwrite + `setup/restore.ps1`.
- **Not adopted (v1):** the `/adopt` mode (read and map an existing vault) —
  our use case is the fresh PC; noted as an extension in BERICHT.
- Caution (from the research): the `capabilities` object in ballred's `plugin.json` is
  **not an official field** and is silently removed when loading — do not copy it.
- Source: https://github.com/ballred/obsidian-claude-pkm

## 6. louisfb01/obsidian-agent-vault-template

Pure Markdown template (50 stars, MIT).

- **Adopted:** the feedback loop is already a property of the live system
  ("second correction ⇒ rule", `docs/lessons.md` skeleton in `home/.claude/docs/`).
- **Not adopted:** Markdown only, no installer, no tests.
- Source: https://github.com/louisfb01/obsidian-agent-vault-template

## 7. affaan-m/ECC (everything-claude-code)

Large Claude Code configuration package. Star count (276,653) deliberately **not** used as
a quality proof (not independently confirmed in the research).

- **Adopted / confirmed:** rules and `CLAUDE.md` are distributed by the **installer**, not a
  plugin — officially documented ("A `CLAUDE.md` at the plugin root isn't loaded"; alternative route skill
  or hook). Agrees with ADR 0007. Also adopted: "never activate hooks implicitly" —
  with us the guards come as files + `settings.json` with the regular install, nothing
  secretly loads code afterwards.
- **Not adopted:** the scope (306 skills, 71 agents …).
- Source: https://github.com/affaan-m/ECC

## 8. kepano/obsidian-skills

Six small Obsidian skills (49,381 stars, MIT, Obsidian maintainer).

- **Adopted:** The skills (`obsidian-markdown`, `-bases`, `json-canvas`, `-cli`) already lie
  in the live vault and travel along via the export
  (`vault/.claude/skills/…`). Not installed as a plugin, but as files —
  this way the version stays visible in the repo.
- Source: https://github.com/kepano/obsidian-skills

## Technical facts from the research (with sources)

- **Windows sandbox:** Education edition **included** (Home not). `.wsb` format:
  `MappedFolders` (`HostFolder` must exist, relative paths not allowed),
  **a single** `LogonCommand`, `MemoryInMB` (minimum applies at 2048), `ReadOnly` true recommended for
  host folders (changes in writable mappings **survive** discarding).
  **winget is missing in the sandbox.** → `tests/sandbox/personal-os.wsb` uses exactly that.
  Source: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox-configure-using-wsb-file
- **GitHub runner:** `windows-latest` is currently Windows Server 2025 and has **winget
  preinstalled** (x64; it is missing on `windows-11-arm`). Our CI does not need winget
  (test installation runs against `-TargetRoot`), but checks its existence at run time.
  Sources: https://github.com/actions/runner-images · https://github.com/actions/runner-images/issues/14083
- **`claude plugin validate <path> [--strict] [--json]`** exists with CI-suitable
  exit codes (0/1/2) — noted as a future additional check, v1 does not need it (we distribute
  no plugin, ADR 0007).
  Source: https://code.claude.com/docs/en/plugins/cli-reference
- **`@` imports** in CLAUDE.md: depth **four** hops, `@~/…` allowed, imports save
  **no** context (only order). Path-scoped rules (`paths:` frontmatter) are the
  real context saver.
  Source: https://code.claude.com/docs/en/memory
- **Additional finds** (small, 0–5 stars, ideas only): Laoujin/Perch (`deploy --dry-run` +
  pre/post hooks per module), risu729/dotfiles (instructions and mechanics in the same repo),
  roest1/dotfiles ("Toggling is commenting", `status` command as drift detection — with us
  planned in phase 7 as a drift check). `cuberhaus/WinDotfiles` no longer exists
  (`gh api` → 404) and was discarded.
