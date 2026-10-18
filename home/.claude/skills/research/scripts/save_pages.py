"""Fetch the full text of candidate pages and save each as Markdown in <workdir>/pages/.

Usage:
  python save_pages.py <workdir> [--candidates candidates] [--max-pages 40] [--max-age-hours 24]

Reads every *.jsonl in the candidates folder (lines from the web-researcher passes:
{"url", "title", "lang", "pass", "type", "date", "why"}), cleans and de-duplicates the URLs,
fetches them and writes pages/NNN-<domain>.md (header + Markdown) and pages/index.json.
Fetch methods in order, each only for the URLs the earlier ones could not read:
crawl4ai (local, first: no quota and no third party sees the URL; one browser session through
crawl4ai_fetch.py in the Crawl4AI venv), Exa Contents, You.com Contents, Tavily Extract,
Firecrawl Scrape, TinyFish Fetch, Jina Reader (public pages only).
Reddit goes through the content services only.
Keys come from the environment (EXA_API_KEY, YDC_API_KEY, TAVILY_API_KEY, FIRECRAWL_API_KEY,
TINYFISH_API_KEY, optional JINA_API_KEY) and are never printed. Prints counts, never page text.
The Internet Archive is only asked for the nearest snapshot (nothing is archived).
Exit 0 when at least one page was saved, else 1.
Standard: ~/.claude/docs/research-standard.md sections 2 and 3.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, quote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import DataError, clean_url, normalize, read_jsonl, utf8_output  # noqa: E402

MIN_CHARS = 200
TYPE_RANK = {"primary": 0, "secondary": 1, "experience": 2}
# A run is allowed at most this many fallback pages per service. crawl4ai is local and has no
# cap beyond --max-pages. The caps are what makes 90 runs a month fit the free tiers: with them
# the worst case stays under every monthly allowance (arithmetic in docs/agent-tooling.md).
PAGE_CAP = {"exa": 10, "you": 10, "tavily": 5, "firecrawl": 5, "tinyfish": 10, "jina": 10}
CRAWL4AI_TIMEOUT = 60      # seconds per page
CRAWL4AI_CONCURRENCY = 5   # browser tabs at once; the helper caps it at 5 as well
CRAWL4AI_SCRIPT = Path(__file__).resolve().parent / "crawl4ai_fetch.py"
WAYBACK_PAUSE = 2.5      # seconds between asks; the availability API rate-limits bursts
WAYBACK_RETRY_WAIT = 30  # seconds after a failed ask; three failures end the asking for the run
SECRET_QUERY = re.compile(r"token|key|session|auth|passw|secret|sig|code", re.I)
REDDIT = re.compile(r"(^|\.)(reddit\.com|redd\.it)$", re.I)
PROVIDERS = ("exa", "you", "tavily", "firecrawl", "tinyfish")
# crawl4ai runs first: it is local, unlimited and no provider sees the URL. The services are
# the fallback for pages the browser cannot read (JavaScript walls, bot checks, timeouts).
ORDER = ("crawl4ai", "exa", "you", "tavily", "firecrawl", "tinyfish", "jina")
KEYS = {"exa": "EXA_API_KEY", "you": "YDC_API_KEY", "tavily": "TAVILY_API_KEY",
        "firecrawl": "FIRECRAWL_API_KEY", "tinyfish": "TINYFISH_API_KEY"}


class ServiceDown(Exception):
    """A service refused for good in this run (no key rights, quota, payment)."""


# ---------- HTTP (replaced in tests) ----------

def http(method, url, headers=None, body=None, timeout=60, retry=True):
    """Return (status, parsed JSON or text). Retries network errors, 429 and 5xx (at most two
    more tries, growing pauses, Retry-After respected). Raises ServiceDown on 401 and 402, on a
    429 that stays, and on a network error that stays. A 403 or a 5xx that stays is returned: it
    is that URL's failure (a site a service refuses), not the end of the service."""
    import requests
    last = None
    for attempt in range(3 if retry else 1):
        try:
            resp = requests.request(method, url, headers=headers, json=body, timeout=timeout)
        except requests.RequestException as exc:
            last = exc
            if retry:
                time.sleep(2 * (attempt + 1))
            continue
        if resp.status_code in (401, 402):
            raise ServiceDown(f"HTTP {resp.status_code}")
        if resp.status_code == 429 or resp.status_code >= 500:
            if attempt == 2 or not retry:
                if resp.status_code == 429:
                    raise ServiceDown("HTTP 429")
                return resp.status_code, None
            try:
                wait = min(30, float(resp.headers.get("Retry-After", 5)))
            except ValueError:
                wait = 5
            time.sleep(wait)
            continue
        try:
            return resp.status_code, resp.json()
        except ValueError:
            return resp.status_code, resp.text
    raise ServiceDown(f"network error ({type(last).__name__})")


# ---------- URLs ----------

def is_reddit(url):
    return bool(REDDIT.search(urlsplit(url).hostname or ""))


def public_for_third_party(url):
    """Jina gets the URL: only plain public pages, nothing that looks like a login or token."""
    parts = urlsplit(url)
    return not any(SECRET_QUERY.search(k) for k, _ in parse_qsl(parts.query))


def domain_slug(url):
    host = (urlsplit(url).hostname or "page").lower().removeprefix("www.")
    return re.sub(r"[^a-z0-9.-]", "-", host)


def find_crawl4ai_python():
    """The Python of the uv tool venv that carries Crawl4AI, or None.

    The setup installs Crawl4AI with `uv tool install crawl4ai`, so the venv lives under the
    uv tool root. UV_TOOL_DIR wins; the defaults cover Windows (APPDATA), the XDG layout
    (including XDG_DATA_HOME) and uv's plain home fallback."""
    roots = []
    if os.environ.get("UV_TOOL_DIR"):
        roots.append(Path(os.environ["UV_TOOL_DIR"]))
    if os.environ.get("XDG_DATA_HOME"):
        roots.append(Path(os.environ["XDG_DATA_HOME"]) / "uv" / "tools")
    roots.append(Path.home() / ".local" / "share" / "uv" / "tools")
    if os.environ.get("APPDATA"):
        roots.append(Path(os.environ["APPDATA"]) / "uv" / "tools")
    for root in roots:
        for rel in ("crawl4ai/Scripts/python.exe", "crawl4ai/bin/python"):
            candidate = root / rel
            if candidate.is_file():
                return str(candidate)
    return None


def load_candidates(folder, max_pages):
    """Cleaned, de-duplicated candidates, primary sources first, passes interleaved."""
    seen, by_pass, dropped = {}, {}, []
    for path in sorted(Path(folder).glob("*.jsonl")):
        for item in read_jsonl(path):
            if not isinstance(item, dict) or "url" not in item:
                continue
            url = clean_url(str(item["url"]))
            if url is None:
                dropped.append(item["url"])
                continue
            rank = TYPE_RANK.get(item.get("type"), 1)
            if url in seen and TYPE_RANK.get(seen[url].get("type"), 1) <= rank:
                continue
            seen[url] = {**item, "url": url}
    for item in seen.values():
        by_pass.setdefault(item.get("pass", "P?"), []).append(item)
    for items in by_pass.values():
        items.sort(key=lambda i: TYPE_RANK.get(i.get("type"), 1))
    ordered, queues = [], [by_pass[k] for k in sorted(by_pass)]
    while queues and len(ordered) < max_pages:
        for queue in list(queues):
            if queue and len(ordered) < max_pages:
                ordered.append(queue.pop(0))
            if not queue:
                queues.remove(queue)
    return ordered, dropped


# ---------- fetch methods: each returns {url: result dict or error string} ----------

def _key(name):
    return os.environ.get(KEYS[name], "")


def fetch_exa(urls, max_age_hours):
    out = {}
    for i in range(0, len(urls), 100):
        chunk = urls[i:i + 100]
        _, data = http("POST", "https://api.exa.ai/contents",
                       {"x-api-key": _key("exa"), "Content-Type": "application/json"},
                       {"urls": chunk, "text": True, "maxAgeHours": max_age_hours})
        if not isinstance(data, dict):
            continue
        bad = {s.get("id"): (s.get("error") or {}).get("tag", "error")
               for s in data.get("statuses") or [] if s.get("status") == "error"}
        results = {}
        for r in data.get("results") or []:
            for k in (r.get("id"), r.get("url")):
                if k:
                    results[k] = r
        for url in chunk:
            if url in bad:
                out[url] = f"exa: {bad[url]}"
            elif url in results and results[url].get("text"):
                r = results[url]
                out[url] = {"text": r["text"], "title": r.get("title"), "author": r.get("author"),
                            "published": r.get("publishedDate"), "final_url": r.get("url")}
    return out


def fetch_you(urls, max_age_hours):
    out = {}
    for i in range(0, len(urls), 10):
        chunk = urls[i:i + 10]
        _, data = http("POST", "https://ydc-index.io/v1/contents",
                       {"X-API-Key": _key("you"), "Content-Type": "application/json"},
                       {"urls": chunk, "formats": ["markdown"], "max_age": max_age_hours * 3600})
        for r in data if isinstance(data, list) else []:
            if r.get("url") in chunk and r.get("markdown"):
                out[r["url"]] = {"text": r["markdown"], "title": r.get("title")}
    return out


def fetch_tavily(urls, max_age_hours):
    out = {}
    for i in range(0, len(urls), 20):
        chunk = urls[i:i + 20]
        _, data = http("POST", "https://api.tavily.com/extract",
                       {"Authorization": "Bearer " + _key("tavily"), "Content-Type": "application/json"},
                       {"urls": chunk, "format": "markdown"})
        if not isinstance(data, dict):
            continue
        for r in data.get("results") or []:
            if r.get("url") in chunk and r.get("raw_content"):
                out[r["url"]] = {"text": r["raw_content"]}
        for r in data.get("failed_results") or []:
            if r.get("url") in chunk:
                out.setdefault(r["url"], f"tavily: {r.get('error', 'failed')}")
    return out


def fetch_firecrawl(urls, max_age_hours):
    out = {}
    for url in urls:
        _, data = http("POST", "https://api.firecrawl.dev/v2/scrape",
                       {"Authorization": "Bearer " + _key("firecrawl"), "Content-Type": "application/json"},
                       {"url": url, "formats": ["markdown"], "onlyMainContent": True,
                        "maxAge": max_age_hours * 3600 * 1000}, timeout=120)
        d = (data or {}).get("data") if isinstance(data, dict) else None
        if not d or not d.get("markdown"):
            continue
        meta = d.get("metadata") or {}
        code = meta.get("statusCode")
        if code is not None and not (200 <= int(code) < 300 or int(code) == 304):
            out[url] = f"firecrawl: page status {code}"
            continue
        out[url] = {"text": d["markdown"], "title": meta.get("title"), "lang": meta.get("language"),
                    "final_url": meta.get("url")}
    return out


def fetch_tinyfish(urls, max_age_hours):
    out = {}
    for i in range(0, len(urls), 10):
        chunk = urls[i:i + 10]
        _, data = http("POST", "https://api.fetch.tinyfish.ai",
                       {"X-API-Key": _key("tinyfish"), "Content-Type": "application/json"},
                       {"urls": chunk, "format": "markdown", "ttl": max_age_hours * 3600,
                        "per_url_timeout_ms": 60000}, timeout=150)
        if not isinstance(data, dict):
            continue
        for r in data.get("results") or []:
            if r.get("url") in chunk and isinstance(r.get("text"), str) and r["text"]:
                out[r["url"]] = {"text": r["text"], "title": r.get("title"), "author": r.get("author"),
                                 "published": r.get("published_date"), "final_url": r.get("final_url")}
        for r in data.get("errors") or []:
            if r.get("url") in chunk:
                out.setdefault(r["url"], f"tinyfish: {r.get('error', 'failed')}")
    return out


def fetch_jina(urls, max_age_hours):
    out = {}
    for url in urls:
        if not public_for_third_party(url):
            out[url] = "jina: skipped, the URL looks private"
            continue
        headers = {"DNT": "1", "Accept": "application/json"}
        if os.environ.get("JINA_API_KEY"):
            headers["Authorization"] = "Bearer " + os.environ["JINA_API_KEY"]
        _, data = http("GET", "https://r.jina.ai/" + url, headers, None, timeout=90)
        d = data.get("data") if isinstance(data, dict) else None
        if d and d.get("content"):
            out[url] = {"text": d["content"], "title": d.get("title"), "published": d.get("publishedTime"),
                        "final_url": d.get("url")}
    return out


def fetch_crawl4ai(urls, max_age_hours):
    """One helper run for every URL: one browser session, UTF-8 output file, no page text on
    stdout. A helper failure is reported per URL; the caller turns it into a NOTE line."""
    python = find_crawl4ai_python()
    if not python:
        return {url: "crawl4ai: the Crawl4AI venv python was not found" for url in urls}
    env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    # the helper stops itself after the same per-page budget plus its own 60 s grace; the parent
    # waits 60 s longer, so the helper's missing-line records reach the file before we read it
    budget = CRAWL4AI_TIMEOUT * max(1, (len(urls) + CRAWL4AI_CONCURRENCY - 1) // CRAWL4AI_CONCURRENCY) + 120
    with tempfile.TemporaryDirectory(prefix="crawl4ai-") as tmp:
        urls_file, out_file = Path(tmp) / "urls.json", Path(tmp) / "pages.jsonl"
        urls_file.write_text(json.dumps(urls, ensure_ascii=False), encoding="utf-8")
        try:
            proc = subprocess.run(
                [python, str(CRAWL4AI_SCRIPT), str(urls_file), str(out_file),
                 "--timeout", str(CRAWL4AI_TIMEOUT), "--concurrency", str(CRAWL4AI_CONCURRENCY)],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
                timeout=budget, env=env)
        except subprocess.TimeoutExpired:
            return {url: f"crawl4ai: timeout after {budget} s" for url in urls}
        except OSError as exc:
            return {url: f"crawl4ai: not startable ({type(exc).__name__})" for url in urls}
        lines = []
        if out_file.is_file():
            try:
                lines = [line for line in out_file.read_text(encoding="utf-8").splitlines() if line.strip()]
            except UnicodeDecodeError:
                return {url: "crawl4ai: output is not UTF-8" for url in urls}
    if proc.returncode != 0 and not lines:
        return {url: f"crawl4ai: the helper failed (exit {proc.returncode})" for url in urls}
    records = {}
    for line in lines:
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and isinstance(record.get("url"), str):
            records[record["url"]] = record
    out = {}
    for url in urls:
        record = records.get(url)
        if record is None:
            out[url] = "crawl4ai: no line for this URL"
        elif record.get("ok") and isinstance(record.get("markdown"), str):
            out[url] = {"text": record["markdown"], "status": record.get("status")}
        else:
            out[url] = f"crawl4ai: {record.get('error') or 'HTTP ' + str(record.get('status'))}"
    return out


FETCHERS = {"exa": fetch_exa, "you": fetch_you, "tavily": fetch_tavily, "firecrawl": fetch_firecrawl,
            "tinyfish": fetch_tinyfish, "jina": fetch_jina, "crawl4ai": fetch_crawl4ai}


def wayback(url):
    """(snapshot URL, timestamp) of the nearest capture, or (None, None). Only asks, once, no
    retries; raises ServiceDown when the Archive refuses (the caller then stops asking)."""
    _, data = http("GET", "https://archive.org/wayback/available?url=" + quote(url, safe=""),
                   None, None, timeout=20, retry=False)
    closest = ((data or {}).get("archived_snapshots") or {}).get("closest") if isinstance(data, dict) else None
    if closest and closest.get("available") and closest.get("url"):
        return closest["url"].replace("http://", "https://", 1), closest.get("timestamp")
    return None, None


# ---------- saving ----------

def header_text(fields):
    lines = ["---"]
    for key, value in fields.items():
        if value in (None, ""):
            continue
        lines.append(f"{key}: {json.dumps(str(value).replace(chr(10), ' ').strip(), ensure_ascii=False)}")
    lines.append("---")
    return "\n".join(lines) + "\n"


ERROR_PAGE = re.compile(r"\b404\b|not found|nicht gefunden|page (?:does not|doesn.t) exist|"
                        r"existiert nicht|access denied|zugriff verweigert|are you a robot|captcha|"
                        r"enable javascript|just a moment", re.I)


ERROR_HEADING = re.compile(r"(?m)^#{1,3}\s[^\n]*(?:\b404\b|not found|nicht gefunden|existiert nicht|"
                           r"access denied|zugriff verweigert)", re.I)


def looks_like_error_page(text):
    """A short page that reads like an error, block or captcha page (soft 404): an error phrase
    at the start, or an error heading in a page that is mostly navigation (under 12,000 characters)."""
    plain = normalize(text)
    if len(plain) < 1500 and ERROR_PAGE.search(plain[:600]):
        return True
    return len(plain) < 12000 and bool(ERROR_HEADING.search(text[:6000]))


def content_hash(text):
    return hashlib.sha256(normalize(text)[:3000].casefold().encode("utf-8")).hexdigest()


def run(workdir, candidates_dir, max_pages, max_age_hours, ask_wayback=True):
    work = Path(workdir)
    pages = work / "pages"
    pages.mkdir(exist_ok=True)
    candidates, dropped = load_candidates(work / candidates_dir, max_pages)
    if not candidates:
        raise DataError("no usable candidates")
    info = {c["url"]: c for c in candidates}
    errors = {u: [] for u in info}
    results, used = {}, {}
    dead = set()
    notes = [f"dropped (not fetchable): {u}" for u in dropped]
    for name in ORDER:
        if name in KEYS and not _key(name):
            notes.append(f"{name}: no key in the environment, skipped")
            continue
        if name == "crawl4ai" and not find_crawl4ai_python():
            notes.append("crawl4ai: the Crawl4AI venv python was not found, skipped - install it with the setup")
            continue
        todo = [u for u in info if u not in results
                and not (name not in PROVIDERS and is_reddit(u))]
        if name in PAGE_CAP:
            todo = todo[:PAGE_CAP[name]]
        if not todo or name in dead:
            continue
        try:
            got = FETCHERS[name](todo, max_age_hours)
        except ServiceDown as exc:
            dead.add(name)
            notes.append(f"{name}: stopped for this run ({exc})")
            continue
        for url, value in got.items():
            reason = None
            if isinstance(value, str):
                errors[url].append(value)
                reason = value.removeprefix("crawl4ai: ") if name == "crawl4ai" else None
            elif len(normalize(value["text"])) < MIN_CHARS:
                reason = f"text shorter than {MIN_CHARS} characters"
                errors[url].append(f"{name}: {reason}")
            elif looks_like_error_page(value["text"]):
                reason = "looks like an error page, not the page"
                errors[url].append(f"{name}: {reason}")
            else:
                results[url], used[url] = value, name
            if name == "crawl4ai" and reason is not None:
                notes.append(f"crawl4ai: {url} -> {reason}")
    index, hashes, number = [], {}, 0
    wayback_failures = 0
    for url, cand in info.items():
        entry = {"url": url, "type": cand.get("type"), "pass": cand.get("pass"), "lang": cand.get("lang"),
                 "attempts": errors[url]}
        if url not in results:
            reason = "; ".join(errors[url]) or "no method returned text"
            if is_reddit(url):
                reason = "not readable (Reddit is read only through the content services): " + reason
            index.append({**entry, "status": "failed", "error": reason})
            continue
        res = results[url]
        digest = content_hash(res["text"])
        if digest in hashes:
            index.append({**entry, "status": "duplicate", "duplicate_of": hashes[digest]})
            continue
        number += 1
        name = f"{number:03d}-{domain_slug(res.get('final_url') or url)}.md"
        hashes[digest] = name
        archive_url, stamp = None, None
        if ask_wayback:
            try:
                archive_url, stamp = wayback(url)
                wayback_failures = 0
                time.sleep(WAYBACK_PAUSE)
            except ServiceDown as exc:
                wayback_failures += 1
                if wayback_failures >= 3:
                    ask_wayback = False
                    notes.append(f"wayback: not asked again in this run ({exc})")
                else:
                    time.sleep(WAYBACK_RETRY_WAIT)
        fields = {"url": url, "final_url": res.get("final_url") if res.get("final_url") != url else None,
                  "title": res.get("title") or cand.get("title"), "author": res.get("author"),
                  "published": res.get("published") or cand.get("date"), "lang": res.get("lang") or cand.get("lang"),
                  "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "method": used[url], "chars": len(res["text"]), "type": cand.get("type"),
                  "pass": cand.get("pass"), "archive_url": archive_url, "archive_timestamp": stamp}
        text = res["text"].replace("\r\n", "\n").replace("\x00", "")
        (pages / name).write_text(header_text(fields) + text.strip("\n") + "\n", encoding="utf-8", newline="\n")
        index.append({**entry, "status": "saved", "file": name, "method": used[url],
                      "chars": len(res["text"]), "title": fields["title"], "archive_url": archive_url})
    (pages / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=1) + "\n",
                                      encoding="utf-8", newline="\n")
    return index, notes


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("workdir")
    parser.add_argument("--candidates", default="candidates")
    parser.add_argument("--max-pages", type=int, default=40)
    parser.add_argument("--max-age-hours", type=int, default=24)
    parser.add_argument("--no-wayback", action="store_true")
    args = parser.parse_args(argv)
    utf8_output()
    try:
        index, notes = run(args.workdir, args.candidates, args.max_pages, args.max_age_hours,
                           not args.no_wayback)
    except (DataError, OSError) as exc:
        print(f"ERROR {exc}")
        return 1
    for note in notes:
        print("NOTE", note)
    saved = [i for i in index if i["status"] == "saved"]
    for item in index:
        if item["status"] == "failed":
            print("FAILED", item["url"], "-", item["error"][:160])
    methods = {}
    for item in saved:
        methods[item["method"]] = methods.get(item["method"], 0) + 1
    print(f"saved {len(saved)} of {len(index)} ({methods}); failed "
          f"{sum(i['status'] == 'failed' for i in index)}; duplicates "
          f"{sum(i['status'] == 'duplicate' for i in index)}; snapshots "
          f"{sum(bool(i.get('archive_url')) for i in saved)}")
    return 0 if saved else 1


if __name__ == "__main__":
    sys.exit(main())
