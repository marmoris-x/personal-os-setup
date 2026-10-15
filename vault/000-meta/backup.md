---
type: note
status: active
date: 2026-10-12
---
# Backup

Encrypted, versioned backup with Kopia to object storage, read over its S3-compatible
interface. No passwords or keys are written into this vault: the repository password is typed
into KopiaUI and kept in a password manager.

Sizes, dates and the names of the sources are the owner's own state. They are **not** in this
file on purpose; the live table is written once on the machine that runs the backup.

## What belongs in the backup
Everything that cannot be rebuilt from a repository:

- the vault (`{{VAULT}}`)
- `{{DEV}}\Projects`, so every project's `docs/vendor/` goes with it
- `{{HOME}}\.claude`, the global agent configuration
- the document archive folder, if one is used
- the small tool folders: `{{HOME}}\.agents`, `{{HOME}}\.githooks`,
  `{{HOME}}\.config\gitleaks`, and both PowerShell profile folders under Documents

Claude Code's own account and project state is not a source of its own: it lives inside
`{{HOME}}\.claude` (the setting `CLAUDE_CONFIG_DIR` points Claude Code there), so it is covered
by that source and never reaches GitHub.

## What never belongs in the backup
The six storage folders in `{{HOME}}\Downloads` (`Compressed`, `Documents`, `Images`, `Music`,
`Programs`, `Videos`) are the owner's permanent storage. They are not a backup source and are
not synced. What lives only there has no second copy — that is the owner's decision, never an
agent's.

Excluded everywhere (global policy): `node_modules/`, `dist/`, `build/`, `out/`, `.venv/`,
`__pycache__/`, `*.tmp`. `.git` folders are included.

## Shrinking the `.claude` source
Session transcripts and caches are most of the size. The file `{{HOME}}\.claude\.kopiaignore`
is read by Kopia inside the source folder and excludes `projects/**/*.jsonl`,
`projects/**/subagents/`, `file-history/`, `paste-cache/`, `debug/`, `session-env/`,
`shell-snapshots/`, `tasks/` and `history.jsonl`.

Two consequences to know before relying on it:

- Old conversations can no longer be resumed (`claude --resume`), and `/rewind` has no history
  after a restore. Snapshots taken before the rule was added still hold them until retention
  removes them.
- The rule only takes effect if the global policy lists `.kopiaignore` under "Ignore rule
  files" (KopiaUI, Policies, global policy). Kopia's default policy does; check it once.

Still backed up inside `.claude`: `projects/*/memory/` and everything else in the folder.

## Where
- Storage: an S3-compatible object store. Endpoint, bucket and keys are the owner's values and
  live outside this vault.
- Connection config: `%APPDATA%\kopia\repository.config`.
- Schedule: daily at {{BACKUP_TIME}}. Missed runs are caught up when the PC is on. Retention is
  the Kopia default (10 latest, 48 hourly, 7 daily, 4 weekly, 24 monthly, 3 annual).
- KopiaUI starts with Windows. Scheduled snapshots only run while KopiaUI is running.

## How to restore
In KopiaUI:

1. Open the **Snapshots** tab and click the source folder.
2. Pick a snapshot by date and browse to the file or folder.
3. Use **Restore** and choose a new target folder. Never restore straight over the original;
   compare first.

On the command line (the CLI ships with KopiaUI):

```powershell
$k = "{{KOPIA_CLI}}"
& $k snapshot list --all --config-file "{{KOPIA_CONFIG}}"
& $k snapshot restore <root-id>/<path inside source> <target> --config-file "{{KOPIA_CONFIG}}"
```

On a new PC: install KopiaUI, choose "Amazon S3 or Compatible Storage", then "Connect to
existing repository". Enter the endpoint and bucket, the key ID and application key, then the
repository password. Without that password nobody can read the backup.

The settings in `{{HOME}}\.claude` are also on GitHub as the private repository
`{{GITHUB_ACCOUNT}}/claude-config`, without keys. Its `setup/restore-tools.ps1` reinstalls the
programs, plugins and hooks.
