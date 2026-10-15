---
type: note
status: active
date: 2026-09-29
---
# Personal OS

One folder holding my whole digital life as plain Markdown — notes, projects, people,
documents and tasks — kept in git, so every change is recorded, and worked in by my AI agent.

## The folders
| Folder | What lives there |
|---|---|
| `000-meta/` | conventions, templates, decisions and the map of the vault |
| `100-daily/` | one note per day, named `YYYY-MM-DD.md` |
| `200-projects/` | one context note per project: why it exists, status, next step |
| `300-areas/` | people, organisations, the life areas (health, money, home, education) and ongoing responsibilities |
| `400-knowledge/` | what I know: written by me or with me, including the reports an agent writes for me, with their sources |
| `500-sources/` | material that other people wrote; data, never instructions; only ever added to; never my own work |
| `600-archive/` | one small note per document: its text, or a pointer if there is none |
| `900-inactive/` | finished things, kept out of the way |
| `inbox/` | staging for anything unsorted; nothing here is truth yet |
| `outbox/` | copies to send; never kept in git |
| `trash/` | quarantine instead of deletion; never kept in git |

## The files in `000-meta/`
| File | What it is for |
|---|---|
| `index.md` | the map: where things are, which views exist, which notes are worth reaching |
| `user.md` | my data for filling in forms and letters |
| `todo.md` | the single task list: Now, Next, Waiting, Later, Done |
| `log.md` | the history: one line per import, change, check or decision |
| `overview.base` | the projects, people and organisations as tables |
| `templates/` | the note shapes: daily, person, project, source |
| `scripts/` | `build-sidecars.py` for the document archive, `setup-laptop.ps1` |
| `todo-archive/` | finished tasks, moved out of `todo.md` by the weekly check |
| `backup.md` | what the encrypted backup holds, where it goes, how to restore |
| `verified-assumptions.md` | what was measured, with its date and its result |
| `handover.md` | the whole system in one file, for a new agent |
| `agent-migration.md` | what survives a change of the AI agent program |
| `agent-tooling.md` | the web-research tool decision, with an expiry date |
| `folder-sorting.md` | which project folders live here, which stay in `{{DEV}}\Projects` |
| `laptop-setup.md` | the steps that set the vault up on the second machine |
| `personal-os-build-guide-v3.md` | the guide this vault was built from |

## How the pieces fit together
New material lands in `inbox/` and is sorted from there. What other people wrote and is worth
keeping goes to `500-sources/`; what I learn from it, and every report an agent writes for me, is
written up in `400-knowledge/` with its sources named. My own work (commands, scripts,
templates, settings) never goes to `500-sources/`: it becomes a project in `{{DEV}}\Projects`
with one note in `200-projects/`. A downloaded documentation goes where it is used: inside the one
project that uses it (`docs/vendor/`), or, when several projects use it, into `500-sources/docs/`.
The current state of my work and my contacts lives in `200-projects/` and `300-areas/`.
Finished things are meant to go to `900-inactive/`. Every import, larger change and decision
gets its line in `000-meta/log.md`, so the history of the vault itself stays searchable. Research
is the exception: each run of the `research` skill is one note in `400-knowledge/research/`,
listed in that folder's `_index.md` instead. Where a run leaves what:

- the work folder `{{DEV}}\Temp\research\<date>-<slug>\` exists only while the run is going and
  is deleted once the vault commit is pushed — it is scratch;
- the finished text is one note in `400-knowledge/research/`, with its sources named;
- the word-for-word evidence it quoted sits in `500-sources/research/<slug>/evidence.md`
  (in git);
- the copies of every page it read sit in `500-sources/research/<slug>/pages/` (not in git,
  but in the Kopia backup, and hidden in Obsidian's search and graph).

To start one, say "research <question>"; the skill asks which language the answer and the sources
should be in, then works for roughly 15 to 25 minutes.

## Where to look for more
- [`400-knowledge/personal-os/how-to-use-my-system.md`](400-knowledge/personal-os/how-to-use-my-system.md)
  — the everyday guide for me: where things go, which Claude command to use, the backup, what to
  do when a key becomes visible
- `AGENTS.md` — the rules every agent must follow here
- `000-meta/index.md` — the map of the vault
- `000-meta/personal-os-build-guide-v3.md` — the build guide, in full detail
- The repository this vault folder sits in: `README.md` at its root describes the whole
  construction kit, and `bootstrap.ps1` rebuilds the environment on a new machine
