---
type: note
status: active
date: 2026-09-23
verified: 2026-09-23
review_by: 2026-12-23
topic: agent tooling
supersedes: DonSeTch decision of 2026-09-07
---

# Web research tooling — decision record

> This file is a **decision**, not a rule. The rules live in `AGENTS.md` and the global
> `~/.claude/CLAUDE.md`. Everything here has an expiry date. If `review_by` has passed and
> nobody has checked, treat this decision as **unverified**, not as confirmed.
>
> This tool attaches to the agent, not to the vault. Nothing in `{{VAULT}}` depends
> on it. Replacing it means changing one line per agent harness.

## Decision

| Layer | Tool | Cost |
|---|---|---|
| 1a. Search (primary, every harness) + page fallback **inside `save_pages.py`** | **Exa**, hosted MCP server `https://mcp.exa.ai/mcp` | Free. Without an account: 150 calls a day. With a free account (no payment method): $10 a month, see "Free limits" |
| 1b. Second index in the **main conversation** (since 2026-09-28) | **Parallel**, hosted MCP server `https://search.parallel.ai/mcp` | Free, no account. Adds about 5,300 characters (~1,300–1,500 tokens) to every request on a profile without tool search — see "What the two servers cost" |
| 2. Built-in search — **last resort, always behind layer 1**. The built-in page fetch is **denied** | Claude Code `WebSearch`, OpenCode `websearch`, Codex web search | Included |
| 3. Page reading — **one entry point only**: `fetch_page.py` (Crawl4AI first, saved as a file) | `~/.claude/skills/research/scripts/fetch_page.py`; the guard `hooks/fetch-guard.ps1` denies WebFetch and every MCP page reader | Local Crawl4AI is free; the services inside `save_pages.py` draw on the same allowances |

**Replaces:** DonSeTch (decision of 2026-09-07).
**Not part of research:** browser automation (Chrome DevTools MCP, Playwright MCP). Those
stay per project, for testing the user's own extensions and website.

## Requirements this decision had to meet

| # | Requirement | Exa | DonSeTch (old) |
|---|---|---|---|
| R1 | Proven: widely used, confirmed by others, not a brand-new project | Official MCP repo about 5k stars, active daily. Listed in Anthropic's official plugin marketplace and ChatGPT/Codex plugins. OpenCode's own `websearch` tool is built on it | About 730 stars, first release 2026-08-07, one maintainer |
| R2 | Free, or a free tier personal use does not exhaust | Search $4 per 1,000 requests (Instant) or $7 (Fast, Auto), page contents $1 per 1,000 pages. The $10 monthly credit covers roughly 1,400 searches a month at the $7 price | Free, no account |
| R3 | Works in every agent harness | Standard remote MCP (one URL): Claude Code, OpenCode, Codex, Gemini CLI, Cursor and others | MCP, but a local binary per machine |
| R4 | Windows 11, no Linux subsystem, nothing to install | Hosted: no binary, no Node, no Python, no Docker | npm package plus downloaded model weights |
| R5 | Good results, independently measured | Top tier in independent benchmarks (see verification log) | Only the author's own benchmark |
| R6 | No commercial pressure toward paid add-ons | Normal freemium pricing, published openly | Affiliate callout for Bright Data at the top of the README |

## Combined free stack (added 2026-09-23, v10.4)

All services below are used together by the `research` skill (Claude Code: four `web-researcher`
search passes, rules in `docs/research-standard.md`, since 2026-10-06) or by the `web-research`
skill (OpenCode, Codex, DeepSeek Harness). The main conversation
keeps **Exa and Parallel** — two different indexes, which is what makes a quick lookup
checkable — and the other services are loaded only for research. The price of the second
index is measured below.

| Service | Without account | With free account (no card) | Best for |
|---|---|---|---|
| Exa | 150 calls/day (search + fetch) | $10/month, resets on the 1st; +$10 once | first search and page reading |
| You.com | 100 searches/day (`you-search` only) | **$100 for new accounts**; search $5/1k, contents $1/1k pages | second search index, batch page reading |
| Tavily | — | 1,000 credits/month (basic search 1, extract 1 per 5 URLs) | extra search capacity, cheap extraction |
| Firecrawl | search, scrape, parse (rate-limited) | 1,000 credits/month (search 2, refund 1 via feedback; page 1); crawl, map, interact | JavaScript pages, whole sites |
| Jina Reader | 20 pages/minute | not needed | free fallback reader |
| crawl4ai | local, unlimited | — | **first** page reader since 2026-10-17: installed by the setup (`uv tool install crawl4ai` + `crawl4ai-setup`), no quota and no provider sees the URL |

## Budget for 90 runs a month (2026-10-17)

The research skill runs at most 90 times a month in the intended use (about three a day). The
per-run caps below make that fit every free tier, including the page fetches that fall back to
a service when the local crawler cannot read a page:

| Service | Calls per run | 90 runs = | Free allowance | Headroom |
|---|---|---|---|---|
| exa + exa-key (one `EXA_API_KEY`) | 10 | 900 searches | $10 a month at $7/1k = about 1,400 searches, plus $1/1k pages | about 1.4x with the page fallback (see below) |
| parallel | 8 | 720 | 5,000 requests a month | 6.9x |
| you-free | 3 | 270 | 100 searches a day | 11x |
| you | 3 | 270 searches | $100 one-time at $5/1k = 20,000 searches | 74x |
| tavily | 5 | 450 searches + 90 extract credits | 1,000 credits a month | 1.85x |
| firecrawl | 2 | 180 net credits | 1,000 credits a month (search 2, feedback refunds 1) | 5.5x |
| TinyFish | 4 | 360 | 500 searches an hour, 1,000 a day | 83x (daily) |
| Serper (reserve, Austria only) | up to 3 | 270 worst case | 2,500 queries once (renewal not stated) | 9 months at three per run, 27 at the default one |

Page fallback (`PAGE_CAP` in `save_pages.py`): at most 10 pages per run for exa, you, TinyFish
and Jina, 5 for tavily and firecrawl; crawl4ai is local and unlimited. Worst case per month:
exa/exa-key 900 searches ($6.30) + 900 pages ($0.90) = $7.20 of the $10 account; tavily 450
searches + 90 extract credits (1 credit per 5 URLs) = 540 of 1,000; firecrawl 180 net search
credits + 450 scrape pages = 630 of 1,000; you 270 searches ($1.35) + 900 pages ($0.90) = $2.25
of the $100 (450 search-equivalents at $5/1k); TinyFish 360 searches + 900 pages = 1,260 of
30,000. Every row stays inside its allowance.
The anonymous 150-calls-a-day Exa limit applies only when `EXA_API_KEY` is empty; with the key
both Exa servers draw on the same $10 account.

**Serper is the reserve for Austria.** Its calls per run, at most three, are spent only on a
question about Austria with `gl=at` and `hl=de`; one in P1 is the default. A general question
never gets it. **No key means no call:** a keyed service whose variable is empty is skipped and
reported as `skipped: no key`, never called with an empty header; Serper is reported as
`reserve`, not as missing. `parallel` and `you-free` need no key, and `exa` runs anonymously
when its key is absent. The same rules stand in `skills/research/SKILL.md` and
`agents/web-researcher.md`.

**Measured 2026-10-18** from the transcripts of 18 earlier research runs: per run on average
Exa 9.0 + exa-key 3.3 searches, parallel 6.1, tavily 4.3, firecrawl 3.1, you-free 3.3, you 2.4,
TinyFish 2.3, Serper 5.7 (before the reserve rule). The Exa average (12.3 searches) was above
the 10 cap; the run budget moves that work to parallel (8) and TinyFish (4), and the total
search budget per run stays above the measured 33 calls. Serper drops from 5.7 to at most 3.

**Accounts worth creating** (all free, no card): You.com (the $100 is the biggest
allowance), Tavily, Firecrawl, Exa. Keys go through
`setup/powershell/set-research-keys.ps1`: on Windows into user environment variables
(`YDC_API_KEY`, `TAVILY_API_KEY`, `FIRECRAWL_API_KEY`, `EXA_API_KEY`), on macOS/Linux into
`~/.config/personal-os/research-keys.env` (mode 600) sourced from the shell profiles. Never
into the repository or the chat. The agent can read
environment variables through the shell; these are free-tier keys, so the risk is limited.

**Not added:** Brave (card required since February 2026); mem0 (a second memory outside the
vault breaks "one source of truth"); aggregator servers such as mcp-omnisearch (about 350 stars,
not proven).

**Closed 2026-09-28 — the `${VAR}` expansion does apply in agent files.** Claude Code documents
it for `.mcp.json` and says inline agent servers use the same schema, but never stated it for
agent files. Measured instead of assumed: all nine services answered inside the research agent,
including the three that authenticate through a `${VAR}` header (You.com, Tavily, Firecrawl).
The expansion works, and no key has to sit in the file.

## Result quality and Google (added 2026-09-23, v10.5)

Independent benchmark by OpenBenchmarks, September 2026, same agent and questions for every
provider:

| Test | Result |
|---|---|
| Search + read pages, 100 coding-documentation tasks | Exa deep 83.0 %, Exa auto 81.7 %, TinyFish 79.0 %, Perplexity 77.7 %, Parallel 76-77 %, Firecrawl 76.0 %, Tavily 59-60 %, You.com 54-55 % |
| Simple fact lookups, 300 questions | Google (SERP via RapidAPI) 96.0 %, in the same band as the best AI search services |
| Multi-step company search (combine several conditions) | Google SERP F1 0.4 (almost nothing), because it returns links and snippets, not page content |

**Meaning:** Google's ranking is excellent for plain facts and, by reasoning rather than a
measured test, for local and German-language topics. For agent research, what counts is
readable page content, which the AI search services deliver directly.

**Google access in 2026:** Google's own Custom Search JSON API is closed to new customers and
ends on 2027-01-01. **Serper** returns real Google results: 2,500 free queries, no card (both on serper.dev, read 2026-09-29; whether the 2,500 renew is not stated).
The reserve for questions about Austria only (`gl=at`, `hl=de`), at most three queries per run;
the 2,500 are a one-time allowance, so they do not renew.

**Added to the stack:** Parallel (hosted MCP, no account, free rate limits; a free account adds
$5 a month) and TinyFish (search and fetch free with a free key: 30 searches and 150 fetched URLs
per minute; plus 500 searches per hour and 1,000 URLs per day on the vendor's pricing page, 2026-09-29), both in the top group of the benchmark.

## What the two servers cost (measured 2026-09-28)

On the Anthropic API, Claude Code defers MCP tool definitions and loads them on demand ("tool
search"). That is what keeps a long server list cheap. It switches itself off when
`ANTHROPIC_BASE_URL` points at a non-first-party host, and DeepSeek and OpenRouter both do — so
on `claude-ds` and `claude-or` **every MCP tool loads into every request**, needed or not.
Forcing it back on with `ENABLE_TOOL_SEARCH=true` is not a way out: Claude Code then sends the
`tool_reference` beta header through the proxy, and requests fail at any proxy that does not
support it, which DeepSeek does not document.

So the only lever is how many servers sit in the main conversation. Measured against the live
servers (`tools/list`, counting `name` + `description` + `inputSchema` of every tool):

| In the main conversation | Tools | Tool definitions (characters) | Whole first request (tokens) |
|---|---|---|---|
| Exa only | 2 | 2,083 | 29,788 |
| Exa + Parallel | 4 | 7,361 | 31,345 |
| **Parallel alone** | 2 | 5,278 | **1,557** |

Parallel is the expensive one: its `web_fetch` description alone is 3,167 characters. Two
top-tier indexes are worth 1,557 tokens for a short lookup; a third would not be — which is why
the five keyed services stay inside `agents/web-researcher.md` and never enter the main
conversation.

The character column counts `name` + `description` + `inputSchema` per tool from `tools/list` of
the live servers — exact. The token column is **measured, not estimated**: two identical headless
sessions (`claude --settings profiles/deepseek.json -p "<same question>" --output-format json`),
one with `parallel` in the user config and one without, reading `input_tokens` of the first
request — 29,788 and 31,345, both with an empty cache. That figure covers everything loaded
upfront (system prompt, all tool definitions, CLAUDE.md, skills), so the difference between the
two runs is the marginal cost of the second index. `/context` in an interactive session shows
the same thing.

The same run is also the proof that the order rule holds: in the session without `parallel` the
first tool call was `mcp__exa__web_search_exa`, and neither session touched the built-in
`WebSearch`/`WebFetch`.

### Re-measured 2026-10-23 (Claude Code 2.1.309): the 2026-09-28 statement no longer holds

The section above is kept as history. On 2026-10-23 `claude-ds` **does** defer MCP tool
definitions, with no setting asking for it:

- `ENABLE_TOOL_SEARCH` is set nowhere: not in `profiles/deepseek.json` (`env`), not in
  `settings.json` (`env`), not in the user or machine environment, not in the launcher
  functions or hooks (checked 2026-10-23).
- The `/context` of a fresh `claude-ds` session lists the MCP tools as "(deferred)", and the
  headless session's tool list carries `ToolSearch`.
- Same method as 2026-09-28, but the server set is chosen with `--strict-mcp-config
  --mcp-config <file>` so the user config stays untouched: two identical headless runs
  (`claude --settings profiles/deepseek.json --strict-mcp-config --mcp-config <file> -p "Reply
  with the single word OK. Do not use any tool." --output-format stream-json --verbose`), each
  twice, reading the usage of the first request (no cache hits in any of the four runs).

| In the run | Tools in the session | Whole first request (tokens) |
|---|---|---|
| no MCP server | 27 | 22,920 (both runs) |
| `parallel` only | 31 (`mcp__parallel__web_search` plus the three MCP resource tools) | 23,300 (both runs) |

The marginal cost of the second index is **380 tokens**, not the 1,557 of 2026-09-28: the
definition of `web_search` is no longer sent up front, only its name, and Claude Code loads the
definition when it is needed. What this changes: the rule "keep few servers in the main
conversation" is much less pressing on `claude-ds` than the section above says, and a third
server would cost a few hundred tokens, not a thousand and more. The proxy caveat about
`ENABLE_TOOL_SEARCH=true` above is not needed. `claude-or` was not measured; do not assume the
same. No setting was changed because of this result.

## A named teammate silently drops the agent file's MCP servers (found 2026-09-28)

`agents/web-researcher.md` carries `mcpServers` and `disallowedTools`. Both take effect only
when the agent is spawned as a **plain subagent**. Spawn the same file with a `name` and it
becomes an in-process teammate, and the fields applied to a teammate are documented as `tools`,
`model`, body, `skills` and `mcpServers` — with `mcpServers` counting for split-pane teammates
only. **An in-process teammate ignores it.** `disallowedTools` is not on that list either.

Measured, not read: the same agent file, spawned both ways, in one session.

| Spawned as | Tools in the list | `mcp__` tools | `Edit`/`Write`/`NotebookEdit` |
|---|---|---|---|
| plain subagent | 65 | 47 (all seven services) | **absent** |
| named teammate | 26 | 2 (context7 only) | **present** |

Both failures are silent. The teammate answers with five services missing instead of seven —
it fell back to the shell tools — and it holds write tools the file forbids. Neither shows up
as an error anywhere.

**Rule: spawn this agent without a name.** The agent's own description says so, and its body
tells it to report the situation instead of working around it with the harness's built-in
search.

## Setup per harness

**Claude Code** (user scope, all projects):
```powershell
claude mcp add --scope user --transport http exa https://mcp.exa.ai/mcp
claude mcp add --scope user --transport http parallel https://search.parallel.ai/mcp
```
Permission in `~/.claude/settings.json` → `permissions.allow`: `"mcp__exa__*"`.
Optional, for the higher free limits: in a session run `/mcp`, select `exa`, sign in.

`agents/web-researcher.md` references both by name, so the agent shares the session's
connection instead of opening a second one. The five keyed services (Exa with key, You.com
free and paid, Tavily, Firecrawl) stay inline in that agent file, so their tools never enter
the main conversation.

**OpenCode:** the built-in `websearch` already uses Exa's hosted service. Turn it on with the
user environment variable `OPENCODE_ENABLE_EXA=1`. For the fetch tool as well, add to
`~/.config/opencode/opencode.json`:
```json
{ "mcp": { "exa": { "type": "remote", "url": "https://mcp.exa.ai/mcp", "enabled": true } } }
```

**Codex:**
```powershell
codex mcp add exa --url https://mcp.exa.ai/mcp
```

**DeepSeek Harness (dsh):** supports MCP clients. Add `https://mcp.exa.ai/mcp` as a remote
server in its MCP settings.

## Free limits (official Exa docs, read 2026-09-23)

Search and page reading come from the **same** server and the **same** allowance. Both tools
(`web_search_exa`, `web_fetch_exa`) are on by default; nothing extra to add.

| Mode | Limit | What one call costs |
|---|---|---|
| **No account** (default) | **150 calls per day**, 3 per second (Exa changelog, 2026-02-02) | nothing |
| **Free account**, no payment method | **$10** on sign-up, balance **resets to $10 on the 1st of every month** (unused credit does not carry over). One-time **$10 bonus** after finishing onboarding in the dashboard | search $0.007 (up to 10 results, page highlights included); page fetch $0.001 per page (text only) |

With the account, $10 is at most about 1,400 searches, or 10,000 page fetches, or a mix
(for example 1,000 searches + 3,000 pages). Without a payment method nothing can be charged;
at $0 the calls simply fail until the 1st of the month.

**Start without an account.** 150 calls a day is more than the account's roughly 47 searches a
day. Sign in (`/mcp` → exa, or an API key) only if Exa reports that the daily limit is reached.
Signed-in calls use the account balance instead of the anonymous allowance.

## How the agent should use it

1. Search with `web_search_exa` (keep the default of 10 results; more results cost extra on an
   account).
2. Read a page only through `fetch_page.py` (Crawl4AI first, the page saved as a file; the
   content services are its fallback). Then Grep the saved file and read only the lines you
   need. WebFetch and every MCP page reader (`web_fetch_exa`, Parallel `web_fetch`,
   `firecrawl_scrape`/`_crawl`/`_extract`, `tavily_extract`/`_crawl`, `you-contents`, Jina) are
   denied by `hooks/fetch-guard.ps1`, and the same names stand in `permissions.deny`.
3. Captcha walls (hCaptcha, reCAPTCHA, Turnstile checkbox) are a dead end. Report it; never
   guess the page's content.
4. **The harness's own web search comes last — always, behind every service with a key.** It
   scores worse than the measured services (see the benchmark table) and exists only inside one
   harness, so a rule that depends on it does not survive a change of tool. Reach for it when
   every allowance is spent or a service is down. It is **not** the cross-check either: for a
   cross-check, search with two of the services above — different indexes agreeing is the
   evidence, and both sides of that comparison have to be services you would trust on their own.

## Known limits — accept these

- Search queries and fetched URLs are sent to Exa (US company). The free plan has no
  zero-data-retention promise (that is an Enterprise feature). Do not put personal data from
  `{{VAULT}}` into search queries.
- Anonymous use has rate limits that Exa does not publish. Signing in removes most of that.
- Exa reads pages with its own crawler. Heavy JavaScript apps or logins can fail; that is what
  layers 2 and 3 are for.

## Risks, and what would change the decision

| Risk | Status on 2026-09-23 |
|---|---|
| Free tier gets cut | It happened to Brave in February 2026: the card-free 2,000 queries per month were replaced by $5 credits with a card on file. If Exa does the same, switch to **Firecrawl** (1,000 credits a month, no card; a search costs 2 credits, a page 1) or **Tavily** (1,000 credits a month, no card; a basic search costs 1 credit) |
| Company change | Tavily was acquired by Nebius in February 2026; ownership changes often bring pricing changes. Re-check the free tier at every review |
| Hosted service outage | Layers 2 and 3 keep research working |

**Revisit if:** the free credits end or need a card; the MCP URL changes; independent
benchmarks drop Exa out of the top tier; or a harness ships a better built-in search.

## Rejected alternatives

| Candidate | Why not |
|---|---|
| DonSeTch (kept until today) | Fails R1 and R6: about 730 stars after seven weeks, one maintainer, affiliate funnel at the top of the README. Its anti-bot engine was strong, but only the author measured it |
| Firecrawl (about 184k stars) | Excellent scraper, top tier in benchmarks. The free tier buys about 500 searches a month instead of about 1,400. First choice if Exa's free tier disappears |
| Tavily | 1,000 credits a month free, but below the top tier in the AIMultiple benchmark |
| Brave Search API | No longer free: card required since February 2026, $5 monthly credits, attribution required |
| SearXNG (about 38k stars) | Self-hosting needs Docker and therefore a Linux subsystem on Windows |
| Crawl4AI (about 84k), Scrapling (about 83k) | Very good local scrapers, but Python plus browser downloads on the PC, and no search engine of their own. More moving parts than the need justifies |
| DuckDuckGo MCP (about 1.5k) | Scrapes DuckDuckGo from the home IP; rate limits under agent load |

## Migration cost if this is dropped

Five minutes: `claude mcp remove exa -s user`, remove the `mcp__exa__*` line, add the
replacement. Nothing else depends on it.

---

## Verification log

**2026-09-23 — every number re-checked, two independent sources where possible.**

| Claim | Verified | Source |
|---|---|---|
| Exa hosted MCP works anonymously with rate limits; OAuth or API key for higher limits | Confirmed | exa-labs/exa-mcp-server README |
| Exa free plan: $10 on sign-up, balance resets to $10 on the 1st of every month, one-time $10 onboarding bonus, no payment method | Confirmed | exa.ai/docs/reference/pricing, read directly |
| Anonymous MCP: 150 free calls per day, 3 QPS | Confirmed | Exa changelog 2026-02-02 (exa.ai/docs/changelog/february-2026-api-updates) |
| MCP defaults: search 10 results with highlights; fetch = `/contents` with `text`, 3,000 characters | Confirmed | exa-mcp-server 3.4.1 source code (npm package) |
| `/contents` bills per page **per content type** (text + highlights = 2) | Confirmed | exa.ai/docs/reference/pricing |
| Exa search $7 per 1,000 requests, contents $1 per 1,000 pages | Changed on 2026-09-29: $4 per 1,000 in the Instant mode, $7 in Fast and Auto; contents unchanged | exa.ai/pricing |
| Exa MCP about 5k stars, last commit today; Firecrawl about 184k; Crawl4AI about 84k; Scrapling about 83k; SearXNG about 38k; Tavily MCP about 2.4k; DonSeTch 732 | Read on 2026-09-23 | img.shields.io (a second host besides GitHub, see method note) |
| Exa is in Anthropic's official plugin marketplace | Confirmed | anthropics/claude-plugins-official, marketplace.json |
| OpenCode `websearch` uses Exa's hosted service, no key needed, enabled by `OPENCODE_ENABLE_EXA` | Confirmed | opencode.ai/docs/tools |
| Independent benchmarks: AIMultiple (100 queries) top tier Brave 14.89, Firecrawl 14.58, Exa 14.39, Parallel Pro 14.21, Tavily below; OpenBenchmarks (Sept. 2026, 100 documentation tasks, search and fetch) Exa deep highest at 83.0 % | Reported by the benchmark publishers, not reproduced here | aimultiple.com/agentic-search; openbenchmarks.com/web-search |
| Firecrawl free: 1,000 credits a month, no card; 5,000 credits = 2,500 searches or 5,000 pages | Confirmed | firecrawl.dev/pricing, read directly |
| Tavily free: 1,000 credits a month, no card; basic search 1 credit | Confirmed | docs.tavily.com, tavily.com/pricing |
| Brave: card-free free tier ended February 2026 | Confirmed by several reports | implicator.ai; Brave's own pricing page now shows only monthly credits |
| Jina Reader free, API key optional for higher rate limit | Confirmed | jina.ai/reader |

**2026-09-29 - free limits of seven services re-read on the vendors' own pages** (Exa, Parallel,
TinyFish, Serper, You.com, Tavily, Firecrawl; live fetch, because a caching fetch layer returned
stale copies of three pricing pages).

| Claim | Result | Source |
|---|---|---|
| Exa: free account $10 monthly, resets on the 1st, +$10 once, no card; contents $1 per 1,000 pages per content type | Confirmed | exa.ai/pricing, exa.ai/docs/admin/pricing.md |
| Exa search price | **Changed:** $4 per 1,000 (Instant), $7 (Fast, Auto) | exa.ai/pricing |
| Exa MCP without account: 150 calls/day, 3 QPS | Confirmed, but only in the changelog of February 2026; the MCP pages give no number | exa.ai/docs/changelog.md |
| Parallel: MCP without account; up to 5,000 requests a month free; $5 monthly credit needs a card | Confirmed | parallel.ai/pricing, docs.parallel.ai/integrations/mcp/search-mcp, parallel.ai/blog/free-tier-parallel |
| Parallel: "up to $80 at signup" | On the pricing page, **conditions not stated** | parallel.ai/pricing |
| TinyFish: 30 searches and 150 URLs per minute, no card | Confirmed; **plus** 500 searches per hour and 1,000 URLs per day on the pricing page | tinyfish.ai/pricing, docs.tinyfish.ai |
| Serper: 2,500 free queries, no card | **Now confirmed** on the vendor's site; "once or renewing" not stated | serper.dev |
| You.com: keyless MCP 100 searches a day; $100 credit for new accounts, no card; $5 and $1 per 1,000 | Confirmed; the word "one-time" is not on the page | you.com/docs/agents/mcp-server, you.com/pricing |
| Tavily: 1,000 credits a month, no card, basic 1 and advanced 2 | Confirmed; a keyless mode exists; Nebius owns Tavily | docs.tavily.com, tavily.com/pricing, nebius.com/blog |
| Firecrawl: 1,000 credits a month, page 1, search 2 per 10 results, free rate limits 10 and 2 per minute | Confirmed | firecrawl.dev/pricing, docs.firecrawl.dev/rate-limits |
| Firecrawl: refund cap 100 credits a day | **Not in the documentation**, only a default in the source code | github.com/firecrawl/firecrawl (apps/api config) |

**Method note, still valid.** A star count read through a caching fetch layer is not
evidence. Read it twice, from two hosts, or not at all.
