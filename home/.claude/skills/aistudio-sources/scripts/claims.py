"""One parser for claims and citation groups.

Both check_sources.py and correct_sources.py use this module. A sentence ends at `.`, `!` or
`?` even when one or more citation markers follow the punctuation. The parser works on a masked
copy of the line: every marker is replaced by spaces of the same length, so offsets stay those
of the real text while the punctuation stays visible.

The same module also extracts every factual statement for the minimal-edit step (Part 4):
sentences, list items, table cells (with row label and column header) and block quotes, cited or
not. Each statement keeps its exact character span in the file and a self-contained form for
checking, with a leading pronoun resolved from the section heading and the previous sentence.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".claude" / "skills" / "research" / "scripts"))
from common import normalize, plain_markdown  # noqa: E402

CITE_ANY = re.compile(r"\[\[(\d+)\]\((https?://[^)\s]+)\)\]|\[(\d+)\]\((https?://[^)\s]+)\)")
PLAIN_CITE = re.compile(r"(?<!\[)\[(\d+)\](?!\()")
ABBR = re.compile(r"(?:(?:z\.\s?B|bzw|ca|vgl|vs|evtl|ggf|inkl|max|min|Nr|Dr|Prof|Mio|Mrd|Std|"
                  r"(?-i:S))\.?$)", re.I)
BOUNDARY = re.compile(r"(?<=[.!?])\s+(?=[A-ZÄÖÜ„\"(])")
HEADING = re.compile(r"^#{1,6}\s+(.*)$")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+")
TABLE_SEP = re.compile(r"^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$")
OPINION = re.compile(
    r"\b(?:meiner meinung|meiner einschätzung|ich empfehle|empfehlenswert|lohnt sich|"
    r"ist besser|am besten|beste wahl|sollte man|würde ich|ist vorzuziehen|ratsam|"
    r"fazit|insgesamt|aus meiner sicht)\b", re.I)
PRONOUN = re.compile(r"^(Es|Er|Sie|Das|Dies|Diese|Dieser|Dabei|Dort|Damit)\b", re.I)
DETERMINERS = {"der", "die", "das", "ein", "eine", "einer", "eines", "dem", "den", "des",
               "dieser", "diese", "dieses", "es", "er", "sie", "wir", "ich", "man"}


def mask_citations(text):
    """The same text with every citation marker replaced by spaces of equal length."""
    return CITE_ANY.sub(lambda m: " " * len(m.group(0)), text)


def clean_text(text):
    text = CITE_ANY.sub("", text)
    text = PLAIN_CITE.sub("", text)
    text = plain_markdown(text)
    text = re.sub(r"^\s*>+\s*", "", text)
    text = re.sub(r"^\s*(?:[-*+]|\d+\.)\s+", "", text)
    return re.sub(r"\s+", " ", text).strip()


def sentence_spans(text):
    """(start, end) of every sentence in text, with trailing markers inside the sentence."""
    masked = mask_citations(text)
    cuts = [0]
    for m in BOUNDARY.finditer(masked):
        before = masked[cuts[-1]:m.start()].rstrip()
        if ABBR.search(before):
            continue
        cuts.append(m.end())
    cuts.append(len(text))
    spans = []
    for a, b in zip(cuts, cuts[1:]):
        while a < b and text[a].isspace():
            a += 1
        while b > a and text[b - 1].isspace():
            b -= 1
        if b > a:
            spans.append((a, b))
    return spans


def sentences(text):
    return [text[a:b] for a, b in sentence_spans(text)]


def marker_numbers(text):
    out = []
    for a, b, c, d in CITE_ANY.findall(text):
        out.append(int(a) if a else int(c))
    out += [int(x) for x in PLAIN_CITE.findall(CITE_ANY.sub("", text))]
    return out


def number_urls(text):
    out = []
    for a, b, c, d in CITE_ANY.findall(text):
        out.append((int(a), b) if a else (int(c), d))
    return out


def table_cells(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [p.strip().replace("\\|", "|") for p in re.split(r"(?<!\\)\|", s)]


def cell_spans(line):
    """(start, end) of each table cell's content in the original line, empty cells dropped."""
    pipes = [m.start() for m in re.finditer(r"(?<!\\)\|", line)]
    bounds = [-1] + pipes + [len(line)]
    spans = []
    for a, b in zip(bounds, bounds[1:]):
        start, end = a + 1, b
        while start < end and line[start].isspace():
            start += 1
        while end > start and line[end - 1].isspace():
            end -= 1
        if end > start:
            spans.append((start, end))
    return spans


def statement_for(line, pos, table_label=""):
    """The full sentence that carries a marker at pos, cleaned; table cells get their label."""
    stripped = line.lstrip()
    quote_prefix = stripped.startswith(">")
    content = line
    if quote_prefix:
        content = re.sub(r"^\s*>\s?", "", line)
        pos = max(0, pos - (len(line) - len(content)))
    if table_label:
        spans = cell_spans(content)
        for a, b in spans:
            if a <= pos <= b:
                cell = content[a:b]
                cell_start = pos - a
                for sa, sb in sentence_spans(cell):
                    if sa <= cell_start <= sb:
                        return _with_label(table_label, clean_text(cell[sa:sb]))
                return _with_label(table_label, clean_text(cell))
    spans = sentence_spans(content)
    for a, b in spans:
        if a <= pos <= b:
            return clean_text(content[a:b])
    previous = [s for s in spans if s[1] <= pos]
    if previous:
        return clean_text(content[previous[-1][0]:previous[-1][1]])
    return clean_text(content[:pos])


def _with_label(label, text):
    if not text:
        return text
    if label and not text.startswith(label):
        return label + ": " + text
    return text


def extract_claims(body, sources):
    """All (claim, source number) pairs in document order, duplicates removed."""
    number_url = {n: s["url"] for n, s in sources.items()}
    for m in CITE_ANY.finditer(body):
        n = int(m.group(1) or m.group(3))
        url = m.group(2) or m.group(4)
        number_url.setdefault(n, url)

    pairs, seen = [], set()
    duplicates = 0
    section = ""

    def add(line_no, sentence, numbers):
        nonlocal duplicates
        claim = clean_text(sentence)
        if not claim:
            return
        for n in numbers:
            key = (n, normalize(claim))
            if key in seen:
                duplicates += 1
                continue
            seen.add(key)
            pairs.append({"line": line_no, "number": n, "url": number_url.get(n, ""),
                          "claim": claim, "section": section})

    for line_no, line in enumerate(body.splitlines(), 1):
        stripped = line.strip()
        if not stripped or TABLE_SEP.match(stripped):
            continue
        h = HEADING.match(stripped)
        if h:
            section = h.group(1).strip()
            continue
        if stripped.startswith("|"):
            cells = table_cells(stripped)
            if not cells:
                continue
            label = clean_text(cells[0])
            for cell in cells[1:]:
                for sentence in sentences(cell):
                    numbers = marker_numbers(sentence)
                    if numbers:
                        add(line_no, _with_label(label, sentence), numbers)
            continue
        if stripped.startswith(">"):
            text = stripped.lstrip(">").strip()
            numbers = marker_numbers(text)
            if numbers:
                add(line_no, text, numbers)
            continue
        for sentence in sentences(stripped):
            numbers = marker_numbers(sentence)
            if numbers:
                add(line_no, sentence, numbers)
    return pairs, duplicates


def _entity(text):
    """The last name-like word of a text, used to resolve a leading pronoun."""
    words = re.findall(r"[A-ZÄÖÜ][\wÄÖÜäöüß.-]+", plain_markdown(text))
    for word in reversed(words):
        if word.casefold() not in DETERMINERS and len(word) > 2:
            return word
    return ""


def _resolve(text, entity):
    if not entity:
        return text
    m = PRONOUN.match(text)
    if not m:
        return text
    return entity + text[m.end():]


def _is_opinion(text):
    return bool(OPINION.search(text))


def _line_offsets(raw):
    offset = 0
    for line in raw.splitlines(keepends=True):
        yield offset, line.rstrip("\r\n")
        offset += len(line)


def statements(raw, body=None):
    """Every factual statement: sentences, list items, table cells, block quotes.

    Returns dicts with: sid, line, start, end, text, self_contained, numbers, section, kind,
    table (optional). `start`/`end` are character offsets into `raw` for the exact text.
    """
    if body is None:
        body = raw
    out = []
    section = ""
    entity = ""
    table_head = None
    in_fence = False
    lines = list(_line_offsets(raw))
    for index, (offset, line) in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or not stripped or TABLE_SEP.match(stripped):
            continue
        h = HEADING.match(stripped)
        if h:
            section = h.group(1).strip()
            entity = _entity(section) or entity
            table_head = None
            continue
        if stripped.startswith("|"):
            cells = table_cells(line)
            if index + 1 < len(lines) and TABLE_SEP.match(lines[index + 1][1].strip()):
                table_head = [clean_text(c) for c in cells]
                continue
            label = clean_text(cells[0]) if cells else ""
            for ci, (a, b) in enumerate(cell_spans(line)):
                if ci == 0:
                    continue
                text = clean_text(line[a:b])
                if not text:
                    continue
                header = table_head[ci] if table_head and ci < len(table_head) else ""
                prefix = ": ".join(x for x in (label, header) if x)
                item = {"line": index + 1, "start": offset + a, "end": offset + b,
                        "text": text, "numbers": marker_numbers(line[a:b]),
                        "section": section, "kind": "wertung" if _is_opinion(text) else "fact",
                        "table": {"label": label, "header": header}}
                item["self_contained"] = _with_label(prefix, text) if prefix else text
                out.append(item)
            continue
        if stripped.startswith(">"):
            start = offset + len(line) - len(line.lstrip())
            text = clean_text(line.lstrip().lstrip(">").strip())
            if text:
                item = {"line": index + 1, "start": start, "end": start + len(line.lstrip()),
                        "text": text, "numbers": marker_numbers(stripped),
                        "section": section, "kind": "wertung" if _is_opinion(text) else "fact"}
                item["self_contained"] = _resolve(text, entity)
                out.append(item)
                entity = _entity(text) or entity
            continue
        m = LIST_ITEM.match(line)
        if m:
            start = offset + m.end()
            text = clean_text(line[m.end():])
            if text:
                item = {"line": index + 1, "start": start, "end": offset + len(line),
                        "text": text, "numbers": marker_numbers(line[m.end():]),
                        "section": section, "kind": "wertung" if _is_opinion(text) else "fact"}
                item["self_contained"] = _resolve(text, entity)
                out.append(item)
                entity = _entity(text) or entity
            continue
        for a, b in sentence_spans(line):
            text = clean_text(line[a:b])
            if not text:
                continue
            item = {"line": index + 1, "start": offset + a, "end": offset + b,
                    "text": text, "numbers": marker_numbers(line[a:b]),
                    "section": section, "kind": "wertung" if _is_opinion(text) else "fact"}
            item["self_contained"] = _resolve(text, entity)
            out.append(item)
            entity = _entity(text) or entity
    for i, item in enumerate(out, 1):
        item["sid"] = "S%03d" % i
    return out
