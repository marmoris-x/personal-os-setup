# Platforms

This file is **generated** - do not edit it by hand. The source is `setup/platforms.yaml`
(which components exist where) together with `setup/manifest.yaml` (what they contain);
regenerate with `pwsh setup/tools/generate-docs.ps1`. Acceptance check L fails when this
file and the map disagree.

- Manifest checksum: `04d13d25bb4f938f`

## What each system can do

| | Windows | macOS | Linux |
|---|---|---|---|
| package source | `windows/configuration.winget` | `macos/Brewfile` | `linux/packages.yaml` |
| package tool | `winget-configure` | `brew-bundle` | `distro-packages` |
| scheduler | `task-scheduler` | `launchd` | `systemd-user` |
| state folder | `{LOCALAPPDATA}/personal-os-setup` | `{HOME}/.local/state/personal-os-setup` | `{HOME}/.local/state/personal-os-setup` |
| documents folder | `known-folder` | `{HOME}/Documents` | `{HOME}/Documents` |
| suggested vault | `{HOME}/PersonalOS` | `{HOME}/PersonalOS` | `{HOME}/PersonalOS` |
| suggested dev | `C:/Dev` | `{HOME}/Dev` | `{HOME}/Dev` |

## Every component on every system

`unsupported` means the component does not exist on that system, and the reason is
written next to it. An agent that meets one of these skips the component and says so
(AGENTS.md, "Platform first", rule 3) - it never invents a replacement.

| ID | Windows | macOS | Linux |
|---|---|---|---|
| `claude-md` | `files` | `files` | `files` |
| `claude-settings` | `files` | `files` | `files` |
| `claude-statusline` | `files` | `files` | `files` |
| `claude-troubleshooting` | `files` | `files` | `files` |
| `claude-gitattributes` | `files` | `files` | `files` |
| `claude-gitignore` | `files` | `files` | `files` |
| `claude-gitleaksignore` | `files` | `files` | `files` |
| `claude-kopiaignore` | `files` | `files` | `files` |
| `claude-hooks` | `files` | `files` | `files` |
| `claude-hook-tests` | `files` | `files` | `files` |
| `claude-agents` | `files` | `files` | `files` |
| `claude-rules` | `files` | `files` | `files` |
| `claude-skills` | `files` | `files` | `files` |
| `claude-docs-research-standard` | `files` | `files` | `files` |
| `claude-docs-agent-tooling` | `files` | `files` | `files` |
| `claude-orientation-deepseek` | `files` | `files` | `files` |
| `claude-docs-repositories` | `files` | `files` | `files` |
| `claude-lessons-skeleton` | `files` | `files` | `files` |
| `claude-changelog-skeleton` | `files` | `files` | `files` |
| `claude-setup-scripts` | `files` | `files` | `files` |
| `claude-repair-script` | `files` | `unsupported: the script repairs a Windows Claude Code install (winget, registry, AppData)` | `unsupported: the script repairs a Windows Claude Code install (winget, registry, AppData)` |
| `claude-profiles-template` | `files` | `files` | `files` |
| `claude-life-os` | `files` | `files` | `files` |
| `claude-life-os-requirements` | `files` | `files` | `files` |
| `claude-other-harnesses` | `files` | `files` | `files` |
| `agents-skills` | `files` | `files` | `files` |
| `other-harness-configs` | `generated` | `generated` | `generated` |
| `claude-setup-security` | `files` | `files` | `files` |
| `home-githooks` | `files` | `files` | `files` |
| `home-gitleaks-config` | `files` | `files` | `files` |
| `dev-external-templates` | `files` | `files` | `files` |
| `dev-external-templates-mirror` | `files` | `files` | `files` |
| `dev-dirs` | `dirs` | `dirs` | `dirs` |
| `pwsh7-profile` | `files` | `files` | `files` |
| `pwsh51-profile` | `files` | `unsupported: Windows PowerShell 5.1 does not exist on this OS` | `unsupported: Windows PowerShell 5.1 does not exist on this OS` |
| `pwsh-profile-unix` | `unsupported: pwsh on Windows reads the profile from the documents folder, not from ~/.config` | `files` | `files` |
| `pwsh7-config` | `files` | `unsupported: pwsh on macOS reads profile.ps1, not a Windows powershell.config.json` | `unsupported: pwsh on Linux reads profile.ps1, not a Windows powershell.config.json` |
| `vault-agents` | `files` | `files` | `files` |
| `vault-claude` | `files` | `files` | `files` |
| `vault-readme` | `files` | `files` | `files` |
| `vault-gitignore` | `files` | `files` | `files` |
| `vault-stignore` | `files` | `files` | `files` |
| `vault-skills-lock` | `files` | `files` | `files` |
| `vault-obsidian-core-plugins` | `files` | `files` | `files` |
| `vault-obsidian-community-plugins` | `files` | `files` | `files` |
| `vault-obsidian-app` | `files` | `files` | `files` |
| `vault-obsidian-appearance` | `files` | `files` | `files` |
| `vault-obsidian-daily-notes` | `files` | `files` | `files` |
| `vault-obsidian-templates` | `files` | `files` | `files` |
| `vault-obsidian-graph` | `files` | `files` | `files` |
| `vault-obsidian-types` | `files` | `files` | `files` |
| `vault-obsidian-git-data` | `files` | `files` | `files` |
| `vault-claude-settings` | `files` | `files` | `files` |
| `vault-rule-sources` | `files` | `files` | `files` |
| `vault-skills` | `files` | `files` | `files` |
| `vault-meta-overview-base` | `files` | `files` | `files` |
| `vault-meta-templates` | `files` | `files` | `files` |
| `vault-meta-laptop-setup` | `files` | `files` | `files` |
| `vault-meta-backup-doc` | `files` | `files` | `files` |
| `vault-meta-script-setup-laptop` | `files` | `files` | `files` |
| `vault-meta-index-skeleton` | `files` | `files` | `files` |
| `vault-meta-todo-skeleton` | `files` | `files` | `files` |
| `vault-meta-log-skeleton` | `files` | `files` | `files` |
| `vault-archive-readme` | `files` | `files` | `files` |
| `vault-dirs` | `dirs` | `dirs` | `dirs` |
| `winget-core` | `packages:windows/configuration.winget` | `packages:macos/Brewfile` | `packages:linux/packages.yaml` |
| `winget-optional` | `packages:windows/configuration.winget` | `packages:macos/Brewfile` | `packages:linux/packages.yaml` |
| `task-life-os-morning` | `scheduler:task-scheduler` | `scheduler:launchd` | `scheduler:systemd-user` |
| `mcp-exa` | `mcp` | `mcp` | `mcp` |
| `mcp-parallel` | `mcp` | `mcp` | `mcp` |
| `mcp-context7` | `mcp` | `mcp` | `mcp` |
| `plugins-claude-code` | `generated` | `generated` | `generated` |
| `obsidian-plugin-obsidian-git` | `plugin` | `plugin` | `plugin` |
| `obsidian-plugin-tasks` | `plugin` | `plugin` | `plugin` |
| `life-os-venv` | `generated` | `generated` | `generated` |
| `crawl4ai` | `generated` | `generated` | `generated` |
| `comfy-cli` | `manual: uv tool install comfy-cli --python 3.13, then the ComfyUI recipe in ~/.claude/skills/image/SKILL.md (about 20 GB, NVIDIA GPU)` | `unsupported: the ComfyUI recipe of this repo is written for an NVIDIA GPU on Windows` | `unsupported: the ComfyUI recipe of this repo is written for an NVIDIA GPU on Windows` |
| `own-tools` | `generated` | `generated` | `generated` |
| `os-sync` | `manual: start SyncTrayzor once - it carries the Syncthing service and sets up its own autostart` | `homebrew-service:syncthing` | `systemd-user:syncthing.service` |
| `os-backup` | `packages:windows/configuration.winget` | `packages:macos/Brewfile` | `packages:linux/packages.yaml` |
| `os-onedrive` | `manual: sign in to the OneDrive client once` | `manual: sign in to the OneDrive client once` | `unsupported: no official OneDrive client for Linux` |

## Where the three systems are really checked

`setup/tools/check.ps1` and `setup/tools/ci-smoke.ps1` run on the system they run on; the CI
matrix covers the others. `windows-latest` and `ubuntu-latest` run on every push, so a
change that only works on one of them is red before it is merged. The macOS job runs on a
release tag, once a week and on request (`gh workflow run ci`) - its minutes cost more,
which is the rule written in the comment at the top of `.github/workflows/ci.yml`. Every
job runs `ci-smoke.ps1` first and prints `IDEMPOTENT-OK`; acceptance check O reads
the conclusion of that step out of the run's JSON and check N wants the newest run to
carry both matrix jobs and a macOS job that really ran.

Three of the guard suites are Windows-only (their cases and the guards under test are
Windows text) and the Windows row of the placeholder tests needs a Windows host. On the
other systems `check.ps1` prints a `SKIP` line with the reason instead of leaving them
out silently, and the macOS and Linux rows run everywhere - they are what found the
missing `{{*_BASH}}` tokens on a Windows machine.

