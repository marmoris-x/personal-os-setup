# personal-os-setup

A construction kit that sets up a complete working environment on **Windows, macOS or Linux**:
Claude Code with its guard hooks, an Obsidian vault skeleton, Life OS (voice notes →
transcript → morning report), PowerShell profiles, the Git and gitleaks chain, scheduled jobs,
backup and sync.

Everything personal — name, paths, accounts, keys, devices — is **not** in the repo. Setup asks
for it and writes it to `~/.personal-os/personal.yaml`, on that machine only.

This is one person's own setup, published so that someone else can build the same environment:
you clone it, the installer asks for your values, and the personal layer (`~/.personal-os/`,
written on your machine only) is the part you adapt. It is for anyone who wants a machine set up
this way — Windows, macOS or Linux.

## Start from zero

One file gets you onto a machine that has nothing but a browser. The bootstrap installs git, the
GitHub CLI and PowerShell 7 with the system's own package manager, lets you sign in, clones this
repository to a folder you confirm, and then runs the installer.

**Windows** (PowerShell 5.1 or 7, no admin needed for this step):

```powershell
# 1. download the start file (the repository is public):
#    https://github.com/<your-account>/personal-os-setup/raw/main/bootstrap.ps1
# 2. run it, and give it the address of the repository:
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -RepoUrl https://github.com/<your-account>/personal-os-setup.git
```

**macOS and Linux** (bash, and no git yet is fine):

```bash
curl -fsSL https://raw.githubusercontent.com/<your-account>/personal-os-setup/main/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh --repo https://github.com/<your-account>/personal-os-setup.git
```

`<your-account>` is the GitHub account that owns the repository. The bootstrap never
guesses it: an account name does not belong into a repository that gets shared (AGENTS.md,
hard rule 1). You find it in the browser after signing in, or in the `personal.yaml` of a
machine you already set up. On a machine that already has `git` and `gh`, three lines do the
same:

```bash
gh auth login
gh repo clone <your-account>/personal-os-setup
cd personal-os-setup && ./bootstrap.sh --skip-install && pwsh -File install.ps1
```

On Linux, Ubuntu and Fedora are the tested distributions. Any other one gets the package list
printed and that one step stops with a clear message — it never guesses a package name.

Or tell an AI agent: read `docs/install-with-an-agent.md` and set everything up.

## What's inside

| Folder | Installs to | Contains |
|---|---|---|
| `home/` | `~` (`%USERPROFILE%` on Windows) | `.claude` (hooks, rules, skills, agents, settings), the global git hook, the PowerShell profiles |
| `vault/` | the vault path | the Obsidian vault skeleton: work folders, rules, templates, skills, plugin settings |
| `dev/` | the dev root | the rule template for other people's repositories |
| `windows/` | — (configured, not copied) | the WinGet Configuration file, the import lists, the scheduled-task template |
| `macos/` | — (configured, not copied) | the Brewfile, the launchd agent template |
| `linux/` | — (configured, not copied) | the package lists, the systemd user timer and service |
| `setup/` | — (the tooling itself) | manifest, platform map, export, verify, restore, the check scripts |
| `tests/` | — | Pester tests, fixtures, the Windows sandbox description |
| `docs/` | — | how it works, the platform matrix, the decisions behind it, the component list |

## Install

1. Get the repo onto the new machine (`bootstrap.ps1` / `bootstrap.sh` above, or `git clone`).
2. `pwsh -File install.ps1`
   The script asks for your personal values, installs the programs with that system's own
   package manager and backs up every file it would replace.
3. `pwsh setup/verify.ps1` — prints what is there, or exactly what is missing.

Which component works where is in `docs/platforms.md`.

## After install

`install.ps1` does what a script can do; the rest is yours. A live run prints this list at its
end, and `docs/install-with-an-agent.md` walks an agent through the same ground:

1. **Sign-ins** (every system): `gh auth login` and sign in to Claude Code
   (`claude`). The Git identity stays yours too: `git config --global user.name` / `user.email`.
2. **Keys** (every system): set the research keys with `pwsh setup/powershell/set-research-keys.ps1`.
   The Kopia password is typed when the backup repository is connected the first time (KopiaUI on
   Windows and macOS, `kopia repository connect` on Linux) - it never goes into a file here.
3. **Packages need more rights on Linux only:** `apt-get`/`dnf` and the Flatpak apps run with
   `sudo`. An unprivileged run prints the exact list and stops that one stage; run the commands,
   then `pwsh -File install.ps1 -Resume`. winget on Windows and Homebrew on macOS need no
   elevation.
4. **Windows only, once, as administrator:** run `install.ps1` again from an elevated PowerShell.
   That is what adds the scheduled task's logon trigger, the Syncthing firewall rule and
   `LongPathsEnabled=1`. On macOS the launch agent and on Linux the systemd user timer are set up
   by the normal run, without root.
5. **First starts:** start the sync and backup programs once and connect them.
   - Windows: SyncTrayzor and KopiaUI (they set up their own autostart), pair the Syncthing
     devices, connect the Kopia repository.
   - macOS: Syncthing runs as a Homebrew service from the install; open its web UI
     (`http://127.0.0.1:8384`) once and pair the devices, then start KopiaUI once.
   - Linux: Syncthing runs as a systemd user unit from the install; open its web UI once and pair
     the devices, then connect Kopia on the command line.
   - Every system: install Obsidian and open the vault - the community plugins are already in it.
6. **Phone:** `docs/phone-setup.md` - voice notes into the vault inbox, vault sync to the phone.

## Keep it up to date

- `pwsh setup/export.ps1` — PC → repo. Writes every changed system file back into the mirror
  folders with the personal values replaced by placeholders, then runs the privacy scan.
- `install.ps1` — repo → PC. Renders the placeholders and writes the files to their places.

## Docs

- `docs/structure.md` — how the repo is built, the naming rules, the whole tree.
- `docs/components.md` — every component (generated from `setup/manifest.yaml`).
- `docs/guards.md` — what the guard hooks block and allow.
- `docs/media-projects.md` — folders and ignore files for a project with large media.
- `docs/install-with-an-agent.md` — the step-by-step version for an agent.
- `docs/updating.md` — keeping the repo current after system changes.
- `docs/troubleshooting.md` — when a step gets stuck.
- `docs/decisions/` — the decisions behind the design.
- `CHANGELOG.md` — what changed when.
