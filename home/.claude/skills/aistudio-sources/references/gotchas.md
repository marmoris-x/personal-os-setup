# Gotchas for aistudio-sources

Read this file when a step behaves unexpectedly, before changing a script, or when a run has
more than about 150 claims. The main SKILL.md keeps the procedure.

- The subagent count grows with the answer: one per six sources. Over eight batches, run them in
  waves; the second pass costs about as much as the first, so tell the owner before it when the
  answer has more than about 300 claims.
- Google AI Studio reuses citation numbers for one page (measured 2026-11-08: 56 numbers for 44
  pages). `resolve_sources.py` merges them to the first number, collapses the resulting adjacent
  identical markers and leaves gaps in `## Sources`; that is intended, the note under the heading
  says so. `apply` and `finalize` list only the sources the corrected text still cites.
- The input file stays the working file. `resolve_sources.py` copies it once to
  `<workdir>\original.md` before the first write; `prepare` uses the same default workdir. If a
  run passes `--workdir` to one step, pass it to all steps.
- The content services rate-limit a large first fetch (24 of 44 Reddit URLs failed, all readable
  on retry). `check_sources.py fetch` retries one by one; if pages stay missing, run `fetch`
  again before starting the agents. Never let an agent guess a missing page.
- A saved page is paired only by its header URL, query included. A page without a matching header
  is reported as `UNMATCHED`; its source stays `failed`. There is no positional fallback any more
  (removed 2026-11-09). Never re-add one.
- A page whose header lost its query can fill a source only when exactly one source has that base
  URL. `watch?v=A` and `watch?v=B` are never one page. `page_identity` keeps the query.
- A Reddit post is often only a teaser that links to the full article. The claim may be true in
  the linked article and still "nicht_belegt" in the saved page; the note should say that. The
  skill checks the cited page, not pages it links to.
- The content services return only the post for many Reddit URLs. The fetch step adds the whole
  comment tree from Arctic Shift (`/api/comments/tree?link_id=t3_<id>&limit=9999`), flattens it
  and writes a combined page; the flat `search` endpoint with `limit=auto` is the fallback. The
  archive is read once per post and cached under `reddit-comments/`. If the archive has no
  comments, the saved post stays the page.
- A quote is proof only when it is found word for word and has at least five words, unless it
  contains a digit (versions, dates, prices, counts). `validate`, `check` and `filter` mark a
  shorter quote `Beleg zu kurz`; the claim goes to the recheck. The prompt still asks for 8-40
  words; never lower the code guard to make an agent pass.
- Quotes with typographic quotes, dashes or Markdown emphasis are accepted (the validator
  unifies them and removes `*`, backticks and backslashes). If a quote still fails, the agent
  paraphrased: re-check that claim, do not edit the quote by hand.
- `fix-quotes` repairs a retyped quote in code before the recheck (0.90 token similarity) and
  keeps the verdict. A repair that adds or removes a negation, or changes a word's meaning rather
  than its ending, is rejected. Only the rest goes to the recheck.
- A block quote (`>`) is verified as one claim. Splitting it into sentences once produced the
  fragment "Clean architecture." with no context; do not reintroduce sentence splitting there.
- Re-running `resolve_sources.py` removes an older `## Quellenprüfung` (it is stale) and rebuilds
  `## Sources`; run the whole chain again, never keep the old verdicts.
- A replacement search among the saved pages looks easy and is not: measured 2026-11-08, the
  first agents proposed 10 replacements, the independent audit accepted 4. Run 8.4 every time;
  never apply a replacement on the search agent's own note.
- A web candidate can be one of the old source pages. `web-verify-plan` drops those and
  `check --web` rejects them; do not count such a group as solved.
- Absence of evidence is not proof of falsehood. `nicht_belegt` means no page carries the
  statement; `unzutreffend` is reserved for a page that says the opposite. Do not collapse the
  two - the owner reads the report as a statement about the answer.
- AI Studio usually attaches the marker directly to the sentence's full stop, but sometimes a
  space sits before it. `claims.statement_for` keeps the whole sentence in both cases; the old
  `SENT_SPLIT` merged two sentences when a marker followed the full stop (fixed 2026-11-09).
- A statement can be supported by one marker and contradicted by another. That group is not
  "clean": `plan` marks it contested, `apply` keeps the supported marker and adds `[umstritten]`.
- Older AI Studio files use `[N](url)` instead of `[[N](url)]`. The correction matches both and
  writes the replacement in the style the file already uses; do not convert the style by hand.
- Two pages are the same only when scheme, host, path **and query** match. `check_sources.url_base`
  drops the query; `page_identity` and `correct_sources.url_key` keep it. With the loose key,
  `watch?v=OLD` and `watch?v=AAA` were treated as one video and the verified replacement was
  discarded (found in review, 2026-11-08).
- A citation with no verdict (`offen`, for example a repeated sentence that the check
  deduplicated) is not a wrong citation: `apply` leaves its marker untouched and counts it under
  `unchecked`. Never turn missing evidence into `nicht belegt`.
- `check` merges its accepted rows into `valid-existing.jsonl` / `valid-web.jsonl`; a second round
  must not truncate the first. `filter` uses the last proposal per group, so a web replacement
  wins over an older, rejected proposal for the same group.
- Duplicate-marker cleanup may consume spaces and tabs, never a newline: two identical markers on
  consecutive lines belong to two statements and must stay.
- The owner rejected the meta sections (`## Sources` note, `## Quellenprüfung`, `Geänderte
  Stellen`, `Alle Prüfungen`) and inline marks in the answer (2026-11-08). The deliverable is the
  clean `- fertig.md` plus one prose `- Prüfbericht.md`; `apply` alone is not the end of the run.
  The working `- korrigiert.md` serves only the audit and the report.
- `finalize` renumbers the sources by first appearance in the clean answer, so the numbers in the
  report can differ from the working copy's. The report maps every old number to the final one;
  never copy an old number into it by hand.
- Report statements are recovered from the answer line, not from the truncated audit table
  (`full_statement`); shorten only at a word boundary. Table cells are shown as `Label: value`, a
  Subreddit attribution after a block quote is removed, and an excerpt that starts mid-sentence
  gets a leading `…`.
- The report counts must match its own lists: replaced bullets = replacements, removed markers =
  `nicht_belegt` statements, partial bullets = partial statements. Check these three counts before
  reporting to the owner.
- A pack shows a cited statement only passages from its cited pages; an uncited statement gets
  all saved pages. Passing every passage to a cited statement made a pack agent confirm a fact
  from an uncited page (found 2026-11-09). Keep the filter by `numbers`.
- Passage packs are optional. Without `embeddings.json` they use exact numbers/names and BM25 and
  say so in `signals`; with it, the local E5 model adds cosine similarity. The model is MIT,
  117.7M parameters, about 470 MB ONNX (quantized about 118 MB), and lives in the Hugging Face
  cache; the uv environment lives in uv's cache. Never install it into the repository.
- A verdict cache is keyed by SHA-256 of page text and statement. A re-run on the same answer and
  pages reuses unchanged verdicts; a changed page or statement gets a fresh check.
- A second `prepare` in the same workdir moves the previous run's `results\pass*.jsonl` into
  `results\previous-<time>\`: the P/S ids are positional, so an old recheck row would otherwise
  attach to another statement (found in review, 2026-11-09). Never merge files from two runs.
- An uncited statement that an edit would delete is searched on the web once
  (`edit-web-plan` / `edit-web-collect` / `edit-web-verify-plan` / `edit-web-filter`). A page that
  proves it keeps the statement; otherwise the deletion stands. The code path exists because the
  saved pages may simply not cover an invented-looking sentence.
- `edit-filter` keeps the audit's reason on a rejected replacement; `edit-apply` reports it and
  deletes the statement only when the check found no support for the original either. An
  `unzutreffend` report names the contradicting source and its full quote, never the first old
  number.
- The report summary uses singular and plural ("1 Verweis wurde ersetzt", "2 Verweise wurden
  ersetzt"); a fixture with one replacement caught the old plural-only wording.
- Part 4 edits are span edits, never rewrites. The code rejects an edit longer than 50 characters
  or half the statement, a new number/name/version/date that is not in the proof quote, a quote
  that is not found or too short, and a change outside the statement's span. A rejected edit
  leaves the statement as it was and goes into the report; the fallback is deletion only when
  nothing supports the original either.
- Formatting check compares every line outside the edited spans byte for byte, the Markdown
  skeleton of edited lines, line endings and the final newline. A table cell deletion becomes
  `—`; a list item deletion removes its whole line. Never reformat a line to make the check pass.
- Every checking prompt carries the one-read rule: read each page once, decide all its claims in
  that turn, write the result file with one Write. Without it an agent greps and rereads per
  claim, and every request is another full thinking pass (measured 2026-11-09: 50-59 requests in
  the existing-page and edit agents).
- A parallel wave starts one agent first and the rest after 10 seconds. Started in the same
  second, every agent pays the shared system prefix as new text; the head start lets DeepSeek
  build the cache once (cost task, 2026-11-09).
- A `gestuetzt` verdict is sent to the recheck again when the claim is a value judgment or carries
  an absolute word (`ABSOLUTE_WORDS` in `check_sources.py`: ausschließlich, vollständig, immer,
  nie, kollabiert, Gesetze, ignoriert, fundamental and similar). The first pass must not mark a
  strong judgment as supported unless the page says it just as strongly (owner, 2026-11-10).
