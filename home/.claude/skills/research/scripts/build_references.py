"""Turn [[E12]] markers of a draft into numbered, linked references and add the reference list.

Usage:
  python build_references.py <workdir> --draft draft/draft.md --out draft/article.md --lang de
         [--accessed YYYY-MM-DD] [--pages-prefix pages/]

Numbers follow the order of first appearance, one number per source page. Each number links to
the page URL plus a text fragment (#:~:text=start,end) built from the evidence text; if start or
end is not found in the saved page, the link has no fragment and a warning is printed.
Numbers the writer wrote itself are removed, repeated numbers in one group are dropped and the
group is sorted ascending. Tracking and challenge parameters are stripped from every URL.
The list goes where the marker <!-- references --> stands (or at the end), between
<!-- references:start --> and <!-- references:end -->.
Standard: ~/.claude/docs/research-standard.md sections 7 and 8.
"""

import argparse
import json
import re
import sys
from collections import Counter
from datetime import date
from pathlib import Path
from urllib.parse import quote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import (MARKER_RE, DataError, clean_url, load_evidence, load_index,  # noqa: E402
                    normalize, plain_markdown, read_page, strip_tracking, utf8_output)

LABELS = {
    "en": {"title": "References", "no_date": "no date", "accessed": "Accessed", "archive": "Archive",
           "local": "Local copy", "language": "Language", "updated": "updated",
           "primary": "primary source", "secondary": "secondary source",
           "experience": "user experience", "type": "Source type"},
    "de": {"title": "Quellen", "no_date": "ohne Datum", "accessed": "Abgerufen", "archive": "Archiv",
           "local": "Lokale Kopie", "language": "Sprache", "updated": "aktualisiert",
           "primary": "Primärquelle", "secondary": "Sekundärquelle",
           "experience": "Erfahrungsbericht", "type": "Quellenart"},
    "ar": {"title": "المراجع", "no_date": "بدون تاريخ", "accessed": "تاريخ الوصول",
           "archive": "الأرشيف", "local": "نسخة محلية", "language": "اللغة", "updated": "محدث",
           "primary": "مصدر أولي", "secondary": "مصدر ثانوي", "experience": "تجربة مستخدم",
           "type": "نوع المصدر"},
}
LANG_NAMES = {"en": "English", "de": "Deutsch", "ar": "العربية", "fr": "Français", "es": "Español"}
START_WORDS = 5
END_WORDS = 5
WHOLE_UP_TO = 8
REF_TOKEN = re.compile(r"\[(\d+)\](?:\(([^)\s]*)\))?")
REF_RUN = re.compile(r"(?:\[\d+\](?:\([^)\s]*\))?[ \t]*){2,}")
QUOTED = re.compile(r'"[^"\n]*"')
JUNK_AUTHOR = re.compile(r"^count \d+ (posts|comments)$", re.I)
TITLE_SLOGANS = (" - the heart of the internet",)
ISO_DATETIME = re.compile(r"(\d{4}-\d{2}-\d{2})T[\d:.]+(?:Z|[+-]\d{2}:?\d{2})?")


def page_url(header):
    url = header.get("final_url") or header.get("url") or ""
    return strip_tracking(url.split("#")[0])


def encode_fragment_part(text):
    """Percent-encode for a text directive: also - , & which have a meaning there."""
    return quote(text, safe="").replace("-", "%2D")


def fragment_for(text, page_body):
    """Return (fragment string, warning). The fragment words must occur in the page, in order."""
    words = plain_markdown(text).split()
    if not words:
        return None, "evidence has no words"
    if len(words) <= WHOLE_UP_TO:
        start, end = " ".join(words), None
    else:
        start, end = " ".join(words[:START_WORDS]), " ".join(words[-END_WORDS:])
    page = normalize(plain_markdown(page_body))
    at = page.find(normalize(start))
    if at < 0:
        return None, "start words not found in the saved page"
    if end is not None:
        if page.find(normalize(end), at) < 0:
            return None, "end words not found in the saved page"
    directive = "text=" + encode_fragment_part(start)
    if end is not None:
        directive += "," + encode_fragment_part(end)
    return directive, None


def first_use_order(draft, evidence):
    """Source pages in order of first appearance of a marker whose evidence exists."""
    order = []
    for match in MARKER_RE.finditer(draft):
        item = evidence.get(match.group(1))
        if item and item["page"] not in order:
            order.append(item["page"])
    return order


def normalize_reference_runs(article):
    """Runs of reference numbers outside quotes: bare numbers out, duplicates out, ascending.
    Returns (text, number of bare numbers removed, number of groups put in order)."""
    removed_bare, reordered = 0, 0

    def fix_segment(segment):
        nonlocal removed_bare, reordered

        def fix_run(match):
            nonlocal removed_bare, reordered
            links, numbers = {}, []
            for token in REF_TOKEN.finditer(match.group(0)):
                number, url = int(token.group(1)), token.group(2)
                if url is None:
                    removed_bare += 1
                    continue
                if number not in links:
                    links[number] = token.group(0)
                    numbers.append(number)
            if sorted(numbers) != numbers:
                reordered += 1
            return "".join(links[n] for n in sorted(numbers))

        segment = REF_RUN.sub(fix_run, segment)
        segment, count = re.subn(r"\[\d+\](?!\()", "", segment)
        removed_bare += count
        return segment

    out, pos = [], 0
    for quoted in QUOTED.finditer(article):
        out.append(fix_segment(article[pos:quoted.start()]))
        out.append(quoted.group(0))
        pos = quoted.end()
    out.append(fix_segment(article[pos:]))
    return "".join(out), removed_bare, reordered


def clean_title(title, domain):
    """The page's own title: no site slogan, no segment that is only the domain."""
    text = " ".join((title or "").split())
    for slogan in TITLE_SLOGANS:
        if text.casefold().endswith(slogan):
            text = text[: -len(slogan)].strip(" -–—").strip()
    bare = domain.removeprefix("www.").casefold()
    segments = [s.strip() for s in re.split(r"\s*\|\s*", text) if s.strip()]
    segments = [s for s in segments if s.casefold() not in (domain.casefold(), bare)]
    text = " | ".join(segments)
    return text or None


def clean_author(author, domain):
    """The author if it is a real one: no counter, not the bare domain."""
    text = " ".join((author or "").split())
    if not text or JUNK_AUTHOR.match(text):
        return None
    bare = domain.removeprefix("www.").casefold()
    if text.casefold() in (domain.casefold(), bare):
        return None
    return text


def normalize_date(value):
    """A date as YYYY-MM-DD; an ISO timestamp keeps only its date."""
    text = " ".join((value or "").split())
    if not text:
        return None
    return ISO_DATETIME.sub(r"\1", text)


def entry_text(number, header, page_name, labels, lang, accessed, pages_prefix, fallback_type=""):
    domain = urlparse(page_url(header)).netloc.removeprefix("www.")
    author = clean_author(header.get("author"), domain)
    title = clean_title(header.get("title"), domain)
    published = normalize_date(header.get("published"))
    updated = normalize_date(header.get("updated"))
    if published:
        date_text = published
    elif updated:
        date_text = f"{labels['updated']} {updated}"
    else:
        date_text = labels["no_date"]
    if title:
        parts = [f"{title}. {domain}. {date_text}."]
    else:
        parts = [f"{domain}. {date_text}."]
    if author:
        parts.insert(0, f"{author}.")
    page_lang = header.get("lang", "")
    if page_lang and page_lang != lang:
        parts.append(f"{labels['language']}: {LANG_NAMES.get(page_lang, page_lang)}.")
    source_type = header.get("type") or ""
    if source_type not in labels:
        source_type = fallback_type if fallback_type in labels else ""
    if source_type:
        parts.append(f"{labels['type']}: {labels[source_type]}.")
    fetched = (header.get("fetched_at") or "")[:10] or accessed
    parts.append(f"{labels['accessed']} {fetched}.")
    parts.append(page_url(header))
    lines = [f"[{number}] " + " ".join(parts)]
    extra = []
    if header.get("archive_url"):
        extra.append(f"{labels['archive']}: {header['archive_url']}")
    extra.append(f"{labels['local']}: [{page_name}]({pages_prefix}{page_name})")
    lines.append("    " + ". ".join(extra))
    return "\n".join(lines)


def page_types(work, labels):
    """Page types from pages/index.json and the candidate files. The candidate files of
    older runs wrote the type as source_type; both spellings count."""
    by_file, by_url = {}, {}
    index = work / "pages" / "index.json"
    if index.exists():
        for entry in load_index(index)[0]:
            if not isinstance(entry, dict):
                continue
            kind = entry.get("type")
            kind = kind.strip().casefold() if isinstance(kind, str) else ""
            if kind in labels:
                if entry.get("file"):
                    by_file[entry["file"]] = kind
                if entry.get("url"):
                    by_url[entry["url"]] = kind
    for path in sorted((work / "candidates").glob("p*.jsonl")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            kind = (item.get("type") or item.get("source_type") or "")
            kind = kind.strip().casefold() if isinstance(kind, str) else ""
            url = clean_url(str(item.get("url") or ""))
            if kind in labels and url:
                by_url.setdefault(url, kind)
    return by_file, by_url


def build(workdir, draft_path, lang, accessed, pages_prefix):
    work = Path(workdir)
    evidence = load_evidence(work)
    draft = Path(draft_path).read_text(encoding="utf-8")
    labels = LABELS.get(lang, LABELS["en"])
    warnings = []
    if lang not in LABELS:
        warnings.append(f"no labels for language {lang!r}, using English labels")
    order = first_use_order(draft, evidence)
    number_of = {name: i + 1 for i, name in enumerate(order)}
    pages = {name: read_page(work / "pages" / name) for name in order}

    def replace_markers(match):
        ev_id = match.group(1)
        item = evidence.get(ev_id)
        if item is None:
            warnings.append(f"marker [[{ev_id}]] has no verified evidence; removed")
            return ""
        header, body, _ = pages[item["page"]]
        directive, warning = fragment_for(item["text"], body)
        if warning:
            warnings.append(f"[[{ev_id}]]: {warning}; link without fragment")
        url = page_url(header)
        if not url:
            warnings.append(f"[[{ev_id}]]: page header has no url")
        url = url.replace("(", "%28").replace(")", "%29")
        link = url + ("#:~:" + directive if directive else "")
        return f"[{number_of[item['page']]}]({link})"

    article = MARKER_RE.sub(replace_markers, draft)
    article, removed_bare, reordered = normalize_reference_runs(article)
    article = article.replace("{{N_SOURCES}}", str(len(order)))
    if removed_bare:
        warnings.append(f"{removed_bare} numbers the writer wrote removed (only [[E12]] markers count)")
    if reordered:
        warnings.append(f"{reordered} reference groups put into ascending order")
    counts = {}
    for item in evidence.values():
        if item.get("page") in number_of and item.get("type"):
            counts.setdefault(item["page"], Counter())[item["type"]] += 1
    fallback = {page: c.most_common(1)[0][0] for page, c in counts.items()}
    file_types, url_types = page_types(work, labels)
    entries = []
    for i, name in enumerate(order):
        header = pages[name][0]
        source_type = header.get("type") or ""
        if source_type not in labels:
            source_type = (file_types.get(name) or url_types.get(header.get("url", "")) or
                           fallback.get(name) or "")
        if source_type not in labels:
            warnings.append(f"page {name}: no source type in the page header, its evidence or the candidates")
        entries.append(entry_text(i + 1, header, name, labels, lang, accessed, pages_prefix,
                                  source_type))
    block = ("<!-- references:start -->\n" + f"## {labels['title']}\n\n" +
             "\n\n".join(entries) + "\n<!-- references:end -->\n")
    if "<!-- references -->" in article:
        article = article.replace("<!-- references -->", block)
    else:
        article = article.rstrip("\n") + "\n\n" + block
    return article, order, warnings


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("workdir")
    parser.add_argument("--draft", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--lang", required=True)
    parser.add_argument("--accessed", default=date.today().isoformat())
    parser.add_argument("--pages-prefix", default="pages/")
    args = parser.parse_args(argv)
    utf8_output()
    work = Path(args.workdir)
    try:
        article, order, warnings = build(work, work / args.draft if not Path(args.draft).is_absolute()
                                         else args.draft, args.lang, args.accessed, args.pages_prefix)
        out = Path(args.out) if Path(args.out).is_absolute() else work / args.out
        out.write_text(article, encoding="utf-8", newline="\n")
    except (DataError, OSError) as exc:
        print(f"ERROR {exc}")
        return 1
    for warning in warnings:
        print("WARNING", warning)
    print(f"references: {len(order)} sources, {len(warnings)} warnings, written {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
