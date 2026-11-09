"""Passage packs: code searches, the first-pass agent judges only four passages.

A saved page is cut into paragraphs of at most about 900 characters, with the heading above
them and their line numbers. For every statement the passages are ranked by exact numbers,
versions and names, by BM25 word overlap, and (when the embedding file exists) by cosine
similarity of a small multilingual E5 model. The pack file holds the statement and its top four
passages word for word; the agent reads nothing else. The recheck still reads whole pages.
"""

import hashlib
import json
import math
import re
from collections import Counter
from pathlib import Path

import check_sources as cs
import claims as cl
import fix_quotes as fq

MAX_CHARS = 900
K1, B = 1.5, 0.75
COMMON = {"der", "die", "das", "und", "ist", "sind", "ein", "eine", "auf", "mit", "von",
          "für", "im", "den", "dem", "zu", "wird", "werden", "nicht", "auch", "als",
          "the", "and", "is", "are", "of", "to", "in", "for", "with", "a", "an"}


def _line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def split_passages(text, max_chars=MAX_CHARS):
    """Paragraphs with heading, character span and first line; long paragraphs are split."""
    out = []
    heading = ""
    current = []
    start = None

    def flush():
        nonlocal current, start
        if not current:
            return
        body = "\n".join(current)
        base = start if start is not None else 0
        for a, b in cl.sentence_spans(body):
            if b - a > max_chars:
                piece_start = a
                while piece_start < b:
                    piece_end = min(piece_start + max_chars, b)
                    cut = body.rfind(" ", piece_start, piece_end)
                    if cut <= piece_start:
                        cut = piece_end
                    out.append(_passage(body[piece_start:cut], base + piece_start,
                                        base + cut, heading, text))
                    piece_start = cut
            else:
                out.append(_passage(body[a:b], base + a, base + b, heading, text))
        current = []
        start = None

    offset = 0
    for line in text.splitlines(keepends=True):
        clean = line.rstrip("\r\n")
        if clean.startswith("#"):
            flush()
            heading = clean.lstrip("#").strip()
            offset += len(line)
            continue
        if not clean.strip():
            flush()
            offset += len(line)
            continue
        if start is None:
            start = offset
        current.append(clean)
        offset += len(line)
    flush()
    return out


def _passage(body, start, end, heading, page_text):
    return {"text": body.strip(), "start": start, "end": end, "heading": heading,
            "line": _line_of(page_text, start)}


def _features(statement):
    numbers = re.findall(r"\d+(?:[.,]\d+)*", statement)
    names = [w for w in fq.tokens(statement)
             if w[:1].isupper() and w.casefold() not in COMMON]
    return [x.casefold() for x in numbers + names]


def _tokens(text):
    return [w.casefold() for w in fq.tokens(text) if w.casefold() not in COMMON]


def bm25_scores(query, docs):
    q = _tokens(query)
    if not q or not docs:
        return [0.0] * len(docs)
    tokenized = [_tokens(d) for d in docs]
    lengths = [len(t) for t in tokenized]
    avg = sum(lengths) / max(1, len(lengths))
    df = Counter()
    for doc in tokenized:
        df.update(set(doc))
    scores = []
    for doc, length in zip(tokenized, lengths):
        tf = Counter(doc)
        score = 0.0
        for term in q:
            if not tf[term]:
                continue
            idf = math.log(1 + (len(docs) - df[term] + 0.5) / (df[term] + 0.5))
            score += idf * tf[term] * (K1 + 1) / (
                tf[term] + K1 * (1 - B + B * length / max(avg, 1)))
        scores.append(score)
    return scores


def rank(statement, passages, embeddings=None, top=4):
    """Top passages by exact features + BM25 (+ embedding), each normalized to 0..1."""
    if not passages:
        return []
    exact = []
    feats = _features(statement)
    for p in passages:
        hay = (p.get("heading", "") + " " + p["text"]).casefold()
        hit = sum(1 for f in feats if f in hay)
        exact.append(hit / len(feats) if feats else 0.0)
    bm = bm25_scores(statement, [p["text"] for p in passages])
    bmax = max(bm) or 1.0
    bm = [x / bmax for x in bm]
    if embeddings:
        emax = max(embeddings) or 1.0
        emb = [max(0.0, x) / emax for x in embeddings]
        scores = [0.40 * e + 0.35 * b + 0.25 * m
                  for e, b, m in zip(exact, bm, emb)]
    else:
        scores = [0.60 * e + 0.40 * b for e, b in zip(exact, bm)]
    order = sorted(range(len(passages)), key=lambda i: (-scores[i], i))[:top]
    return [{**passages[i], "score": round(scores[i], 4)} for i in order]


def cache_key(page_text, statement):
    return hashlib.sha256((page_text + "\x00" + statement).encode("utf-8")).hexdigest()


def cached_result(cache, statement, pages):
    """(result, keys) when every scoped page has the same cached verdict, else (None, keys)."""
    text = statement.get("text", "")
    keys = [cache_key(p["body"], text) for p in pages if p.get("body")]
    if not keys:
        return None, keys
    rows = [cache.get(k) for k in keys]
    if any(row is None for row in rows):
        return None, keys
    verdicts = {row.get("verdict") for row in rows}
    if len(verdicts) != 1:
        return None, keys
    return rows[0], keys


def update_verdict_cache(work):
    """Store the final verdict per (page text, statement) so a re-run can reuse it."""
    work = Path(work)
    pages = {p["number"]: p for p in read_pages(work)}
    cache_file = work / "verdict-cache.json"
    try:
        cache = json.loads(cache_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        cache = {}
    added = 0
    try:
        rows = [json.loads(l) for l in open(work / "verdicts.jsonl", encoding="utf-8")
                if l.strip()]
    except (OSError, json.JSONDecodeError):
        return 0
    for row in rows:
        page = pages.get(row.get("number"))
        if not page or not row.get("quote"):
            continue
        if not cs.locate_quote(page["body"], row["quote"], 0):
            continue
        key = cache_key(page["body"], row.get("claim", ""))
        value = {"verdict": row.get("verdict"), "quote": row.get("quote"),
                 "note": row.get("note", "")}
        if cache.get(key) != value:
            cache[key] = value
            added += 1
    cache_file.write_text(json.dumps(cache, ensure_ascii=False, indent=1) + "\n",
                          encoding="utf-8")
    return added


def passage_key(p):
    return hashlib.sha256(
        ("%s\x00%s" % (p.get("page", ""), p["text"])).encode("utf-8")).hexdigest()


def cosine(a, b):
    if not a or not b:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def pack_entry(statement, passages, embeddings=None):
    numbers = set(statement.get("numbers") or [])
    scoped = passages
    if numbers:
        scoped = [p for p in passages if p.get("page") in numbers]
    vectors = None
    signals = ["exact", "bm25"]
    if embeddings:
        passage_vectors = embeddings.get("passages") or {}
        statement_vector = (embeddings.get("statements") or {}).get(statement.get("sid"))
        raw = [passage_vectors.get(passage_key(p)) for p in scoped]
        if statement_vector and raw and all(v is not None for v in raw):
            vectors = [cosine(statement_vector, v) for v in raw]
            signals = ["exact", "bm25", "embedding"]
    picked = rank(statement.get("self_contained") or statement.get("text", ""),
                  scoped, embeddings=vectors)
    return {"sid": statement.get("sid"), "text": statement.get("text", ""),
            "self_contained": statement.get("self_contained", ""),
            "numbers": sorted(numbers), "signals": signals,
            "passages": [{"text": p["text"], "line": p["line"], "page": p.get("page"),
                          "heading": p.get("heading", ""), "score": p["score"]}
                         for p in picked]}


def read_pages(work):
    data = json.loads((Path(work) / "pages.json").read_text(encoding="utf-8"))
    out = []
    for src in data["sources"]:
        page = src.get("page")
        if not page or not Path(page).is_file():
            continue
        try:
            _header, body, _offset = cs.read_page(page)
        except (OSError, UnicodeDecodeError):
            continue
        out.append({"number": src["number"], "url": src["url"], "page": page, "body": body})
    return out


def build_packs(work, statements, per_agent=6):
    """Write packs/batch-*.json and packs/index.json; no model needed."""
    pages = read_pages(work)
    passages = []
    for p in pages:
        for row in split_passages(p["body"]):
            passages.append({**row, "page": p["number"], "url": p["url"]})
    embed_file = Path(work) / "packs" / "embeddings.json"
    embeddings = {}
    if embed_file.is_file():
        try:
            embeddings = json.loads(embed_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            embeddings = {}
    try:
        cache = json.loads((Path(work) / "verdict-cache.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        cache = {}
    entries, reused = [], []
    for st in statements:
        numbers = set(st.get("numbers") or [])
        scoped_pages = [p for p in pages if not numbers or p["number"] in numbers]
        result, _keys = cached_result(cache, st, scoped_pages)
        if result:
            reused.append({"sid": st.get("sid"), **result})
        else:
            entries.append(pack_entry(st, passages, embeddings=embeddings))
    cached_file = Path(work) / "results" / "pass0-cache.jsonl"
    cached_file.parent.mkdir(parents=True, exist_ok=True)
    cached_file.write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in reused),
        encoding="utf-8", newline="\n")
    outdir = Path(work) / "packs"
    outdir.mkdir(exist_ok=True)
    for old in outdir.glob("batch-*.json"):
        old.unlink()
    batches = cs.make_batches(entries, per_agent)
    for i, batch in enumerate(batches, 1):
        cs.write_json(outdir / ("batch-%02d.json" % i),
                      {"batch": i, "pass": 1, "statements": batch})
    cs.write_json(outdir / "index.json",
                  {"created": cs.datetime.now().isoformat(timespec="seconds"),
                   "pages": len(pages), "passages": len(passages),
                   "statements": len(entries), "cached": len(reused),
                   "batches": len(batches), "embedding": bool(embed_file.is_file())})
    return len(entries), len(passages), len(batches)
