# Keys and credentials — only NAMES

Only names stand here — what they are for, where they lie today and how they are loaded.
**Values are nowhere in the repo** — not even in the history, in CI or in logs.

| Name | What for | Where it lies today | How it is loaded |
|---|---|---|---|
| DeepSeek API key | Claude Code profile `claude-ds` | `~/.claude/profiles/deepseek.json` (locked file, changed only by script) | `claude --settings …` reads the profile file |
| OpenRouter API key | Profile `claude-or` | `~/.claude/profiles/openrouter.json` | as above |
| GitHub CLI token | `gh`, pushes | Windows Credential Manager (keyring) | `gh auth login` |
| Codex token | Codex CLI | `~/.codex/auth.json` | Codex sign-in |
| Exa / Tavily / Firecrawl / You (YDC) / TinyFish / Serper | Research services | Windows environment variables (`EXA_API_KEY` etc.) | `setup/powershell/set-research-keys.ps1` (Read-Host -AsSecureString) |
| Claude Code OAuth | Claude Pro (subscription) | `~/.claude/.credentials.json` | `claude` sign-in |
| Kopia repository password | Backup repo | The user's password manager + Credential Manager | KopiaUI connection / manually |
| Backblaze B2 keyID + app key | Backup storage (S3) | Password manager; the user's `~/.personal-os` note | `kopia repository connect` |
| Syncthing device IDs + keys | Sync devices | `%LOCALAPPDATA%\Syncthing` (cert.pem/key.pem, config.xml) | interactively when pairing |
| Windows Hello / BitLocker | System | System | not part of this repo |

## Rules

- Never values into a file of this repo, never into a commit, never into a CI output.
- `install.ps1` enters MCP servers with `${ENV_VAR}` placeholders (values stay environment variables).
- For the research keys it calls the existing `set-research-keys.ps1`.
- The scanners (gitleaks + `setup/tools/privacy-scan.ps1`) run before every commit.
