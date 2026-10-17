# Research standard

Single source of truth for research in this system. The research skill, the web-researcher,
evidence-extractor and research-writer agents and the online routine page follow it. Change it
only here. The texts are written for the user's private use first.

## 1. Languages
- The user chooses the answer language and the source languages. Ask with the question tool
  unless the request already states them.
- Write search queries natively in each source language, the way native speakers search. Do not
  translate queries word for word.
- System notes and technical files are in English. Text for the user is in the chosen language.

## 2. Sources
- Use every configured search service at least once per research run, within its per-run cap:
  a keyed service whose key is missing is skipped and reported, never called with an empty
  header. `exa` is the exception: without `EXA_API_KEY` it runs on the anonymous daily limit.
  Serper is the reserve and is used only for local (Austria), German-language, price, shop,
  authority or very recent questions. The caps and the arithmetic for 90 runs a month are in
  `~/.claude/docs/agent-tooling.md` ("Budget for 90 runs a month").
- Run at least four passes: primary and official sources; secondary and expert sources; user
  experiences (forums, blogs, Reddit through the search services); counter-check (criticism,
  opposing views, corrections, recent changes).
- A statement about what a tool or program can do comes from the project's own README or
  documentation, not from a review; an entry in a TODO list or a wish list proves no existing
  function.
- A claim that a product cannot do something ("supports no X", "cannot Y") needs a primary
  source - the project's own documentation or issue tracker; a review or forum post alone
  carries no absence claim.
- A GitHub or project address is followed to the current name (the redirect of a renamed
  repository resolves); text and reference carry the current name, and the text fragment of a
  link matches the page as it stands today.
- For a "best tool" or "newest X" question, run one coverage check in two source languages
  ("best <topic> <year>", "neueste <Thema> <Jahr>") and compare the tools those pages name with
  the result; a strong tool that is missing is searched again before writing.
- A tax, benefit or law question gets one gap pass: amounts for low earners and small incomes,
  special cases (students, apprentices, part-time, disability, single parents), and the law in
  force today from a primary source. A question about languages, voices or translations gets
  its gap pass in the answer language: what do the sources say about the answer language
  itself? What stays missing is named under "Open questions".
- A question that touches the rights of people (voice cloning, faces, personal data,
  AI-generated media) gets the law in force from a primary source: for the EU the AI Act's
  transparency duties (article 50, applicable from 2026-08-02), consent and labelling.
- Read full pages. Never answer from search snippets.
- Reddit: no direct .json requests and no scraping. Use what the search and content services
  return. If a thread cannot be read, say so.
- Label community sources as experiences, never as established facts.
- When sources disagree: primary source (law text, authority, original text, manufacturer,
  original study) over secondary sources over community sources. Report the disagreement.
- Use the primary source first; where it carries the same statement, alone. Wording attributed
  to a work must stand in a page of that work among the saved pages; a secondary source may
  report it only marked as "according to X" (nach X).

## 3. Evidence
- Extract evidence word for word: the full relevant sentence, plus the sentence before or after
  when it is needed for context. Never shorten or rephrase evidence.
- Each evidence item records: id, page file, line range, section heading, verbatim text,
  language, source type, the claim it supports.
- An evidence item not found in its saved page after Unicode and whitespace normalization is
  removed.
- If the sources do not answer a question, say that it was not found. Never fill gaps from memory.

## 4. Writing: composition, not summary
- Build the text from the sources' own wording: phrases, main clauses, subordinate clauses.
- Keep the source's word choice as far as possible. Punctuation may be adapted so that a sentence
  works. A word form may be adapted only where grammar requires it; the word itself stays.
- Own words only as connectors: articles, pronouns, neutral conjunctions, the minimum grammar
  needed to join fragments.
- Connectors that claim a relation (because, therefore, however, despite) only when a source
  states that relation.
- Never add a claim that no evidence item supports.
- Only what answers the question. A tool's general description or a feature list the question
  does not ask for stays out.
- Source wording in another language stands in quotes with its translation (section 5), never
  bare in the running text: a run of four or more foreign words in a text of another language
  is a leftover of the source wording, not composition.
- Every statement carries a reference number; only a note that the sources say nothing about a
  point stands without one. Keep own sentences near 35 words; 45 words draw a warning.
- Each paragraph carries an HTML comment in English listing the evidence ids and the fragments
  used; it stands on the line directly under its paragraph, without a blank line. Adapted word
  forms are marked there with the original form.
- No work notes in the text: "the saved page", "the fragment", "the section ends mid-sentence"
  and the like never stand in the text. What the text still needs from a page is fetched from
  the page, not described.

## 5. Quotes
- Quote where it fits: definitions, legal and official wording, key claims, opinions, promises,
  statements a reader might doubt, and any place where other wording would change the meaning.
- A quote is copied character for character, including the source's own punctuation and
  special characters. Nothing inside a quote is changed.
- Foreign-language quote in a text of another language: the original wording first, then a
  faithful, literal translation marked as translation, directly after the quote. Needed from
  five words on; a short keyword needs none.
- A quote built into an own sentence must end where the source ends, never on a function word;
  its first letter stays as the source writes it - a lowered first letter is an adaptation.

## 6. Terminology
- Use the term of the authoritative primary source first.
- Otherwise use the term most reliable sources use.
- Mention a common variant once if readers may know the subject under that name.
- One spelling per name in the text; a variant is mentioned once, next to the usual spelling.
- Hard words, especially classical Arabic: check classical dictionaries (for example Lisan
  al-Arab through ejtaal.net/aa, arabiclexicon.hawramani.com, baheth.info) or an established
  translation, and cite it. Never invent a rendering.

## 7. References in the text
- Numeric style in order of first appearance: [1], [2]. The same source keeps its number.
- Place a number at the end of the passage it supports. If one source supports consecutive
  sentences, one number after the last of them is enough. Put a number directly after a sentence
  that carries a figure, a date, a quote or a disputed claim. More than three numbers in a row is
  clutter: keep the strongest sources.
- Each number links to the source page and jumps to the supporting passage with a text fragment:
  [3](https://example.org/page#:~:text=start%20words,end%20words). The text fragment uses words
  that exist in the saved page, percent-encoded. If the page changes, the browser opens the top
  of the page, which is acceptable.
- The writer writes no reference numbers itself, only the [[E12]] markers; the numbers in one
  group stand ascending and never twice.
- Where sources of different years disagree, name each source's year with its number. A source
  older than two years, or older than the last change of law or version in the subject, is
  marked when the statement is about today: give its year in the text.
- A capability stated as "not yet" or "noch nicht" carries the date of the statement and, where
  the state today matters, a check of the state today; an old statement is presented as
  then/today, never as the state today.
- A year named next to a source ("the rule of 2024") matches the date in its reference-list
  entry.

## 8. Reference list
One entry per source, numbered in order of first appearance:

    [n] Author or organisation. Title. Website (domain). Published or updated YYYY-MM-DD, or
        "no date". Language, if it differs from the answer language. Source type: primary,
        secondary or experience. Accessed YYYY-MM-DD. URL
        Archive: Wayback URL, if a snapshot exists. Local copy: link to the saved page.

- The URL in the list is the plain page URL, without text fragment and without tracking or
  challenge parameters. Dates are YYYY-MM-DD only. The domain stands once in an entry; when no
  author is known, the entry starts with the title, and a site slogan is no title.
- Labels in the list are written in the answer language.
- One website keeps one source type across the list. On platforms where many authors publish
  side by side (forums, Q&A sites, code hosts, paper servers) the type follows the contribution.

## 9. Characters
- Inside quotes and verbatim fragments: keep the source's characters unchanged.
- In own words, common keyboard punctuation is allowed where the situation calls for it:
  . , ; : ! ? ( ) " / - _ ' plus digits and the letters of the answer language. This is room to
  work in, not an instruction to use these characters.
- Not used in own words: em dash U+2014, en dash U+2013, a spaced hyphen standing in for a dash,
  the single ellipsis character U+2026, typographic quotes U+2018 U+2019 U+201A U+201C U+201D
  U+201E, arrows U+2190 to U+21FF, bullet U+2022, no-break and thin spaces U+00A0 U+2009,
  emojis, and transliteration letters with macron or dot below.
- Arabic and other scripts are allowed wherever text in that language appears.

## 10. Structure
1. A title that states the subject.
2. Lead: two or three sentences that answer the question. When the request arrived spoken, the
   names it carries (products, people) are confirmed with the question tool or checked against
   the sources before they shape the lead.
3. Key points: three to six short lines, each at most about 15 words, none a sentence of the
   text repeated word for word.
4. Sections with descriptive headings; one idea per paragraph; two to four sentences each.
5. "Where sources disagree" only when two sources give different values or statements on the
   same point, both values named next to each other with their numbers; without that pair the
   section is left out. Numbers that change with time (stars, downloads, watchers) form no
   disagreement: name each with the date it was read, or leave it out of the section.
6. "Open questions", when something was not found - and only after the point was searched in
   all saved pages: what a saved page carries is not an open question.
7. "How this text was made": languages, number of sources, date, AI use.
8. References.

## 11. Style
- Avoid the AI-writing patterns condensed in the research skill's `references/style-rules.md`
  (from blader/humanizer and humanizer-de; nothing is installed). `check_article.py` checks the
  mechanical ones.
- Style fixes may change only connectors, order and formatting. They never change a quote or a
  verbatim fragment.
- Where a style rule tolerates a character that section 9 excludes, section 9 wins.

## 12. Honesty
- Say "not found in the sources" instead of guessing.
- State which languages and how many sources were used.
- A claim whose evidence fails verification is removed.
- A note is checked against the notes already in the vault about the same tool: a version
  or number that differs is looked up again and, if both readings stand, the difference
  is named (newer reading or a noted change).
