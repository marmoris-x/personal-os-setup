---
type: note
status: active
date: 2026-09-20
---
# Laptop — setup in six steps

Fifteen minutes, once. This file is in the vault on purpose: after the
clone you have it on the laptop too.

## 1. Git
Install Git for Windows. It is also what Claude Code uses for its shell.

## 2. The Git Bash path
In `{{HOME_CMD}}\.claude\settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe"
  }
}
```

Windows has its own `bash.exe` that shadows Git Bash. Without this line
Claude Code picks the wrong one.

## 3. Claude Code
Install it, then always start it from PowerShell, never from Git Bash:

```powershell
cd {{VAULT}}
claude
```

## 4. Obsidian
Install Obsidian 1.13.7 or newer, then in Obsidian:
Settings → General → Command line interface → on, follow the prompt,
restart the terminal.

## 5. The vault
```powershell
git clone https://github.com/{{GITHUB_ACCOUNT}}/personal-os.git {{VAULT}}
```
Then in Obsidian: "Open folder as vault" → `{{VAULT}}`.

Then in Obsidian: Settings → Community plugins → turn community plugins
on. The Git plugin is already in the repo; it needs this one switch.

## 6. Auto-commit stays OFF on the laptop
Only one machine commits automatically, and that is the main PC. Two
automatic writers create conflicts nobody caused.

Open the Git plugin settings and set the interval to 0. Commit and pull
by hand instead:

```powershell
git -C {{VAULT}} pull
git -C {{VAULT}} add -A
git -C {{VAULT}} commit -m "notes from the laptop"
git -C {{VAULT}} push
```

## What is there and what is not
**There:** every note, all 463 document sidecars (fully searchable), the
rules, the skills, the plugin.
**There via OneDrive:** the PDF and Word originals.
**Not there:** source code (clone what you need), ID documents (main PC
only), Kopia (main PC only).
