---
name: vault-lint
description: >
  Health check for this Obsidian vault. Use when the user says "lint", "Gesundheitscheck",
  "aufräumen", "prüf den Vault", or once a week. Finds broken links, notes without links,
  missing frontmatter, stale "Current truth", claims that contradict their sources, a bloated
  todo list, and personal data in the wrong place. Fixes structure itself; asks before
  changing facts.
---

# Vault lint

Follow the vault's AGENTS.md. This is Karpathy's "lint" step: keep the wiki true, not just tidy.

## 1. Structure (fix these yourself, then list what you fixed)

- Broken `[[wikilinks]]`: find the intended note; if unclear, list them.
  Exempt: `500-sources/`. It holds imported foreign text (raw copies, PDF sidecars,
  research dumps) in which `[[...]]` is usually not a link at all — in a Python or wiki
  snippet it is a list, a docstring or markup. The folder is append-only, so "repairing"
  one would edit a source. Check links there only when the user asks.
- Notes in `200-projects`, `300-areas`, `400-knowledge` that no other note links to: add them
  to the matching index or hub note.
- Missing or invalid frontmatter fields the AGENTS.md requires: add them.
- Empty notes and duplicates (same topic twice): list them; merge only after the user agrees.
- Pages over 200 lines in `400-knowledge` and `200-projects` (count with
  `(Get-Content <file>).Count`): list them and propose how to split each by topic. Split only
  after the user agrees. Exception: in `400-knowledge/research` a note is one piece with its
  numbered references, so only warn from 400 lines (AGENTS.md "Page length"). Second
  exception: a note whose frontmatter has `provenance: "KI-Chat, ungeprüft"` is a saved AI chat,
  one piece too, and never gets a length warning.
- Move notes with the Obsidian CLI so links stay intact.
- `500-sources/` holds only what other people wrote. A report, a research result, a script, a
  command or a template that we wrote and that sits there is in the wrong place: list it and say
  where it belongs (a report to `400-knowledge/`, code or commands to a project). Never move it
  without asking. A folder under `500-sources/docs/` without a `_source.md` is a finding.

## 2. Script checks (run first; they name file and line, read-only)

- `python -I -X utf8 .claude/skills/vault-lint/graph_health.py` — broken wikilinks, broken
  relative Markdown links (`[text](../path.md)`, as the research notes link their local
  copies; a folder is no target), orphan notes in `200-projects`, `300-areas`,
  `400-knowledge`, duplicate page names and alias collisions. Fix a broken link by finding
  the intended note; if the intent is unclear, list it. An orphan note gets linked from its
  hub or the index (AGENTS.md rule 13). A duplicate name gets an `aliases` entry or a path
  link. Exit 1 means findings.
- `python -I -X utf8 .claude/skills/vault-lint/project_sync.py` — every git repository under
  `{{DEV}}\Projects` has exactly one hub note (`200-projects/` while active, `900-inactive/`
  when finished), hub notes carry `repo:`, and an active note may not be more than 30 days
  behind its repository's last commit (AGENTS.md rule 12). Refresh the note (Timeline,
  status, next step) or record the drift in the report.
- `python -I -X utf8 .claude/skills/vault-lint/conflicts.py` — files that a sync conflict left
  behind (`*.sync-conflict-*`, from Syncthing). Report them; do not merge them here — the
  Life OS morning run merges conflicts (phase-1 order part 2.4). Exit 1 means findings.
- `python -I -X utf8 .claude/skills/vault-lint/expiry.py` — notes in `200-projects`,
  `300-areas` and `400-knowledge` whose optional `valid_until` is in the past or within
  14 days, plus a malformed date. Names file and date; read-only. Exit 1 means findings.

## 3. Truth (never change facts without asking)

- For each note in `400-knowledge` and `200-projects` changed since the last lint (see
  `000-meta/log.md`), pick its three most important claims and check each against the
  cited source in `500-sources` or on the web. Report: claim | source says | verdict.
- "Current truth" sections older than 90 days: ask whether they are still true.
- Notes that `expiry.py` lists (past or within 14 days): show file and date, ask whether the
  fact still holds. Never edit the fact yourself; a new date or a removal is the user's call.
- Two notes that say different things about the same fact: show both, ask which is right.
- Show proposed fact changes as a diff and wait for a yes before writing them.

## 4. Hygiene

- `000-meta/todo.md`: keep only open items. Move finished items to
  `000-meta/todo-archive/<YYYY-MM>.md`. If more than 50 open items remain, ask which to park.
- `inbox/`: list items older than 14 days and propose where each belongs.
- Dated "open", "next step" or "still to do" lines that have been done since: add a "done"
  note with the date (do not delete the line). Numbers that age (advisories, stars, prices) written
  into a note as fixed values: list them and point to the living source.
- Personal data outside the archive sidecars (social insurance numbers, dates of birth,
  IBANs, passport numbers in normal notes): list the note and line, do not print the value.

## 5. Sync health (report only)

- `.git/index.lock` exists and no git process is running (`Get-Process git`): report it; the
  user decides whether to remove it. A stale lock silently stops Obsidian Git's backups.
- Last commit older than 24 hours while `git status` shows changes: report that the
  automatic commit has stopped.
- Conflict files from the sync (`*.sync-conflict-*`): the script check in section 2 lists
  them; they wait for the next morning run, which merges them.

## 6. Finish

- Append one line to `000-meta/log.md`:
  `## [YYYY-MM-DD] lint | fixed N, questions M`
- Report in German: what was fixed, what needs a decision, what looks wrong.

## Gotchas

- `graph_health.py` counted 20 findings inside moved foreign pages in `500-sources` whose links point to their origin sites -> `500-sources` is exempt; check links there only when the user asks.
- `graph_health.py` reported links inside inline code and fences as broken -> the check exempts code now; a finding inside a code block is a false positive, not a link to repair.
- Sync-conflict files parked in `trash/` were re-reported every day -> `trash/` is out of scope; a conflict file waits for the morning run, which merges it.
