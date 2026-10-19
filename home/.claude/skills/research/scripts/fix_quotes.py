"""Repair fragments that are not word sequences of their evidence, without a model.

A writer retyping a quote from a source can change a word, a comma or an ending. When the
evidence still holds a contiguous span that is at least --min-ratio similar (token level,
default 0.90), the fragment in the compose comment and the same span in the paragraph are
replaced with the evidence's exact wording. Anything less similar is left for the normal
repair round. The decision is made in code; no model is called.

Usage:
  python fix_quotes.py <draft file> --workdir <work folder> [--min-ratio 0.90]

Prints one `NOTE quote fixed: ...` line per change and `FIX-QUOTES: N fixed`.
"""

import argparse
import difflib
import json
import re
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import (COMPOSE_RE, DataError, find_tokens, load_evidence, parse_compose,  # noqa: E402
                    tokens, utf8_output)

MIN_RATIO = 0.90


def token_spans(text):
    """(word, start, end) for each word, with the same word rules as common.tokens."""
    spans, cur, start = [], [], None
    for i, ch in enumerate(text):
        if ch.isalnum() or unicodedata.category(ch).startswith("M"):
            if start is None:
                start = i
            cur.append(ch)
        elif ch in "'’" and cur:
            cur.append(ch)
        elif cur:
            assert start is not None
            word = "".join(cur).strip("'")
            if word:
                spans.append((word, start, start + len("".join(cur).rstrip("'"))))
            cur, start = [], None
    if cur:
        assert start is not None
        word = "".join(cur).strip("'")
        if word:
            spans.append((word, start, start + len("".join(cur).rstrip("'"))))
    return spans


def find_token_span(text, needle):
    """(start, end) of the first word sequence in text, or None."""
    spans = token_spans(text)
    index = find_tokens([span[0] for span in spans], needle)
    if index < 0:
        return None
    return spans[index][1], spans[index + len(needle) - 1][2]


def best_evidence_span(evidence_text, needle, min_ratio=MIN_RATIO):
    """The evidence's raw text span closest to needle, when at least min_ratio similar."""
    spans = token_spans(evidence_text)
    words = [span[0].casefold() for span in spans]
    wanted = [word.casefold() for word in needle]
    if not words or not wanted:
        return None
    # The rarest needle word is the anchor: its occurrences bound the candidate windows.
    counts = []
    for index, word in enumerate(wanted):
        count = words.count(word)
        if count:
            counts.append((count, index))
    if not counts:
        return None
    _, anchor = min(counts)
    best = None
    size = len(wanted)
    for position in [i for i, word in enumerate(words) if word == wanted[anchor]]:
        for shift in range(-3, 4):
            start = position - anchor + shift
            for length in range(max(1, size - 3), size + 4):
                if start < 0 or start + length > len(words):
                    continue
                matcher = difflib.SequenceMatcher(
                    None, wanted, words[start:start + length], autojunk=False)
                matches = sum(block.size for block in matcher.get_matching_blocks())
                # matches / the longer side: a truncated span loses the words it dropped,
                # instead of scoring high for having skipped them (ratio would).
                ratio = matches / max(size, length)
                if ratio + 1e-12 < min_ratio:
                    continue
                candidate = (ratio, -abs(length - size), -start)
                if best is None or candidate > best[0]:
                    best = (candidate, start, length)
    if best is None:
        return None
    _, start, length = best
    return evidence_text[spans[start][1]:spans[start + length - 1][2]], best[0][0]


def fix_block(block, evidence_by_id, notes):
    """One paragraph with its compose comment; returns the repaired block."""
    match = COMPOSE_RE.search(block)
    if not match:
        return block
    data = parse_compose(block)
    if not data:
        return block
    forms = {}
    for entry in data.get("forms", []):
        if isinstance(entry, list) and len(entry) == 3:
            forms[(entry[0], entry[1])] = entry[2]
    visible = block[:match.start()]
    replacements, new_frags, changed = [], [], False
    for entry in data.get("frags", []):
        if not (isinstance(entry, list) and len(entry) == 2):
            new_frags.append(entry)
            continue
        ev_id, text = entry
        item = evidence_by_id.get(ev_id)
        words = tokens(text)
        if not item or not item.get("text") or not words:
            new_frags.append(entry)
            continue
        original = [forms.get((ev_id, word), word) for word in words]
        if find_tokens(tokens(item["text"]), original) >= 0:
            new_frags.append(entry)
            continue
        found = best_evidence_span(item["text"], original)
        if not found:
            new_frags.append(entry)
            continue
        exact, ratio = found
        span = find_token_span(visible, words)
        if span is None:
            new_frags.append(entry)
            continue
        replacements.append((span[0], span[1], exact))
        new_frags.append([ev_id, exact])
        notes.append('NOTE quote fixed: "%s" -> "%s" (%.2f)' % (text, exact, ratio))
        changed = True
    if not changed:
        return block
    data["frags"] = new_frags
    if data.get("forms"):
        frag_words = {}
        for entry in new_frags:
            if isinstance(entry, list) and len(entry) == 2:
                frag_words.setdefault(entry[0], set()).update(
                    word.casefold() for word in tokens(entry[1]))
        kept = [entry for entry in data["forms"]
                if not (isinstance(entry, list) and len(entry) == 3
                        and entry[1].casefold() not in frag_words.get(entry[0], set()))]
        if kept:
            data["forms"] = kept
        else:
            data.pop("forms", None)
    new_visible = visible
    for start, end, exact in sorted(replacements, reverse=True):
        new_visible = new_visible[:start] + exact + new_visible[end:]
    comment = match.group(0)
    json_start = match.start(1) - match.start()
    json_end = match.end(1) - match.start()
    new_comment = (comment[:json_start]
                   + json.dumps(data, ensure_ascii=False, separators=(",", ": "))
                   + comment[json_end:])
    return new_visible + new_comment + block[match.end():]


def fix_text(text, evidence_by_id, notes=None):
    """Repair every compose block of a draft; returns the new text and the notes."""
    if notes is None:
        notes = []
    out, last = [], 0
    for match in COMPOSE_RE.finditer(text):
        prefix = text[:match.start()]
        end = len(prefix.rstrip())
        chunk_start = 0
        for separator in re.finditer(r"\n[ \t]*\n", prefix[:end]):
            chunk_start = separator.end()
        fixed = fix_block(prefix[chunk_start:end] + text[end:match.end()],
                          evidence_by_id, notes)
        out.append(text[last:chunk_start])
        out.append(fixed)
        last = match.end()
    out.append(text[last:])
    return "".join(out), notes


def main():
    utf8_output()
    parser = argparse.ArgumentParser(description="Repair near-miss quotes from their evidence.")
    parser.add_argument("draft", help="draft Markdown with compose comments")
    parser.add_argument("--workdir", required=True, help="work folder with evidence/verified.jsonl")
    parser.add_argument("--min-ratio", type=float, default=MIN_RATIO,
                        help="minimum token similarity (default 0.90)")
    args = parser.parse_args()
    try:
        evidence_by_id = load_evidence(args.workdir)
        path = Path(args.draft)
        text = path.read_text(encoding="utf-8")
        fixed, notes = fix_text(text, evidence_by_id)
        if fixed != text:
            path.write_text(fixed, encoding="utf-8", newline="")
        for note in notes:
            print(note)
        print("FIX-QUOTES: %d fixed" % len(notes))
        return 0
    except (DataError, OSError) as exc:
        print("FIX-QUOTES error: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
