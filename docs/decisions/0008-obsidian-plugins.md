# ADR 0008 – Obsidian plugins: only the list in the repo, code is downloaded later

- Date: 2026-10-11
- Status: decided

## Context

Obsidian plugins live in `.obsidian/plugins/<id>/` (`main.js`, `manifest.json`, `styles.css`)
and come from GitHub releases. `main.js` is bundled third-party code (0.7–0.9 MB), settings
can contain personal content. The current inventory: `obsidian-git` 2.40.0
(Vinzent03/obsidian-git), `obsidian-tasks-plugin` 8.4.0
(obsidian-tasks-group/obsidian-tasks).

## Decision

- Into the repo go: `.obsidian` core files (core-plugins, community-plugins, app, appearance,
  daily-notes, templates, graph, types), the checked `obsidian-git` `data.json` (no personal
  data – checked) and the plugin details **directly in `setup/manifest.yaml`** (`obsidian-plugin`
  entries with ID, repo, version per plugin). The first draft provided a separate
  `obsidian/plugins.lock.json` for that; the versions in the manifest make it superfluous
  (correction after review-1, 2026-10-11).
- The program code (`main.js`, `styles.css`) does **not** go into the repo; `install.ps1`
  downloads exactly the manifest version from the GitHub release and skips entries whose
  version is already present (`-Components`/`-Profile minimal` can specifically exclude the
  plugin entries).
- Before including further plugin settings the rule applies: check for personal data first
  (the scanner runs over everything anyway).

## Alternatives

- Committing `main.js` along: third-party code in the repo, updates hard to follow, bloat.
- Having the plugins installed manually: breaks the "one command" idea.

## Consequences

- Versions age in `setup/manifest.yaml`; that is intended (reproducibility) and is kept as an "aging
  number" with a date.
