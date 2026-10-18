# 18. Research orchestration as a dynamic workflow

Date: 2026-10-18

## Status

Accepted.

## Context

The `research` skill runs four search passes, saves the pages, extracts word-for-word
evidence, verifies it, writes the text and checks it. Until now the main session did this
turn by turn: every pass result, every extractor reply and every check output passed through
the main context, and the orchestration itself cost tokens and attention.

A dynamic workflow is a JavaScript script that the Workflow tool executes. The script spawns
its subagents through `agent()` and keeps intermediate results in script variables, so the
main context sees only the final answer. The orchestrator script itself costs no tokens; only
the agents do. A run is resumable in the same session through `resumeFromRunId`
(https://code.claude.com/docs/en/workflows, read 2026-10-18).

The gate required by the task was measured in `claude-ds` first, Claude Code 2.1.302:
the Workflow tool and `/workflows` are available; a tiny two-agent workflow returned
`GATE-ONE-OK`; and an `agentType: "web-researcher"` agent reached its own MCP servers - one
`exa-key` search returned 10 candidates with `services_used: ["exa-key"]`.

## Decision

Ship the orchestration as `~/.claude/skills/research/research.workflow.js` and keep the
twelve steps in `SKILL.md` as the fallback for harnesses without the Workflow tool (OpenCode,
Codex, any session where workflows are off). `SKILL.md` now starts with "If the Workflow tool
is available, run `research.workflow.js` with these args; otherwise follow the steps below."
The steps themselves are unchanged, so the harness-independent path stays intact.

The workflow keeps the skill's order and every cap: four passes with the same per-service
budgets (exa 3+3, parallel 3+5, exa-key 4, tavily 3+2, you-free 3, firecrawl 2, TinyFish 4,
you 3), Serper only on an Austrian question with `gl=at`/`hl=de` and at most 3 calls, at most
12 candidates per pass, at most 40 saved pages, word-for-word evidence decided by
`verify_evidence.py`, at most one gap pass for a tax/benefit/law question, the same writer,
`build_references.py`, `check_article.py` and at most two repair rounds. The question, answer
and source languages, work folder, date, slug and paths arrive through `args`; the script
never calls `Date.now()` or `Math.random()`.

`check_services.py` gains `--transcript-dir`, because the main session's transcript contains
only the Workflow tool call, not the search agents' tool calls. The workflow returns its
`transcriptDir`; the check counts both the main transcript and the workflow's `agent-*.jsonl`
files. Two tests cover that (a workflow dir alone, and a workflow dir together with a
session).

`quick-research`, `docs-import`, `vault-lint` and `life-os-morning` stay as they are: they are
too small for a workflow to pay off. `batch-run.ps1` stays harness-independent.

## Consequences

- The main context no longer carries four candidate lists, the raw evidence and every check
  output. The measured comparison below shows how much that is worth.
- The orchestration is deterministic: order, fan-out and retry bounds live in code, not in a
  model's turn-by-turn choices. A workflow that fails can be resumed; the completed agents
  return from the journal.
- There are now two descriptions of the same procedure. `SKILL.md` remains the source; the
  JavaScript mirrors it. A change to a cap or a step must land in both, and the comparison
  run is the check that they still agree.
- Workflow runs depend on the Workflow tool and the session's agent types. A harness without
  them uses the steps; a workflow with no MCP in its agents would fail at the search passes,
  which is why the gate tested the `web-researcher` agent type before any code was written.
- A workflow run is not storable from inside the script: the store step and the vault commit
  stay in the main session, as `SKILL.md` says.
- The comparison exposed a defect in a shared script, not in the workflow: a second
  `save_pages.py` call in the gap pass saves already-saved pages again under new numbers
  (72 page files, 53 unique bodies). Both paths show it. A follow-up should make `save_pages.py`
  idempotent and add a test.

## Comparison (same question, `claude-ds`)

Question: "Wie hoch ist das Kilometergeld in Österreich 2026, und welche Voraussetzungen
gelten?" Both runs used the same `plan.md` and stopped after the article check; neither stored
or cleaned up, so the same stretch is measured.

| Measure | Old skill path | Workflow |
|---|---|---|
| Duration | 1479.8 s (24.7 min) | 1777.1 s (29.6 min) |
| Agents | 11 (5 web-researcher, 5 evidence-extractor, 1 research-writer) | 25 (Search 5 incl. persist, Save pages 2, Extract 8, Verify 2, Gap pass 2, Write 4, Check 2) |
| Main-session tokens | 22,158,573 (input 369,615 + cache_read 21,482,112 + output 306,846) | 576,070 in an isolated headless start (input 173,641 + cache_read 396,032 + output 6,397); the interactive main session holds the whole task and cannot be isolated |
| Agent tokens | 11,616,000 (input 2,578,252 + cache_read 8,746,496 + output 291,252) | 47,183,087 (input 4,436,025 + cache_read 42,233,600 + output 513,462); `/workflows` reports 2,114,760 `subagent_tokens` |
| Main context at the end | 215,904 tokens (21.6 %) | 46,292 tokens (4.6 %) in the isolated headless start; the interactive session already held the task at 321,556 |
| Calls per service | exa 9, parallel 13, serper 3, exa-key 7, tavily 7, you-free 8, firecrawl 6, TinyFish 6, you 4 | exa 16, parallel 21, serper 1, exa-key 6, tavily 12, you-free 5, firecrawl 5, TinyFish 0 (skipped: no key in that session), you 4 |
| Pages saved | 72 page files (+ index.json), 53 unique bodies, 19 duplicates from the second save | `saved_pages` 39; 53 page files, 43 unique bodies, 10 duplicates |
| Verified evidence | 68 (11 failed the word-for-word check) | 128 |
| `check_article.py` | 0 errors, 2 warnings; 3 repair rounds (9 -> 14 -> 3 problems) | 0 errors, 5 warnings; 1 repair round |
| Cost | 18.8656 USD | no dollar figure is exposed in the interactive session; the aborted headless partial run cost 12.7409 USD for 37 pages and 86 evidence items |

The workflow ran in the main session because a `claude -p` session exits after launching the
background workflow and kills it (measured: the headless partial run above stopped in the gap
pass and produced no article). TinyFish was not called in the workflow because the session did
not have `TINYFISH_API_KEY`; the "no key, no call" rule applied and P3 reported
`tinyfish: skipped: no key`. The workflow verified 128 rather than 68 evidence items because
the gap pass started four more extractors; that, not a rule deviation, explains the higher
agent and token counts.

The trade-off is visible: the main context stays at 46k instead of 216k, but the workflow used
more agent tokens (47.2M against 11.6M) and took about five minutes longer. The orchestration
moved out of the main context; the total work grew because the gap pass was more thorough.
The workflow is therefore not a cost reduction per se; it is a context-hygiene decision.

The stopped-and-resumed run: stopped with `TaskStop` right after the search phase (six agents
started, five results, the save-pages agent running, 0 pages, no article), then resumed with
`resumeFromRunId` and the same args. The four search transcripts end at 20:36:27 to 20:37:10;
after the resume no new search agent starts (the next agents begin at 20:40:53), so the cached
candidates were reused. The resumed run saved 40 pages, verified 106 evidence items, needed one
repair round, and `check_article.py` reported 0 errors and 9 warnings. Duration 1722.6 s, 25
completed agents (26 started: the killed save-pages agent counts), 0 errors. TinyFish was used
twice in this run; the first main run lacked its key and correctly skipped it, so the session
environment differed between the two runs while the workflow behaved correctly in both.

## Alternatives

- **Leave the skill as it is.** Rejected: the main context carried every intermediate result,
  and the orchestration quality depended on the model following twelve steps in order.
- **A separate orchestration service.** Rejected: another daemon, another credential and
  another failure mode; the Workflow tool is already part of the harness and resumes runs.
- **Run research through `batch-run.ps1`.** Rejected for the same question: a batch starts
  fresh sessions per item, but the research pipeline is one multi-stage run with shared
  intermediate state, not many independent items.
