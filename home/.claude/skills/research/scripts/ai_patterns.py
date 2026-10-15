"""AI-writing patterns that check_article.py looks for in the writer's own words.

The English lists are copied from blader/humanizer (commit 225a6f3, MIT). The German lists are
this repository's own: the German tells of the same kinds, selected and phrased here, copied
from no German source. Hits are warnings: one hit is rarely a problem, a cluster is
(see references/style-rules.md).
Text inside quotes and verbatim fragments is never checked.
"""

import re

# Words and stems. Matched case-insensitively at a word start; a trailing stem allows endings.
EN_WORDS = [
    "actually", "additionally", "align with", "bolstered", "crucial", "deep dive", "delve",
    "enduring", "enhance", "garner", "interplay", "intricate", "intricacies", "landscape",
    "meticulous", "meticulously", "pivotal", "quietly", "robust", "showcase", "tapestry",
    "testament", "underscore", "underscores", "underscored", "valuable", "vibrant",
]
DE_WORDS = [
    "atemberaubend", "aufzeig", "bahnbrechend", "beleucht", "einzigartig", "entfessel",
    "facettenreich", "faszinierend", "ganzheitlich", "hochkarätig", "hochmodern",
    "maßgeschneidert", "massgeschneidert", "meilenstein", "nahtlos", "revolutionier",
    "spannungsfeld", "spektakulär", "untermauer", "vielschichtig", "wegweisend",
    "zukunftsweisend", "zusammenspiel",
]

# Phrases, matched case-insensitively as written (spaces match any whitespace).
EN_PHRASES = [
    "this isn't about", "this isn't mainly about", "i'm not saying", "to be clear",
    "don't get me wrong", "this is not to say", "a tempting approach", "one might be tempted",
    "you might think", "let's dive in", "let's explore", "let's break this down",
    "here's what you need to know", "now let's look at", "without further ado",
    "here's the thing", "the thing is", "let's be honest", "real talk",
    "the real question is", "at its core", "what really matters", "the deeper issue",
    "the heart of the matter", "stands as a testament", "a pivotal moment", "plays a key role",
    "underscores its importance", "reflects a broader", "enduring legacy", "lasting legacy",
    "setting the stage for", "evolving landscape", "indelible mark", "the future looks bright",
    "exciting times ahead", "a step in the right direction", "serves as", "stands as",
    "functions as", "boasts", "experts argue", "observers have cited", "industry reports",
    "i hope this helps", "of course!", "certainly!", "great question", "you're absolutely right",
    "let me know", "as of my last", "up to my last training", "it is believed that",
    "in conclusion", "in summary", "moreover", "furthermore", "it is worth noting",
    "it's worth noting", "in today's digital", "this article will", "the table below",
]
DE_PHRASES = [
    "aber was bedeutet das", "als ki-sprachmodell", "als sprachmodell",
    "an dieser stelle sei erwähnt", "auf erfolgskurs", "auf ganzer linie",
    "beobachter haben", "bereit für die zukunft", "bestens aufgestellt",
    "branchenberichte zeigen", "das fazit:", "das ist der punkt", "das nonplusultra",
    "das wichtigste vorweg", "die möglichkeiten sind grenzenlos", "die sache ist die",
    "die tabelle unten", "die weichen sind gestellt", "die zukunft sieht rosig aus",
    "dient als", "digitale landschaft", "doch was steckt dahinter", "du hast völlig recht",
    "ein eindrucksvolles beispiel", "ein wahrer meilenstein", "ein wahrer segen",
    "eindrucksvoll unter beweis", "ehrlich gesagt", "eigentlich ist es komplizierter",
    "erweist sich als", "es bleibt spannend", "es ist erwähnenswert",
    "es ist wichtig zu beachten", "es ist wichtig zu bemerken", "es sei darauf hingewiesen",
    "es sollte hervorgehoben werden", "es wird allgemein angenommen",
    "experten sind sich einig", "fairerweise muss man sagen", "fungiert als",
    "genauer gesagt", "gerne!", "grenzenlose möglichkeiten", "gute frage",
    "haben sie sich jemals gefragt", "hand aufs herz", "hochkarätige besetzung",
    "ich hoffe, das hilft", "ich hoffe, das war hilfreich", "im folgenden abschnitt",
    "im laufe der geschichte", "im kern", "im zeitalter der digitalisierung",
    "in der heutigen digitalen welt", "in der heutigen schnelllebigen zeit",
    "in einer zunehmend vernetzten welt", "in diesem artikel", "in diesem text",
    "in zeiten des wandels", "innovative lösungen", "keine diskussion wäre vollständig",
    "kennen sie das gefühl", "kommen wir zu", "lassen sie mich wissen",
    "lassen sie uns einen blick", "läutet eine neue ära ein", "man darf gespannt sein",
    "man geht davon aus", "markiert einen wendepunkt", "maßgeschneiderte lösung",
    "massgeschneiderte lösung", "nahtlose integration", "nach meinem wissensstand",
    "natürlich!", "nicht mehr wegzudenken", "nicht unerwähnt bleiben soll",
    "nimmt eine schlüsselrolle ein", "ohne weitere umschweife", "präziser formuliert",
    "restlos überzeugen", "revolutionäre entwicklung", "schauen wir uns an", "sehr gerne",
    "seit jeher", "seit menschengedenken", "selbstverständlich!", "sie haben völlig recht",
    "spielt eine bedeutende rolle", "spielt eine zentrale rolle", "studien belegen",
    "sucht seinesgleichen", "um ehrlich zu sein", "und zeigt damit, dass", "unterm strich",
    "unterstreicht die bedeutung", "verfügt über", "verschiedene maßnahmen",
    "vielfältige möglichkeiten",
    "warum das wichtig ist:", "was am ende funktionierte, war", "was deutlich macht, wie",
    "was die bedeutung unterstreicht", "was du wissen musst", "was fehlte, war",
    "was heißt das konkret", "was mich überrascht hat, war", "was einmal mehr belegt",
    "was sie wissen müssen", "wie bereits erwähnt", "wie oben gezeigt",
    "wie sie sehen können", "wie wir gesehen haben", "wirft ein schlaglicht auf",
    "worauf es wirklich ankommt", "zahlreiche aspekte", "zeugt von einer neuen ära",
    "zeichnet sich durch",
    "zu beachten ist, dass", "zukunftsweisende technik", "zusammenfassend lässt sich sagen",
]

# Mechanical connectors: one per paragraph is tolerated, more is a warning.
EN_CONNECTORS = ["additionally", "moreover", "furthermore"]
DE_CONNECTORS = [
    "darüber hinaus", "außerdem", "zudem", "ferner", "des weiteren", "überdies",
    "zusammenfassend", "abschließend", "insgesamt", "kurz gesagt",
]

# Regular expressions: "not X but Y" and its German forms, tacked-on analysis, tool residue.
REGEXES = [
    ("not X but Y", r"\bnot (?:just|only|merely|simply)\b[^.;!?\n]{1,100}?\bbut\b"),
    ("not X but Y", r"\bnot\b[^.;!?\n]{1,60}?,\s*but\b"),
    ("not X but Y", r"\bit'?s not\b[^.;!?\n]{1,60}?,\s*it'?s\b"),
    ("not X but Y", r"\bisn'?t (?:just|merely|simply)\b"),
    ("not X but Y", r"\bnicht nur\b[^.;!?\n]{1,100}?\bsondern\b"),
    ("not X but Y", r"\bnicht\b[^.;!?\n]{1,60}?,\s*sondern\b"),
    ("not X but Y", r"\bweder\b[^.;!?\n]{1,60}?\bnoch\b"),
    ("not X but Y", r"\bkein(?:e|en|em|er)?\b[^.\n]{1,40}\.\s+Sondern\b"),
    ("not X but Y", r"\bweniger\b[^.;!?\n]{1,60}?\bals vielmehr\b"),
    ("tacked-on analysis", r",\s*was \w+ (?:unterstreicht|belegt|verdeutlicht|bestätigt|beweist)\b"),
    ("tacked-on analysis", r",\s*(?:highlighting|underscoring|emphasizing|showcasing|symbolizing)\b"),
    ("tool residue", r"oaicite|contentReference|turn\d+search\d+|utm_source=chatgpt\.com|\[cite: ?\d+\]"),
]


def _phrase_regex(phrase):
    return re.escape(phrase).replace(r"\ ", r"\s+")


def _word_regex(word):
    return r"(?<!\w)" + _phrase_regex(word) + r"\w*"


def compile_patterns():
    """Return (name, compiled regex, kind) triples. kind is 'word', 'phrase', 'connector' or 'regex'."""
    flags = re.IGNORECASE | re.UNICODE
    out = []
    for w in EN_WORDS + DE_WORDS:
        out.append((w, re.compile(_word_regex(w), flags), "word"))
    for p in EN_PHRASES + DE_PHRASES:
        out.append((p, re.compile(r"(?<!\w)" + _phrase_regex(p), flags), "phrase"))
    for c in sorted(set(EN_CONNECTORS + DE_CONNECTORS)):
        out.append((c, re.compile(r"(?<!\w)" + _phrase_regex(c) + r"(?!\w)", flags), "connector"))
    for name, rx in REGEXES:
        out.append((name, re.compile(rx, flags), "regex"))
    return out
