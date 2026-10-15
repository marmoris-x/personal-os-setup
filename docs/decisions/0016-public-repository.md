# 16. Publish the construction kit as a fresh public repository

Date: 2026-10-15

## Status

Accepted. Carried out in v3.0.0.

## Context

The construction kit is worth sharing: it shows how a working environment with Claude Code, an
Obsidian vault, guard hooks, schedules and a backup chain is built from a manifest, on three
operating systems. Sharing it means the repository becomes public. Two things stood in the way,
and a third made the choice between the two possible routes easy.

1. The tree carried personal structure. The archive category list - the folder names the owner
   keeps his documents in - stood in `add-to-archive.ps1`, and an authority abbreviation stood
   in the guard test suites. Both say something about the owner's circumstances. They are out of
   the tree since v3.0.0 (see below), but the **history** still holds them: every commit that
   ever contained them would be public too. GitHub's own documentation on removing sensitive
   data is explicit that a rewrite has side effects - the data stays in forks and in cached
   views.
2. GitHub's documentation on repository visibility states that when a private repository is
   made public, "Actions history and logs will be visible to everyone". The old repository has
   months of CI logs, and no scan can prove they are clean enough to publish.
3. Commit identities are already noreply addresses. A fresh history therefore loses no
   attribution, and everything that is worth keeping - every commit, every tag - stays in the
   old, private repository.

## Decision

- The old repository is **not** deleted and is **not** made public. It is renamed to
  `personal-os-setup-history`, stays private, and keeps its full history and its tags.
- A **new** repository `personal-os-setup` starts with **one** commit - the cleaned tree - and
  the tag `v3.0.0`. It carries the security policy.
- Personal values live in the personal layer (`~/.personal-os/`, ADR 0004) and nowhere else.
  Since v3.0.0 that includes the archive category list: `add-to-archive.ps1` reads it from
  `personal.yaml` at run time, `setup/lib/personal.ps1` is the reader the repository tools
  share, and `privacy-scan.ps1` loads the same list as denylist terms.
- The line is held by four guards, not by care: `privacy-scan.ps1` (tree, staged changes,
  history), gitleaks, trufflehog, and GitHub's secret scanning with push protection. The
  acceptance run checks the first three, and check S checks that the two GitHub settings are
  on.
- The local clone follows the new repository: its `main` is the single release commit, and the
  old history is reached through a second remote named `history`.

## Alternatives

- **Switch the existing repository to public.** Rejected: the three reasons above. Rewriting
  the history would have to remove the category list from every commit, and the CI logs cannot
  be unpublished at all.
- **Delete the old repository after copying the tree.** Rejected: the history is the record of
  two years of work, the tags name released states, and a public repository gains nothing from
  destroying it.
- **Keep everything private.** Rejected: the point of the construction kit is that someone else
  can build the same environment from it.
- **Squash the local clone too.** Rejected: the local clone is where the history is read, and
  `git log --follow` on a single-commit repository answers nothing. The history stays reachable
  through the `history` remote.

## Consequences

- Two repositories carry the same name stem: the public kit and the private archive. Every
  change goes into the public one; the archive receives nothing more.
- A personal value that reaches the tree is now a publication, not just a mistake. That is why
  the category list moved into the personal layer and why the scans load it there.
- The acceptance run's check S reads `setup/config/repo.yaml`: the repository must be in the
  state that file describes. Publishing a repository that still says `published: false` fails
  the check, and so does the reverse.
- The CI logs of the new repository are public from the first run. `install.ps1` renders with
  `personal.example.yaml` in CI, and check V reads the newest log back through the personal
  layer's denylist.
