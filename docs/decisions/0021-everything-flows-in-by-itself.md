# 21. Everything flows in by itself

Date: 2026-10-25

## Status

Accepted.

## Context

The owner only dictates or types on the phone. Everything after that has to happen without
him: loose notes reach the life log, tasks reach one list, the area notes follow his own
words, and the project hubs stay current. Safety comes from checks and from git history, not
from asking him each time. Measured before this change: on four days in a row (22 to 25
October) the morning agent started and cost 0.25 to 0.59 USD per run although it reported
"nothing to process". On 23 to 25 October the project flag was set by real commits; on 22
October the pre-check logged no reason, so the cause cannot be proven.

## Decision

A script does everything that needs no judgement, the agent only orders and writes in its own
words, and a token-free check restores whatever the agent should not have changed.

| What | How |
|---|---|
| The agent starts only for work | `morning-checks.ps1` `Get-AgentReasons`: a transcript, a loose note, a sync conflict, an unseen other file, text typed after the stored anchor, a changed project whose hub is older than its repository. The log line `agent reasons: ...` names why. Everything else (not committed, not pushed, a note about to expire, a transcription fallback, a failed run, files that were not processed) is written into the morning report by `morning.ps1` itself, between `<!-- morning.ps1 -->` markers the agent never touches. |
| Loose notes | `.md` and `.txt` files directly in `inbox/` (at least ten minutes old) are copied word for word into `## Roh` of their change day by the script, images become their alt text, the file goes to the trash queue. A model copy of a 60,000-character note was measured to invent one line and drop another, which breaks vault rule 14, so the script copies and the agent only orders. Any other file in `inbox/` is named in the morning report as not processed. |
| One task list | The agent writes `- [ ] task` into the daily note; the script moves it to `## Next` of `000-meta/todo.md` with a link back and a `📅` date. Nothing was queryable before: the Tasks plugin is installed but no query exists. |
| Areas follow the owner | The agent appends a Timeline line and may replace a sentence of "Current truth" in `300-areas/`, only from his own entries, with the source (`[[100-daily/<date>]]`) and the old sentence kept. `area-check.ps1` compares with a snapshot taken before the agent ran and restores every change that has no source, a word the source does not contain, a number of four digits or more, a changed frontmatter or a removed line. One vault commit per run. |
| Project hubs | The agent that worked in a project writes the hub itself at the end of every task (`dev/Projects/CLAUDE.md`, key `hub_written`). The Stop hook `hub-reminder.ps1` blocks the end of a turn once when the hub is older than the repository. The morning run catches up what is still missing, in its own words (`hub_stale` in the flag file). |
| Weekly hint | On Mondays the script compares, per area, the newest date at the end of the file names in its archive folder with the newest Timeline date, and writes one line. It reads names only, and only where the folder is unambiguous (not named by another area, not enclosing the folder of another area). |

The owner's principle: safety comes from checks and git history, not from questions. A change
that could be wrong is repaired by a script from a copy, not by waiting for him.

## Why not

- The agent copies the notes: measured to corrupt long text (see above).
- A `reviewed:` key on every area note: the weekly hint covers the same need without a field
  that someone has to maintain.
- A rule file for OpenCode and Codex: `install.ps1` deploys no global agent file for them, and
  the Codex file is personal and not in this repo. The morning catch-up is their safety net.
- Hub text copied from `PROGRESS.md`: it goes stale in a different way; the agent says it
  again in its own words and the hook checks the time.

## Safety net

`area-check.ps1` (restores, never deletes a new note, only names it), `Save-VaultCommit` (one
commit per run, only the four folders the run writes, never pushes), a fail-open Stop hook
(any error exits 0 so a broken reminder cannot trap an agent), a vault-path check at the top
of `morning.ps1` (exit 2 for a value that is not an existing absolute folder), and tests that
failed once on purpose before they were trusted.

## Cost

Measured with the real agent on throw-away vault copies: an agent run with a typical inbox is
about 0.25 to 0.6 USD; the area step adds about 0.35 USD on a day with area-relevant entries
(1.23 against 0.88 USD for the same day with the old skill); a hub catch-up is about 0.4 USD.
A day with nothing to order costs nothing, where it cost 0.25 to 0.59 USD before.

## Consequences

- The morning agent runs on fewer days. The morning report gains script-written lines and loses
  nothing the agent used to write.
- Vault rule 12 and rule 4 change (`hub_written`), the vault `AGENTS.md` gets one exception for
  `300-areas/`, and the global `CLAUDE.md` gets the hub exception.
- `vault-lint` `project-sync` also reports a finished hub whose `repo:` path does not exist.
