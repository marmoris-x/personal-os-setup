# Components

This file is **generated** - do not edit it by hand. The source is `setup/manifest.yaml`;
regenerate with `pwsh setup/tools/generate-docs.ps1`. `setup/tools/check.ps1` fails when this
file no longer matches the manifest (`-Check`).

- Manifest checksum: `b3b2cd75e9f26350` (SHA256, first 16 characters)
- Manifest version: 1

## Core (64 of 80)

| ID | Area | Scope | What happens |
|---|---|---|---|
| `claude-md` | claude | core | template with placeholders to `HOME/.claude/CLAUDE.md` |
| `claude-settings` | claude | core | template with placeholders to `HOME/.claude/settings.json` |
| `claude-statusline` | claude | core | file/folder to `HOME/.claude/statusline.ps1` |
| `claude-troubleshooting` | claude | core | file/folder to `HOME/.claude/TROUBLESHOOTING.md` |
| `claude-gitattributes` | claude | core | file/folder to `HOME/.claude/.gitattributes` |
| `claude-gitignore` | claude | core | file/folder to `HOME/.claude/.gitignore` |
| `claude-gitleaksignore` | claude | core | file/folder to `HOME/.claude/.gitleaksignore` |
| `claude-kopiaignore` | claude | core | file/folder to `HOME/.claude/.kopiaignore` |
| `claude-hooks` | guards | core | file/folder to `HOME/.claude/hooks` |
| `claude-hook-tests` | guards | core | file/folder to `HOME/.claude/setup/tests` |
| `claude-agents` | research | core | file/folder to `HOME/.claude/agents` |
| `claude-rules` | claude | core | file/folder to `HOME/.claude/rules` |
| `claude-skills` | claude | core | file/folder to `HOME/.claude/skills` |
| `claude-docs-research-standard` | research | core | file/folder to `HOME/.claude/docs/research-standard.md` |
| `claude-lessons-skeleton` | claude | core | skeleton to `HOME/.claude/docs/lessons.md` (only when nothing is there) |
| `claude-changelog-skeleton` | claude | core | skeleton to `HOME/.claude/docs/CHANGELOG.md` (only when nothing is there) |
| `claude-setup-scripts` | claude | core | file/folder to `HOME/.claude/setup/powershell` |
| `claude-profiles-template` | claude | core | file/folder to `HOME/.claude/profiles-template` |
| `claude-life-os` | life-os | core | file/folder to `HOME/.claude/life-os` |
| `claude-life-os-requirements` | life-os | core | skeleton to `HOME/.claude/life-os/requirements.txt` (only when nothing is there) |
| `claude-setup-security` | git | core | file/folder to `HOME/.claude/setup/security` |
| `home-githooks` | git | core | file/folder to `HOME/.githooks` |
| `home-gitleaks-config` | git | core | skeleton to `HOME/.config/gitleaks/gitleaks.toml` (only when nothing is there) |
| `dev-external-templates` | dev | core | file/folder to `DEV/External` |
| `dev-external-templates-mirror` | dev | core | file/folder to `HOME/.claude/setup/external` |
| `dev-dirs` | dev | core | create folders |
| `pwsh7-profile` | powershell | core | file/folder to `DOCUMENTS/PowerShell/Microsoft.PowerShell_profile.ps1` |
| `pwsh51-profile` | powershell | core | file/folder to `DOCUMENTS/WindowsPowerShell/Microsoft.PowerShell_profile.ps1` |
| `pwsh-profile-unix` | powershell | core | file/folder to `HOME/.config/powershell/profile.ps1` |
| `pwsh7-config` | powershell | core | file/folder to `DOCUMENTS/PowerShell/powershell.config.json` |
| `vault-agents` | vault | core | template with placeholders to `VAULT/AGENTS.md` |
| `vault-claude` | vault | core | template with placeholders to `VAULT/CLAUDE.md` |
| `vault-gitignore` | vault | core | file/folder to `VAULT/.gitignore` |
| `vault-stignore` | vault | core | file/folder to `VAULT/.stignore` |
| `vault-skills-lock` | vault | core | file/folder to `VAULT/skills-lock.json` |
| `vault-obsidian-core-plugins` | vault | core | file/folder to `VAULT/.obsidian/core-plugins.json` |
| `vault-obsidian-community-plugins` | vault | core | file/folder to `VAULT/.obsidian/community-plugins.json` |
| `vault-obsidian-app` | vault | core | file/folder to `VAULT/.obsidian/app.json` |
| `vault-obsidian-daily-notes` | vault | core | file/folder to `VAULT/.obsidian/daily-notes.json` |
| `vault-obsidian-templates` | vault | core | file/folder to `VAULT/.obsidian/templates.json` |
| `vault-obsidian-git-data` | vault | core | file/folder to `VAULT/.obsidian/plugins/obsidian-git/data.json` |
| `vault-claude-settings` | vault | core | template with placeholders to `VAULT/.claude/settings.json` |
| `vault-rule-sources` | vault | core | file/folder to `VAULT/.claude/rules/sources.md` |
| `vault-skills` | vault | core | file/folder to `VAULT/.claude/skills` |
| `vault-meta-overview-base` | vault | core | file/folder to `VAULT/000-meta/overview.base` |
| `vault-meta-templates` | vault | core | file/folder to `VAULT/000-meta/templates` |
| `vault-meta-backup-doc` | backup | core | template with placeholders to `VAULT/000-meta/backup.md` |
| `vault-meta-index-skeleton` | vault | core | skeleton to `VAULT/000-meta/index.md` (only when nothing is there) |
| `vault-meta-todo-skeleton` | vault | core | skeleton to `VAULT/000-meta/todo.md` (only when nothing is there) |
| `vault-meta-log-skeleton` | vault | core | skeleton to `VAULT/000-meta/log.md` (only when nothing is there) |
| `vault-archive-readme` | vault | core | skeleton to `VAULT/600-archive/README.md` (only when nothing is there) |
| `vault-dirs` | vault | core | create folders |
| `winget-core` | windows | core | programs from `windows/winget-core.json` |
| `task-life-os-morning` | life-os | core | scheduled task "Life OS Morning" from `windows/scheduled-tasks/life-os-morning.xml.tmpl` |
| `mcp-exa` | research | core | MCP server "exa" |
| `mcp-parallel` | research | core | MCP server "parallel" |
| `mcp-context7` | research | core | MCP server "context7" |
| `obsidian-plugin-obsidian-git` | vault | core | Vinzent03/obsidian-git v2.40.0 |
| `obsidian-plugin-tasks` | vault | core | obsidian-tasks-group/obsidian-tasks v8.4.0 |
| `life-os-venv` | life-os | core | created by install.ps1: python -m venv %LOCALAPPDATA%\life-os\venv + home/.claude/life-os/requirements.txt; model loads on first run (-WithWhisperModel preloads) |
| `own-tools` | windows | core | winget for uv (astral-sh.uv, lands in ~/.local/bin) and gh (GitHub.cli); trufflehog from the official GitHub release, SHA256 checked |
| `os-sync` | backup | core | Windows: SyncTrayzor carries the Syncthing service. macOS: brew services start syncthing. Linux: systemctl --user enable --now syncthing.service |
| `os-backup` | backup | core | Kopia and KopiaUI from the OS package source. Connecting the repository and typing the password stays manual (decision D8) |
| `os-onedrive` | backup | core | The OneDrive client and the document archive beside the documents folder. Windows and macOS only - there is no official OneDrive client for Linux (decision D9) |

## Optional (16)

| ID | Area | Scope | What happens |
|---|---|---|---|
| `claude-docs-agent-tooling` | research | optional | file/folder to `HOME/.claude/docs/agent-tooling.md` |
| `claude-docs-repositories` | research | optional | file/folder to `HOME/.claude/docs/repositories.md` |
| `claude-repair-script` | claude | optional | file/folder to `HOME/.claude/setup/repair-claude-code.ps1` |
| `claude-other-harnesses` | claude | optional | file/folder to `HOME/.claude/setup/other-harnesses` |
| `agents-skills` | research | optional | file/folder to `HOME/.agents/skills` |
| `other-harness-configs` | research | optional | install.ps1 merges home/.claude/setup/other-harnesses/{opencode,codex} into ~/.config/opencode/opencode.json and ~/.codex/config.toml when that harness folder exists; existing values win and every replaced file is backed up first |
| `vault-readme` | vault | optional | template with placeholders to `VAULT/README.md` |
| `vault-obsidian-appearance` | vault | optional | file/folder to `VAULT/.obsidian/appearance.json` |
| `vault-obsidian-graph` | vault | optional | file/folder to `VAULT/.obsidian/graph.json` |
| `vault-obsidian-types` | vault | optional | file/folder to `VAULT/.obsidian/types.json` |
| `vault-meta-laptop-setup` | vault | optional | file/folder to `VAULT/000-meta/laptop-setup.md` |
| `vault-meta-script-setup-laptop` | vault | optional | file/folder to `VAULT/000-meta/scripts/setup-laptop.ps1` |
| `winget-optional` | windows | optional | programs from `windows/winget-optional.json` |
| `plugins-claude-code` | claude | optional | Claude Code marketplaces and plugins are installed by install.ps1 from settings.json (enabledPlugins). |
| `crawl4ai` | research | optional | uv tool install crawl4ai + crawl4ai-setup (browser); crwl lands in ~/.local/bin. It is the first page fetcher of save_pages.py, so a missing uv or Python is reported with a manual step instead of silently skipping it |
| `comfy-cli` | research | optional | Local image generation (/image skill, ADR 0019): `uv tool install comfy-cli --python 3.13`, then ComfyUI and one model by the recipe in ~/.claude/skills/image/SKILL.md (about 20 GB, NVIDIA GPU). Not installed by install.ps1: the models are re-downloadable and the owner starts it on purpose. |

## Fixed installer stages (deliberately not in the manifest, see `docs/decisions/0013-install-stages.md`)

- git-config: `core.hooksPath`, `init.defaultBranch` (and `core.longpaths` on Windows)
- packages: from the platform map - `windows/configuration.winget` (WinGet Configuration), `macos/Brewfile` (brew bundle), `linux/packages.yaml` (apt/dnf + Flatpak)
- task, mcp, obsidian-plugins, life-os-venv, own-tools (uv/gh/trufflehog)
- sync and backup: SyncTrayzor, `brew services`, `systemctl --user`; KopiaUI / Kopia
- os-extras (Windows only): firewall rule for Syncthing, `LongPathsEnabled` (both need administrator rights)
