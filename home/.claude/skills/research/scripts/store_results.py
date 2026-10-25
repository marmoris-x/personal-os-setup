"""Store a finished research text in the vault (standard section 8, vault layout of part 6.8).

Usage:
  python store_results.py <workdir> --article draft/article.md --slug <slug> --date YYYY-MM-DD
         --answer-lang de --source-langs de,ar [--vault {{VAULT_JSON}}] [--review-days 90]

Writes, and never overwrites:
  <vault>/400-knowledge/research/<date>-<slug>.md          the text, with frontmatter
  <vault>/500-sources/research/<date>-<slug>/evidence.md   the evidence the text uses (English)
  <vault>/500-sources/research/<date>-<slug>/pages/*.md    copies of the cited pages only
  <vault>/400-knowledge/research/_index.md                 one line, newest first
Markdown images are removed from the copied pages (vault rule 5). Prints paths and counts only.
A text that still carries bare reference numbers ([1](url) [1] - the r1 defect) is refused:
it has to go through build_references.py and check_article.py first.
It does not run git; the caller adds exactly the printed paths.
"""

import argparse
import re
import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import (COMPOSE_RE, DataError, load_evidence, paragraphs, parse_compose,  # noqa: E402
                    UNTRUSTED_MARKER_RE, read_page, utf8_output)

SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+){0,5}$")
IMAGE_RE = re.compile(r"!\[[^\]]*\]\([^)]*\)")


def frontmatter_first(raw):
    """A saved page opens with the untrusted marker line; the vault copy needs the frontmatter on
    the very first line, so the marker moves to the line below the frontmatter."""
    lines = raw.split("\n")
    if not (lines and UNTRUSTED_MARKER_RE.match(lines[0]) and len(lines) > 1 and lines[1].strip() == "---"):
        return raw
    for i in range(2, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i + 1] + [lines[0]] + lines[i + 1:])
    return raw
LANG_RE = re.compile(r"^[a-z]{2,3}(?:-[A-Za-z]{2,4})?$")
LOCAL_COPY_RE = re.compile(r"\]\(([^)\s]*pages/([^)\s/]+\.md))\)")
REFS_RE = re.compile(r"<!-- references:start -->(.*?)<!-- references:end -->", re.S)
BARE_REF = re.compile(r"\[(\d+)\](?!\()")
QUOTED = re.compile(r'"[^"\n]*"')
LONG_NOTE_LINES = 400


def bare_reference_numbers(article):
    """Numbers like [12] that stand without a link, outside quotes, comments and the list.

    The r1 defect [1](url) [1] leaves exactly such a number behind each link. A number
    inside a quote is source wording, and the reference list's own [n] leads are fine.
    """
    text = REFS_RE.sub("", article)
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.S)
    text = QUOTED.sub(lambda m: " " * len(m.group(0)), text)
    return [m.group(1) for m in BARE_REF.finditer(text)]


def title_of(article):
    match = re.search(r"(?m)^# (.+?)\s*$", article)
    if not match:
        raise DataError("the article has no level-1 title")
    return match.group(1)


def used_evidence_ids(article):
    ids = []
    for block in paragraphs(article):
        compose = parse_compose(block)
        if compose:
            for ev_id in compose["ids"]:
                if ev_id not in ids:
                    ids.append(ev_id)
    return ids


def evidence_md(question, day, answer_lang, source_langs, items):
    lines = ["---", "type: document", "status: active", f"date: '{day}'", "trust: untrusted", "---", "",
             f"# Evidence: {question}", "",
             "Text quoted from other people's pages, verified word for word against the saved copies.",
             f"Answer language: {answer_lang}. Source languages: {', '.join(source_langs)}.", ""]
    for item in items:
        lines += [f"## {item['id']}", "",
                  f"- URL: {item.get('url', '')}",
                  f"- Page copy: pages/{item['page']} (lines {item['lines'][0]} to {item['lines'][1]})",
                  f"- Type: {item.get('type', '')}; language: {item.get('lang', '')}; match: {item.get('match', '')}",
                  f"- Supports: {item.get('claim', '')}", ""]
        lines += ["> " + IMAGE_RE.sub("", part) for part in item["text"].split("\n")]
        lines.append("")
    return "\n".join(lines)


def frontmatter(title, day, answer_lang, source_langs, count, review_days):
    review = (date.fromisoformat(day) + timedelta(days=review_days)).isoformat()
    topic = title.replace("'", "''")
    return "\n".join([
        "---", "type: note", "status: active", f"date: '{day}'", f"verified: '{day}'",
        f"review_by: '{review}'", f"topic: '{topic}'", f"answer_language: {answer_lang}",
        f"source_languages: [{', '.join(source_langs)}]", f"sources_count: {count}", "---", ""])


def index_line(slug, day, title, answer_lang, count):
    clean = re.sub(r"[|\]#^\[]", "", title).strip()
    return f"- [[{day}-{slug}|{clean}]] - {answer_lang}, {count} sources ({day})"


def update_index(index_path, line):
    if index_path.exists():
        lines = index_path.read_text(encoding="utf-8").splitlines()
        first = next((n for n, old in enumerate(lines) if old.startswith("- [[")), None)
        if first is None:  # no entry yet: after the intro, at the end of the file
            while lines and not lines[-1].strip():
                lines.pop()
            lines += ["", line]
        else:
            lines.insert(first, line)
        text = "\n".join(lines) + "\n"
    else:
        text = ("---\ntype: note\nstatus: active\ndate: '" + date.today().isoformat() + "'\n---\n\n"
                "# Research\n\nOne line per research text, newest first. Made with the `research` skill.\n\n"
                + line + "\n")
    index_path.write_text(text, encoding="utf-8", newline="\n")


def store(workdir, article_path, slug, day, answer_lang, source_langs, vault, review_days):
    work, vault = Path(workdir), Path(vault)
    if not SLUG_RE.match(slug):
        raise DataError("slug must be lower case ASCII words joined by hyphens, at most six words")
    date.fromisoformat(day)
    for lang in [answer_lang, *source_langs]:
        if not LANG_RE.match(lang):
            raise DataError(f"not a language code: {lang!r}")
    article = Path(article_path).read_text(encoding="utf-8")
    bare = bare_reference_numbers(article)
    if bare:
        raise DataError(f"the article has {len(bare)} bare reference number(s) (for example "
                        f"[{bare[0]}]); only [n](url) links belong in the text - run "
                        f"build_references.py and check_article.py first")
    title = title_of(article)
    note = vault / "400-knowledge" / "research" / f"{day}-{slug}.md"
    src = vault / "500-sources" / "research" / f"{day}-{slug}"
    if note.exists() or src.exists():
        raise DataError(f"already exists, not overwritten: {note.name}")
    copied_names = []
    for _, name in LOCAL_COPY_RE.findall(article):
        if name not in copied_names:
            copied_names.append(name)
    for name in copied_names:
        if not (work / "pages" / name).is_file():
            raise DataError(f"the text links page {name}, which is not in the work folder")
    prefix = f"500-sources/research/{day}-{slug}/pages/"
    if copied_names and prefix not in "/".join(LOCAL_COPY_RE.findall(article)[0][0].split("\\")):
        raise DataError(f"local copy links must point to ../../{prefix}")
    evidence = load_evidence(work)
    used = [evidence[i] for i in used_evidence_ids(article) if i in evidence]
    count = len(copied_names)
    (src / "pages").mkdir(parents=True)
    removed = 0
    for name in copied_names:
        header, body, _ = read_page(work / "pages" / name)
        raw = (work / "pages" / name).read_text(encoding="utf-8")
        removed += len(IMAGE_RE.findall(raw))
        (src / "pages" / name).write_text(frontmatter_first(IMAGE_RE.sub("", raw)), encoding="utf-8", newline="\n")
    question = (work / "question.md").read_text(encoding="utf-8").strip().splitlines()[0].lstrip("# ").strip() \
        if (work / "question.md").is_file() else title
    (src / "evidence.md").write_text(evidence_md(question, day, answer_lang, source_langs, used),
                                     encoding="utf-8", newline="\n")
    note.parent.mkdir(parents=True, exist_ok=True)
    body = COMPOSE_RE.sub("", article)
    note.write_text(frontmatter(title, day, answer_lang, source_langs, count, review_days) + body.lstrip("\n"),
                    encoding="utf-8", newline="\n")
    index = note.parent / "_index.md"
    update_index(index, index_line(slug, day, title, answer_lang, count))
    paths = [note, src / "evidence.md", index, *sorted((src / "pages").glob("*.md"))]
    lines = len(note.read_text(encoding="utf-8").splitlines())
    return paths, count, removed, lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("workdir")
    parser.add_argument("--article", required=True)
    parser.add_argument("--slug", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--answer-lang", required=True)
    parser.add_argument("--source-langs", required=True)
    parser.add_argument("--vault", default=r"{{VAULT}}")
    parser.add_argument("--review-days", type=int, default=90)
    args = parser.parse_args(argv)
    utf8_output()
    work = Path(args.workdir)
    article = Path(args.article) if Path(args.article).is_absolute() else work / args.article
    try:
        paths, count, removed, lines = store(work, article, args.slug, args.date, args.answer_lang,
                                             [s for s in args.source_langs.split(",") if s],
                                             args.vault, args.review_days)
    except (DataError, OSError, ValueError) as exc:
        print(f"ERROR {exc}")
        return 1
    for path in paths:
        print("WROTE", path)
    if lines >= LONG_NOTE_LINES:
        print(f"WARNING the note has {lines} lines (vault-lint warns from {LONG_NOTE_LINES})")
    print(f"stored: {count} pages copied, {removed} images removed, note {lines} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
