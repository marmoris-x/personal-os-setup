"""AI-writing patterns that check_article.py looks for in the writer's own words.

Condensed from blader/humanizer (225a6f3) and marmbiz/humanizer-de (9248315); lists copied as
the repos give them, the English equivalents of the German connectors added by hand. Hits are
warnings: one hit is rarely a problem, a cluster is (see references/style-rules.md).
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
    "beleucht", "eintauch", "unterstreich", "aufzeig", "spannend", "entscheidend",
    "maßgeblich", "massgeblich", "nahtlos", "vielschichtig", "facettenreich", "dynamisch",
    "ganzheitlich", "maßgeschneidert", "massgeschneidert", "essenziell", "entfessel",
    "revolutionier", "zusammenspiel", "meilenstein", "spannungsfeld", "digitale landschaft",
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
    "steht als zeugnis für", "ist ein beweis für", "spielt eine wichtige rolle", "symbolisiert",
    "reiches kulturelles erbe", "atemberaubend", "spektakulär", "faszinierend", "einzigartig",
    "game-changer", "das ändert alles", "es ist wichtig zu bemerken", "es kann nicht ignoriert",
    "keine diskussion wäre vollständig", "es sollte hervorgehoben werden", "es ist erwähnenswert",
    "es ist wichtig zu beachten", "zu beachten ist, dass", "branchenberichte zeigen",
    "beobachter haben zitiert", "es wird gesagt", "manche argumentieren",
    "die eigentliche frage ist", "im kern", "in wirklichkeit", "was wirklich zählt",
    "im grunde genommen", "das tiefere problem", "worauf es wirklich ankommt",
    "der kern der sache", "letztlich geht es um", "so betrachtet", "schauen wir uns an",
    "lassen sie uns erkunden", "was sie wissen müssen", "die sache ist die",
    "ohne weitere umschweife", "jetzt werfen wir einen blick", "kommen wir zu",
    "warum das wichtig ist:", "das große bild", "es stellte sich heraus, dass",
    "aber was bedeutet das", "haben sie sich jemals gefragt", "doch was steckt dahinter",
    "was heißt das konkret", "seit jeher", "seit anbeginn der zivilisation",
    "schon immer hat die menschheit", "im laufe der geschichte", "seit menschengedenken",
    "in der heutigen digitalen welt", "in einer zunehmend vernetzten welt", "in zeiten von",
    "im zeitalter der digitalisierung", "in der heutigen schnelllebigen",
    "bestens aufgestellt", "die möglichkeiten sind grenzenlos", "bereit für die nächste stufe",
    "an der schwelle zu einer neuen ära", "die weichen sind gestellt",
    "mit zuversicht in die zukunft blicken", "das potenzial ist enorm", "auf erfolgskurs",
    "zweifellos", "grundlegend verändert", "hält sich bedeckt", "es ist anzunehmen, dass",
    "und zeigt damit, dass", "und unterstreicht die bedeutung", "ich hoffe, das hilft",
    "natürlich!", "gute frage", "wie sie sehen können", "lassen sie mich wissen",
    "selbstverständlich!", "du hast völlig recht", "sie haben völlig recht",
    "bis zu meinem letzten update", "nach meinem wissen", "als ki-sprachmodell",
    "was mich überrascht hat, war", "was am ende funktionierte, war", "was fehlte, war",
    "genauer gesagt", "präziser gesagt", "fairerweise muss man sagen",
    "eigentlich ist es komplizierter", "ehrlich gesagt", "keine sorge", "spoiler:",
    "fungiert als", "dient als", "verfügt über", "zeichnet sich", "erweist sich als",
    "in diesem text", "wie oben gezeigt",
]

# Mechanical connectors: one per paragraph is tolerated, more is a warning.
EN_CONNECTORS = ["additionally", "moreover", "furthermore"]
DE_CONNECTORS = [
    "darüber hinaus", "zudem", "außerdem", "ferner", "des weiteren", "des weiteren",
    "ebenfalls", "gleichzeitig", "überdies", "zusammenfassend", "abschließend",
    "insgesamt", "kurz gesagt", "im wesentlichen",
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
