"""Minimal, checked corrections of the answer text (Part 4).

An agent proposes one edit per statement; this module guards the edit in code. Nothing is
rewritten in free form: only the statement's own span changes, the new text must be backed by a
word-for-word quote from the saved page, and every number, version, date or proper name that is
new must occur in that quote. Deletions remove a whole sentence, list item or table cell.
"""

import difflib
import re
from pathlib import Path

import check_sources as cs
import fix_quotes as fq

COMMON_CAP = {"der", "die", "das", "ein", "eine", "einer", "eines", "dem", "den", "des",
              "dieser", "diese", "dieses", "es", "er", "sie", "wir", "ich", "man",
              "aber", "auch", "damit", "dabei", "dort", "hier", "wenn", "weil", "und"}
GERMAN = {"der", "die", "das", "und", "ist", "sind", "auf", "mit", "von", "für", "im",
          "den", "dem", "ein", "eine", "zu", "wird", "werden", "nicht", "auch"}


def _words(text):
    return [w.casefold() for w in fq.tokens(text)]


def _is_number(token):
    return bool(re.search(r"\d", token))


def _proper_name(token):
    return token[:1].isupper() and token.casefold() not in COMMON_CAP


def looks_german(text):
    return any(w in GERMAN for w in _words(text))


def validate_edit(statement, old, new, quote, page_body, language="de"):
    """(ok, reason). `statement` is the whole statement, `old`/`new` the changed span."""
    if not statement or not old or not new:
        return False, "leerer Text"
    length = cs.quote_length_state(quote)
    if length != "ok":
        return False, cs.EVIDENCE_LABEL.get(length, length)
    if not cs.locate_quote(page_body, quote, 0):
        return False, "Beleg nicht gefunden"
    limit = min(50, max(1, len(statement) // 2))
    if len(new) > limit:
        return False, "Ersatz zu lang (%d Zeichen, erlaubt %d)" % (len(new), limit)
    old_words = _words(statement)
    quote_words = set(_words(quote))
    for token in fq.tokens(new):
        word = token.casefold()
        if word in old_words:
            continue
        if _is_number(token) or _proper_name(token):
            if word not in quote_words:
                return False, "Name oder Zahl nicht im Beleg: %s" % token
    if language.startswith("de") and re.search(r"[A-Za-zÄÖÜäöü]", new):
        if looks_german(statement) and not looks_german(new):
            return False, "neuer Text ist nicht deutsch"
    return True, ""


def _line_bounds(raw, start):
    left = raw.rfind("\n", 0, start) + 1
    right = raw.find("\n", start)
    if right < 0:
        right = len(raw)
    return left, right


def _whole_line(raw, start, end):
    left, right = _line_bounds(raw, start)
    return (raw[left:start].strip() == "" and raw[end:right].strip() == "")


def apply_decisions(raw, decisions):
    """Apply validated replace/delete spans; return (new text, changes, rejected)."""
    rejected, clean = [], []
    for d in decisions:
        action = d.get("action")
        try:
            start, end = int(d["start"]), int(d["end"])
        except (KeyError, TypeError, ValueError):
            rejected.append({**d, "reason": "keine Spanne"})
            continue
        if start < 0 or end < start or end > len(raw):
            rejected.append({**d, "reason": "Spanne außerhalb des Textes"})
            continue
        if action not in ("replace", "delete"):
            rejected.append({**d, "reason": "unbekannte Aktion"})
            continue
        if action == "replace" and not d.get("new"):
            rejected.append({**d, "reason": "Ersatz fehlt"})
            continue
        clean.append((start, end, d))
    clean.sort(key=lambda x: x[0], reverse=True)
    out = raw
    changes = 0
    for start, end, d in clean:
        if d["action"] == "replace":
            out = out[:start] + d["new"] + out[end:]
        else:
            left, right = _line_bounds(out, start)
            if _whole_line(out, start, end):
                if right < len(out):
                    out = out[:left] + out[right + 1:]
                else:
                    out = out[:left].rstrip("\r\n") + ("\r\n" if out[:left].endswith("\r\n") else "")
            elif "|" in out[left:right]:
                out = out[:start] + "—" + out[end:]
            else:
                before = out[:start].rstrip(" \t")
                after = out[end:].lstrip(" \t")
                out = before + (" " if before and after else "") + after
        changes += 1
    return out, changes, rejected


def _offsets(lines):
    out, pos = [], 0
    for line in lines:
        out.append(pos)
        pos += len(line)
    return out


def _line_of(offsets, pos):
    lo, hi = 0, len(offsets) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if offsets[mid] <= pos:
            lo = mid
        else:
            hi = mid - 1
    return lo


def skeleton(line):
    body = line.rstrip("\r\n")
    prefix = re.match(r"^(\s*)(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)?", body)
    lead, mark = prefix.group(1), prefix.group(2) or ""
    return (len(lead), mark.strip(), body.count("|"), body.count("**"),
            body.count("`"), body.count("]("))


def format_check(original, edited, spans):
    """(ok, reasons): every line outside an edited span is byte-identical."""
    reasons = []
    if original.endswith("\r\n") != edited.endswith("\r\n") and (
            original.endswith("\n") != edited.endswith("\n")):
        reasons.append("letzter Zeilenumbruch geändert")
    if "\r\n" in original and re.search(r"(?<!\r)\n", edited):
        reasons.append("LF in einer CRLF-Datei")
    orig_lines = original.splitlines(keepends=True)
    new_lines = edited.splitlines(keepends=True)
    offsets = _offsets(orig_lines)
    edited_lines = set()
    for start, end in spans:
        first = _line_of(offsets, max(0, start))
        last = _line_of(offsets, max(0, end - 1))
        edited_lines.update(range(first, last + 1))
    matcher = difflib.SequenceMatcher(None, orig_lines, new_lines, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        for index in range(i1, i2):
            if index not in edited_lines:
                reasons.append("Zeile %d wurde außerhalb der Spanne geändert" % (index + 1))
        if tag == "replace" and (i2 - i1) == (j2 - j1) and not reasons:
            for old_line, new_line in zip(orig_lines[i1:i2], new_lines[j1:j2]):
                if skeleton(old_line) != skeleton(new_line):
                    reasons.append("Markdown-Gerüst in Zeile %d geändert" % (i1 + 1))
                    break
    return not reasons, reasons


def preservation(old, new):
    """RARR's score, computed from difflib's changed blocks."""
    if not old:
        return 1.0 if not new else 0.0
    matcher = difflib.SequenceMatcher(None, old, new)
    changed = sum(max(i2 - i1, j2 - j1) for tag, i1, i2, j1, j2
                  in matcher.get_opcodes() if tag != "equal")
    return max(1.0 - changed / len(old), 0.0)
