"""Correct the citations of a checked Google AI Studio answer.

Runs after check_sources.py validate/report. It works per citation group (the text in front of
one `[[N](url)]` group), never per number globally: a number that is right for one statement stays
untouched when it is wrong for another.

  plan              parse the document into citation groups, write the search tasks
  check             validate replacement decisions (saved source pages or web candidates)
  missing           list the groups that still have no valid replacement
  web-plan          build the web-search batches for those groups
  web-collect       turn the search agents' JSON lines into one candidate list per group
  fetch-web         save the candidate pages found by the web search
  web-verify-plan   build the strict check of candidates against their statement
  verify-plan       build the independent audit of every proposed replacement
  filter            drop replacements the audit did not confirm
  merge             join per-agent JSONL files unchanged
  apply             write `<name> - korrigiert.md` with replaced markers and inline marks

Decision file (JSONL, one object per citation group):
  {"gid":"G001","action":"replace","source":57,"quote":"...","note":"..."}   existing source
  {"gid":"G001","action":"replace","url":"https://...","page":"...","quote":"..."}  new web source
  {"gid":"G001","action":"none","kind":"nicht_belegt|teilweise|umstritten|unzutreffend|nicht_pruefbar","note":"..."}
  {"gid":"G001","action":"clean"}   another marker in the group already supports the statement

Usage:
  python -I correct_sources.py plan      <file.md> --workdir DIR
  python -I correct_sources.py check     --workdir DIR --file <results> [--web]
  python -I correct_sources.py missing   --workdir DIR
  python -I correct_sources.py web-plan  --workdir DIR [--only G001,G002] [--out web-batches]
  python -I correct_sources.py web-collect --workdir DIR --file <raw> [--file <raw> ...] [--append]
  python -I correct_sources.py fetch-web --workdir DIR
  python -I correct_sources.py web-verify-plan --workdir DIR [--only ...] [--out web-verify]
  python -I correct_sources.py verify-plan --workdir DIR
  python -I correct_sources.py filter    --workdir DIR --file <audit results>
  python -I correct_sources.py merge     --out <file> --file <part> --file <part> ...
  python -I correct_sources.py apply     <file.md> --workdir DIR [--out FILE]

Exit codes: 0 ok, 1 findings, 2 bad input.
"""
import argparse
import json
import re
import shutil
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path.home() / ".claude" / "skills" / "research" / "scripts"))
import check_sources as cs  # noqa: E402
from common import normalize, read_page, utf8_output  # noqa: E402

GROUP = re.compile(r"(?:\[\[(\d+)\]\((https?://[^)\s]+)\)\]|\[(\d+)\]\((https?://[^)\s]+)\))+")
ONE = re.compile(r"\[\[(\d+)\]\((https?://[^)\s]+)\)\]")
CITE_ANY = re.compile(r"\[\[(\d+)\]\((https?://[^)\s]+)\)\]|\[(\d+)\]\((https?://[^)\s]+)\)")
HEADINGS = ("## Sources", "## Quellenverzeichnis", "## Quellenprüfung", "## Source check")


def die(msg):
    print(msg)
    return 2


def read_jsonl(path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                out.append(json.loads(line))
    return out


def write_jsonl(path, rows):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def write_json(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n",
                          encoding="utf-8")


def read_text_raw(path):
    """Read a document without universal-newline translation.

    `Path.read_text` turns CRLF into LF, which would shift every offset and silently change
    a Windows file's line endings. The offsets used by apply must match the bytes on disk.
    """
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def body_of(raw):
    cut = len(raw)
    for h in HEADINGS:
        m = re.search(r"(?m)^" + re.escape(h) + r"\s*$", raw)
        if m:
            cut = min(cut, m.start())
    return raw[:cut]


def clean(text):
    text = cs.CITE.sub("", text)
    text = cs.PLAIN_CITE.sub("", text)
    text = cs.plain_markdown(text)
    text = re.sub(r"^\s*>+\s*", "", text)
    text = re.sub(r"^\s*(?:[-*+]|\d+\.)\s+", "", text)
    return re.sub(r"\s+", " ", text).strip()


def statement_before(line, pos, last_end, table_label=""):
    chunk = line[last_end:pos].rstrip()
    # AI Studio usually puts the marker directly after the full stop, but a space or a
    # line with several sentences must not swallow the sentence that carries the claim.
    if chunk and not re.search(r"[.!?;]\s*$", chunk):
        cut = max(chunk.rfind(". "), chunk.rfind("! "), chunk.rfind("? "), chunk.rfind("; "))
        if cut >= 0:
            chunk = chunk[cut + 2:]
    chunk = clean(chunk)
    if table_label and chunk and not chunk.startswith(table_label):
        chunk = table_label + ": " + chunk
    return chunk


def url_key(url):
    """Identity of a page for replacement matching: query kept, fragment dropped.

    `check_sources.url_base` drops the whole query, which makes different YouTube videos
    (watch?v=A vs watch?v=B) the same page. A replacement must never swap one for the other.
    """
    p = urlsplit(url)
    return urlunsplit((p.scheme.lower(), p.netloc.lower().removeprefix("www."),
                       p.path.rstrip("/"), p.query, ""))


def cites_in(text):
    """Return [(number, url)] for both marker styles, in document order."""
    out = []
    for a, b, c, d in CITE_ANY.findall(text):
        out.append((int(a), b) if a else (int(c), d))
    return out


def parse_groups(path, claims):
    raw = read_text_raw(path)
    body = body_of(raw)
    by_line_num = {}
    for c in claims:
        by_line_num.setdefault((c["line"], c["number"]), []).append(c)
    groups = []
    used_claims = set()
    section = ""
    offset = 0
    for line_no, line in enumerate(raw.splitlines(keepends=True), 1):
        content = line.rstrip("\r\n")
        if offset >= len(body):
            break
        h = re.match(r"^#{1,6}\s+(.*)$", content.strip())
        if h:
            section = h.group(1).strip()
        line_offset = offset
        last_end = 0
        table_label = ""
        if content.lstrip().startswith("|"):
            cells = [c.strip() for c in content.strip().strip("|").split("|")]
            if cells:
                table_label = clean(cells[0])
        for m in GROUP.finditer(content):
            parts = cites_in(m.group(0))
            numbers = [n for n, _ in parts]
            urls = [u for _, u in parts]
            style = "double" if m.group(0).startswith("[[") else "single"
            start = line_offset + m.start()
            end = line_offset + m.end()
            if start >= len(body):
                continue
            stmt = statement_before(content, m.start(), last_end, table_label)
            context = clean(content)
            claim_ids, verdicts, notes = [], [], []
            assigned = {}
            for n in numbers:
                if n in assigned:
                    pick = assigned[n]
                else:
                    # Pair the groups of one (line, number) with its claims in document order.
                    # Exact text wins; a substring match is not enough ("B ist falsch" is also
                    # inside "A und B ist falsch" and would inherit the wrong verdict).
                    cand = [c for c in by_line_num.get((line_no, n), [])
                            if c["id"] not in used_claims]
                    pick = None
                    for c in cand:
                        if normalize(c["claim"]) == normalize(stmt):
                            pick = c
                            break
                    if pick is None and cand:
                        pick = cand[0]
                    if pick is not None:
                        used_claims.add(pick["id"])
                    assigned[n] = pick
                claim_ids.append(pick["id"] if pick else None)
                verdicts.append(pick["verdict"] if pick and "verdict" in pick else "offen")
                notes.append(pick["note"] if pick else "")
            groups.append({"gid": "G%03d" % (len(groups) + 1), "line": line_no,
                           "start": start, "end": end, "numbers": numbers,
                           "urls": urls, "style": style,
                           "claim_ids": claim_ids,
                           "verdicts": verdicts, "notes": notes,
                           "statement": stmt, "context": context[:600],
                           "section": section})
            last_end = m.end()
        offset += len(line)
    return raw, body, groups


def group_kind(group):
    # Absence of evidence is not proof of falsehood: "nicht belegt" says the sources do not
    # carry the statement, "unzutreffend" is kept for a page that says the opposite.
    if any(v == "widerspricht" for v in group["verdicts"]):
        return "umstritten" if any(v == "teilweise" for v in group["verdicts"]) else "unzutreffend"
    if any(v == "teilweise" for v in group["verdicts"]):
        return "teilweise"
    if group["verdicts"] and all(v == "nicht_pruefbar" for v in group["verdicts"]):
        return "nicht_pruefbar"
    return "nicht_belegt"


def cmd_plan(args):
    path = Path(args.file)
    work = Path(args.workdir).resolve()
    try:
        claims = read_jsonl(work / "claims.jsonl")
        verdicts = {r["id"]: r for r in read_jsonl(work / "verdicts.jsonl")}
        sources = {s["number"]: s["url"] for s in json.loads(
            (work / "sources.json").read_text(encoding="utf-8"))["sources"]}
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read input: {e}")
    for c in claims:
        c.update(verdicts.get(c["id"], {}))
    _raw, _body, groups = parse_groups(path, claims)

    clean_groups, tasks = [], []
    for g in groups:
        old = [n for n in g["numbers"] if n in sources]
        if len(old) != len(g["numbers"]):
            print(f"Warning: {g['gid']} cites numbers without a source entry")
        if any(v == "gestuetzt" for v in g["verdicts"]):
            if any(v != "gestuetzt" for v in g["verdicts"]):
                g["contested"] = "widerspricht" in g["verdicts"]
                clean_groups.append(g)
            continue
        if not g["statement"]:
            continue
        tasks.append({**g, "kind": group_kind(g),
                      "old_urls": [sources.get(n, "") for n in g["numbers"]]})

    fix = work / "fix"
    fix.mkdir(exist_ok=True)
    write_json(fix / "plan.json", {"file": str(path.resolve()), "groups": groups})
    write_json(fix / "clean.json", {"groups": clean_groups})
    write_json(fix / "tasks.json", {"tasks": tasks})
    batches = cs.make_batches(tasks, args.per_agent)
    for old in (fix / "tasks").glob("batch-*.json"):
        old.unlink()
    (fix / "tasks").mkdir(exist_ok=True)
    for i, batch in enumerate(batches, 1):
        write_json(fix / "tasks" / ("batch-%02d.json" % i),
                   {"batch": i, "tasks": batch})
    print("groups: %d total, %d need a search, %d can be cleaned in place, %d batches"
          % (len(groups), len(tasks), len(clean_groups), len(batches)))
    print("workdir: %s" % fix.resolve())
    return 0


def valid_quote(page, quote):
    if not page or not Path(page).is_file() or not quote:
        return False
    _header, body, offset = read_page(page)
    return bool(cs.locate_quote(body, quote, offset))


def cmd_check(args):
    work = Path(args.workdir).resolve()
    path = Path(args.file)
    web = args.web
    try:
        plan = json.loads((work / "fix" / "plan.json").read_text(encoding="utf-8"))
        sources = {s["number"]: s["url"] for s in json.loads(
            (work / "sources.json").read_text(encoding="utf-8"))["sources"]}
        pages = {s["number"]: s.get("page") for s in json.loads(
            (work / "pages.json").read_text(encoding="utf-8"))["sources"]}
        results = read_jsonl(path)
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read input: {e}")
    by_gid = {g["gid"]: g for g in plan["groups"]}
    good, bad = [], []
    for r in results:
        g = by_gid.get(r.get("gid"))
        if not g:
            bad.append({**r, "reason": "unknown gid"})
            continue
        action = r.get("action")
        if action == "clean" or action == "none":
            good.append({**r, "kind": r.get("kind") or group_kind(g)})
            continue
        if action != "replace":
            bad.append({**r, "reason": "unknown action"})
            continue
        quote = r.get("quote") or ""
        if web:
            page = r.get("page")
            url = r.get("url")
            if not url or not page:
                bad.append({**r, "reason": "web replace needs url and page"})
                continue
            if url_key(url) in {url_key(u) for u in g.get("urls", [])}:
                bad.append({**r, "reason": "candidate is an old source"})
                continue
            if not valid_quote(page, quote):
                bad.append({**r, "reason": "quote not found in candidate page"})
                continue
            gid = r["gid"]
            good.append({**r, "number": None})
            continue
        n = r.get("source")
        if n not in sources:
            bad.append({**r, "reason": "source number not in list"})
            continue
        if n in g["numbers"]:
            bad.append({**r, "reason": "replacement is the old source"})
            continue
        if not valid_quote(pages.get(n), quote):
            bad.append({**r, "reason": "quote not found in source page"})
            continue
        good.append({**r, "url": sources[n], "number": n})
    out = work / "fix" / ("valid-web.jsonl" if web else "valid-existing.jsonl")
    checked = {r.get("gid") for r in results}
    previous = read_jsonl(out) if out.is_file() else []
    merged = [r for r in previous if r.get("gid") not in checked] + good
    write_jsonl(out, merged)
    print("check: %d valid, %d rejected -> %s (%d rows kept from earlier rounds)"
          % (len(good), len(bad), out, len(merged) - len(good)))
    for b in bad[:10]:
        print("REJECT %s | %s" % (b.get("gid"), b.get("reason")))
    return 0 if good else 1


def cmd_missing(args):
    work = Path(args.workdir).resolve()
    try:
        tasks = json.loads((work / "fix" / "tasks.json").read_text(encoding="utf-8"))["tasks"]
        have = set()
        for name in ("valid-existing.jsonl", "valid-web.jsonl"):
            p = work / "fix" / name
            if p.is_file():
                have |= {r["gid"] for r in read_jsonl(p) if r.get("action") == "replace"}
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read input: {e}")
    missing = [t for t in tasks if t["gid"] not in have]
    write_json(work / "fix" / "web-tasks.json", {"tasks": missing})
    print("missing: %d groups without a replacement source" % len(missing))
    return 0




def cmd_web_plan(args):
    work = Path(args.workdir).resolve()
    try:
        tasks = json.loads((work / "fix" / "web-tasks.json").read_text(encoding="utf-8"))["tasks"]
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read web-tasks.json: {e}")
    if args.only:
        wanted = {x.strip() for x in args.only.split(",") if x.strip()}
        tasks = [t for t in tasks if t["gid"] in wanted]
    batches = cs.make_batches(tasks, args.per_agent)
    outdir = work / "fix" / args.out
    outdir.mkdir(exist_ok=True)
    for old in outdir.glob("batch-*.json"):
        old.unlink()
    for i, batch in enumerate(batches, 1):
        write_json(outdir / ("batch-%02d.json" % i), {"batch": i, "tasks": batch})
    print("web-plan: %d tasks in %d batches -> %s" % (len(tasks), len(batches), outdir))
    return 0


def cmd_web_verify_plan(args):
    work = Path(args.workdir).resolve()
    try:
        tasks = {t["gid"]: t for t in json.loads(
            (work / "fix" / "web-tasks.json").read_text(encoding="utf-8"))["tasks"]}
        pages = json.loads((work / "fix" / "web-pages.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read web input: {e}")
    wanted = {x.strip() for x in args.only.split(",")} if args.only else None
    items = []
    for gid, candidates in pages.items():
        if wanted is not None and gid not in wanted:
            continue
        task = tasks.get(gid)
        if not task:
            continue
        old = {url_key(u) for u in task.get("urls", [])}
        candidates = [c for c in candidates if url_key(c.get("url", "")) not in old]
        if not candidates:
            continue
        items.append({"gid": gid, "line": task["line"], "statement": task["statement"],
                      "context": task.get("context", ""), "old_numbers": task["numbers"],
                      "candidates": candidates})
    batches = cs.make_batches(items, args.per_agent)
    outdir = work / "fix" / args.out
    outdir.mkdir(exist_ok=True)
    for old in outdir.glob("batch-*.json"):
        old.unlink()
    for i, batch in enumerate(batches, 1):
        write_json(outdir / ("batch-%02d.json" % i), {"batch": i, "tasks": batch})
    print("web-verify-plan: %d groups in %d batches -> %s" % (len(items), len(batches), outdir))
    return 0


def cmd_web_collect(args):
    """Turn the search agents' JSON lines into one candidate list per citation group."""
    work = Path(args.workdir).resolve()
    grouped = {}
    if args.append and (work / "fix" / "web-candidates.jsonl").is_file():
        for r in read_jsonl(work / "fix" / "web-candidates.jsonl"):
            grouped[r["gid"]] = list(r.get("urls") or [])
    try:
        for name in args.file:
            for line in Path(name).read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                gid, url = r.get("gid"), r.get("url")
                if not gid or not url or not str(url).startswith("http"):
                    continue
                urls = grouped.setdefault(gid, [])
                if url not in urls:
                    urls.append(url)
    except OSError as e:
        return die(f"Cannot read search results: {e}")
    rows = [{"gid": g, "urls": u[:3]} for g, u in sorted(grouped.items())]
    write_jsonl(work / "fix" / "web-candidates.jsonl", rows)
    print("web-collect: %d groups, %d candidate URLs"
          % (len(rows), sum(len(x["urls"]) for x in rows)))
    return 0


def cmd_fetch_web(args):
    work = Path(args.workdir).resolve()
    try:
        candidates = read_jsonl(work / "fix" / "web-candidates.jsonl")
    except OSError as e:
        return die(f"Cannot read web-candidates.jsonl: {e}")
    outdir = work / "fix" / "web-pages"
    outdir.mkdir(exist_ok=True)
    mapping = {}
    for cand in candidates:
        gid = cand.get("gid")
        urls = [u for u in (cand.get("urls") or []) if u.startswith("http")][:3]
        if not gid or not urls:
            continue
        saved, failures = cs.run_fetch(urls, work, args.timeout)
        by_base = {}
        for item in saved:
            by_base[url_key(cs.page_header_url(item["page"]))] = item["page"]
        pages = []
        for i, url in enumerate(urls, 1):
            page = by_base.get(url_key(url))
            if not page:
                continue
            target = outdir / ("%s-%d.md" % (gid, i))
            shutil.copyfile(page, target)
            pages.append({"url": url, "page": str(target)})
        if pages:
            mapping[gid] = pages
    write_json(work / "fix" / "web-pages.json", mapping)
    print("fetch-web: %d groups with candidate pages" % len(mapping))
    return 0


def source_list_text(sources, new_sources):
    allsrc = dict(sources)
    allsrc.update(new_sources)
    numbers = sorted(allsrc)
    gaps = any(n not in allsrc for n in range(1, numbers[-1] + 1)) if numbers else False
    lines = ["## Sources", ""]
    if gaps:
        lines += ["*Nummern wie im Text. Mehrfach verwendete Nummern derselben Quelle wurden "
                  "auf die erste zusammengeführt.*", ""]
    for n in numbers:
        host = urlsplit(allsrc[n]).netloc.lower().removeprefix("www.")
        lines.append("%d. [%s](%s)" % (n, host, allsrc[n]))
    return "\n".join(lines)


def marker(n, url, style="double"):
    if style == "single":
        return "[%d](%s)" % (n, url)
    return "[[%d](%s)]" % (n, url)


def dedupe_markers(marks):
    seen, out = set(), []
    for m in marks:
        hit = re.search(r"\[{1,2}(\d+)\]", m)
        if hit and hit.group(1) in seen:
            continue
        if hit:
            seen.add(hit.group(1))
        out.append(m)
    return "".join(out)


def render_group(g, action, sources, new_sources, source_number=None, url=None, kind=None):
    style = g.get("style", "double")
    if action == "clean":
        kept = [marker(n, sources[n], style) for n, v in zip(g["numbers"], g["verdicts"])
                if v == "gestuetzt" and n in sources]
        if g.get("contested"):
            return (dedupe_markers(kept) + " [umstritten]") if kept else " [umstritten]"
        return dedupe_markers(kept) or " [nicht belegt]"
    if action == "replace":
        if source_number is not None:
            return marker(source_number, sources[source_number], style)
        existing = next((k for k, v in sources.items()
                         if url_key(v) == url_key(url)), None)
        if existing is not None:
            return marker(existing, sources[existing], style)
        n = next((k for k, v in new_sources.items()
                  if url_key(v) == url_key(url)), None)
        if n is None:
            n = (max(list(sources) + list(new_sources)) + 1) if (sources or new_sources) else 1
            new_sources[n] = url
        return marker(n, url, style)
    if kind == "teilweise":
        kept = [marker(n, sources[n], style) for n, v in zip(g["numbers"], g["verdicts"])
                if v == "teilweise" and n in sources]
        return (kept[0] + " [nur teilweise belegt]") if kept else " [nur teilweise belegt]"
    if kind == "umstritten":
        return " [umstritten]"
    if kind == "nicht_belegt":
        return " [nicht belegt]"
    if kind == "nicht_pruefbar":
        return " [nicht prüfbar]"
    return " [unzutreffend]"


def cmd_verify_plan(args):
    """Build a second-pass check of every replacement decision.

    A word-for-word match only proves that the quote exists, not that it carries the whole
    statement. One independent agent per batch judges each replacement against its statement;
    `filter` drops the ones that do not hold.
    """
    work = Path(args.workdir).resolve()
    try:
        plan = json.loads((work / "fix" / "plan.json").read_text(encoding="utf-8"))
        groups = {g["gid"]: g for g in plan["groups"]}
        pages = {s["number"]: s.get("page") for s in json.loads(
            (work / "pages.json").read_text(encoding="utf-8"))["sources"]}
        by_gid = {}
        for name in ("valid-existing.jsonl", "valid-web.jsonl"):
            p = work / "fix" / name
            if p.is_file():
                for r in read_jsonl(p):
                    if r.get("action") == "replace":
                        by_gid[r["gid"]] = r  # the later file (web) wins
        rows = list(by_gid.values())
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read input: {e}")
    items = []
    for r in rows:
        g = groups.get(r.get("gid"))
        if not g:
            continue
        items.append({"gid": g["gid"], "line": g["line"], "statement": g["statement"],
                      "context": g["context"], "old_numbers": g["numbers"],
                      "source": r.get("number") or r.get("url"), "quote": r.get("quote", ""),
                      "page": r.get("page") or pages.get(r.get("number")),
                      "agent_note": r.get("note", "")})
    batches = cs.make_batches(items, args.per_agent)
    outdir = work / "fix" / "verify"
    outdir.mkdir(exist_ok=True)
    for old in outdir.glob("batch-*.json"):
        old.unlink()
    for i, batch in enumerate(batches, 1):
        write_json(outdir / ("batch-%02d.json" % i), {"batch": i, "tasks": batch})
    print("verify-plan: %d replacements in %d batches -> %s" % (len(items), len(batches), outdir))
    return 0


def cmd_filter(args):
    """Keep only replacements whose quote an independent agent confirmed for the statement."""
    work = Path(args.workdir).resolve()
    try:
        results = {r["gid"]: r for r in read_jsonl(Path(args.file))}
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read verify results: {e}")
    files = [name for name in ("valid-existing.jsonl", "valid-web.jsonl")
             if (work / "fix" / name).is_file()]
    selected = {}
    for name in files:
        for idx, r in enumerate(read_jsonl(work / "fix" / name)):
            if r.get("action") == "replace":
                selected[r["gid"]] = (name, idx, r)  # the later file (web) wins
    log = []
    for name in files:
        keep = []
        for idx, r in enumerate(read_jsonl(work / "fix" / name)):
            if r.get("action") != "replace":
                keep.append(r)
                continue
            sel = selected.get(r["gid"])
            if not sel or sel[0] != name or sel[1] != idx:
                continue  # an older proposal for the same group; the later one is used
            v = results.get(r["gid"])
            ok = bool(v) and v.get("verdict") == "gestuetzt"
            if ok:
                keep.append(r)
            log.append({"gid": r["gid"], "verdict": (v or {}).get("verdict", "fehlt"),
                        "note": (v or {}).get("note", "")})
        write_jsonl(work / "fix" / name, keep)
    write_jsonl(work / "fix" / "replacement-check.jsonl", log)
    rejected = [x["gid"] for x in log if x["verdict"] != "gestuetzt"]
    print("filter: %d replacements kept, %d rejected" % (len(log) - len(rejected), len(rejected)))
    for x in log:
        if x["verdict"] != "gestuetzt":
            print("REJECT %s | %s | %s" % (x["gid"], x["verdict"], x["note"][:100]))
    return 0


def cmd_merge(args):
    """Join the per-agent JSONL files into one file, unchanged."""
    lines = []
    try:
        for name in args.file:
            lines += [l.rstrip("\r\n") for l in Path(name).read_text(encoding="utf-8").splitlines()
                      if l.strip()]
    except OSError as e:
        return die(f"Cannot read input: {e}")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print("merge: %d lines -> %s" % (len(lines), out))
    return 0


MARK_RE = re.compile(
    r"[ \t]*\[(?:nur teilweise belegt|nicht belegt|unzutreffend|umstritten|nicht prüfbar)\]")


def strip_marks(text):
    return MARK_RE.sub("", text)


def renumber_markers(body):
    """Number only the sources the text still cites, 1..N in order of first appearance.

    The finished answer uses plain `[N]` markers; the URLs live in `## Quellen` only.
    """
    key_to_new = {}
    order = []

    def sub(m):
        text = m.group(0)
        n, url = cites_in(text)[0]
        key = url_key(url)
        if key not in key_to_new:
            key_to_new[key] = len(order) + 1
            order.append(url)
        return "[%d]" % key_to_new[key]

    body = CITE_ANY.sub(sub, body)
    body = re.sub(r"(\[\d+\])(?:[ \t]*\1)+", r"\1", body)
    return body, order


def source_map(marked):
    out = {}
    inside = False
    for line in marked.splitlines():
        if line.strip() == "## Sources":
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        m = re.match(r"(\d+)\. \[[^\]]*\]\((https?://[^)\s]+)\)", line)
        if m:
            out[int(m.group(1))] = m.group(2)
    return out


def table_cells(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [p.strip().replace("\\|", "|") for p in re.split(r"(?<!\\)\|", s)]


def changed_rows(marked):
    rows = []
    start = marked.find("### Geänderte Stellen")
    if start < 0:
        return rows
    for line in marked[start:].splitlines()[1:]:
        if line.startswith("## ") or line.startswith("### "):
            break
        if not line.startswith("| G"):
            continue
        cells = table_cells(line)
        if len(cells) < 6:
            continue
        rows.append({"gid": cells[0], "line": int(cells[1]), "statement": cells[2],
                     "old": cells[3], "correction": cells[4], "note": cells[5]})
    return rows


def kept_marker_number(line, statement, old_numbers, old_to_new):
    """The partial source that stayed in the text, as a clean number."""
    prefix = statement.rstrip("…").strip()[:50]
    pos = line.find(prefix)
    if pos < 0:
        pos = 0
    m = re.search(r"\[\[(\d+)\]\([^)]+\)\]", line[pos:])
    if not m:
        m = re.search(r"(?<!\[)\[(\d+)\]\([^)]+\)", line[pos:])
    if not m:
        return None
    return old_to_new.get(int(m.group(1)))


def full_statement(line, table_statement):
    """Recover the untruncated statement from the answer line, if it can be found there."""
    prefix = table_statement.rstrip("…").strip()
    candidates = [prefix]
    if ": " in prefix:
        candidates.append(prefix.split(": ", 1)[1])
    pos = -1
    for cand in candidates:
        pos = line.find(cand[:50])
        if pos >= 0:
            break
    if pos < 0:
        return None
    rest = line[pos:]
    m = re.search(r"\[\[|\]\(|\[(?:nur teilweise belegt|nicht belegt|unzutreffend|"
                  r"umstritten|nicht prüfbar)\]", rest)
    if m:
        text = rest[:m.start()]
    else:
        sm = re.search(r"[.!?](?=\s|$)", rest)
        text = rest[:sm.end()] if sm else rest
    text = text.strip()
    text = re.sub(r"^\|\s*", "", text)
    return text or None


def shorten(text, limit=120):
    text = " ".join(text.split())
    if text.endswith("…"):
        text = text[:-1].rstrip()
        cut = text.rfind(" ")
        if cut > 0:
            text = text[:cut].rstrip(" ,;:")
        return text + " …"
    if len(text) <= limit:
        return text
    cut = text.rfind(" ", 0, limit)
    return text[:cut if cut > 0 else limit].rstrip(" ,;:") + " …"


def build_report(marked, marked_body, order, title, date_text):
    sources = source_map(marked)
    key_to_new = {url_key(u): i for i, u in enumerate(order, 1)}
    old_to_new = {n: key_to_new[url_key(u)] for n, u in sources.items()
                  if url_key(u) in key_to_new}
    rows = changed_rows(marked)

    m_total = re.search(r"(\d+) Zitatstellen", marked)
    m_before = re.search(r"(\d+) gestützt, (\d+) teilweise, (\d+) nicht belegt, "
                         r"(\d+) unpassend, (\d+) widersprechend", marked)
    m_cited = re.search(r"(\d+) Quellen zitiert, davon (\d+) neue", marked)
    m_clean = re.search(r"(\d+) Gruppen ohne Änderung bereinigt", marked)
    m_unchecked = re.search(r"(\d+) Zitatstellen ohne Prüfergebnis", marked)

    total = int(m_total.group(1)) if m_total else 0
    good, partial_claims, bad, unrelated, contradicting = (
        [int(x) for x in m_before.groups()] if m_before else (0, 0, 0, 0, 0))
    cited, new_sources = ([int(x) for x in m_cited.groups()] if m_cited else (0, 0))
    cleaned = int(m_clean.group(1)) if m_clean else 0
    unchecked = int(m_unchecked.group(1)) if m_unchecked else 0

    replaced = sorted((r for r in rows if r["correction"].startswith("ersetzt durch")),
                      key=lambda r: r["line"])
    missing = sorted((r for r in rows if r["correction"] == "nicht_belegt"),
                     key=lambda r: r["line"])
    partial = sorted((r for r in rows if r["correction"] == "teilweise"),
                     key=lambda r: r["line"])
    other = sorted((r for r in rows if r["correction"] in ("umstritten", "nicht_pruefbar",
                                                           "unzutreffend")),
                   key=lambda r: r["line"])
    lines_for_body = marked_body.splitlines()

    def stmt_for(row):
        line = lines_for_body[row["line"] - 1] if row["line"] <= len(lines_for_body) else ""
        is_table = line.strip().startswith("|")
        lookup = line if is_table else re.sub(
            r"\[\[\d+\]\([^)]*\)\]|\[\d+\](?:\([^)]*\))?", "", line)
        found = None if is_table else full_statement(lookup, row["statement"])
        text = found
        if text is None and is_table:
            cells = table_cells(line)
            label = re.sub(r"\*\*|`", "", cells[0]).strip() if cells else ""
            stmt = row["statement"].strip()
            if label and stmt.lower().startswith(label.lower()):
                text = label + ": " + stmt[len(label):].lstrip(": ").strip()
        text = text or row["statement"]
        text = re.split(r"\s*\*?\s*[—–]\s*Subreddit\b", text)[0]
        text = text.rstrip("*\"“” ")
        if found and not line.strip().startswith(("|", ">")):
            start = lookup.find(found[:40])
            before = lookup[:start].rstrip() if start > 0 else ""
            if before and (text[:1].islower() or before[-1] not in ".!?:;*>—–"):
                text = "… " + text
        return shorten(text, 160)

    def domain(url):
        return urlsplit(url).netloc.lower().removeprefix("www.")

    out = [
        "# Prüfbericht: %s" % title, "",
        "Geprüft am %s. Grundlage sind die Antwort und die darin genannten Quellen; die "
        "Zeilenangaben beziehen sich auf die fertige Datei." % date_text, "",
        "## Ergebnis", "",
        "Von %d Aussage-Quelle-Paaren stützten %d die Aussage vollständig, %d nur teilweise "
        "und %d gar nicht; %d bezogen sich auf ein anderes Thema."
        % (total, good, partial_claims, bad, unrelated)
        + (" %d widersprachen der Aussage." % contradicting if contradicting else ""),
        "",
        "Im fertigen Text werden %d Quellen zitiert, davon %d neue. %d Verweise wurden ersetzt, "
        "bei %d Aussagen wurde der Verweis entfernt, weil keine geprüfte Quelle sie belegt, "
        "und %d Aussagen sind nur teilweise belegt. Bei %d Stellen wurde ein zusätzlicher, "
        "nicht stützender Verweis entfernt; die Aussage selbst war durch eine andere Quelle "
        "belegt."
        % (cited, new_sources, len(replaced), len(missing), len(partial), cleaned),
        "",
        "Die Quellen im fertigen Text sind neu von 1 bis %d durchnummeriert; die Nummern in "
        "diesem Bericht beziehen sich auf diese Zählung." % len(order),
        "",
    ]

    if replaced:
        out += ["## Ersetzte Verweise", ""]
        for r in replaced:
            m = re.search(r"ersetzt durch (\d+)", r["correction"])
            n = old_to_new.get(int(m.group(1))) if m else None
            url = sources.get(int(m.group(1))) if m else None
            target = ("Quelle %d (%s)" % (n, domain(url))) if n and url else "eine neue Quelle"
            out.append("- **Zeile %d:** „%s“ – Die bisherige Quelle belegte die Aussage nicht. "
                       "Jetzt belegt %s sie."
                       % (r["line"], stmt_for(r), target))
        out.append("")

    if missing:
        out += ["## Nicht belegte Aussagen", ""]
        for r in missing:
            out.append("- **Zeile %d:** „%s“ – Keine der geprüften Quellen belegt diese "
                       "Aussage. Der Verweis wurde entfernt; der Satz steht ohne Quelle im Text."
                       % (r["line"], stmt_for(r)))
        out.append("")

    if partial:
        out += ["## Nur teilweise belegte Aussagen", ""]
        for r in partial:
            line_no = r["line"]
            line = lines_for_body[line_no - 1] if line_no <= len(lines_for_body) else ""
            n = kept_marker_number(line, r["statement"], r["old"], old_to_new)
            source = ("Quelle %d" % n) if n else "Eine der bisherigen Quellen"
            out.append("- **Zeile %d:** „%s“ – Nur teilweise belegt. %s stützt einen Teil der "
                       "Aussage, die vollständige Behauptung aber nicht."
                       % (line_no, stmt_for(r), source))
        out.append("")

    if other:
        out += ["## Sonstige Einschränkungen", ""]
        for r in other:
            label = {"umstritten": "Die Quellen widersprechen sich, die Aussage ist daher "
                                   "umstritten",
                     "nicht_pruefbar": "Für diese Aussage ließ sich keine prüfbare Quelle "
                                       "abrufen",
                     "unzutreffend": "Die Aussage ist nach den geprüften Quellen "
                                     "unzutreffend"}.get(r["correction"], r["correction"])
            out.append("- **Zeile %d:** „%s“ – %s."
                       % (r["line"], stmt_for(r), label))
        out.append("")

    if unchecked:
        out += ["## Ungeprüft", "",
                "%d Zitatstellen hatten kein Prüfergebnis und blieben unverändert." % unchecked,
                ""]
    out += ["## Unverändert", "",
            "Die übrigen Aussagen waren bereits durch mindestens eine geprüfte Quelle "
            "vollständig belegt und blieben unverändert.", ""]
    return "\n".join(out)


def cmd_finalize(args):
    marked_path = Path(args.file)
    try:
        marked = read_text_raw(marked_path)
    except OSError as e:
        return die(f"Cannot read file: {e}")
    cut = len(marked)
    for h in ("## Sources", "## Quellenprüfung"):
        i = marked.find(h)
        if i >= 0:
            cut = min(cut, i)
    marked_body = marked[:cut].rstrip("\r\n")
    body = strip_marks(marked_body)
    body, order = renumber_markers(body)
    nl = "\r\n" if "\r\n" in marked else "\n"
    clean = body
    if order:
        clean += nl * 2 + "## Quellen" + nl * 2
        clean += nl.join("%d. [%s](%s)" % (i, urlsplit(u).netloc.lower().removeprefix("www."), u)
                         for i, u in enumerate(order, 1))
    clean += nl
    clean_path = Path(args.out_clean)
    report_path = Path(args.out_report)
    clean_path.write_text(clean, encoding="utf-8", newline="")
    title = args.title or marked_path.stem.replace(" - korrigiert", "")
    report_path.write_text(
        build_report(marked, marked_body, order, title, args.date) + "\n",
        encoding="utf-8", newline="")
    print("finalize: %d sources, clean -> %s, report -> %s"
          % (len(order), clean_path, report_path))
    return 0


def cmd_apply(args):
    path = Path(args.file)
    work = Path(args.workdir).resolve()
    out = Path(args.out) if args.out else path.with_name(path.stem + " - korrigiert.md")
    try:
        raw = read_text_raw(path)
        plan = json.loads((work / "fix" / "plan.json").read_text(encoding="utf-8"))
        clean = json.loads((work / "fix" / "clean.json").read_text(encoding="utf-8"))["groups"]
        sources = {s["number"]: s["url"] for s in json.loads(
            (work / "sources.json").read_text(encoding="utf-8"))["sources"]}
        verdicts = {r["id"]: r for r in read_jsonl(work / "verdicts.jsonl")}
    except (OSError, json.JSONDecodeError) as e:
        return die(f"Cannot read input: {e}")
    if plan.get("file") and Path(plan["file"]).resolve() != path.resolve():
        return die("plan.json belongs to another file; run plan again")
    for g in plan["groups"]:
        if not GROUP.fullmatch(raw[g["start"]:g["end"]]):
            return die("the input changed after plan; run plan again")
    results = {}
    for name in ("valid-existing.jsonl", "valid-web.jsonl"):
        p = work / "fix" / name
        if p.is_file():
            for r in read_jsonl(p):
                results[r["gid"]] = r
    new_sources = {}
    edits = []
    replaced = marked = partial = clean_count = unchecked = 0
    kinds = Counter()
    details = []
    clean_gids = {x["gid"] for x in clean}
    for g in plan["groups"]:
        # A citation that was never checked ("offen") is not evidence of a wrong citation.
        # Leave it as it is unless a confirmed replacement exists; a clean group has a
        # supported marker and is handled normally.
        if (g["gid"] not in clean_gids and not results.get(g["gid"])
                and any(v == "offen" for v in g["verdicts"])):
            unchecked += 1
            continue
        r = results.get(g["gid"])
        action = None
        kind = None
        if g["gid"] in clean_gids:
            action = "clean"
            clean_count += 1
        elif r:
            action = r["action"]
            kind = r.get("kind")
        elif not any(v == "gestuetzt" for v in g["verdicts"]):
            action = "none"
            kind = group_kind(g)
        else:
            continue
        if action == "replace":
            if r is None:
                continue
            if r.get("number"):
                new_marker = render_group(g, "replace", sources, new_sources,
                                          source_number=r["number"])
            else:
                new_marker = render_group(g, "replace", sources, new_sources, url=r["url"])
            replaced += 1
        elif action == "clean":
            new_marker = render_group(g, "clean", sources, new_sources)
        elif kind == "teilweise":
            new_marker = render_group(g, "none", sources, new_sources, kind="teilweise")
            partial += 1
        else:
            if not kind:
                kind = group_kind(g)
            if kind not in ("umstritten", "nicht_belegt", "nicht_pruefbar", "unzutreffend"):
                kind = "nicht_belegt"
            new_marker = render_group(g, "none", sources, new_sources, kind=kind)
            kinds[kind] += 1
            marked += 1
        old_text = raw[g["start"]:g["end"]]
        if new_marker != old_text:
            edits.append((g["start"], g["end"], new_marker))
        details.append({"gid": g["gid"], "line": g["line"], "statement": g["statement"],
                        "old": ", ".join(map(str, g["numbers"])),
                        "action": action, "kind": kind or "",
                        "new": new_marker, "quote": (r or {}).get("quote", ""),
                        "note": (r or {}).get("note", "")})
    body = body_of(raw)
    for start, end, repl in sorted(edits, reverse=True):
        # A mark like " [unzutreffend]" needs its own space only when the marker is
        # attached to the sentence; after an existing space it would double.
        if repl.startswith(" ") and start > 0 and body[start - 1] in (" ", "\t"):
            repl = repl.lstrip(" ")
        body = body[:start] + repl + body[end:]
    # resolve_sources.py can leave two identical markers side by side when two numbers
    # pointed to the same page; one marker is enough.
    body = re.sub(r"((?:\[\[\d+\]\([^)\s]+\)\]|\[\d+\]\([^)\s]+\)))(?:[ \t]*\1)+", r"\1", body)
    used = {int(n) for n in re.findall(r"\[{1,2}(\d+)\]", body)}
    old_used = {n: u for n, u in sources.items() if n in used}
    new_used = {n: u for n, u in new_sources.items() if n in used}
    dropped = len(sources) - len(old_used)
    sources_text = source_list_text(old_used, new_used)
    counts = Counter(v["verdict"] for v in verdicts.values())
    mark_parts = []
    for key, label in (("nicht_belegt", "als nicht belegt"),
                       ("unzutreffend", "als unzutreffend"),
                       ("umstritten", "als umstritten"),
                       ("nicht_pruefbar", "als nicht prüfbar")):
        if kinds.get(key):
            mark_parts.append("%d %s" % (kinds[key], label))
    lines = [
        "## Quellenprüfung", "",
        "Korrigiert am %s · %d Zitatstellen · %d Quellen zitiert, davon %d neue."
        % (datetime.now().strftime("%Y-%m-%d"), len(verdicts),
           len(old_used) + len(new_used), len(new_used)),
        "",
        "**Vorher:** %d gestützt, %d teilweise, %d nicht belegt, %d unpassend, %d widersprechend."
        % (counts.get("gestuetzt", 0), counts.get("teilweise", 0),
           counts.get("nicht_belegt", 0), counts.get("unpassend", 0),
           counts.get("widerspricht", 0)),
        "",
        "**Korrektur:** %d Referenzen ersetzt. Markiert: %s, %d als nur teilweise belegt. "
        "%d Gruppen ohne Änderung bereinigt."
        % (replaced, ", ".join(mark_parts) if mark_parts else "0", partial, clean_count),
        "",
    ]
    if dropped:
        lines += ["*%d Quellen der ursprünglichen Antwort werden nicht mehr zitiert und stehen "
                  "deshalb nicht mehr im Quellenverzeichnis; die Prüftabelle nennt sie "
                  "weiterhin.*" % dropped, ""]
    if unchecked:
        lines += ["*%d Zitatstellen ohne Prüfergebnis blieben unverändert.*" % unchecked, ""]
    changed = [d for d in details if d["action"] in ("replace", "none")]
    if changed:
        lines += ["### Geänderte Stellen", "",
                  "| Stelle | Zeile | Aussage | alt | Korrektur | Beleg / Grund |",
                  "|---|---|---|---|---|---|"]
        for d in changed:
            new = d["new"].replace("|", "\\|")
            if d["action"] == "replace":
                m = re.search(r"\[{1,2}(\d+)\]", new)
                verdict = "ersetzt durch " + (m.group(1) if m else "?")
            else:
                verdict = d["kind"]
            lines.append("| %s | %d | %s | %s | %s | %s |"
                         % (d["gid"], d["line"], cs.cell(d["statement"], 100),
                            d["old"] or "—", verdict,
                            cs.cell(d["quote"] or d["note"], 180)))
        lines.append("")
    if new_sources:
        lines += ["### Neue Quellen", ""]
        for n in sorted(new_sources):
            host = urlsplit(new_sources[n]).netloc.lower().removeprefix("www.")
            lines.append("%d. [%s](%s)" % (n, host, new_sources[n]))
        lines.append("")
    if verdicts:
        lines += ["### Alle Prüfungen", "", "<details>",
                  "<summary>%d Zeilen</summary>" % len(verdicts), "",
                  "| Stelle | Zeile | Aussage | Quelle | Urteil | Beleg | Beleg-Prüfung |",
                  "|---|---|---|---|---|---|---|"]
        for v in sorted(verdicts.values(),
                        key=lambda x: (x.get("line", 0), x.get("id", ""))):
            lines.append("| %s | %d | %s | %s | %s | %s | %s |"
                         % (v.get("id", ""), v.get("line", 0),
                            cs.cell(v.get("claim", ""), 100), v.get("number", ""),
                            cs.VERDICT_LABEL.get(v.get("verdict"), v.get("verdict", "")),
                            cs.cell(v.get("quote", ""), 160),
                            cs.EVIDENCE_LABEL.get(v.get("evidence"),
                                                  v.get("evidence") or "")))
        lines += ["", "</details>", ""]
    section = "\n".join(lines)
    nl = "\r\n" if "\r\n" in raw else "\n"
    if nl == "\r\n":
        section = section.replace("\n", nl)
    out.write_text(body.rstrip("\r\n") + nl * 2 + sources_text.replace("\n", nl) +
                   nl * 2 + section, encoding="utf-8", newline="")
    write_json(work / "fix" / "summary.json",
               {"created": datetime.now().isoformat(timespec="seconds"),
                "groups": len(plan["groups"]), "replaced": replaced, "marked": marked,
                "partial": partial, "clean": clean_count, "unchecked": unchecked,
                "new_sources": len(new_sources), "out": str(out)})
    print("apply: %d replaced, %d marked, %d partial, %d clean, %d unchecked -> %s"
          % (replaced, marked, partial, clean_count, unchecked, out))
    return 0


def main(argv=None):
    utf8_output()
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("plan")
    p.add_argument("file")
    p.add_argument("--workdir", required=True)
    p.add_argument("--per-agent", type=int, default=8)
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("check")
    p.add_argument("--workdir", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--web", action="store_true")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("missing")
    p.add_argument("--workdir", required=True)
    p.set_defaults(func=cmd_missing)

    p = sub.add_parser("web-plan")
    p.add_argument("--workdir", required=True)
    p.add_argument("--per-agent", type=int, default=5)
    p.add_argument("--only")
    p.add_argument("--out", default="web-batches")
    p.set_defaults(func=cmd_web_plan)

    p = sub.add_parser("web-verify-plan")
    p.add_argument("--workdir", required=True)
    p.add_argument("--per-agent", type=int, default=6)
    p.add_argument("--only")
    p.add_argument("--out", default="web-verify")
    p.set_defaults(func=cmd_web_verify_plan)

    p = sub.add_parser("web-collect")
    p.add_argument("--workdir", required=True)
    p.add_argument("--file", required=True, action="append")
    p.add_argument("--append", action="store_true")
    p.set_defaults(func=cmd_web_collect)

    p = sub.add_parser("fetch-web")
    p.add_argument("--workdir", required=True)
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=cmd_fetch_web)

    p = sub.add_parser("verify-plan")
    p.add_argument("--workdir", required=True)
    p.add_argument("--per-agent", type=int, default=8)
    p.set_defaults(func=cmd_verify_plan)

    p = sub.add_parser("filter")
    p.add_argument("--workdir", required=True)
    p.add_argument("--file", required=True)
    p.set_defaults(func=cmd_filter)

    p = sub.add_parser("merge")
    p.add_argument("--out", required=True)
    p.add_argument("--file", required=True, action="append")
    p.set_defaults(func=cmd_merge)

    p = sub.add_parser("apply")
    p.add_argument("file")
    p.add_argument("--workdir", required=True)
    p.add_argument("--out")
    p.set_defaults(func=cmd_apply)

    p = sub.add_parser("finalize")
    p.add_argument("file")
    p.add_argument("--out-clean", required=True)
    p.add_argument("--out-report", required=True)
    p.add_argument("--title")
    p.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"))
    p.set_defaults(func=cmd_finalize)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
