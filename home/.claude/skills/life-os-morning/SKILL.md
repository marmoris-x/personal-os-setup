---
name: life-os-morning
description: Use when running the Life OS morning routine in the PersonalOS vault - ordering new life-log entries, pulling out tasks, merging Syncthing conflicts, writing the Morgenbericht. Triggered by the scheduled headless run (/life-os-morning) and by "Morgenroutine", "Lebensprotokoll verarbeiten".
---

# Life OS morning routine

You are the ordering step of the Life OS morning run. A PowerShell script has already
transcribed new voice recordings (faster-whisper) and collected the inputs. You read those
inputs, then you only structure and write. You have no shell and no internet, on purpose.

**You work only inside the current working directory (the vault `{{VAULT}}`).**
Never read, write or edit anything outside it. Never delete or move anything. That is not
your job: files that should go away go into a list; a script moves them later.

**Violating the letter of these rules is violating their spirit.** The life log is the user's
unfiltered memory. What you write here he will read for years.

## Inputs (read exactly these; do not explore the vault)

| File | What it holds |
|---|---|
| `000-meta/life-os-inbox.json` | every transcript waiting in `inbox/audio`: `txt`, `audio`, `recorded` (ISO), `chars` |
| `000-meta/life-os-conflicts.json` | sync conflict files found by the vault-lint check: `file`, `original`, `modified`, `bytes` |
| `000-meta/life-os-expiry.json` | notes whose `valid_until` is past or within 7 days: `file`, `valid_until`, `days`, `status` (written by the runner; may not exist) |
| `000-meta/life-os-transcribe.json` | this run's transcription: `engine`, `files`, `groq_ok`, `local_fallback`, `fallback_reasons_de` (German reasons), `groq_seconds_today`, `daily_cap_seconds` (may not exist) |
| `000-meta/life-os-projects.json` | project changes from the tracker: `projects`, `attention`, `missing`, `no_git`, `large_files`, `media_raw_total_gb` (written only when something needs action; may not exist) |
| `000-meta/life-os-runs.log` | one line per script run: `<iso> \| transcribe\|morning \| ok\|warn\|fail \| detail` |
| `000-meta/life-os-state.json` | what was already processed (may not exist yet) |
| `000-meta/trash-queue.txt` | list of vault-relative paths to remove (may not exist yet) |
| `100-daily/<YYYY-MM-DD>.md` | the daily notes |
| `000-meta/templates/daily.md` | the template for a missing daily note |

If `life-os-inbox.json`, `life-os-conflicts.json`, `life-os-expiry.json`,
`life-os-transcribe.json` or `life-os-projects.json` does not exist, treat it as empty.
Today's date and the optional date argument after `/life-os-morning` both count: the argument
wins, otherwise use today. (The runner passes no argument; tests may.)

## Fixed formats - do not invent your own

- Transcript entry in `## Roh`: `- **HH:MM (Sprachaufnahme)** <transcript text, verbatim>`
- Protokoll entry: `- **HH:MM** <ordered text>` (`HH:MM` only when the raw entry has a time;
  a topic label like `**Einkauf:**` may replace the time)
- Task in `## Aufgaben`: `- [ ] <task>` - append `📅 YYYY-MM-DD` only when the text names a
  concrete date (then compute the ISO date; never guess a date from vague wording like
  "nächste Woche")
- Trash list: one vault-relative path per line, nothing else

## The six steps

### 1. Transcripts into `## Roh` of the recording day

For every entry in `life-os-inbox.json`:
1. Target note: `100-daily/<recorded date>.md`. If it does not exist, create it from
   `000-meta/templates/daily.md` with `{{date}}` replaced by that date (frontmatter `date:`
   included).
2. Skip the transcript when the note already contains a line with the same `HH:MM
   (Sprachaufnahme)` **and** the same first ~8 words - it was processed by an earlier run.
3. Otherwise read `inbox/audio/<txt>` and append, at the very end of the `## Roh` section
   (after the last existing line, before the next `##`):
   `- **HH:MM (Sprachaufnahme)** <text>`
   The text goes in **verbatim**. Never rewrite, shorten or "fix" it - it is raw material.
4. In a multi-paragraph transcript, keep the user's paragraph breaks; never reorder.

### 2. Order new entries into `## Protokoll`

"New" means: everything in `## Roh` **after** the note's stored anchor (see state below).
For a note with no stored anchor, everything is new.

For each note with new content, append to the end of its `## Protokoll` section:
- the ordered version: time points, topics, the user's own words; group by time of day or
  topic; correct only obvious hearing errors (a name that no source knows stays as it sounds,
  with a `[?]` next to it);
- **never invent** facts, names, numbers or feelings that are not in the raw text;
- do not copy raw lines unchanged unless they are already clear sentences;
- nothing that is already in `## Protokoll` gets written again. If unsure, skip.

Then update the note's anchor in the state file: the **last line of `## Roh`**, first 120
characters, exactly as it stands after your edit.

**If the stored anchor is not found in `## Roh`** (the user edited raw text by hand): do not
process that note, write one line into the Morgenbericht that the raw text changed, and leave
the anchor alone. Guessing here costs the user his words.

### 3. Tasks into `## Aufgaben`

Scan the new raw content (transcripts and entries from step 2) for anything the user wants to
do: explicit ("ich muss", "erinnere mich", "sollte") and clear implied tasks. For each, append
`- [ ] <task>` to `## Aufgaben` of the note it came from - unless the same task is already
there. Keep the user's wording. One task per line. No Task that the user did not voice or
write - when in doubt, leave it in the Protokoll only.

### 4. Sync conflicts

For every entry in `life-os-conflicts.json`:
1. Read the conflict `file` and its `original`.
2. If the original does not exist: leave everything, write one sentence in the Morgenbericht.
3. If the conflict copy holds wording that the original does not: merge it in at the matching
   place - keep the original text in full, add what is missing. When the right place is
   unclear, append the missing part at the end of the matching section, with
   `<!-- zusammengeführt <YYYY-MM-DD> -->` after it.
4. If the conflict copy holds nothing new (its content is fully contained in the original),
   change nothing in the original.
5. In every case: append the conflict file's path to `000-meta/trash-queue.txt` (one line;
   create the file if missing). Never delete or move the conflict file yourself.

### 5. Projects into `200-projects/<name>.md`

Read `life-os-projects.json`. If it does not exist, skip this step. Do not explore
`{{DEV}}\Projects`: the tracker has already read every repository, and you have no shell.
The note frontmatter (`last_activity`, `uncommitted`, `unpushed`) is already updated; never
write it yourself.

For every entry in `projects` (changed since the last run):
1. Note path `200-projects/<name>.md`. If it does not exist: one Morgenbericht line
   `Projekt ohne Notiz: <name>`, and nothing else for that project.
2. Append exactly one line to `## Timeline` (create the heading at the end of the note if it
   is missing; never reorder other lines):
   `- <YYYY-MM-DD> — <what changed>`. Build it only from the entry's fields:
   `new` -> "neu angelegt"; `rewritten` -> "Historie umgeschrieben"; `commits` ->
   "Commits: <subjects joined with '; '>"; `uncommitted` -> "nicht committet"; when
   `dirty_days` is greater than 0 add "seit N Tag(en)"; `unpushed` greater than 0 ->
   "N nicht gepusht"; `stashes` greater than 0 -> "N Stash(es)". Join with ", ".
   If the same line (same date and wording) is already there, do not add it again.
3. Replace the content of `## Next step` with the entry's `next_step` when that is not null.
   Keep the heading. When `next_step` is null, leave the section unchanged. Copy the text
   as it stands, do not shorten or improve it.

An entry in `attention` that is not in `projects` is unchanged since an earlier run: no
Timeline line and no "Next step" update; only the Morgenbericht lines in step 6 apply.
An entry in `missing` (repository gone or renamed) is never written into a note.

### 6. Morgenbericht and state

Ensure today's note exists (same rule as step 1), then replace the content of its
`## Morgenbericht` section with:
- one line per thing this run did (transcripts taken in, notes ordered, tasks added, conflicts
  merged, project notes updated) - only what really happened;
- a line "Heute:" with the open tasks of today's `## Aufgaben` whose `📅` is today or earlier;
- when `life-os-expiry.json` names notes, ONE line `Ablaufend: <file> am <valid_until>` (join
  several with `; `) - only what that file says, and do not check or change the fact;
- when `life-os-transcribe.json` has `local_fallback` greater than 0, ONE line
  `Transkription: lokaler Fallback (<fallback_reasons_de joined with '; '>)` - only what that
  file says, never a guessed reason;
- from `life-os-projects.json`, only the lines that apply:
  - `Nicht gepusht: <name> (<N> Commit(s))` for every `attention` entry with `unpushed`
    greater than 0; join several with `; `.
  - `Nicht committet seit <N> Tag(en): <name>` for every `attention` entry with
    `uncommitted` true. When `dirty_days` is 0, write `Nicht committet: <name>`.
  - `Große Datei im Backup (außerhalb media\raw): <path> (<size_gb> GB)` for every entry in
    `large_files`.
  - `Projekt ohne Notiz: <name>` for every entry in `projects` with `note_missing` true.
  - `Projektordner ohne Git: <names>` when `no_git` is not empty.
  - `Projekt verschwunden: <names>` when `missing` is not empty.
  - `media\raw gesamt: <media_raw_total_gb> GB` when the value is greater than 0.
- one sentence for each `fail` or `warn` line in `life-os-runs.log` from today or yesterday
  (a failed earlier run must be visible here);
- if nothing happened at all: one line saying so.

Write the state file `000-meta/life-os-state.json` last (merge with its old content):

```json
{
  "version": 1,
  "notes": { "2026-10-08": { "roh_anchor": "<first 120 chars of the last processed ## Roh line>" } },
  "last_run": "<ISO timestamp of this run>"
}
```

Only write it when all steps are done. A crash before this point means the next run repeats
the work; the dedup rules above are what make that harmless.

## Report to the user (your final answer)

In German, short: what was processed (transcript count, notes touched, tasks added, conflicts
merged), what could not be done, and the file paths you changed. No JSON, no code.

## Red flags - stop and reconsider

- You are about to write, read or delete something outside the vault -> never.
- You are about to look into `{{DEV}}\Projects` yourself -> no. `life-os-projects.json`
  already holds what the tracker read, including the "Next step" text.
- You are about to "improve", shorten or delete raw text -> never. `## Roh` is append-only.
- You are about to invent a fact, name, date or task -> never. Unclear stays unclear.
- You are about to move a file "just this once" -> never. The trash list is the only exit.
- You are about to explore the vault for more context -> no. The input table is complete;
  every extra file read costs money and adds nothing.

## Gotchas

- none recorded yet
