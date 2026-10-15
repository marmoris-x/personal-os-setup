# home

The mirror of the user profile. Everything in here is installed to `%USERPROFILE%` by
`install.ps1`; the paths below are the paths it lands on.

| Here | On the machine | What it is |
|---|---|---|
| `.claude/` | `%USERPROFILE%\.claude\` | the global agent configuration: hooks (the guards), rules, skills, agents, settings, both ignore files, the status line |
| `.claude/life-os/` | `%USERPROFILE%\.claude\life-os\` | Life OS: the morning run, the transcription driver, the cleanup pass, the Python requirements |
| `.claude/setup/` | `%USERPROFILE%\.claude\setup\` | the setup scripts and the guard test suites |
| `.githooks/` | `%USERPROFILE%\.githooks\` | the global git pre-commit hook (gitleaks, fail-open) |
| `.config/gitleaks/` | `%USERPROFILE%\.config\gitleaks\` | the global gitleaks rules |
| `.config/powershell/profile.ps1` | `$HOME/.config/powershell/profile.ps1` | the PowerShell profile for macOS and Linux, where pwsh reads it. Windows installs nothing from here: it keeps both profiles in `Documents/` (see `setup/platforms.yaml`). |
| `Documents/` | the Windows Documents folder | `Microsoft.PowerShell_profile.ps1` for PowerShell 7 and 5.1, plus the 7 config |

Files whose dotted name git would interpret inside this repo are stored here **without** the
dot and installed **with** it: `gitignore`, `gitattributes`, `gitleaksignore`, `kopiaignore`.
The hidden folders keep their dot, because git does not interpret those.

## What is deliberately not here

- `profiles/` — the live provider profiles carry real keys. Only `profiles-template/` is in the
  repo, with placeholders.
- Session state, transcripts, histories, caches, `projects/`, `settings.local.json`,
  `.credentials.json`.
- The owner's own notes, research results and run records, even when they live under
  `~/.claude/setup/tests/`. `tests/Structure.Tests.ps1` fails if any of them appears here.

`README.md` and the other top-level files of this folder are documentation and are never
installed. See `docs/structure.md` for the whole picture.
