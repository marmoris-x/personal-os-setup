# ADR 0004 – Personal additional layer stays local

- Date: 2026-10-11
- Status: decided
- Partly superseded by [0016](0016-public-repository.md) (2026-10-15): the repository is public since v3.0.0.

## Context

The user wants a repo without any personal information, but on his PC the set-up system
should stay personal (real name in the archive naming scheme, vault path, GitHub account,
devices).

## Decision

- Local values: `%USERPROFILE%\.personal-os\personal.yaml` (outside the repo, never committed).
  Keys: `user_name`, `user_given`, `user_family`, `github_account`, `vault_path`, `dev_root`,
  `archive_dir_name`, `b2_bucket`, `morning_time`, `backup_time`. Example with made-up values:
  `setup/config/personal.example.yaml`.
- Rule files in the repo end with an import of the local supplement
  (`@~/.personal-os/instructions.local.md`; Claude Code resolves `@path` imports up to 4 levels,
  also `@~/…`). This way the general version stays in the repo, the personal one with the user.
- `setup/export.ps1` separates automatically: general part → repo, personal part → stays local.
  Where that cannot be cleanly separated (e.g. `add-to-archive.ps1` with the real name in the
  scheme), the repo version reads the value from `personal.yaml` at runtime.
- `install.ps1` puts both back together: repo file + local supplement + filled placeholders.

## Alternatives

- Values in the repo with `.gitignore`: an oversight commits them anyway; the history would be
  contaminated.
- Two separate repos ("public"/"private"): more upkeep, unwanted.

## Consequences

- A fresh PC: `install.ps1` asks for the values (`-NonInteractive` reads a file) and creates
  `personal.yaml`.
- Checks (`privacy-scan`, gitleaks) know both worlds; the denylist is local.
