# Structure

How the repo works, in short sections. The decisions behind it stand in `docs/decisions/`
(0001–0016), the components in `docs/components.md` (generated from the manifest).

## What this repo is

A construction kit that rebuilds a Windows workspace: Claude Code with its guard hooks, an
Obsidian vault skeleton, Life OS (voice notes → transcript → morning report), PowerShell
profiles, the Git and gitleaks chain, scheduled tasks, backup and sync templates.

The root is deliberately small: **8 folders and 8 files**. Everything else lives inside one of
them.

## The one source: `setup/manifest.yaml`

Every component of the system stands exactly once in the manifest: files, templates, skeletons,
folders, programs, the scheduled task, MCP servers, Obsidian plugins. `setup/export.ps1`,
`install.ps1`, `setup/verify.ps1`, the docs generator and `setup/tools/verify-all.ps1` read
only this file. A component that is not in the manifest does not exist for the tools.

Three exceptions deliberately stand *not* in the manifest, but as fixed stages in the installer
(`docs/decisions/0013-install-stages.md`): Git global config, firewall rule and
`LongPathsEnabled`, the PowerShell modules.

## The mirror folders: `home/`, `vault/`, `dev/`

The repo installs the **system**, not the owner's data. A mirror folder holds exactly what the
installer writes onto a machine, plus the documentation next to it:

| Mirror | Installs to | What it holds |
|---|---|---|
| `home/` | `%USERPROFILE%` | `.claude` (hooks, rules, skills, agents, settings), the Windows Documents profiles, the global git hook |
| `vault/` | the vault path | the Obsidian vault skeleton: work folders, rules, templates, skills, plugin settings |
| `dev/` | the dev root | the rule template for other people's repositories |

`home/Documents/` is the Windows Documents folder, resolved through the known-folder API
(OneDrive redirection does not matter). `windows/` is *not* a mirror: it holds machine-level
setup that is configured rather than copied (winget lists, the scheduled-task template).

### The skeleton rule

For every file in a mirror: rules, settings, templates, scripts, skills and hooks stay; a
working file whose structure matters but whose content is personal or time-bound becomes an
empty starter template (`.tmpl`); anything that records the owner's own situation — task files,
notes, research results, recordings, transcripts, run records — never enters the repo.
`tests/Structure.Tests.ps1` enforces the mechanical part of that rule.

### Three naming rules, written down in one place

All live in `setup/lib/manifest.ps1` and nowhere else:

1. **Where a target lives in the repo.** Manifest targets start with a root token:
   `HOME/` → `home/`, `DOCUMENTS/` → `home/Documents/`, `VAULT/` → `vault/`, `DEV/` → `dev/`.
2. **How a target file is stored.** A dotted name that git itself would interpret inside this
   repo is stored **without** the dot and installed **with** it:
   `.gitignore`, `.gitattributes`, `.gitleaksignore`, `.kopiaignore`, `.stignore`.
   Hidden *folders* (`.claude`, `.obsidian`, `.config`, `.githooks`) keep their dot — git does
   not interpret those. `store_as:` is the one exception, for a starter template that is stored
   as `<name>.tmpl` and installed as `<name>`.
3. **Which targets must be executable** on macOS and Linux: every file under a githooks
   folder (`Test-ExecutableTarget`). A copy carries no mode, and git skips a hook that is not
   executable — silently. `install.ps1` sets the bit, the git index carries it for a clone, and
   `tests/Hooks.Tests.ps1` proves both.

Further conventions:

- `*.tmpl` marks a template with `{{placeholders}}`, rendered at install time.
- `README.md` at the top of `home/`, `dev/`, `windows/` and `setup/` is documentation and is
  never installed. `vault/README.md` **is** installed — it is the vault's own readme.
- All names are lower-case with dashes, except names the target tool requires:
  `Microsoft.PowerShell_profile.ps1`, `CLAUDE.md`, `AGENTS.md`, `README.md`,
  `TROUBLESHOOTING.md`, `*.Tests.ps1`.

Files with `{{placeholders}}` live in the mirror as well. What is binding is the **content**: a
`copy` entry whose file carries known placeholders is rendered like a `template` during
installation; `verify.ps1` lets no known placeholder through in the target.
Git cannot store empty folders. Folders that carry no file of their own therefore stand as
`dirs:` entries in the manifest, and the installer creates them: the vault work folders
(`vault-dirs`: the numbered category folders, the inbox paths, `outbox`, `trash`, plus
`000-meta/todo-archive` and `500-sources/research` — where a research run
stores the pages it read) and the dev root with its two work folders (`dev-dirs`: `DEV`,
`DEV/Projects`, `DEV/Temp`). The repo itself carries no placeholder file (no `.gitkeep`): the
manifest is the written form of the structure, `verify.ps1` checks the folders on an installed
machine, and a Pester test installs into a test sandbox and asserts every `dirs:` entry exists
there. Not taken into `dirs:` are folders that programs create themselves and the owner's
content folders, above all folders whose names would reveal personal content — content decides
those, not the manifest.

## The directions

- **Export (live → repo):** `setup/export.ps1` reads every live file, replaces every personal
  value with its placeholder, writes it into the mirror folder and at the end lets the privacy
  scanner run. If it finds something, the export ends with an error — nothing is ever committed
  automatically. Its run state (`export-state.json`) lives outside the repo, in
  `%USERPROFILE%\.personal-os\state\`.
- **Install (repo → PC):** `install.ps1` renders the placeholders with the values from
  `%USERPROFILE%\.personal-os\personal.yaml` and the paths of the target machine and writes in
  the order of the fixed stages. Idempotent: a second run changes nothing. `-Profile
  minimal` takes only core components, `-Components <ids>` only the named ones; an existing
  differing file stays in place without `-Force` (ADR 0006).

## Placeholders in four spellings

The same path appears in files in four forms: `C:\…` (Windows), `C:/…` (Markdown, JSON
exceptions), `C:\\…` (JSON-escaped) and `/c/…` (Git Bash). Each form has its own
placeholder (`{{HOME}}`, `{{HOME_FWD}}`, `{{HOME_JSON}}`, `{{HOME_BASH}}`). The complete,
fixed list stands in `docs/decisions/0003-placeholders.md`. Runtime placeholders of other
systems (such as `{{N_SOURCES}}` of the research skill) are never touched.

## The fixed installer stages

Order (details in `docs/decisions/0013-install-stages.md`):

1. `preflight` – check the manifest, load values, resolve targets
2. `files` – `copy` (byte-exact; files with known placeholders are rendered like `template`),
   `template` (rendered), `doc-only` (rendered, but only
   created when nothing lies at the target)
3. `dirs` – create folders (never delete)
4. `git-config` – `core.hooksPath`, `core.longpaths`, `init.defaultBranch`
5. `winget` – programs from `windows/winget-core.json` (optional: `windows/winget-optional.json`)
6. `task` – scheduled task "Life OS Morning" from the XML template
7. `mcp` – MCP servers for research (exa, parallel)
8. `obsidian-plugins` – plugin files matching `manifest.yaml` (version pinned there)
9. `life-os-venv` – Python environment from `home/.claude/life-os/requirements.txt`
10. `own-tools` – uv and gh (winget) as well as trufflehog (GitHub release, SHA256-checked)
11. `os-extras` – firewall rule for Syncthing, `LongPathsEnabled` (admin needed)

Every stage writes a line into the journal after success (`-Resume` jumps completed
stages). Every file that would be replaced is backed up beforehand; `setup/restore.ps1` brings
back exactly the last run (index with SHA256). In test mode (`-TargetRoot`) only the
file stages run; the system stages write preview files to `.install-state\preview\`.

## Checking

- `setup/verify.ps1` compares every manifest component with reality: `copy` byte for
  byte, `template` against the rendered text, plus leftover placeholders, folders, and in
  live operation the system pieces (task, MCP, plugins, venv, tools).
- `setup/tools/check.ps1` is the repo's check command: PSScriptAnalyzer (0 errors), Pester
  (`tests/`), the guard suites from a rendered tree, plus the freshness of
  `docs/components.md`. CI calls the same command.
- `setup/tools/check-structure.ps1` compares the repo tree with the block below.
- `setup/tools/privacy-scan.ps1` searches for personal patterns (worktree, `-History`, `-Staged`).
- `setup/tools/verify-all.ps1` is the acceptance check (twelve points plus A–P).

## Tests and the strongest proof

`tests/Roundtrip.Tests.ps1` renders every exported file with the real personal values
and compares it byte for byte with the live original. On the source machine this
test really runs; in CI it is cleanly reported as skipped (there is no
`personal.yaml` there). Alongside it `tests/Install.Tests.ps1` (install → verify → repeat →
restore in the test target), `tests/Manifest.Tests.ps1` (schema, with a broken fixture),
`tests/Structure.Tests.ps1` (the tree and the skeleton rule) and
`tests/Format-Strings.Tests.ps1` (every `-f` template standing in the source as a
literal or expandable string has to parse: a `{0,>2}` in the acceptance script made it
unrunnable while CI stayed green).

## CI and sandbox

`.github/workflows/ci.yml` runs on `windows-latest`: install modules, `setup/tools/check.ps1`,
privacy scan (worktree + history), gitleaks over the whole history. The
Windows sandbox (`tests/sandbox/personal-os.wsb`) is the manual test on a disposable
Windows — repo mapped read-only, `winget` is missing there, so the installer fetches PowerShell 7
by direct download.

## The tree

Every file git tracks, one path per line. `setup/tools/check-structure.ps1` compares this block
with reality, so the two cannot drift apart. Regenerate it with
`pwsh setup/tools/check-structure.ps1 -Write` and read the diff.

<!-- structure-check -->
```text
.gitattributes
.github/workflows/ci.yml
.gitignore
.gitleaks.toml
AGENTS.md
bootstrap.ps1
bootstrap.sh
CHANGELOG.md
CLAUDE.md
dev/External/CLAUDE.md
dev/External/README.md
dev/README.md
docs/components.md
docs/decisions/0001-repo-layout.md
docs/decisions/0002-manifest.md
docs/decisions/0003-placeholders.md
docs/decisions/0004-personal-layer.md
docs/decisions/0005-secrets.md
docs/decisions/0006-copy-instead-of-link.md
docs/decisions/0007-no-plugin.md
docs/decisions/0008-obsidian-plugins.md
docs/decisions/0009-python-environment.md
docs/decisions/0010-test-strategy.md
docs/decisions/0011-ci-scope.md
docs/decisions/0012-pre-commit.md
docs/decisions/0013-install-stages.md
docs/decisions/0014-final-layout.md
docs/decisions/0015-portable-engine-instead-of-chezmoi.md
docs/decisions/0016-public-repository.md
docs/decisions/0017-unique-skill-names.md
docs/decisions/0018-research-as-a-workflow.md
docs/documents.md
docs/guards.md
docs/inspiration.md
docs/install-with-an-agent.md
docs/media-projects.md
docs/phone-setup.md
docs/platforms.md
docs/structure.md
docs/troubleshooting.md
docs/updating.md
home/.agents/skills/docs-import-portable/SKILL.md
home/.agents/skills/media-tools-portable/SKILL.md
home/.agents/skills/quick-research-portable/SKILL.md
home/.agents/skills/web-research/SKILL.md
home/.claude/agents/evidence-extractor.md
home/.claude/agents/research-writer.md
home/.claude/agents/web-researcher.md
home/.claude/CLAUDE.md
home/.claude/docs/agent-tooling.md
home/.claude/docs/CHANGELOG.md
home/.claude/docs/lessons.md
home/.claude/docs/repositories.md
home/.claude/docs/research-standard.md
home/.claude/gitattributes
home/.claude/gitignore
home/.claude/gitleaksignore
home/.claude/hooks/archive-guard.ps1
home/.claude/hooks/block-dangerous.ps1
home/.claude/hooks/downloads-guard.ps1
home/.claude/hooks/fetch-guard.ps1
home/.claude/hooks/no-license-files.ps1
home/.claude/hooks/notification-events.ps1
home/.claude/hooks/notification-idle.ps1
home/.claude/hooks/onedrive-guard.ps1
home/.claude/hooks/session-check.ps1
home/.claude/hooks/skill-usage.ps1
home/.claude/hooks/stop-notify.ps1
home/.claude/hooks/trifecta-guard.ps1
home/.claude/kopiaignore
home/.claude/life-os/cleanup.ps1
home/.claude/life-os/groq_worker.py
home/.claude/life-os/life-os-common.ps1
home/.claude/life-os/morning.ps1
home/.claude/life-os/project-tracker.ps1
home/.claude/life-os/register-tasks-elevated.ps1
home/.claude/life-os/register-tasks.ps1
home/.claude/life-os/requirements.txt
home/.claude/life-os/transcribe_worker.py
home/.claude/life-os/transcribe.ps1
home/.claude/profiles-template/deepseek.json
home/.claude/profiles-template/openrouter.json
home/.claude/rules/browser-extensions-userscripts.md
home/.claude/rules/dotnet-csharp.md
home/.claude/rules/javascript-typescript.md
home/.claude/rules/markdown-obsidian.md
home/.claude/rules/powershell-batch.md
home/.claude/rules/python.md
home/.claude/settings.json
home/.claude/setup/external/CLAUDE.md
home/.claude/setup/external/README.md
home/.claude/setup/other-harnesses/agents-skills/docs-import-portable/SKILL.md
home/.claude/setup/other-harnesses/agents-skills/quick-research-portable/SKILL.md
home/.claude/setup/other-harnesses/agents-skills/web-research/SKILL.md
home/.claude/setup/other-harnesses/codex/config-mcp.toml
home/.claude/setup/other-harnesses/opencode/opencode.json
home/.claude/setup/powershell/add-to-archive.ps1
home/.claude/setup/powershell/batch-run.ps1
home/.claude/setup/powershell/claude-profile-functions.ps1
home/.claude/setup/powershell/set-research-keys.ps1
home/.claude/setup/repair-claude-code.ps1
home/.claude/setup/security/githooks/pre-commit
home/.claude/setup/security/gitleaks/gitleaks.toml
home/.claude/setup/tests/check-hooks-path.ps1
home/.claude/setup/tests/research/run_mutations.py
home/.claude/setup/tests/research/test_build_references.py
home/.claude/setup/tests/research/test_check_article.py
home/.claude/setup/tests/research/test_check_note.py
home/.claude/setup/tests/research/test_check_services.py
home/.claude/setup/tests/research/test_fix_quotes.py
home/.claude/setup/tests/research/test_save_pages.py
home/.claude/setup/tests/research/test_store_results.py
home/.claude/setup/tests/research/test_verify_evidence.py
home/.claude/setup/tests/research/testlib.py
home/.claude/setup/tests/test-add-to-archive.ps1
home/.claude/setup/tests/test-archive-guard.ps1
home/.claude/setup/tests/test-batch-run.ps1
home/.claude/setup/tests/test-block-dangerous-51.ps1
home/.claude/setup/tests/test-block-dangerous.ps1
home/.claude/setup/tests/test-downloads-guard.ps1
home/.claude/setup/tests/test-fetch-guard.ps1
home/.claude/setup/tests/test-no-license-files.ps1
home/.claude/setup/tests/test-onedrive-guard.ps1
home/.claude/setup/tests/test-session-check.ps1
home/.claude/setup/tests/test-skill-usage.ps1
home/.claude/setup/tests/test-trifecta-guard.ps1
home/.claude/skills/docs-import/SKILL.md
home/.claude/skills/life-os-morning/SKILL.md
home/.claude/skills/media-tools/SKILL.md
home/.claude/skills/quick-research/SKILL.md
home/.claude/skills/research/references/style-rules.md
home/.claude/skills/research/research.workflow.js
home/.claude/skills/research/scripts/ai_patterns.py
home/.claude/skills/research/scripts/build_references.py
home/.claude/skills/research/scripts/check_article.py
home/.claude/skills/research/scripts/check_note.py
home/.claude/skills/research/scripts/check_services.py
home/.claude/skills/research/scripts/common.py
home/.claude/skills/research/scripts/crawl4ai_fetch.py
home/.claude/skills/research/scripts/fetch_page.py
home/.claude/skills/research/scripts/fix_quotes.py
home/.claude/skills/research/scripts/save_pages.py
home/.claude/skills/research/scripts/store_results.py
home/.claude/skills/research/scripts/verify_evidence.py
home/.claude/skills/research/SKILL.md
home/.claude/skills/reuse-first/SKILL.md
home/.claude/statusline.ps1
home/.claude/TROUBLESHOOTING.md
home/.config/gitleaks/gitleaks.toml
home/.config/powershell/profile.ps1
home/.githooks/pre-commit
home/Documents/PowerShell/Microsoft.PowerShell_profile.ps1
home/Documents/PowerShell/powershell.config.json
home/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1
home/README.md
install.ps1
linux/packages.yaml
linux/systemd/personal-os-morning.service.tmpl
linux/systemd/personal-os-morning.timer.tmpl
macos/Brewfile
macos/launchagents/com.personal-os.life-os-morning.plist.tmpl
README.md
SECURITY.md
setup/config/personal.example.yaml
setup/config/repo.yaml
setup/config/secrets.example.md
setup/export.ps1
setup/githooks/pre-commit
setup/githooks/pre-push
setup/lib/harness.ps1
setup/lib/manifest.ps1
setup/lib/personal.ps1
setup/lib/placeholders.ps1
setup/lib/platform.ps1
setup/lib/releases.ps1
setup/manifest.yaml
setup/platform/linux.ps1
setup/platform/macos.ps1
setup/platform/windows.ps1
setup/platforms.yaml
setup/README.md
setup/restore.ps1
setup/tools/archive-name-scan.ps1
setup/tools/check-language.ps1
setup/tools/check-structure.ps1
setup/tools/check.ps1
setup/tools/ci-full-setup.ps1
setup/tools/ci-gitleaks.ps1
setup/tools/ci-smoke.ps1
setup/tools/drift-check.ps1
setup/tools/generate-docs.ps1
setup/tools/install-fingerprint.ps1
setup/tools/old-paths.txt
setup/tools/privacy-scan.ps1
setup/tools/verify-all.ps1
setup/verify.ps1
tests/AgentFileBudget.Tests.ps1
tests/fixtures/install-baseline-v2.1.2.json
tests/fixtures/manifest-broken.yaml
tests/fixtures/personal.dummy.yaml
tests/Format-Strings.Tests.ps1
tests/Harness.Tests.ps1
tests/Hooks.Tests.ps1
tests/Install.Tests.ps1
tests/LineEndings.Tests.ps1
tests/Manifest.Tests.ps1
tests/PersonalLayer.Tests.ps1
tests/Platforms.Tests.ps1
tests/Privacy-Scan.Tests.ps1
tests/README.md
tests/Releases.Tests.ps1
tests/ResearchKeys.Tests.ps1
tests/Roundtrip.Tests.ps1
tests/sandbox/personal-os.wsb
tests/sandbox/smoke-install.ps1
tests/Structure.Tests.ps1
vault/.claude/rules/sources.md
vault/.claude/settings.json
vault/.claude/skills/json-canvas/references/EXAMPLES.md
vault/.claude/skills/json-canvas/SKILL.md
vault/.claude/skills/obsidian-bases/references/FUNCTIONS_REFERENCE.md
vault/.claude/skills/obsidian-bases/SKILL.md
vault/.claude/skills/obsidian-cli/SKILL.md
vault/.claude/skills/obsidian-markdown/references/CALLOUTS.md
vault/.claude/skills/obsidian-markdown/references/EMBEDS.md
vault/.claude/skills/obsidian-markdown/references/PROPERTIES.md
vault/.claude/skills/obsidian-markdown/SKILL.md
vault/.claude/skills/vault-lint/conflicts.py
vault/.claude/skills/vault-lint/expiry.py
vault/.claude/skills/vault-lint/graph_health.py
vault/.claude/skills/vault-lint/project_sync.py
vault/.claude/skills/vault-lint/SKILL.md
vault/.claude/skills/vault-lint/test_expiry.py
vault/.obsidian/app.json
vault/.obsidian/appearance.json
vault/.obsidian/community-plugins.json
vault/.obsidian/core-plugins.json
vault/.obsidian/daily-notes.json
vault/.obsidian/graph.json
vault/.obsidian/plugins/obsidian-git/data.json
vault/.obsidian/templates.json
vault/.obsidian/types.json
vault/000-meta/backup.md
vault/000-meta/index.md.tmpl
vault/000-meta/laptop-setup.md
vault/000-meta/log.md.tmpl
vault/000-meta/overview.base
vault/000-meta/scripts/setup-laptop.ps1
vault/000-meta/templates/daily.md
vault/000-meta/templates/person.md
vault/000-meta/templates/project.md
vault/000-meta/templates/source.md
vault/000-meta/todo.md.tmpl
vault/600-archive/README.md
vault/AGENTS.md
vault/CLAUDE.md
vault/gitignore
vault/README.md
vault/skills-lock.json
vault/stignore
windows/configuration.winget
windows/README.md
windows/scheduled-tasks/life-os-morning.xml.tmpl
windows/winget-core.json
windows/winget-optional.json
```
