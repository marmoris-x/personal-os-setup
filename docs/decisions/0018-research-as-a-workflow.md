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

Step 3's recovery pass and step 8's warning rule stay in the workflow. A callable service that
failed in one of the four passes gets one small extra pass (at most five candidates, one or two
queries from the plan); `skipped: no key` and the Serper reserve never trigger it. The
authoritative per-service count is still `check_services.py` after the run. The check's warnings
travel with the first repair, or, when no error repair happens, go to the writer once as a
warning pass; error repairs stay at two rounds. The comparison runs needed no recovery pass
(TinyFish was skipped for a missing key, which is not a failure), and their warnings travelled
with the repair, so the table's agent counts are unaffected by these two steps.

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

Question (asked in German): how high is the kilometre allowance (Kilometergeld) in Austria in
2026, and which conditions apply? Both runs used the same `plan.md` and stopped after the article check; neither stored
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

### Lean workflow (2026-10-19)

The lean two-level workflow was measured on the same question in the main `claude-ds`
session, at peak `deepseek-flash` prices. Standard used two search passes, a 15-page cap and
no gap pass; deep used P1 to P3, stopped after P1 to P3 on the early-finish rule (25 unique
candidates from 8 domains; P4 skipped) and ran the gap pass. All agents ran on
`deepseek-flash`.

| Measure | Standard | Deep |
|---|---|---|
| Duration | 21.9 min | 19.6 min |
| Agents | 10 (2 search, 1 save, 2 extract, 1 verify, 1 writer, 1 repair, 2 check) | 15 (P1-P3 + gap, 1 save, 5 extract, 1 verify, 1 writer, 1 repair, 2 check) |
| Agent tokens | 10,935,945 (input 1,647,921 + cache_read 9,031,552 + output 256,472) | 23,240,395 (input 2,346,609 + cache_read 20,521,216 + output 372,570) |
| Main-session tokens | 13,411,162 all assistant records; 6,202,712 deduplicated by message id | 1,196,998 |
| Total tokens | 24,347,107 (17,138,657 deduplicated) | 24,437,393 |
| Pages | 14 unique, 0 duplicates (15 candidates, 1 failed) | 34 unique, 0 duplicates |
| Verified evidence | 35 (23 exact, 12 markdown-stripped) | 85 |
| `check_article.py` | 4 errors, 8 warnings, 1 repair round (11 -> 4) | 0 errors, 0 warnings, 1 repair round (3 -> 0) |
| Cost at peak `deepseek-flash` | 1.0027 USD (agents 0.8563; deduplicated 0.9248) | 1.2905 USD (agents 1.2742) |

The standard answer and the deep answer both state 0.50 Euro per car kilometre, 0.25 Euro
for motorcycle and bicycle and 0.15 Euro per passenger.

**Decision (owner, 2026-10-19): keep the lean workflow for deep; turn standard off.**
Deep meets the total-token target (24.4M against 33.8M), the zero-error target (0 errors,
1 of 2 repairs) and the evidence target (85 against 60). It costs 1.2905 USD against 2.26 USD
for the accepted workflow. The owner later set the deep cost limit to **1.50 USD** at peak
`deepseek-flash` price: the two corrected runs below differ by 0.12 USD, so the 0.03 USD miss
against the earlier 1.40 USD estimate is within run-to-run noise; the quality criteria are
unchanged. Standard is off: 4 errors and 1.0027 USD, almost the cost of deep. Research runs
deep until standard is fixed; the standard branch stays in the code for a later measurement
but is not selectable. The table measures the first candidate; after the review the gap pass
moved behind verification (it reads `verified.jsonl`) and the extractor groups were balanced
(34 pages -> 7,7,7,7,6), so the corrected deep path needs a new measurement; 1.2905 USD is the
measured first candidate. The deep run used 15 agents (14 without the one repair), one over
the design target of 14; recorded, not hidden.

### Repeated deep runs with deterministic quoting (2026-10-19)

`fix_quotes.py` (skill `research`, scripts folder) repairs a fragment that is not a word
sequence of its evidence when the evidence holds a contiguous span with at least 90 % token
similarity (matches divided by the longer side, so a truncated span loses the words it
dropped); the exact span replaces the fragment in the paragraph and the compose comment. No
model is called. Two fresh deep runs used the same question and plan at peak `deepseek-flash`
prices.

| Measure | Run 1 | Run 2 |
|---|---|---|
| Agents | 17 | 17 |
| Agent tokens | 27,459,292 (input 2,259,712 + cache_read 24,747,008 + output 452,572) | 27,455,417 (input 2,603,662 + cache_read 24,388,480 + output 463,275) |
| Main-session tokens | 380,606 | 1,163,812 |
| Total tokens | 27,839,898 | 28,619,229 |
| Pages | 38 unique, 0 duplicates | 35 unique, 0 duplicates |
| Verified evidence | 82 | 81 |
| `check_article.py` | 0 errors, 5 warnings, 1 repair round | 0 errors, 5 warnings, 1 repair round |
| Duration | 27.4 min | 28.0 min |
| Cost at peak `deepseek-flash` | 1.3722 USD (agents 1.3695; main 0.0027) | 1.4917 USD (agents 1.4834; main 0.0083) |

Both runs skipped P4 on the early-finish rule, ran the gap pass, and state 0.50 Euro per car
kilometre, 0.25 Euro for motorcycle and bicycle and 0.15 Euro per passenger. `fix_quotes.py`
reported `FIX-QUOTES: 0 fixed` on both final drafts: the writer wrote exact fragments, so the
new repair path was not needed in these runs; its eight tests cover the repair. The owner
accepted both runs on 2026-10-19: 0 errors, 1 repair round, 82 and 81 verified, 27.84M and
28.62M tokens, the same amounts, and an average cost of **1.4320 USD** under the owner's
**1.50 USD** deep limit (1.4265 USD even without the main-session records). The 0.03 USD
above the earlier 1.40 USD estimate is within the 0.12 USD spread between the two runs; the
quality criteria were not changed. The table and the decision are committed, exported and
pushed with the fix.

## Alternatives

- **Leave the skill as it is.** Rejected: the main context carried every intermediate result,
  and the orchestration quality depended on the model following twelve steps in order.
- **A separate orchestration service.** Rejected: another daemon, another credential and
  another failure mode; the Workflow tool is already part of the harness and resumes runs.
- **Run research through `batch-run.ps1`.** Rejected for the same question: a batch starts
  fresh sessions per item, but the research pipeline is one multi-stage run with shared
  intermediate state, not many independent items.

## Pruned reading copy (search tuning, 2026-10-25)

Crawl4AI's `PruningContentFilterLXML` (threshold 0.6, docs example) now yields a `fit_markdown` next
to the unchanged raw markdown. `save_pages.py` writes it to `pages/fit/<same name>` (the full text
when pruning leaves nothing); `verify_evidence.py` keeps checking the raw page. The workflow
argument `fit` lets the extractors read the copy; the same code ran both measurement runs
(Kilometergeld, deep, German, identical `plan.md`, SHA-256 `d3b81a69...c8f39`). The owner ran them in
`claude-ds` at the same time.

| | Run A: fit off | Run B: fit on |
|---|---|---|
| Pages saved | 36 | 34 |
| Extractor input tokens | 3,236,521 | 2,584,633 (-20.1 %; per saved page 89,903 vs 76,019, -15.4 %) |
| Verified evidence | 76 | 75 |
| `check_article.py` | 1 error | 0 errors |
| DeepSeek cost by timestamp | 0.5025 USD | 0.4361 USD (not used: run B reads the cache run A warmed) |

Run A alone, same pages: the pruned copies hold 30.9 % fewer tokens than the full pages (about
437,600 vs 633,300; 23 of 36 pages shortened).

The saved URLs overlap by 17 of 53 (Jaccard 0.32; 50 % of the smaller run): search results differ
between two runs, and run B's Tavily search hit a 429 on its second call. By the owner's gate
(under 70 % overlap) the evidence comparison is **not reliable**. Taken at face value the task's
rule is not met either: the extractor drop is 20.1 % in total but 15.4 % per page, and verified
evidence is 75 against 76.

Decision: the reading copy **stays off by default** (`fit: true` switches it on); the code stays
because it is tested and the copy is a pure addition. A fair decision needs both arms on the
same URL set, i.e. extracting once from the saved pages of one run, with and without the
reading copy, rather than two fresh searches. Run A's one remaining `check_article` error (E67: the key-point
bullet writes "gesetzlicher Anspruch", the recorded fragment reads "gesetzlichen Anspruch") belongs
to the existing writer step, not to the reading copy; it does not touch the token numbers.
