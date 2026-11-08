"""Resolve redirect links in a Markdown file, unify the citation numbers, write a source list.

Handles: google.com/url?...q=<target> (decoded locally) and
vertexaisearch.cloud.google.com/grounding-api-redirect/... (one request, Location header).

The citation markers of Google AI Studio are `[[N](url)]` (older files may use `[N](url)`).
The same page often appears under several numbers. The script keeps the first number of each
unique page and rewrites the later markers to it, so every number in the text matches exactly
one entry in the `## Sources` list.

Usage: python -I resolve_sources.py <file.md> [--dry-run]
Exit codes: 0 ok, 1 some links unresolved, 2 bad input.
"""
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HEADINGS = ("## Sources", "## Quellenverzeichnis", "## Quellenprüfung", "## Source check")
HEADING = "## Sources"
LINK = re.compile(r"\[([^\]]*)\]\((https?://[^)\s]+)\)")
# [[N](url)] first, then the older [N](url)
CITE = re.compile(r"\[\[(\d+)\]\((https?://[^)\s]+)\)\]|\[(\d+)\]\((https?://[^)\s]+)\)")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def host(url):
    return urllib.parse.urlparse(url).netloc.lower()


def is_redirect(url):
    h = host(url)
    path = urllib.parse.urlparse(url).path
    return (h in ("www.google.com", "google.com") and path == "/url") or (
        h == "vertexaisearch.cloud.google.com" and "grounding-api-redirect" in path
    )


def resolve(url):
    cur = url
    for _ in range(6):
        if not is_redirect(cur):
            return cur
        if host(cur) in ("www.google.com", "google.com"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(cur).query)
            nxt = (q.get("q") or q.get("url") or [None])[0]
            if not nxt:
                return None
            cur = nxt
            continue
        try:
            OPENER.open(urllib.request.Request(cur, headers={"User-Agent": "Mozilla/5.0"}), timeout=20)
            return None
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location")
            if e.code in (301, 302, 303, 307, 308) and loc:
                cur = urllib.parse.urljoin(cur, loc)
            else:
                return None
        except Exception:
            return None
    return None


def canon(url):
    """Compare URLs without fragment, trailing slash or a different host case."""
    p = urllib.parse.urlsplit(url)
    path = p.path.rstrip("/") or "/"
    return urllib.parse.urlunsplit((p.scheme.lower(), p.netloc.lower(), path, p.query, ""))


def citation_parts(m):
    """Return (number, url, style) for a citation match; style is 'double' or 'single'."""
    if m.group(1) is not None:
        return int(m.group(1)), m.group(2), "double"
    return int(m.group(3)), m.group(4), "single"


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = "--dry-run" in sys.argv[1:]
    if len(args) != 1 or not args[0].lower().endswith(".md"):
        print("Usage: resolve_sources.py <file.md> [--dry-run]")
        return 2
    path = args[0]
    try:
        raw = open(path, encoding="utf-8", newline="").read()
    except OSError as e:
        print("Cannot read file: %s" % e)
        return 2
    nl = "\r\n" if "\r\n" in raw else "\n"
    # Cut every section this script owns; an old check is stale after a new run.
    cut = len(raw)
    for h in HEADINGS:
        m = re.search(r"(?m)^" + re.escape(h) + r"\s*$", raw)
        if m:
            cut = min(cut, m.start())
    body = raw[:cut]

    unique = sorted({m.group(2) for m in LINK.finditer(body) if is_redirect(m.group(2))})
    with ThreadPoolExecutor(8) as ex:
        real = dict(zip(unique, ex.map(resolve, unique)))
    failed = [u for u, r in real.items() if not r]

    replaced = [0]

    def sub_link(m):
        text, url = m.group(1), m.group(2)
        if not is_redirect(url):
            return m.group(0)
        r = real.get(url)
        if not r:
            return m.group(0)
        replaced[0] += 1
        return "[%s](%s)" % (text, r)

    body = LINK.sub(sub_link, body)

    # Canonical numbering: one number per page, first occurrence wins.
    targets = {}      # canonical url key -> number
    used = {}         # number -> canonical url key
    display = {}      # canonical url key -> url as written
    max_num = max([citation_parts(m)[0] for m in CITE.finditer(body)] or [0])
    next_num = max_num
    conflicts = 0
    merged = 0
    citations = 0
    rewrite = {}      # (style, original number, url) -> new number

    for m in CITE.finditer(body):
        citations += 1
        n, url, style = citation_parts(m)
        if is_redirect(url):
            continue  # unresolved: keep the marker, do not list a redirect as a source
        key = canon(url)
        if key in targets:
            target = targets[key]
            if target != n:
                merged += 1
        elif n not in used:
            target = n
            targets[key] = n
            used[n] = key
        else:
            next_num += 1
            target = next_num
            targets[key] = target
            used[target] = key
            conflicts += 1
        display.setdefault(key, url)
        rewrite[(style, n, url)] = target

    def sub_cite(m):
        n, url, style = citation_parts(m)
        target = rewrite.get((style, n, url), n)
        if style == "double":
            return "[[%d](%s)]" % (target, url)
        return "[%d](%s)" % (target, url)

    body = CITE.sub(sub_cite, body)
    # Two numbers for the same page both became the first number; one marker is enough.
    # Only spaces/tabs between them may be consumed - a newline starts another statement.
    body = re.sub(r"((?:\[\[\d+\]\([^)\s]+\)\]|\[\d+\]\([^)\s]+\)))(?:[ \t]*\1)+", r"\1", body)

    items = sorted((n, display[key]) for key, n in targets.items())
    domains = {host(u).removeprefix("www.") for _, u in items}
    gaps = [n for n in range(1, (items[-1][0] if items else 0) + 1)
            if n not in {x[0] for x in items}]

    if items:
        lines = [HEADING, ""]
        if merged or conflicts or gaps:
            lines += ["*Nummern wie im Text. Mehrfach verwendete Nummern derselben Quelle wurden "
                      "auf die erste zusammengeführt.*", ""]
        lines += ["%d. [%s](%s)" % (n, host(u).removeprefix("www."), u) for n, u in items]
        new = body.rstrip("\r\n") + nl + nl + nl.join(lines) + nl
    else:
        new = raw
    if not dry and items:
        open(path, "w", encoding="utf-8", newline="").write(new)
    print("%sresolved %d links, %d citations, %d sources, %d domains, "
          "%d duplicate numbers merged, %d number conflicts, %d unresolved"
          % ("DRY RUN: " if dry else "", replaced[0], citations,
             len(items), len(domains), merged, conflicts, len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
