"""Verify word-for-word evidence against the saved pages, and (optionally) a draft's fragments.

Usage:
  python verify_evidence.py <workdir>                      verify evidence/raw-*.jsonl
  python verify_evidence.py <workdir> --check-draft FILE   check the compose comments of a draft

Raw evidence line: {"page": "003-example.org.md", "text": "...", "lines": [10, 12],
  "heading": "...", "lang": "en", "type": "primary", "claim": "..."}  (id is assigned here)
Writes evidence/verified.jsonl and evidence/failed.jsonl. Prints counts, never page text.
Exit 0 when the run worked and at least one item verified (or --check-draft found nothing wrong);
exit 1 otherwise. --strict also exits 1 when any item failed.
Standard: ~/.claude/docs/research-standard.md sections 3 and 4.
"""

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import (COMPOSE_RE, DataError, check_fragments, load_evidence, locate,  # noqa: E402
                    normalize, paragraphs, parse_compose, read_jsonl, read_page, safe_child,
                    tokens, utf8_output, write_jsonl)

MIN_WORDS = 3


def verify_item(item, pages_dir, page_cache):
    """Return (verified item, None) or (None, reason)."""
    text = item.get("text")
    if not isinstance(text, str) or not normalize(text):
        return None, "empty text"
    if len(tokens(text)) < MIN_WORDS:
        return None, f"fewer than {MIN_WORDS} words"
    try:
        page_path = safe_child(pages_dir, item.get("page"))
    except DataError as exc:
        return None, str(exc)
    if page_path.name not in page_cache:
        page_cache[page_path.name] = read_page(page_path)
    header, body, header_lines = page_cache[page_path.name]
    found = locate(body, text, header_lines)
    if found is None:
        return None, "text not found in the saved page"
    kind, first, last = found
    verified = {
        "page": page_path.name,
        "lines": [first, last],
        "heading": item.get("heading", ""),
        "text": text,
        "lang": item.get("lang") or header.get("lang", ""),
        "type": item.get("type") or header.get("type", ""),
        "claim": item.get("claim", ""),
        "match": kind,
        "url": header.get("final_url") or header.get("url", ""),
    }
    return verified, None


def run_verify(workdir):
    work = Path(workdir)
    pages_dir = work / "pages"
    raw_files = sorted((work / "evidence").glob("raw-*.jsonl"))
    if not raw_files:
        raise DataError(f"no evidence/raw-*.jsonl in {work}")
    verified, failed, seen, cache = [], [], set(), {}
    for raw in raw_files:
        for item in read_jsonl(raw):
            if "term_variants" in item and "text" not in item:
                continue  # the extractor's terminology line, not evidence
            key =(item.get("page"), normalize(item.get("text") or ""))
            if key in seen:
                continue
            seen.add(key)
            good, reason = verify_item(item, pages_dir, cache)
            if good is None:
                failed.append({**item, "reason": reason})
            else:
                good["id"] = f"E{len(verified) + 1}"
                verified.append(good)
    ordered = [{"id": v["id"], **{k: x for k, x in v.items() if k != "id"}} for v in verified]
    write_jsonl(work / "evidence" / "verified.jsonl", ordered)
    write_jsonl(work / "evidence" / "failed.jsonl", failed)
    return ordered, failed


def run_check_draft(workdir, draft):
    evidence = load_evidence(workdir)
    text = Path(draft).read_text(encoding="utf-8")
    problems, checked = [], 0
    for number, block in enumerate(paragraphs(text), 1):
        compose = parse_compose(block)
        if compose is None:
            continue
        checked += 1
        for ev_id in compose["ids"]:
            if ev_id not in evidence:
                problems.append(f"paragraph {number}: evidence {ev_id} is not verified")
        clean = re.sub(r"<!--.*?-->", " ", COMPOSE_RE.sub(" ", block), flags=re.S)
        for problem in check_fragments(compose, evidence, clean):
            problems.append(f"paragraph {number}: {problem}")
    return checked, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("workdir")
    parser.add_argument("--check-draft", metavar="FILE")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args(argv)
    utf8_output()
    try:
        if args.check_draft:
            checked, problems = run_check_draft(args.workdir, args.check_draft)
            for problem in problems:
                print("PROBLEM", problem)
            print(f"draft: {checked} paragraphs with compose comments, {len(problems)} problems")
            return 1 if problems else 0
        verified, failed = run_verify(args.workdir)
    except (DataError, OSError) as exc:
        print(f"ERROR {exc}")
        return 1
    reasons = Counter(f["reason"] for f in failed)
    kinds = Counter(v["match"] for v in verified)
    print(f"verified {len(verified)} ({dict(kinds)}), failed {len(failed)} ({dict(reasons)})")
    if not verified or (args.strict and failed):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
