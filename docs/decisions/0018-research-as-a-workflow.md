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

## How tokens are counted (corrected 2026-10-27)

Claude Code writes one model response as several transcript lines, one per content block
(thinking, text, tool_use), and every line carries the full `usage` of the request. This ADR
first summed every line for the agents, so each request was counted about 2.7 times. The
2026-10-27 measurement found it: the per-line sums were 2.7 to 3.3 times the real figures. Counted
per request, the lean runs' agent tokens are 63 to 67 % lower and their agent USD at peak price
42 to 46 % lower. ClaudeBar counted 4 times for the same reason
(https://github.com/tddworks/ClaudeBar/issues/207); ccusage keeps the most complete line per
key, because `output_tokens` grows while streaming and the input and cache fields are identical
(https://github.com/ccusage/ccusage/issues/938).

Rule: one request is one key, (`message.id`, `requestId`), or `message.id` alone when a line has
no `requestId`; per key the line with the highest `output_tokens` counts. Every measurement uses
`~/.claude/skills/research/scripts/count_usage.py`. It reads a session transcript, its
`subagents/agent-*.jsonl` and a Workflow run's `transcriptDir`, prints the raw line sum next to
the deduplicated sum, prices each request with DeepSeek's rates by its own time (peak 01:00 to
04:00 and 06:00 to 10:00 UTC, Monday to Friday,
https://api-docs.deepseek.com/quick_start/pricing, read 2026-10-27), and also prints `USD@peak`,
every request at the peak rate, which is the convention of the tables below and of the cost
limit. Only DeepSeek models are priced: a `claude-*` model gets tokens and no USD, any other
model is `unknown`. It also splits cache misses into cold start, new content and prefix break.

Every agent-token and cost figure below was recomputed from the transcripts that still exist.
The main-session figure of a run is the deduplicated sum of the main session's requests from the
first to the last line of the run's agents. The raw line sums of that window reproduce the earlier
main-session figures exactly (13,411,162, 1,196,998, 380,606 and 1,163,812), so the window is the
one the earlier tables used; the earlier "6,202,712 deduplicated by message id" of the standard
run equals the corrected figure. The two main-session figures of the first comparison table are
whole sessions (their raw line sums, 22,158,573 and 576,070, are reproduced as well). The cost
figures of the tables are USD at DeepSeek's peak rates. The old figures stay here as history:

| Run | Agent tokens, counted per line | Agent tokens, counted per request | Agent USD at peak, per line | Agent USD at peak, per request |
|---|---|---|---|---|
| Old skill path (2026-10-18) | 11,616,000 | 3,538,818 | 1.1755 (not stated before) | 0.5504 |
| Workflow, first run (2026-10-18) | 47,183,087 | 15,839,037 | 2.2004 (not stated before) | 1.0897 |
| Workflow, resumed run (2026-10-18) | 37,261,707 (not stated before) | 13,063,714 | 1.9621 (not stated before) | 0.9327 |
| Lean standard (2026-10-19) | 10,935,945 | 3,626,032 | 0.8563 | 0.4765 |
| Lean deep (2026-10-19) | 23,240,395 | 7,634,512 | 1.2742 | 0.6936 |
| Deep run 1 (2026-10-19) | 27,459,292 | 9,684,545 | 1.3695 | 0.7976 |
| Deep run 2 (2026-10-19) | 27,455,417 | 10,033,095 | 1.4834 | 0.8484 |

The pruned-copy table further down was already counted per request and is unchanged; the
recomputation reproduces its extractor input (3,236,521 and 2,584,633) and its cost by
timestamp (0.5025 and 0.4361 USD) exactly. The USD figures Claude Code itself displayed
(18.8656 and 12.7409 USD) are not DeepSeek prices and are not comparable with the tables.

## Comparison (same question, `claude-ds`)

Question (asked in German): how high is the kilometre allowance (Kilometergeld) in Austria in
2026, and which conditions apply? Both runs used the same `plan.md` and stopped after the article check; neither stored
or cleaned up, so the same stretch is measured.

| Measure | Old skill path | Workflow |
|---|---|---|
| Duration | 1479.8 s (24.7 min) | 1777.1 s (29.6 min) |
| Agents | 11 (5 web-researcher, 5 evidence-extractor, 1 research-writer) | 25 (Search 5 incl. persist, Save pages 2, Extract 8, Verify 2, Gap pass 2, Write 4, Check 2) |
| Main-session tokens | 8,435,351 (input 124,302 + cache_read 8,212,736 + output 98,313) | 224,377 in an isolated headless start (input 44,756 + cache_read 177,536 + output 2,085); the interactive main session holds the whole task and cannot be isolated |
| Agent tokens | 3,538,818 (input 618,384 + cache_read 2,629,504 + output 290,930) | 15,839,037 (input 1,301,492 + cache_read 14,024,960 + output 512,585); `/workflows` reports 2,114,760 `subagent_tokens` |
| Main context at the end | 215,904 tokens (21.6 %) | 46,292 tokens (4.6 %) in the isolated headless start; the interactive session already held the task at 321,556 |
| Calls per service | exa 9, parallel 13, serper 3, exa-key 7, tavily 7, you-free 8, firecrawl 6, TinyFish 6, you 4 | exa 16, parallel 21, serper 1, exa-key 6, tavily 12, you-free 5, firecrawl 5, TinyFish 0 (skipped: no key in that session), you 4 |
| Pages saved | 72 page files (+ index.json), 53 unique bodies, 19 duplicates from the second save | `saved_pages` 39; 53 page files, 43 unique bodies, 10 duplicates |
| Verified evidence | 68 (11 failed the word-for-word check) | 128 |
| `check_article.py` | 0 errors, 2 warnings; 3 repair rounds (9 -> 14 -> 3 problems) | 0 errors, 5 warnings; 1 repair round |
| Cost | 18.8656 USD is the figure Claude Code displayed; at DeepSeek's peak rates the agents cost 0.5504 USD and the main session 0.2045 USD | no dollar figure is exposed in the interactive session; the agents cost 1.0897 USD at DeepSeek's peak rates. The aborted headless partial run (37 pages, 86 evidence items) showed 12.7409 USD in Claude Code; at DeepSeek's peak rates it cost 0.5580 USD (agents 0.5410, main 0.0170) |

The workflow ran in the main session because a `claude -p` session exits after launching the
background workflow and kills it (measured: the headless partial run above stopped in the gap
pass and produced no article). TinyFish was not called in the workflow because the session did
not have `TINYFISH_API_KEY`; the "no key, no call" rule applied and P3 reported
`tinyfish: skipped: no key`. The workflow verified 128 rather than 68 evidence items because
the gap pass started four more extractors; that, not a rule deviation, explains the higher
agent and token counts.

The trade-off is visible: the main context stays at 46k instead of 216k, but the workflow used
more agent tokens (15.8M against 3.5M) and took about five minutes longer. The orchestration
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
| Agent tokens | 3,626,032 (input 505,304 + cache_read 2,864,256 + output 256,472) | 7,634,512 (input 690,947 + cache_read 6,571,136 + output 372,429) |
| Main-session tokens | 6,202,712 | 598,499 |
| Total tokens | 9,828,744 | 8,233,011 |
| Pages | 14 unique, 0 duplicates (15 candidates, 1 failed) | 34 unique, 0 duplicates |
| Verified evidence | 35 (23 exact, 12 markdown-stripped) | 85 |
| `check_article.py` | 4 errors, 8 warnings, 1 repair round (11 -> 4) | 0 errors, 0 warnings, 1 repair round (3 -> 0) |
| Cost at peak `deepseek-flash` | 0.5451 USD (agents 0.4765; main 0.0685) | 0.7018 USD (agents 0.6936; main 0.0082) |

The standard answer and the deep answer both state 0.50 Euro per car kilometre, 0.25 Euro
for motorcycle and bicycle and 0.15 Euro per passenger.

**Decision (owner, 2026-10-19): keep the lean workflow for deep; turn standard off.**
Deep meets the total-token target (24.4M against 33.8M), the zero-error target (0 errors,
1 of 2 repairs) and the evidence target (85 against 60). It costs 1.2905 USD against 2.26 USD
for the accepted workflow. The owner later set the deep cost limit to **1.50 USD** at peak
`deepseek-flash` price: the two corrected runs below differ by 0.12 USD, so the 0.03 USD miss
against the earlier 1.40 USD estimate is within run-to-run noise; the quality criteria are
unchanged. Standard is off: 4 errors and 1.0027 USD, almost the cost of deep. (These figures are
the line-counted ones of the day. Counted per request, deep is 8.2M tokens and 0.70 USD, standard
9.8M and 0.55 USD (about four fifths of deep, so "almost the cost of deep" no longer fits), the
accepted workflow 1.13 USD; the ranking holds. The 1.50 USD limit was set
on the inflated figures and is replaced by 1.20 USD, see the 2026-10-27 section.) Research runs
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
| Agent tokens | 9,684,545 (input 680,591 + cache_read 8,552,192 + output 451,762) | 10,033,095 (input 805,613 + cache_read 8,765,696 + output 461,786) |
| Main-session tokens | 190,303 | 581,906 |
| Total tokens | 9,874,848 | 10,615,001 |
| Pages | 38 unique, 0 duplicates | 35 unique, 0 duplicates |
| Verified evidence | 82 | 81 |
| `check_article.py` | 0 errors, 5 warnings, 1 repair round | 0 errors, 5 warnings, 1 repair round |
| Duration | 27.4 min | 28.0 min |
| Cost at peak `deepseek-flash` | 0.7989 USD (agents 0.7976; main 0.0013) | 0.8526 USD (agents 0.8484; main 0.0042) |

Both runs skipped P4 on the early-finish rule, ran the gap pass, and state 0.50 Euro per car
kilometre, 0.25 Euro for motorcycle and bicycle and 0.15 Euro per passenger. `fix_quotes.py`
reported `FIX-QUOTES: 0 fixed` on both final drafts: the writer wrote exact fragments, so the
new repair path was not needed in these runs; its eight tests cover the repair. The owner
accepted both runs on 2026-10-19: 0 errors, 1 repair round, 82 and 81 verified, the same
amounts, and, on the figures of that day, 27.84M and 28.62M tokens at an average cost of
**1.4320 USD** under the owner's **1.50 USD** deep limit. Counted per request (2026-10-27) the
runs hold 9.87M and 10.62M tokens and cost 0.7989 and 0.8526 USD, average **0.8258 USD** (0.8230
USD without the main-session records). The quality criteria were not changed. The table and the decision are committed, exported and
pushed with the fix.

## Alternatives

- **Leave the skill as it is.** Rejected: the main context carried every intermediate result,
  and the orchestration quality depended on the model following twelve steps in order.
- **A separate orchestration service.** Rejected: another daemon, another credential and
  another failure mode; the Workflow tool is already part of the harness and resumes runs.
- **Run research through `batch-run.ps1`.** Rejected for the same question: a batch starts
  fresh sessions per item, but the research pipeline is one multi-stage run with shared
  intermediate state, not many independent items.

## Pruned reading copy: tried and taken back (search tuning, 2026-10-25)

The idea: Crawl4AI's `PruningContentFilterLXML` (threshold 0.6, docs example) yields a
`fit_markdown` next to the raw markdown; the evidence extractors read the shorter copy and
`verify_evidence.py` still checks every quote against the full page. The change was built behind a
workflow argument `fit` and measured on the Kilometergeld deep run, German, identical `plan.md`
(SHA-256 `d3b81a69...c8f39`), two runs at the same time in `claude-ds`.

| | Run A (fit off) | Run B (fit on) |
|---|---|---|
| Pages saved | 36 | 34 |
| Extractor input tokens | 3,236,521 | 2,584,633 |
| Extractor input per saved page | 89,903 | 76,019 |
| Verified evidence | 76 | 75 |
| `check_article.py` errors (final draft) | 1 | 0 |
| DeepSeek cost by timestamp | 0.5025 USD | 0.4361 USD |

- Run B against run A: extractor input **-20.1 %** in total, **-15.4 %** per saved page. USD is not
  used: run B reads the cache that run A warmed.
- Run A alone, the same pages in both versions: the pruned copies hold **30.9 % fewer** tokens
  (about 437,600 against 633,300; 23 of 36 pages were shortened).
- Saved URLs: 17 of 53 are in both runs (overlap 0.32, 50 % of the smaller run). The searches
  differ from run to run, and run B's Tavily search hit a 429 on its second call.

Decision: **taken back** (code, tests and switch), as the task's rule says. The rule is not
met (verified evidence is 75 in run B against 76 in run A, and the per-page saving is 15.4 %),
and with an overlap of 0.32 the evidence comparison is not reliable in either direction. The
removed parts: the `fit_markdown` request in `crawl4ai_fetch.py`, the `pages/fit/` copies and the
`fit_file`/`fit_chars` index fields in `save_pages.py`, the workflow argument `fit`, and their
tests. The untrusted-marker line (Part 4) stays.

Re-entry only with a test on the same saved pages: take the saved pages of one run, let the
extractors read them once as raw pages and once as pruned copies, and compare tokens and
verified evidence on the same URLs.

Run A's remaining `check_article` error (E67, the key-point bullet says "gesetzlicher", the
recorded fragment reads "gesetzlichen") was a gap in the existing system, not in the reading
copy. `fix_quotes.py` now also repairs that direction: the paragraph keeps its grammatical
wording, the fragment is rewritten to what the paragraph says, and each changed word is declared in
`forms` (used, original). A span qualifies when it has the same number of words, every
differing word is an ending variant (the same first four letters or more, one German ending
of at most two letters, no digit) and the spans are at least 90 % alike by letters. `same_stem`
alone is too wide: it also accepts the pairs permissible/impermissible, a/no, 20/120 and
tax-free/taxable (German originals in `test_fix_quotes.py`), so a reversed statement would pass as checked. On run A's real draft
`check_article.py` goes from 1 error to 0.

## Crawl4AI keeps its own browser folder (Crawl4AI watch, 2026-10-26)

Context: from 2026-10-23 to 2026-10-25 Crawl4AI could not start its browser and every page went
to the paid services unseen. The watch (`crawl4ai-selftest.ps1`, the `crawl4ai_ok` flag in
`pages/index.json`, the warning in `save_pages.py`) makes such an outage visible the same
morning. The likely cause, not proven: Playwright keeps one browser folder for all its
installations (`%USERPROFILE%\AppData\Local\ms-playwright`) and "When there are no more clients
that require a particular version of the browser, that version is deleted from the system"
(https://playwright.dev/docs/browsers), so another Playwright installation on the PC can delete
the browser Crawl4AI needs.

Decision: Crawl4AI gets a folder of its own through `PLAYWRIGHT_BROWSERS_PATH`, set in exactly
the places that start Crawl4AI or install its browser, and never as a global user variable:
`main()` of `crawl4ai_fetch.py` (which `save_pages.py` and the self-test both run), and the
install stage, which runs `crawl4ai-setup` through `Invoke-Crawl4AiBrowserSetup` with the variable
set for that call only. The self-test sets nothing itself: it runs `crawl4ai_fetch.py`, so it
proves the setting the research runs really use. The folder on Windows is
`%LOCALAPPDATA%\crawl4ai-browsers`, chosen by the owner because no program manages it and it is
outside the backup; on macOS and Linux it sits where Playwright's own default sits
(`~/Library/Caches`, `~/.cache`), a derived default. `browsers_path()` in `crawl4ai_fetch.py` and
`Get-PlatformCrawl4AiBrowsersDir` in `setup/lib/platform.ps1` give the same answer, which
`tests/Platforms.Tests.ps1` compares; `CRAWL4AI_BROWSERS_PATH` replaces both.

Consequence: a bare `crawl4ai-setup` fills the shared folder and does not help. Every remedy text
(skills, `verify.ps1`, the install notes, the morning report line) therefore names one command,
`~/.claude/life-os/crawl4ai-repair.ps1`: it sets the variable for the setup call, runs the
self-test and exits 0 only when the self-test passes. The morning run calls it once by itself
when the self-test fails (10 minute limit) and reports the result; the agent does not start for
it.
Measured on 2026-10-26: with the new folder still empty the self-test failed with
`Executable doesn't exist at ...\crawl4ai-browsers\...`, although `ms-playwright` held the
browser; after the install into the new folder it printed `crawl4ai=ok`, and it still did with
`ms-playwright` renamed for the test.

## Cost shares, cache misses and the limits (measured 2026-10-27)

Counted per request with `count_usage.py`. The seven research runs are the seven lean-workflow
runs from 2026-10-19 and 2026-10-25 (standard, four deep runs of 10-19 and the two pruned-copy runs of 10-25);
every request in them is `deepseek-flash`, none is an Anthropic or any other model.

| Run | Agents | Requests | Tokens | USD at peak | web-researcher share | Cache hit | Cold-start misses (tokens) | Cold-start cost, own time / at peak |
|---|---|---|---|---|---|---|---|---|
| standard (10-19) | 10 | 61 | 3,626,032 | 0.4765 | 20.1 % | 85.0 % | 244,414 | 0.0367 / 0.0733 |
| deep (10-19) | 15 | 114 | 7,634,512 | 0.6936 | 21.7 % | 90.5 % | 97,549 | 0.0163 / 0.0293 |
| deep run 1 (10-19) | 17 | 139 | 9,684,545 | 0.7976 | 23.0 % | 92.6 % | 63,811 | 0.0096 / 0.0191 |
| deep run 2 (10-19) | 17 | 146 | 10,033,095 | 0.8484 | 22.3 % | 91.6 % | 73,984 | 0.0111 / 0.0222 |
| deep (10-19, later) | 19 | 154 | 9,526,653 | 0.8978 | 21.6 % | 91.2 % | 106,829 | 0.0160 / 0.0320 |
| deep A (10-25) | 19 | 171 | 10,615,230 | 1.0050 | 20.1 % | 90.0 % | 265,762 | 0.0399 / 0.0797 |
| deep B (10-25) | 17 | 145 | 9,339,067 | 0.8721 | 23.2 % | 90.5 % | 186,871 | 0.0280 / 0.0561 |
| **7 runs** | 114 | 930 | 60,459,134 | 5.5911 | 21.8 % | 90.7 % | 1,039,220 | 0.1576 / 0.3118 |

- **No search wrapper.** The web-researcher agents are about 22 % of the agent cost (21.8 %; each
  run between 20.1 and 23.2 %). The rule is to build a search script only at 30 % or more.
- **Where the cache misses come from** (5,318,425 miss tokens in the seven runs): new content
  79.9 % (815 requests), cold start 19.5 % (114 requests, one per agent), prefix break 0.5 %
  (1 request). New content is not fixable: it is text that did not exist before. A prefix break
  needs a changed prefix, and the only one in the runs is a compaction.
- **DeepSeek cache hits by kind of session.** The first measurement reported 99.3 % cache hits for
  "58 interactive sessions". The 58 are all session files (main transcripts) with `deepseek-*`
  requests from 2026-10-20 to 2026-10-26; recounted per request they give 99.3 % again, but only
  eight of the 58 are interactive. Grouped by working folder, entry point and first message:

  | Kind of session | Sessions | Requests | Cache hit | Dates |
  |---|---|---|---|---|
  | Morning run (headless `claude -p`, vault folder, `life-os-morning` skill) | 8 | 53 | 87.8 % | 10-20 to 10-25 |
  | Test and measurement runs (headless: 35, in the CLI: 4, for example a one-word reply, the orientation test, a research-workflow measurement) | 39 | 202 | 86.3 % | 10-20 to 10-25 |
  | Task sessions (CLI, started with a `/goal` task file) | 3 | 570 | 99.5 % | 10-19 to 10-22 |
  | **Interactive** (CLI, free input or pasted text) | 8 | 2,193 | **99.6 %** | 10-20 to 10-25 |
  | All of them | 58 | 3,018 | 99.3 % | |

  Only the interactive row is an interactive result. Of its miss tokens 77.6 % are new content,
  12.2 % cold start and 10.2 % prefix break (14 requests of 2,193, 0.6 %; a break has no time
  criterion, so a cache that expired in a pause counts too; in the largest breaks only the 24k
  to 27k system prefix was still cached, which fits a compaction, not checked one by one).
  The 8 interactive sessions are from 2026-10-20 to 2026-10-25, one of them (15 requests) from
  2026-10-25; their transcripts show `deepseek-flash` as the model of every request, and they
  do not record why a session ran on DeepSeek. Two requests of the test runs carry the unknown
  model name `deepseek/deepseek-v4.1-flash` and are unpriced. Seven further CLI sessions in the
  window hold only Claude models (1,763 `claude-sonnet-5-5` requests); they are counted as tokens
  only and belong to no DeepSeek figure.
- **Deep cost limit: 1.20 USD** at peak `deepseek-flash` price, replacing 1.50 USD, which was set
  on the inflated figures, and an interim 1.00 USD. The corrected deep runs cost 0.69 to 0.90 USD
  at peak; deep run A of 2026-10-25, the dearest, cost 1.0050 USD (1.0055 with its main
  session), so 1.20 USD is about 20 % above it. A run above the limit is reported to the owner,
  as before.
- **No staggered start of the agents.** The cold-start misses cost 2.3 cents a run at the prices
  of their own time (4.5 cents at peak; the dearest run 4.0 and 8.0 cents), less than the code
  for a staggered start is worth. Revisit only if one run's cold start passes 10 cents at peak.
