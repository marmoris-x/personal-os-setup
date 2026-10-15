"""Hard checks for a finished research text, before it is saved.

Usage:
  python check_article.py ARTICLE.md --workdir <workdir> --lang de
         [--max-own 0.4] [--skip-sections "How this text was made,..."] [--fail-on-warnings]

Errors (exit 1): characters section 9 excludes in own words, numbers without a list entry or the
reverse, wrong order, bare reference numbers without a link, a group of numbers that is not
ascending or holds a duplicate, list entry without URL, link that does not match its entry, a
list entry with an ISO-timestamp date, without source type, with a repeated domain, with a site
placeholder as title or author, or with tracking or challenge parameters, text fragment that is
not in the saved page, quote that is not word for word in its evidence, a foreign-language quote
of five words or more without a translation marker, fragment that is not in the paragraph or in
its evidence, a statement after the last reference number without one, unreadable compose comment.
Warnings: AI-writing patterns in own words, more than three numbers in a row, paragraphs with
claims but no number or no compose comment, share of own words above --max-own, a sentence from
45 words, lead of more than three sentences, key points outside three to six lines, longer than
15 words or repeated word for word, two spellings for one name, sources from different years
compared without naming a year, a primary source that carries a fragment used from a secondary
one.
Quotes ("...") and the fragments named in a paragraph's compose comment are never checked for
characters or patterns. Prints the own-word share of every composed paragraph.
Standard: ~/.claude/docs/research-standard.md sections 2, 4, 5, 6, 7, 8, 9, 10, 11.
"""

import argparse
import re
import sys
import unicodedata
from collections import Counter
from datetime import date
from pathlib import Path
from urllib.parse import unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ai_patterns import compile_patterns  # noqa: E402
from common import (COMPOSE_RE, DataError, check_fragments, find_tokens, load_evidence,  # noqa: E402
                    normalize, paragraphs, parse_compose, plain_markdown, read_page, strip_tracking,
                    tokens, utf8_output)

LINK_RE = re.compile(r"\[(\d+)\]\((https?://[^)\s]+)\)")
ENTRY_RE = re.compile(r"(?m)^\[(\d+)\]\s+(.*)$")
QUOTE_RE = re.compile(r'"([^"\n]{3,}?)"')
URL_RE = re.compile(r"https?://\S+")
REFS_RE = re.compile(r"<!-- references:start -->(.*?)<!-- references:end -->", re.S)
RUN_RE = re.compile(r"(?:\[\d+\]\([^)\s]*\)[\s,;]*){4,}")
SPACED_HYPHEN = re.compile(r"(?<=\S) (?:-|--) (?=\S)")
DEFAULT_SKIP = ("how this text was made", "wie dieser text entstand", "wie dieser text gemacht wurde",
                "كيف أعد هذا النص")
REF_TOKEN = re.compile(r"\[(\d+)\](?:\(([^)\s]*)\))?")
TRACKING_URL = re.compile(r"[?#&](utm_[a-z_]+|fbclid|gclid|dclid|mc_cid|mc_eid|igshid|ref|ref_src|"
                          r"solution|js_challenge|jsc_token|jsc_orig_r|_gl|twclid|msclkid|__cf[a-z_]*)=",
                          re.I)
ISO_TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T")
JUNK_AUTHOR = re.compile(r"count \d+ (posts|comments)", re.I)
JUNK_TITLE = re.compile(r"reddit\s*[-–—]\s*the heart of the internet", re.I)
TYPE_LABEL = re.compile(r"(quellenart|source type|نوع المصدر)\s*:", re.I)
TRANSLATION_WORDS = {"de": ("Übersetzung",), "en": ("Translation",), "ar": ("ترجمة",)}
TRANSLATION_FALLBACK = ("Übersetzung", "Translation", "translation", "ترجمة", "Traducción", "Traduction")
NO_SOURCE_SENTENCE = re.compile(r"(?i)\b(quellen|sources|المصادر)\b.{0,80}\b(nichts|keine|no |not |لم|لا)\b")
YEAR = re.compile(r"\b(1[89]\d\d|20\d\d)\b")
ABBREV = {"z", "b", "ca", "vgl", "bzw", "d", "u", "o", "evtl", "ggf", "inkl", "exkl", "max", "min",
          "nr", "abs", "st", "dr", "mag", "prof", "bzgl", "etc", "resp", "approx", "no", "vs", "sog",
          "jan", "feb", "mrz", "apr", "jun", "jul", "aug", "sep", "okt", "nov", "dez", "vol", "abb",
          "tab", "з", "др"}

BANNED = {
    "—": "em dash", "–": "en dash", "…": "ellipsis character",
    "‘": "typographic quote", "’": "typographic quote", "‚": "typographic quote",
    "“": "typographic quote", "”": "typographic quote", "„": "typographic quote",
    "•": "bullet", " ": "no-break space", " ": "thin space",
}
EMOJI_RANGES = ((0x1F000, 0x1FAFF), (0x2600, 0x27BF), (0x2B00, 0x2BFF), (0x2300, 0x23FF),
                (0xFE0F, 0xFE0F), (0x200D, 0x200D))
ARROWS = (0x2190, 0x21FF)
LATIN_BASE = set("abcdefghijklmnopqrstuvwxyz")
LANG_LETTERS = {
    "en": "", "de": "äöüß", "fr": "àâæçéèêëîïôœùûüÿ", "es": "áéíóúüñ", "it": "àèéìíîòóùú",
    "pt": "àáâãçéêíóôõúü", "nl": "éëïóö", "ar": "",
}


def split_article(text):
    """Return (body without frontmatter and reference block, reference block or None)."""
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end > 0:
            text = text[end + 4:].lstrip("\n")
    match = REFS_RE.search(text)
    if match:
        return text[:match.start()] + text[match.end():], match.group(1)
    return text, None


def remove_spans(text, spans):
    """Remove literal (whitespace-tolerant) occurrences of each span text."""
    for span in spans:
        pattern = r"\s+".join(re.escape(part) for part in span.split())
        if pattern:
            text = re.sub(pattern, " ", text, count=1)
    return text


def own_text(block, compose):
    """The writer's own words: no comments, link syntax, URLs, quotes or listed fragments."""
    text = COMPOSE_RE.sub(" ", block)
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.S)
    text = LINK_RE.sub(lambda m: f"[{m.group(1)}]", text)
    text = URL_RE.sub(" ", text)
    text = QUOTE_RE.sub(" ", text)
    if compose:
        text = remove_spans(text, [f[1] for f in compose.get("frags", []) if len(f) == 2])
    return text


def char_problems(text, lang):
    """(kind, detail) for each excluded character in own words."""
    found = []
    for ch in text:
        code = ord(ch)
        if ch in BANNED:
            found.append(("error", f"{BANNED[ch]} U+{code:04X}"))
        elif ARROWS[0] <= code <= ARROWS[1]:
            found.append(("error", f"arrow U+{code:04X}"))
        elif any(lo <= code <= hi for lo, hi in EMOJI_RANGES):
            found.append(("error", f"emoji or symbol U+{code:04X}"))
        elif unicodedata.category(ch).startswith("L") and code > 127:
            decomposed = unicodedata.normalize("NFD", ch)
            if "̄" in decomposed or "̣" in decomposed or ch in "ʿʾ":
                found.append(("error", f"transliteration letter {ch!r} U+{code:04X}"))
            elif lang in LANG_LETTERS and unicodedata.name(ch, "").startswith("LATIN"):
                if ch.lower() not in LANG_LETTERS[lang]:
                    found.append(("warning", f"letter {ch!r} is not a letter of {lang}"))
    if SPACED_HYPHEN.search(text):
        found.append(("error", "spaced hyphen standing in for a dash"))
    return found


def style_hits(text, patterns):
    hits, connector_count = [], 0
    for name, rx, kind in patterns:
        found = rx.findall(text)
        if not found:
            continue
        if kind == "connector":
            connector_count += len(found)
            continue
        hits.append(name)
    if connector_count > 1:
        hits.append(f"{connector_count} mechanical connectors")
    return hits


def mask_quotes(text):
    return re.sub(r'"[^"\n]*"', lambda m: " " * len(m.group(0)), text)


def split_sentences(text):
    """Sentences; a split after a common abbreviation or a single letter is undone.

    Punctuation inside a quoted span does not end a sentence: a quotation is
    one unit, so 'He said "One. Two." and left.' is one sentence, not three.
    """
    masked = re.sub(r'"[^"\n]*"', lambda m: re.sub(r"[.!?]", "\u0001", m.group(0)), text)
    parts = []
    position = 0
    for match in re.finditer(r"(?<=[.!?])\s+|\n+", masked):
        parts.append(text[position:match.start()])
        position = match.end()
    parts.append(text[position:])
    merged = []
    for part in parts:
        if merged:
            tail = merged[-1].rstrip()
            last = re.split(r"[\s(\[]", tail)[-1].rstrip(".").casefold()
            if last in ABBREV or (len(last) == 1 and last.isalpha()):
                merged[-1] += " " + part
                continue
        merged.append(part)
    return [s for s in merged if s.strip()]


def script_name(ch):
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return "other"
    for script in ("ARABIC", "HEBREW", "CYRILLIC", "GREEK", "CJK", "HIRAGANA", "KATAKANA",
                   "HANGUL", "DEVANAGARI", "THAI", "BENGALI"):
        if script in name:
            return "nonlatin"
    return "latin" if "LATIN" in name else "other"


def looks_foreign(text, lang):
    """True when the letters of the text are mostly of another script than the answer's."""
    letters = [ch for ch in text if unicodedata.category(ch).startswith("L")]
    if not letters:
        return False
    if lang == "ar":
        return sum(1 for ch in letters if script_name(ch) == "latin") / len(letters) >= 0.6
    if lang in ("de", "en", "fr", "es", "it", "pt", "nl"):
        return sum(1 for ch in letters if script_name(ch) == "nonlatin") / len(letters) >= 0.6
    return False


def check_number_groups(body, errors):
    """No bare numbers, no duplicates and ascending order inside a group of links."""
    masked = mask_quotes(re.sub(r"<!--.*?-->", lambda m: " " * len(m.group(0)), body))
    bare = [m.group(1) for m in REF_TOKEN.finditer(masked) if m.group(2) is None]
    if bare:
        errors.append(f"bare reference numbers without a link: {len(bare)} (e.g. [{bare[0]}])")
    for match in re.finditer(r"(?:\[\d+\]\([^)\s]*\)[ \t]*){2,}", masked):
        numbers = [int(m.group(1)) for m in REF_TOKEN.finditer(match.group(0))]
        if any(b <= a for a, b in zip(numbers, numbers[1:])):
            kind = "duplicate" if len(set(numbers)) < len(numbers) else "not ascending"
            errors.append(f"reference numbers {kind} in one group: {numbers}")


def check_translations(label, block, compose, evidence, lang, errors):
    """A foreign-language quote of five words or more needs its translation right after it."""
    text = re.sub(r"<!--.*?-->", " ", block)
    words_of_mark = TRANSLATION_WORDS.get(lang, TRANSLATION_FALLBACK)
    for match in QUOTE_RE.finditer(text):
        quote = match.group(1)
        if len(tokens(quote)) < 5:
            continue
        foreign = False
        if compose:
            for ev_id in compose.get("ids", []):
                item = evidence.get(ev_id)
                if (item and item.get("lang") and item["lang"] != lang
                        and normalize(quote) in normalize(item["text"])):
                    foreign = True
                    break
        if not foreign and looks_foreign(quote, lang):
            foreign = True
        if not foreign:
            continue
        marker = re.match(r"\s*\(([^()]*)\)", text[match.end():])
        if marker and any(w.casefold() in marker.group(1).casefold() for w in words_of_mark):
            continue
        errors.append(f"{label}: foreign-language quote of {len(tokens(quote))} words without a "
                      f"translation marker: {quote[:40]!r}")


def translation_spans(block, lang):
    """The inner text of each "(Übersetzung: ...)" parenthetical of a paragraph."""
    words = TRANSLATION_WORDS.get(lang, TRANSLATION_FALLBACK)
    text = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block))
    spans = []
    for m in re.finditer(r"\(([^()]*)\)", text):
        if any(w.casefold() in m.group(1).casefold() for w in words):
            spans.append(m.group(1))
    return spans


def check_statements_and_length(label, block, errors, warnings, lang):
    """Every statement after the last reference number needs a number; no runaway sentences.
    Quotes and translation parentheses are mandated wording, not sentence length."""
    text = re.sub(r"<!--.*?-->", " ", block)
    sentences = split_sentences(text)
    if not sentences:
        return
    linked = [bool(LINK_RE.search(s)) for s in sentences]
    last_link = max((i for i, has in enumerate(linked) if has), default=-1)
    for index, sentence in enumerate(sentences):
        without_quotes = re.sub(r'"[^"\n]*"', " ", sentence)
        for inner in translation_spans(without_quotes, lang):
            without_quotes = without_quotes.replace(f"({inner})", " ")
        words = len(tokens(LINK_RE.sub(" ", without_quotes)))
        if words >= 45:
            warnings.append(f"{label}: sentence has {words} words (limit 45, aim 35): "
                            f"{sentence.strip()[:50]!r}")
        if linked[index] or index < last_link:
            continue
        if words < 6 or NO_SOURCE_SENTENCE.search(sentence):
            continue
        errors.append(f"{label}: statement without a reference number: {sentence.strip()[:60]!r}")


def check_source_years(label, block, entries, warnings):
    """Comparing sources from different years needs the years in the text."""
    years = set()
    for number, _ in LINK_RE.findall(block):
        rest = entries.get(int(number))
        if rest:
            rest = re.sub(r"(?i)(abgerufen|accessed|تاريخ الوصول)[^.]*", " ", rest)
            years.update(int(y) for y in YEAR.findall(URL_RE.sub(" ", rest)))
    if len(years) < 2 or min(years) > date.today().year - 2:
        return
    if YEAR.search(re.sub(r"<!--.*?-->", " ", block)):
        return
    warnings.append(f"{label}: compares sources from {min(years)} to {max(years)} without naming a year")


def fragment_covered(words, hay_tokens):
    """True when the fragment's words are (mostly) in the other text."""
    if find_tokens(hay_tokens, words) >= 0:
        return True
    distinctive = [w for w in words if len(w) >= 5 or any(ch.isdigit() for ch in w)]
    if len(distinctive) < 4:
        # short fragments share common words with any primary text; only an
        # exact run (checked above) counts for them
        return False
    hay_set = {w.casefold() for w in hay_tokens}
    # a digit word counts only as itself: '20' must not ride on '120'
    hits = sum(1 for w in distinctive if w.casefold() in hay_set)
    if hits / len(distinctive) < 0.7:
        return False
    # 'mostly in' must mean a shared phrase, not the same common words
    # scattered through unrelated sentences: four consecutive words of the
    # fragment have to appear as one run in the other text
    for start in range(len(words) - 3):
        if find_tokens(hay_tokens, words[start:start + 4]) >= 0:
            return True
    return False


def check_primary_sources(label, compose, evidence, warnings):
    """A primary source that carries the same words should be used before a secondary one."""
    if not compose:
        return
    cited = set(compose.get("ids", []))
    primaries = [item for item in evidence.values() if item.get("type") == "primary"]
    for entry in compose.get("frags", []):
        if not (isinstance(entry, list) and len(entry) == 2):
            continue
        ev_id, frag = entry
        item = evidence.get(ev_id)
        if not item or item.get("type") == "primary":
            continue
        words = tokens(frag)
        if len(words) < 3:
            continue
        for primary in primaries:
            if primary["id"] in cited:
                continue
            if fragment_covered(words, tokens(primary["text"])):
                warnings.append(f"{label}: primary evidence {primary['id']} carries this fragment "
                                f"({str(frag)[:30]!r}); use the primary source first")
                break


def check_structure(body, warnings):
    """Lead of two or three sentences; key points of three to six short lines."""
    blocks = paragraphs(body)
    seq = [b for b in blocks if not re.match(r"\s*#{1,6}\s", b)]
    if not seq:
        return
    lead = split_sentences(LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", seq[0])))
    if len(lead) > 3:
        warnings.append(f"lead has {len(lead)} sentences (two to three)")
    points = seq[1] if len(seq) > 1 else None
    lines = [l.strip() for l in points.split("\n") if l.strip().startswith("- ")] if points else []
    if len(lines) < 2:
        warnings.append("no key-point block after the lead (three to six short lines)")
        return
    if not 3 <= len(lines) <= 6:
        warnings.append(f"key-point block has {len(lines)} lines (three to six)")
    body_sentences = []
    for block in blocks:
        if block is points:
            continue
        body_sentences.extend(tokens(s) for s in
                              split_sentences(LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block))))
    for index, line in enumerate(lines, 1):
        words = tokens(LINK_RE.sub(" ", line[2:].strip()))
        if len(words) > 15:
            warnings.append(f"key point {index} has {len(words)} words (limit 15)")
        if len(words) >= 3 and words in body_sentences:
            warnings.append(f"key point {index} repeats a sentence of the text word for word")


def near_duplicate(a, b):
    """Same-length words sharing a long head and tail, differing in exactly one letter."""
    if len(a) < 7 or a == b:
        return False
    differences = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
    if len(differences) != 1:
        return False
    at = differences[0]
    return at >= 3 and len(a) - at - 1 >= 3


def near_callout(folded, major, minor):
    positions = [m.start() for m in re.finditer(re.escape(minor), folded)]
    if len(positions) != 1:
        return False
    return any(abs(positions[0] - m.start()) <= 150 for m in re.finditer(re.escape(major), folded))


def check_spelling_variants(body, warnings):
    """One spelling per name: long near-identical words (one letter swapped) are reported."""
    text = re.sub(r"<!--.*?-->", " ", body)
    text = re.sub(r"\[\d+\]\([^)\s]*\)", " ", text)
    counts, forms, named = Counter(), {}, {}
    for word in tokens(text):
        key = word.casefold()
        if len(key) < 7 or any(ch.isdigit() for ch in key):
            continue
        counts[key] += 1
        forms.setdefault(key, word)
        looks_named = word[:1].isupper() or any(script_name(ch) == "nonlatin" for ch in word)
        named[key] = named.get(key, False) or looks_named
    buckets = {}
    for key in counts:
        buckets.setdefault(len(key), []).append(key)
    folded = text.casefold()
    seen_pairs = set()
    for keys in buckets.values():
        for i, a in enumerate(keys):
            for b in keys[i + 1:]:
                if not near_duplicate(a, b):
                    continue
                if not (named[a] or named[b]):
                    # two lowercase Latin words are inflected forms, not name spellings
                    continue
                pair = (a, b) if counts[a] >= counts[b] else (b, a)
                if pair in seen_pairs:
                    continue
                seen_pairs.add(pair)
                major, minor = pair
                if counts[minor] >= 2 or not near_callout(folded, major, minor):
                    warnings.append(f"two spellings for one name: {forms[major]!r} ({counts[major]}x) "
                                    f"and {forms[minor]!r} ({counts[minor]}x) - keep one, "
                                    f"name the variant once")


def check_references(body, refs_block, errors, warnings):
    links = LINK_RE.findall(body)
    cited, order = {}, []
    for number, url in links:
        n = int(number)
        if n not in cited:
            cited[n] = url
            order.append(n)
    if refs_block is None:
        errors.append("no reference list (<!-- references:start --> ... <!-- references:end -->)")
        return cited, {}
    entries = {int(n): rest for n, rest in ENTRY_RE.findall(refs_block)}
    for n in sorted(set(cited) - set(entries)):
        errors.append(f"number [{n}] is cited but has no list entry")
    for n in sorted(set(entries) - set(cited)):
        errors.append(f"list entry [{n}] is never cited")
    if order != sorted(order) or (order and order != list(range(1, len(order) + 1))):
        errors.append(f"numbers are not in order of first appearance: {order}")
    for n, rest in entries.items():
        entry_urls = URL_RE.findall(rest)
        if not entry_urls:
            errors.append(f"list entry [{n}] has no URL")
        elif n in cited:
            base = strip_tracking(unquote(cited[n].split("#")[0]))
            if base not in [strip_tracking(unquote(u)).rstrip(".") for u in entry_urls]:
                errors.append(f"link of [{n}] does not match the URL of its list entry")
        text_only = URL_RE.sub(" ", rest)
        if ISO_TIMESTAMP.search(text_only):
            errors.append(f"list entry [{n}]: date is an ISO timestamp, must be YYYY-MM-DD")
        if not TYPE_LABEL.search(text_only):
            errors.append(f"list entry [{n}]: no source type")
        if JUNK_TITLE.search(text_only) or JUNK_AUTHOR.search(text_only):
            errors.append(f"list entry [{n}]: site placeholder as title or author")
        if TRACKING_URL.search(rest):
            errors.append(f"list entry [{n}]: tracking or challenge parameters in a URL")
        if entry_urls:
            domain = urlsplit(unquote(entry_urls[0])).netloc.removeprefix("www.")
            segments = [s.strip() for s in text_only.split(". ")]
            domain_forms = (domain.casefold(), "www." + domain.casefold())
            if domain and sum(1 for s in segments if s.casefold() in domain_forms) > 1:
                errors.append(f"list entry [{n}]: the domain appears more than once")
    if RUN_RE.search(body):
        warnings.append("more than three reference numbers in a row")
    tracked = [url for _, url in links if TRACKING_URL.search(url)]
    if tracked:
        errors.append(f"links with tracking or challenge parameters: {len(tracked)} "
                      f"(e.g. {tracked[0][:60]})")
    return cited, entries


def page_for_url(workdir, url):
    """The saved text of a URL. A URL can be saved more than once (a second, fuller fetch);
    all copies are joined, so a passage counts when any saved copy of that page carries it."""
    base = strip_tracking(unquote(url.split("#")[0]))
    pages = Path(workdir) / "pages"
    bodies = []
    for path in sorted(pages.glob("*.md")):
        header, body, _ = read_page(path)
        for key in ("final_url", "url"):
            if header.get(key) and strip_tracking(unquote(header[key].split("#")[0])) == base:
                bodies.append(body)
                break
    return "\n".join(bodies) if bodies else None


def check_fragments_in_pages(body_text, workdir, errors, warnings):
    seen = set()
    for _, url in LINK_RE.findall(body_text):
        if "#:~:text=" not in url or url in seen:
            continue
        seen.add(url)
        page = page_for_url(workdir, url)
        if page is None:
            warnings.append(f"no saved page for {url.split('#')[0]}; fragment not checked")
            continue
        haystack = normalize(plain_markdown(page))
        directive = url.split("#:~:text=", 1)[1]
        position = 0
        for part in directive.split(","):
            word = normalize(unquote(part))
            at = haystack.find(word, position)
            if at < 0:
                errors.append(f"text fragment words not in the saved page: {word[:40]!r}")
                break
            position = at


def run(article_path, workdir, lang, max_own, skip_sections):
    text = Path(article_path).read_text(encoding="utf-8")
    body, refs_block = split_article(text)
    errors, warnings, info, style_total = [], [], [], 0
    evidence = {}
    try:
        evidence = load_evidence(workdir)
    except DataError as exc:
        errors.append(str(exc))
    _, entries = check_references(body, refs_block, errors, warnings)
    if workdir:
        check_fragments_in_pages(body, workdir, errors, warnings)
    if not re.search(r"(?m)^# \S", body):
        warnings.append("no level-1 title")
    check_number_groups(body, errors)
    check_structure(body, warnings)
    check_spelling_variants(body, warnings)
    patterns = compile_patterns()
    skipping = False
    for number, block in enumerate(paragraphs(body), 1):
        label = f"paragraph {number}"
        heading = re.match(r"\s*#{1,6}\s+(.*)", block)
        if heading:
            # a listed section name matches when the heading starts with it
            heading_text = heading.group(1).strip().lower()
            skipping = any(heading_text.startswith(name) for name in skip_sections)
        plain = block.strip()
        try:
            compose = parse_compose(block)
        except DataError as exc:
            errors.append(f"{label}: {exc}")
            compose = None
        mine = own_text(block, compose)
        for kind, detail in char_problems(mine, lang):
            (errors if kind == "error" else warnings).append(f"{label}: {detail}")
        hits = style_hits(mine, patterns)
        style_total += len(hits)
        for hit in hits:
            warnings.append(f"{label}: style pattern {hit!r}")
        if skipping or heading:
            continue
        check_translations(label, block, compose, evidence, lang, errors)
        check_statements_and_length(label, block, errors, warnings, lang)
        check_source_years(label, block, entries, warnings)
        check_primary_sources(label, compose, evidence, warnings)
        words = len(tokens(re.sub(r"<!--.*?-->", " ", LINK_RE.sub("", plain), flags=re.S)))
        has_number = bool(LINK_RE.search(block))
        if compose is None:
            if words >= 12 and not plain.startswith(("|", "```", "[")):
                warnings.append(f"{label}: no compose comment ({words} words)")
            if QUOTE_RE.search(re.sub(r"<!--.*?-->", " ", block)):
                errors.append(f"{label}: quote without a compose comment")
            continue
        if not has_number and words >= 8:
            warnings.append(f"{label}: statements without a reference number")
        clean = COMPOSE_RE.sub(" ", block)
        for problem in check_fragments(compose, evidence, clean):
            errors.append(f"{label}: {problem}")
        allowed = " ".join(normalize(evidence[i]["text"]) for i in compose["ids"] if i in evidence)
        for i in compose["ids"]:
            if i not in evidence:
                errors.append(f"{label}: evidence {i} is not verified")
        for quote in QUOTE_RE.findall(re.sub(r"<!--.*?-->", " ", block)):
            if normalize(quote) not in allowed:
                errors.append(f"{label}: quote not word for word in its evidence: {quote[:40]!r}")
        total = tokens(LINK_RE.sub("", re.sub(r"<!--.*?-->", " ", block)))
        covered = sum(len(tokens(q)) for q in QUOTE_RE.findall(clean))
        para_tokens = total
        for entry in compose.get("frags", []):
            if len(entry) == 2:
                words_f = tokens(entry[1])
                if find_tokens(para_tokens, words_f) >= 0:
                    covered += len(words_f)
        # a "the sources say nothing" note is required by the standard, not own phrasing
        for sentence in split_sentences(clean):
            if NO_SOURCE_SENTENCE.search(sentence):
                covered += len(tokens(LINK_RE.sub("", sentence)))
        # a mandated literal translation is source wording, not the writer's own
        for inner in translation_spans(block, lang):
            covered += len(tokens(inner))
        share = max(0.0, 1 - covered / len(total)) if total else 0.0
        info.append(f"{label}: own words {share:.0%} of {len(total)}")
        # a key-point block is writer-formulated on purpose, and it has its own check
        bullets = sum(1 for line in block.splitlines() if line.strip().startswith("- "))
        if share > max_own and bullets < 2:
            warnings.append(f"{label}: own words {share:.0%} is above {max_own:.0%}")
    return errors, warnings, info, style_total


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("article")
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--lang", required=True)
    parser.add_argument("--max-own", type=float, default=0.4)
    parser.add_argument("--skip-sections", default="")
    parser.add_argument("--fail-on-warnings", action="store_true")
    args = parser.parse_args(argv)
    utf8_output()
    skip = {s.strip().lower() for s in args.skip_sections.split(",") if s.strip()} | set(DEFAULT_SKIP)
    try:
        errors, warnings, info, style = run(args.article, args.workdir, args.lang, args.max_own, skip)
    except (DataError, OSError) as exc:
        print(f"ERROR {exc}")
        return 1
    for line in info:
        print("INFO", line)
    for line in warnings:
        print("WARNING", line)
    for line in errors:
        print("ERROR", line)
    print(f"SUMMARY errors={len(errors)} warnings={len(warnings)} style_hits={style}")
    return 1 if errors or (args.fail_on_warnings and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())
