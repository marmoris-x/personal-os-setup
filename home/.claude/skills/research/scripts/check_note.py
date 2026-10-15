"""Check a finished research note against its saved pages (the vault note, after store_results).

Usage:
  python -I -X utf8 check_note.py NOTE.md --pages <pages dir> --lang de [--today YYYY-MM-DD]
         [--max-quote-words 5] [--other-notes <folder with other notes>]

The stored note has no compose comments any more (store_results removes them), so these checks
work from the text itself, the reference list and the saved pages. The checks of the research
standard that need the evidence file stay in check_article.py and run during a research run;
this script is the counter-check that runs on the finished note (Teil 4 of the correction order
of 2026-10-08, and vault-lint's truth step).

Errors:
  - the reference checks of check_article.py (number order, list entry, URL, source type)
  - a "where sources disagree" paragraph with fewer than two sources
  - a "the sources say nothing" sentence whose words stand in a saved page
  - a quote in a paragraph whose sources are all secondary while a primary page of the run
    carries the same wording
  - a quote that is cut: it ends on a word that cannot end a sentence
  - a foreign-language quote without a translation marker
  - work notes in the text ("the saved page", "the fragment", "Ableitungsabschnitt")
  - one website with two different source types (platforms with many authors - forums, Q&A
    sites, code hosts, paper servers - are exempt: there the type follows the contribution)
  - a "not yet" claim without a year in its paragraph: such a statement needs its date in the
    text and a check of the state today, never a presentation as a current disagreement
  - a sentence that calls the answer language absent ("no German voice") while a saved page or
    the note's own text carries that language in a language or voice context (the gap pass)
  - an English run of four or more words in a German note outside quotes: a leftover of the
    source wording belongs in a quote (with translation) or in German
  - a stars, downloads or version-number value inside a "where sources disagree" paragraph
    without a year: such numbers change with time and form no disagreement
  - with --other-notes: a version of a named tool that differs from the version another note
    in that folder gives (new notes are checked against the existing notes)
Warnings:
  - a value named for two different sources in a disagreement paragraph (possible false
    disagreement: the sources may agree)
  - a quote whose first letter was lowered although the saved page carries the wording
    only with an upper-case first letter (the quote may have been adapted)
  - a year named for a source that does not match its list entry
  - a number from a source older than two years without the year in the text
Exit 1 when there is at least one error.
Standard: ~/.claude/docs/research-standard.md sections 2, 4, 5, 7, 8, 10.
"""

import argparse
import re
import sys
from datetime import date
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_article  # noqa: E402  (its reference checks are reused)
from common import find_tokens, normalize, plain_markdown, read_page, tokens, utf8_output  # noqa: E402

LINK_RE = check_article.LINK_RE
ENTRY_RE = check_article.ENTRY_RE
QUOTE_RE = check_article.QUOTE_RE
URL_RE = check_article.URL_RE
YEAR = check_article.YEAR
NO_SOURCE_SENTENCE = check_article.NO_SOURCE_SENTENCE

# Common spellings of the section's name; a note that renames the heading must not slip
# past the check. The standard writes "Where sources disagree".
DISAGREE_HEAD = re.compile(
    r"(?mi)^#{1,6}\s*(where sources disagree|wo (?:die )?quellen\s+"
    r"(?:abweichen|sich widersprechen)|حيث تختلف المصادر)")
HEAD = re.compile(r"(?m)^#{1,6}\s")
ACCESS_RE = re.compile(r"(?i)(?:abgerufen|accessed|access date|تم الوصول)\s+\d{4}-\d{2}-\d{2}")
TYPE_RE = re.compile(r"(?i)(?:quellenart|source type|نوع المصدر)\s*:\s*([^.]*)")
TYPE_WORDS = {
    "primary": ("primärquelle", "primary", "أولي"),
    "secondary": ("sekundärquelle", "secondary", "ثانوي"),
    "experience": ("erfahrungsbericht", "experience", "تجربة"),
}
# Websites that carry both original texts and modern works (digital libraries and archives),
# and platforms where different authors publish side by side (forums, Q&A sites, code hosts,
# paper servers): there the source type follows the single document, not the website.
MIXED_TYPE_SITES = (
    "shamela.ws", "islamweb.net", "lib.eshia.ir", "arabiclexicon.hawramani.com", "almaany.com",
    "qamus.inoor.ir", "ar.islamway.net", "ahlalhdeeth.com", "discuss.python.org",
    "stackoverflow.com", "news.ycombinator.com", "reddit.com", "medium.com", "github.com",
    "arxiv.org", "pv-forum.ars.at",
)
WORK_NOTES = (
    "gespeicherte seite", "gespeicherten seite", "gespeicherten seiten", "gespeicherter seite",
    "ableitungsabschnitt", "im work folder", "work folder", "the saved page", "saved page",
    "the work folder", "der entwurf", "dem entwurf", "arbeitsnotiz", "Arbeitsnotizen".lower(),
    "fragment endet", "endet mitten im satz", "hier fehlt", "noch zu prüfen",
)
# Words that cannot end a complete sentence at all: an error when a quote ends on one.
HARD_TAIL = {
    "de": ("der", "die", "das", "den", "dem", "des", "und", "oder", "aber", "dass", "weil",
           "ein", "eine", "einen", "einem", "einer", "sowie", "sowohl", "je"),
    "en": ("and", "or", "but", "that", "because", "the", "a", "an", "of"),
}
# Words that end a sentence only together with its punctuation: "ready to experiment with."
# is a complete sentence, "ready to experiment with" is a cut. German separable verbs
# ("Das macht viel aus.") belong here too, so this is a hint, not an error.
SOFT_TAIL = {
    "de": ("zu", "mit", "in", "auf", "an", "nach", "über", "durch", "gegen", "für", "von",
           "bei", "aus", "ist", "wird", "sind", "werden"),
    "en": ("to", "with", "for", "from", "in", "on", "at", "as", "by", "is", "are", "was",
           "were", "be", "been"),
}
SENTENCE_END = ".!?…"
SKIP_SECTIONS = ("wie dieser text entstanden ist", "how this text was made",
                 "wie dieser text gemacht wurde", "كيف أعد هذا النص")
# A value is one number, or a range like "40-43%": the range must not fall apart into two
# values, or "40" from "40-43" looks like a value that a second source also names.
# A value starts and ends with a digit: the separator inside ("1.234,56") stays, a comma or
# period after the value is the sentence's, not the value's.
VALUE_RE = re.compile(r"\d(?:[\d.,]*\d)?(?:\s*[-–]\s*\d(?:[\d.,]*\d)?)?")
# A citation becomes one private-use character (U+E000 + number), never a digit: the number
# of the marker itself must not be read as a value of the paragraph.
MARKER_RE = re.compile("[-]")
def marker(number):
    return chr(0xE000 + int(number))


def paragraphs_of(body):
    return [b for b in re.split(r"\n\s*\n", body) if b.strip()]


def section_paragraphs(body, head_re):
    """The paragraphs between the heading the pattern finds and the next heading."""
    match = head_re.search(body)
    if not match:
        return []
    rest = body[match.end():]
    stop = HEAD.search(rest)
    if stop:
        rest = rest[:stop.start()]
    return paragraphs_of(rest)


def entry_parts(rest):
    """(domain, year, type) of a reference list entry."""
    urls = URL_RE.findall(rest)
    domain = ""
    if urls:
        match = re.match(r"https?://([^/]+)", urls[0])
        domain = (match.group(1) if match else "").lower().removeprefix("www.")
    # The access date is not the source's year: "Abgerufen 2026-10-06" must not make an old
    # source look young, or the old-number and year checks can never fire.
    text = ACCESS_RE.sub(" ", URL_RE.sub(" ", rest))
    years = [int(y) for y in YEAR.findall(text)]
    kind = ""
    label = TYPE_RE.search(URL_RE.sub(" ", rest))
    if label:
        text = label.group(1).casefold()
        for name, words in TYPE_WORDS.items():
            if any(w in text for w in words):
                kind = name
                break
    return domain, years, kind


def page_index(pages_dir):
    """[(file name, header type, normalized body, word list)] and {url without fragment: body}."""
    pages, by_url = [], {}
    for path in sorted(Path(pages_dir).glob("*.md")):
        header, body, _ = read_page(path)
        page_type = (header.get("type") or "").strip().casefold()
        clean = normalize(plain_markdown(body))
        pages.append((path.name, page_type, clean, tokens(clean)))
        for key in ("final_url", "url"):
            if header.get(key):
                by_url.setdefault(unquote(header[key].split("#")[0]).rstrip("/"), []).append(clean)
    return pages, by_url


def body_of(by_url, url):
    return by_url.get(unquote(url.split("#")[0]).rstrip("/")) or []


def check_disagreement(body, errors, warnings):
    """Every paragraph of a "where sources disagree" section names two sources and two values."""
    for number, block in enumerate(section_paragraphs(body, DISAGREE_HEAD), 1):
        numbers = [int(n) for n, _ in LINK_RE.findall(block)]
        if len(set(numbers)) < 2:
            errors.append(f"disagreement paragraph {number}: only {len(set(numbers))} source(s); "
                          f"a disagreement needs two")
            continue
        text = LINK_RE.sub(lambda m: marker(m.group(1)), block)
        markers = list(MARKER_RE.finditer(text))
        owner = {}
        for value in VALUE_RE.finditer(text):
            after = [m for m in markers if m.start() > value.end()]
            if after:
                source = str(ord(after[0].group(0)) - 0xE000)
            else:
                before = [m for m in markers if m.start() < value.start()]
                if not before:
                    continue
                source = str(ord(before[-1].group(0)) - 0xE000)
            owner.setdefault(value.group(0), set()).add(source)
        for value, sources in sorted(owner.items()):
            if len(value) < 2 or YEAR.fullmatch(value) or "." in value:
                continue  # a year or a version number is not the value under dispute
            if all(YEAR.fullmatch(p) for p in re.findall(r"\d+", value)):
                continue  # a range of years is not a value under dispute either
            if len(sources) > 1:
                warnings.append(f"disagreement paragraph {number}: the value {value} is named "
                                f"for sources {sorted(sources)}; check that they really differ")


def check_open_questions(body, pages, errors):
    """A "the sources say nothing" sentence must survive a search over all saved pages.

    The claim can stand before the phrase ("to X the sources say nothing") or after it
    ("the sources say nothing about X"); both sides are looked for in every saved page as
    a run of four consecutive words, one of them at least six letters long. A hit means
    the point may well stand in a source that was read.
    """
    for number, block in enumerate(paragraphs_of(body), 1):
        plain = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block))
        for sentence in check_article.split_sentences(plain):
            match = NO_SOURCE_SENTENCE.search(sentence)
            if not match:
                continue
            # The claim reaches to the end of its clause: a follow-up clause after a
            # semicolon often names the sources that carry the point, not the point itself.
            for part in (sentence[:match.start()], sentence[match.end():].split(";")[0]):
                words = tokens(part)
                if len(words) < 4:
                    continue
                for at in range(len(words) - 3):
                    run = words[at:at + 4]
                    if not any(len(w) >= 6 for w in run):
                        continue
                    for name, _, _, page_words in pages:
                        if find_tokens(page_words, run) >= 0:
                            errors.append(f"paragraph {number}: \"the sources say nothing\", but "
                                          f"{name} carries {run}; check the pages")
                            return


def check_primary_quotes(body, entries, pages, errors, max_words):
    """A quote must come from the work itself when a primary page of the run carries it."""
    for number, block in enumerate(paragraphs_of(body), 1):
        numbers = {int(n) for n, _ in LINK_RE.findall(block)}
        if not numbers:
            continue
        kinds = {entry_parts(entries.get(n, ""))[2] for n in numbers}
        if not kinds or "primary" in kinds or kinds == {""}:
            continue
        for quote in QUOTE_RE.findall(re.sub(r"<!--.*?-->", " ", block)):
            if len(tokens(quote)) < max_words:
                continue
            needle = normalize(quote)
            for name, page_type, hay, _ in pages:
                if page_type != "primary" or needle not in hay:
                    continue
                errors.append(f"paragraph {number}: the quote {quote[:40]!r} stands word for word "
                              f"in the primary page {name}; take the wording from there")
                break


def check_cut_quotes(body, lang, errors, warnings):
    """A quote that ends on a function word is a cut sentence."""
    hard = HARD_TAIL.get(lang, HARD_TAIL["en"])
    soft = SOFT_TAIL.get(lang, SOFT_TAIL["en"])
    for number, block in enumerate(paragraphs_of(body), 1):
        for quote in QUOTE_RE.findall(re.sub(r"<!--.*?-->", " ", block)):
            words = tokens(quote)
            if len(words) < 2:
                continue
            last = words[-1].casefold().strip(".,;:!?")
            closed = quote.rstrip()[-1:] in SENTENCE_END
            if closed:
                continue  # the quote carries the source sentence's own end
            elif last in hard:
                errors.append(f"paragraph {number}: the quote {quote[:40]!r} ends on {last!r}; "
                              f"the sentence is cut")
            elif last in soft:
                warnings.append(f"paragraph {number}: the quote {quote[:40]!r} ends on {last!r} "
                                f"without the sentence's own end; check for a cut")


def check_lowered_quotes(body, pages, warnings):
    """A lowered first letter changes the quote: a page carrying only the upper-case
    wording proves the adaptation. The lower-case wording may stand mid-sentence in the
    page (the usual, correct way to integrate a quote), then nothing is reported."""
    for number, block in enumerate(paragraphs_of(body), 1):
        for quote in QUOTE_RE.findall(re.sub(r"<!--.*?-->", " ", block)):
            letters = [ch for ch in quote if ch.isalpha()]
            if len(letters) < 2 or not letters[0].islower():
                continue
            at = quote.index(letters[0])
            raised = quote[:at] + letters[0].upper() + quote[at + 1:]
            needle, needle_up = normalize(quote), normalize(raised)
            for name, _, hay, _ in pages:
                if needle not in hay and needle_up in hay:
                    warnings.append(f"paragraph {number}: the quote {quote[:40]!r} stands only "
                                    f"with an upper-case first letter in {name}; the quote may "
                                    f"have been adapted")
                    break


def check_work_notes(body, errors):
    folded = body.casefold()
    for phrase in WORK_NOTES:
        if phrase in folded:
            errors.append(f"work notes in the text: {phrase!r}")


def check_attribution_years(body, entries, today, warnings):
    """A year named next to a source must match the year of its list entry."""
    attribution = re.compile(r"(?i)(von|aus dem jahr|stand|im jahr|jahr|seit)\s+((?:19|20)\d\d)")
    for number, block in enumerate(paragraphs_of(body), 1):
        links = LINK_RE.findall(block)
        if len(links) != 1:
            continue
        cited = int(links[0][0])
        _, years, _ = entry_parts(entries.get(cited, ""))
        if not years:
            continue
        for match in attribution.finditer(LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block))):
            year = int(match.group(2))
            if year not in years and year <= today.year:
                warnings.append(f"paragraph {number}: the text says {match.group(0)!r} for [{cited}], "
                                f"whose entry names {years}")
                break


def check_old_numbers(body, entries, today, warnings):
    """A number from a source older than two years needs the year in the text."""
    for number, block in enumerate(paragraphs_of(body), 1):
        links = LINK_RE.findall(block)
        if len(links) != 1:
            continue
        cited = int(links[0][0])
        _, years, _ = entry_parts(entries.get(cited, ""))
        if not years or max(years) > today.year - 2:
            continue
        plain = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block))
        if not VALUE_RE.search(plain) or YEAR.search(plain):
            continue
        warnings.append(f"paragraph {number}: numbers from [{cited}] ({max(years)}) without a year "
                        f"in the text")


def check_source_types(entries, errors):
    """One website keeps one source type across the list (platforms excepted)."""
    by_domain = {}
    for number, rest in entries.items():
        domain, _, kind = entry_parts(rest)
        if domain and kind:
            by_domain.setdefault(domain, {}).setdefault(kind, []).append(number)
    for domain, kinds in sorted(by_domain.items()):
        if len(kinds) > 1 and domain not in MIXED_TYPE_SITES:
            errors.append(f"the website {domain} carries two source types: "
                          + ", ".join(f"{k} {sorted(v)}" for k, v in sorted(kinds.items())))


# A "not yet"/"noch nicht" statement about a capability reads as the state today. Without a
# year in its paragraph it cannot be told apart from an old statement; the reader is told to
# check today's state and to present older statements as "then/today" (standard section 7).
NOT_YET_RE = re.compile(r"(?i)\bnot\s+yet\b|\bnoch\s+nicht\b")
ABILITY_RE = re.compile(
    r"(?i)(support\w*|unterstütz\w*|work\w*|funktionier\w*|runs?\b|läuft|lauf\w*"
    r"|available|verfügbar|possible|möglich|compatib\w*|kompatibel|usable|nutzbar)")


def check_stale_claims(body, errors):
    """A "not yet" claim needs its year in the text (and a check of the state today)."""
    for number, block in enumerate(paragraphs_of(body), 1):
        plain = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block))
        if YEAR.search(plain):
            continue  # the paragraph names a year; the statement carries its date
        for sentence in check_article.split_sentences(plain):
            if NOT_YET_RE.search(sentence) and ABILITY_RE.search(sentence):
                errors.append(
                    f"paragraph {number}: the \"not yet\" claim needs its date in the text and "
                    f"a check of the state today; present an older statement as then/today, "
                    f"never as a current disagreement")
                break


# A sentence that calls the answer language absent ("no German voice", "the sources say
# nothing about German") is checked against the saved pages and the note's own text: a
# language list there is an answer to the claim. The gap pass of standard section 2 runs in
# the answer language for language, text and translation questions.
LANGUAGE_WORDS = {
    "de": ("deutsch", "deutschen", "deutsche", "deutscher", "german"),
    "en": ("englisch", "englische", "englischen", "english"),
    "ar": ("arabisch", "arabische", "arabischen", "arabic"),
}
ABSENCE_RE = re.compile(
    r"(?i)\b(kein\w*|nicht\w*|nichts|ohne|nie|no|not|none|without|lack\w*|fehlt|fehlen|never)\b")
VOICE_CONTEXT_RE = re.compile(
    r"(?i)(support\w*|unterstütz\w*|languag\w*|voice\w*|speech|\btts\b|\basr\b"
    r"|sprachen\b|stimme\w*|stimmen|sprecher\w*|dub\w*|klon\w*)")
# "sprach\w*" is not on the list on purpose: "in der Deutschen Sprache" is prose about
# language, not an offer that lists a language (wrong finding on the Taqwa note).


def absence_near(sentence, words):
    """The absence word stands close to the language word; a "nicht" far away says
    nothing about the language."""
    for word in words:
        at = sentence.find(word)
        while at >= 0:
            for m in ABSENCE_RE.finditer(sentence):
                if abs(m.start() - (at + len(word))) <= 80:
                    return True
            at = sentence.find(word, at + 1)
    return False


def in_voice_context(text, word):
    """The language word stands in a language or voice context somewhere in the text."""
    at = text.find(word)
    while at >= 0:
        window = text[max(0, at - 150):at + 150]
        if VOICE_CONTEXT_RE.search(window):
            return True
        at = text.find(word, at + 1)
    return False


def check_language_absence(body, lang, pages, errors):
    """"No <answer language> voice" claims fall against the pages and the note's own text."""
    words = LANGUAGE_WORDS.get(lang)
    if not words:
        return
    blocks = paragraphs_of(body)
    for number, block in enumerate(blocks, 1):
        plain = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block)).casefold()
        hit = None
        for sentence in check_article.split_sentences(plain):
            if any(w in sentence for w in words) and absence_near(sentence, words):
                hit = sentence
                break
        if not hit:
            continue
        reported = False
        for name, _kind, clean, _words in pages:
            low = clean.casefold()
            if any(in_voice_context(low, w) for w in words):
                errors.append(
                    f"paragraph {number}: the sentence calls {words[0]!r} absent, but the "
                    f"saved page {name} carries it in a language or voice context; the gap "
                    f"pass belongs in the answer language (standard section 2)")
                reported = True
                break
        if reported:
            continue
        for other_nr, other in enumerate(blocks, 1):
            if other_nr == number:
                continue
            low = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", other)).casefold()
            if any(in_voice_context(low, w) for w in words):
                errors.append(
                    f"paragraph {number}: the sentence calls {words[0]!r} absent, but the "
                    f"note's own text (paragraph {other_nr}) carries it in a language or "
                    f"voice context; check the claim against the text")
                break


# A German note keeps English wording inside quotes (with a translation). A run of four or
# more English-looking words in the running text is a leftover of the source wording
# (correction order part 2, item 7; standard section 4).
EN_FUNCTION = {
    "the", "a", "and", "or", "but", "of", "to", "with", "for", "from", "by", "is",
    "are", "were", "been", "being", "this", "these", "those", "that", "it", "its", "as",
    "not", "no", "you", "your", "we", "our", "they", "their", "can", "would", "should",
    "does", "do", "did", "has", "have", "had", "if", "when", "where", "which", "who",
    "what", "how", "than", "then", "only", "more", "most", "such", "into", "over", "under",
    "between", "without", "within",
}
# Words that also exist in German ("was", "will", "also", "in", "an", "man") stay out of the
# English list, and German function words end a run: a run with a German function word is
# German text, not a leftover.
DE_FUNCTION = {
    "der", "die", "das", "den", "dem", "des", "und", "oder", "aber", "dass", "weil", "ein",
    "eine", "einen", "einem", "einer", "ist", "sind", "war", "waren", "wird", "werden",
    "wurde", "wurden", "für", "mit", "von", "zu", "zum", "zur", "im", "in", "am", "als",
    "auch", "nicht", "kein", "keine", "keinen", "keinem", "keiner", "sich", "sowie", "beim",
    "bei", "nach", "aus", "durch", "über", "unter", "vor", "zwischen", "noch", "nur", "wie",
    "wenn", "dann", "damit", "diese", "dieser", "dieses", "diesem", "diesen", "kann",
    "können", "muss", "müssen", "soll", "sollen", "hat", "haben", "hatte", "hatten", "es",
    "sie", "ihre", "ihrer", "ihrem", "ihren", "seine", "seiner", "seinem", "seinen", "sein",
    "etwa", "rund", "mehr", "meisten", "jedoch", "denn", "doch", "hier", "dort", "ohne",
    "gegen", "seit", "bis", "vom", "beim", "würde", "würden", "man",
    # Frequent German content words break a run as well: "bündelt 16 TTS and ..." must not
    # read as an English run because of the one German word in front of it.
    "an", "auf", "nennt", "nutzt", "umfasst", "alles", "fehl", "fehlen", "fehlt", "zeigt",
    "zeigen", "bietet", "bieten", "steht", "stehen", "gibt", "geben", "macht", "machen",
    "lässt", "lassen", "bleibt", "bleiben", "gehört", "gehören", "gilt", "gelten", "findet",
    "finden", "wirkt", "wirken", "läuft", "laufen", "geht", "gehen", "kommt", "kommen",
    "liefert", "liefern", "sorgt", "sorgen", "liegt", "liegen", "dauert", "kostet",
    "braucht", "brauchen", "benötigt", "verwendet", "verwenden", "baut", "bauten", "setzt",
    "setzen", "empfiehlt", "erlaubt", "unterstützt", "unterstützen", "beschreibt",
    "beschreiben", "bezeichnet", "heißt", "heißen", "zählt", "zählen", "enthält",
    "enthalten", "außerdem", "zudem", "allerdings", "hingegen", "dagegen", "damals",
    "heute", "aktuell", "derzeit", "bisher", "zuletzt", "zuerst", "danach", "vorher",
    "später", "früher", "bereits", "schon", "oft", "selten", "kaum", "fast", "circa",
    "ungefähr", "deshalb", "darum", "daher", "inzwischen", "mittlerweile",
    "um", "ab", "je",
    # "deutsch" does not end in "-isch", so name the family here too (identifiers like
    # CUBLAS_STATUS_NOT_SUPPORTED stay one token through the underscore).
    "deutsch", "deutsche", "deutschen", "deutscher", "deutsches", "status",
}
# German word endings that make a word ineligible for an English run (the word is German
# morphology even without an umlaut: "Projektbeschreibung").
DE_SUFFIX = ("ung", "keit", "heit", "lich", "isch", "schaft", "chen", "tum", "sam")
# One letter ("L 34 a") proves nothing on its own: it counts only together with an
# English-looking word ("roughly 20 commits a day", "2.5 M downloads a month").
EN_WEAK = {"a"}
EN_SUFFIX = ("ly", "th", "ing", "tion", "sion", "ity", "ment", "ness", "ous", "ive",
             "able", "ible", "ance", "ence")
WORD_TOKEN_RE = re.compile(
    r"[0-9]+(?:[.,][0-9]+)*|[^\W\d_](?:[^\W\d_]|['_-])*", re.UNICODE)


def english_run_token(word):
    """True when the word can be part of an English run inside a German text."""
    if word[0].isdigit():
        return True
    if not word.isascii():
        return False  # umlauts and diacritics: Arabic transliteration, not English text
    folded = word.casefold()
    if folded in DE_FUNCTION or any(folded.endswith(s) for s in DE_SUFFIX):
        return False
    return True


def check_foreign_runs(body, lang, errors):
    """An English run of four or more words in the German running text (outside quotes)."""
    if lang != "de":
        return
    for number, block in enumerate(paragraphs_of(body), 1):
        masked = re.sub(r"<!--.*?-->", " ", block)
        masked = QUOTE_RE.sub(lambda m: " " * len(m.group(0)), masked)
        masked = LINK_RE.sub(" ", masked)
        words = WORD_TOKEN_RE.findall(masked)
        run = []
        for word in words + ["."]:
            if word != "." and english_run_token(word):
                run.append(word)
                continue
            if len(run) >= 4:
                folded = [w.casefold() for w in run]
                strong = any(w in EN_FUNCTION and w not in EN_WEAK for w in folded)
                weak = any(w in EN_WEAK for w in folded)
                if strong or (weak and any(w.endswith(EN_SUFFIX) for w in folded)):
                    shown = " ".join(run[:10]) + ("..." if len(run) > 10 else "")
                    errors.append(
                        f"paragraph {number}: the English run {shown!r} stands in the "
                        f"German text without quotes; quote it with a translation or turn "
                        f"it into German")
            run = []


# Star counts, downloads and similar GitHub numbers change with the time; two different
# values are no disagreement but two reading dates (correction order part 2, item 9;
# standard section 10.5). Only a number near such a word counts - "Windows-Fork" alone is
# an ordinary word, not a reading.
TIME_WORD = (r"(?:sterne?n?zahlen?|sterns?zahl\w*|stars?|forks?|watchers?|downloads?"
             r"|abrufe?|aufrufe?|installations?zahlen?)")
TIME_VARYING_RE = re.compile(
    r"(?i)(?:" + TIME_WORD + r"\b\s*[:=]?\s*\+?\s*\d[\d.,]*"
    r"|\d[\d.,]*\s*\+?\s*(?:\w+\s+){0,2}" + TIME_WORD + r"\b)")


def check_time_varying_disagreement(body, errors):
    """Stars/downloads/version numbers in a disagreement paragraph form no disagreement."""
    for number, block in enumerate(section_paragraphs(body, DISAGREE_HEAD), 1):
        plain = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", block))
        match = TIME_VARYING_RE.search(plain)
        if not match or YEAR.search(plain):
            continue
        errors.append(
            f"disagreement paragraph {number}: {match.group(0)!r} changes with time and "
            f"forms no disagreement; name the number with the date it was read, or leave it "
            f"out of the section")


# New notes are checked against the existing notes about the same tools (correction order
# part 2, item 10; standard section 12): a version that differs from another note's version
# is a finding.
BINNEN_RE = re.compile(
    r"\b[a-zäöü][A-Za-zÄÖÜäöü0-9]*[A-ZÄÖÜ][A-Za-zÄÖÜäöü0-9]*\b"
    r"|\b[A-ZÄÖÜ][a-zäöü]+[A-ZÄÖÜ][A-Za-zÄÖÜäöü0-9]*\b")
VERSION_RE = re.compile(r"\bv(\d+(?:\.\d+)+)\b", re.I)
CROSS_NAME_SKIP = {"github", "gitlab", "youtube"}
# A version right after a licence name is the licence's version, not the tool's
# ("GNU General Public License v3.0" says nothing about pyVideoTrans' own version).
LICENSE_NEAR_RE = re.compile(r"(?i)(licen[cs]e|lizenz|gpl)")


def version_pairs(text):
    """{tool name folded: {versions}} from the running text; names carry a capital inside."""
    pairs = {}
    body, _ = check_article.split_article(text)
    plain = LINK_RE.sub(" ", re.sub(r"<!--.*?-->", " ", body))
    for sentence in check_article.split_sentences(plain):
        versions = set()
        for m in VERSION_RE.finditer(sentence):
            # Licence words stand before the version ("... License v3.0"); a word right
            # after it ("v4.08, GPL-3.0") says nothing about that version.
            if LICENSE_NEAR_RE.search(sentence[max(0, m.start() - 40):m.start()]):
                continue
            versions.add(m.group(1))
        if not versions:
            continue
        for name in BINNEN_RE.findall(sentence):
            key = name.casefold()
            if key in CROSS_NAME_SKIP:
                continue
            pairs.setdefault(key, set()).update(versions)
    return pairs


def check_cross_notes(body, note_path, other_notes, errors):
    """Versions of the same named tool must not differ between two notes of this vault."""
    own = version_pairs(body)
    if not own:
        return
    self_path = Path(note_path).resolve()
    for path in sorted(Path(other_notes).glob("*.md")):
        if path.resolve() == self_path:
            continue
        try:
            other = version_pairs(path.read_text(encoding="utf-8"))
        except OSError:
            continue
        for name in sorted(set(own) & set(other)):
            here, there = own[name], other[name]
            if here and there and here.isdisjoint(there):
                errors.append(
                    f"the version of {name} differs from {path.name}: "
                    f"v{', v'.join(sorted(here))} here, v{', v'.join(sorted(there))} there; "
                    f"check the notes against each other")


def run(note_path, pages_dir, lang, today, max_words, other_notes=""):
    text = Path(note_path).read_text(encoding="utf-8")
    body, refs_block = check_article.split_article(text)
    errors, warnings = [], []
    entries = {int(n): rest for n, rest in ENTRY_RE.findall(refs_block or "")}
    if refs_block is None:
        errors.append("no reference list")
    check_article.check_references(body, refs_block, errors, warnings)
    check_article.check_number_groups(body, errors)
    check_article.check_fragments_in_pages(body, Path(pages_dir).parent, errors, warnings)
    check_article.check_spelling_variants(body, warnings)
    check_article.check_translations("note", body, None, {}, lang, errors)
    pages, _ = page_index(pages_dir)
    sections = paragraphs_of(body)
    keep = []
    skipping = False
    for block in sections:
        heading = re.match(r"\s*#{1,6}\s+(.*)", block)
        if heading:
            skipping = any(heading.group(1).strip().lower().startswith(s) for s in SKIP_SECTIONS)
        if not skipping:
            keep.append(block)
    body_checked = "\n\n".join(keep)
    check_disagreement(body_checked, errors, warnings)
    check_open_questions(body_checked, pages, errors)
    check_primary_quotes(body_checked, entries, pages, errors, max_words)
    check_cut_quotes(body_checked, lang, errors, warnings)
    check_lowered_quotes(body_checked, pages, warnings)
    check_work_notes(body_checked, errors)
    check_attribution_years(body_checked, entries, today, warnings)
    check_old_numbers(body_checked, entries, today, warnings)
    check_source_types(entries, errors)
    check_stale_claims(body_checked, errors)
    check_language_absence(body_checked, lang, pages, errors)
    check_foreign_runs(body_checked, lang, errors)
    check_time_varying_disagreement(body_checked, errors)
    if other_notes:
        check_cross_notes(body_checked, note_path, other_notes, errors)
    return errors, warnings


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("note")
    parser.add_argument("--pages", required=True)
    parser.add_argument("--lang", required=True)
    parser.add_argument("--today", default=date.today().isoformat())
    parser.add_argument("--max-quote-words", type=int, default=5)
    parser.add_argument("--other-notes", default="",
                        help="folder with other notes of this vault (version cross-check)")
    args = parser.parse_args(argv)
    utf8_output()
    try:
        today = date.fromisoformat(args.today)
        errors, warnings = run(args.note, args.pages, args.lang, today, args.max_quote_words,
                               args.other_notes)
    except (OSError, ValueError) as exc:
        print(f"ERROR {exc}")
        return 1
    for line in warnings:
        print("WARNING", line)
    for line in errors:
        print("ERROR", line)
    print(f"SUMMARY errors={len(errors)} warnings={len(warnings)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
