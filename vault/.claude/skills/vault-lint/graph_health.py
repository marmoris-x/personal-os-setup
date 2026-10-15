r"""Check the vault's wiki graph: broken links, orphan notes, duplicate names.

Usage: python -I -X utf8 graph_health.py [--vault {{VAULT}}]

Scanned as notes (link sources): 000-meta, 100-daily, 200-projects,
300-areas, 400-knowledge, 900-inactive.
Never scanned (per vault-lint): 500-sources (append-only foreign text,
[[...]] is usually not a link there), 900-inactive/research-tests (test
material of the research system: saved foreign pages and their evidence
files, whose internal links point into the origin sites, never into the
vault - same reasoning as 500-sources), 600-archive (machine generated),
inbox (staging), trash, outbox, .obsidian, .claude, .git.
Links may still point INTO those folders; resolution sees every file in
the vault except .git, .obsidian, trash and outbox.

Checks:
  1. broken wikilinks - every [[target]] ([[target|alias]], [[target#head]],
     [[target^block]] included) in a scanned note must resolve to an existing
     file, by vault-relative path or by name, case-insensitive
  2. broken relative Markdown links - every [text](target) whose target is a
     relative path (no scheme, no leading slash) must point at an existing
     file; the research notes link their local copies this way
     (../../500-sources/...). Percent-encoding is decoded; an anchor is
     ignored; code fences and spans are exempt like above
  3. orphan notes - a note in 200-projects, 300-areas or 400-knowledge that
     no scanned note links to (AGENTS.md hard rule 13)
  4. duplicate names - the same file name (stem) twice in the scanned area,
     or the same frontmatter alias on two notes: such links are ambiguous;
     fix with an alias or a path link

Obsidian does not render [[...]] inside code as links, so fenced blocks
and inline code spans are blanked out before the scan (line numbers stay
true). Best effort: escaped backticks are not modelled.
Exit 1 when there is at least one finding.
"""
import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote

SCAN_DIRS = ["000-meta", "100-daily", "200-projects", "300-areas",
             "400-knowledge", "900-inactive"]
ORPHAN_DIRS = ["200-projects", "300-areas", "400-knowledge"]
# Vault-relative subtrees that stay out of the note scan (see the doc string).
SCAN_SKIP_SUBTREES = ["900-inactive/research-tests"]
TARGET_SKIP = {".git", ".obsidian", "trash", "outbox"}
LINK_RE = re.compile(r"\[\[([^\[\]\n]+?)\]\]")
MD_LINK_RE = re.compile(r"!?\[[^\]\n]*\]\(([^)\n]+)\)")
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
FENCE_RE = re.compile(r"```.*?```", re.S)
CODE_SPAN_RE = re.compile(r"`[^`\n]*`")


def md_target(raw):
    """The path of a Markdown link target, or None when it is not a relative path."""
    target = raw.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1].strip()
    elif " " in target:
        target = target.split(" ", 1)[0]  # a title after the path
    target = target.split("#", 1)[0]
    if not target or target.startswith(("/", "#")) or SCHEME_RE.match(target):
        return None
    return unquote(target)


def strip_code(text):
    # Blank out fenced blocks and inline code spans while keeping length and
    # line breaks, so [[...]] inside code is not read as a link and the line
    # numbers of the remaining links stay true.
    text = FENCE_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    text = CODE_SPAN_RE.sub(lambda m: " " * len(m.group(0)), text)
    return text


FM_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---", re.S)
ALIASES_RE = re.compile(r"^aliases:\s*(.*)$")


def read_aliases(text):
    # aliases: [a, b]  /  aliases: a  /  aliases:\n  - a\n  - b
    m = FM_RE.match(text)
    if not m:
        return []
    lines = m.group(1).splitlines()
    for i, line in enumerate(lines):
        am = ALIASES_RE.match(line)
        if not am:
            continue
        rest = am.group(1).strip()
        if rest.startswith("[") and rest.endswith("]"):
            parts = [x.strip().strip("'\"") for x in rest[1:-1].split(",")]
        elif rest:
            parts = [rest.strip("'\"")]
        else:
            parts = []
            for nxt in lines[i + 1:]:
                item = re.match(r"^\s+-\s+(.+)$", nxt)
                if not item:
                    break
                parts.append(item.group(1).strip().strip("'\""))
        return [p for p in parts if p]
    return []


def split_target(raw):
    target = raw.split("|", 1)[0]
    target = target.split("#", 1)[0].split("^", 1)[0].strip()
    return target


def in_skipped_subtree(path, vault):
    rel = path.relative_to(vault).as_posix()
    return any(rel == s or rel.startswith(s + "/") for s in SCAN_SKIP_SUBTREES)


def collect_targets(vault):
    by_key = {}
    by_stem = {}
    for p in vault.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(vault)
        if rel.parts[0] in TARGET_SKIP:
            continue
        relposix = rel.as_posix()
        key = relposix[:-3].lower() if p.suffix.lower() == ".md" else relposix.lower()
        by_key.setdefault(key, []).append(p)
        by_stem.setdefault(p.stem.lower(), []).append(p)
    return by_key, by_stem


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", default=r"{{VAULT}}")
    args = parser.parse_args()
    vault = Path(args.vault)

    by_key, by_stem = collect_targets(vault)

    def resolve(target):
        t = target.replace("\\", "/")
        if t.lower().endswith(".md"):
            t = t[:-3]
        key = t.lower()
        if key in by_key:
            return by_key[key]
        stem = key.rsplit("/", 1)[-1]
        return by_stem.get(stem, [])

    notes = []
    for d in SCAN_DIRS:
        folder = vault / d
        if folder.is_dir():
            notes.extend(sorted(p for p in folder.rglob("*.md")
                                if p.is_file() and not in_skipped_subtree(p, vault)))

    findings = 0
    link_count = 0
    md_count = 0
    incoming = {}
    alias_map = {}

    for note in notes:
        try:
            text = note.read_text(encoding="utf-8", errors="replace")
        except OSError:
            print("FINDING unreadable note: " + note.relative_to(vault).as_posix())
            findings += 1
            continue
        for alias in read_aliases(text):
            alias_map.setdefault(alias.lower(), []).append(note)
        scan = strip_code(text)
        for m in LINK_RE.finditer(scan):
            target = split_target(m.group(1))
            if not target:
                continue
            link_count += 1
            hits = resolve(target)
            if not hits:
                line = scan.count("\n", 0, m.start()) + 1
                print("FINDING broken link: " + note.relative_to(vault).as_posix()
                      + ":" + str(line) + " -> " + target)
                findings += 1
                continue
            for h in hits:
                if h != note:
                    incoming[h] = incoming.get(h, 0) + 1
        for m in MD_LINK_RE.finditer(scan):
            target = md_target(m.group(1))
            if target is None:
                continue
            md_count += 1
            if not (note.parent / target).resolve().is_file():
                line = scan.count("\n", 0, m.start()) + 1
                print("FINDING broken markdown link: " + note.relative_to(vault).as_posix()
                      + ":" + str(line) + " -> " + target)
                findings += 1

    for d in ORPHAN_DIRS:
        folder = vault / d
        if not folder.is_dir():
            continue
        for note in sorted(p for p in folder.rglob("*.md") if p.is_file()):
            if incoming.get(note, 0) == 0:
                print("FINDING orphan note: " + note.relative_to(vault).as_posix())
                findings += 1

    dupes = {}
    for d in SCAN_DIRS:
        folder = vault / d
        if folder.is_dir():
            for p in folder.rglob("*.md"):
                if p.is_file() and not in_skipped_subtree(p, vault):
                    dupes.setdefault(p.stem.lower(), []).append(
                        p.relative_to(vault).as_posix())
    for stem, paths in sorted(dupes.items()):
        if len(paths) > 1:
            print("FINDING duplicate name: " + stem + " -> "
                  + ", ".join(sorted(paths)))
            findings += 1

    for alias, files in sorted(alias_map.items()):
        if len(files) > 1:
            print("FINDING alias collision: " + alias + " -> "
                  + ", ".join(sorted(p.relative_to(vault).as_posix() for p in files)))
            findings += 1

    print("scanned " + str(len(notes)) + " notes, " + str(link_count) + " wikilinks, "
          + str(md_count) + " markdown links")
    print("findings: " + str(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
