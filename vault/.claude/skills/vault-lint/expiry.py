#!/usr/bin/env python3
"""expiry.py - read-only list of notes whose valid_until is past or near.

The optional frontmatter field `valid_until: YYYY-MM-DD` marks a note whose content
stops being true at a known date (a benefit amount for one year, a contract end, a
deadline). It lives next to the recording date, not instead of it. This check only
reports; it never edits a note or a fact.

Scope: 200-projects, 300-areas, 400-knowledge. A note without the field is silent.

    python -I -X utf8 expiry.py [--vault PATH] [--days 14] [--json PATH]

Exit codes: 0 nothing expiring, 1 findings (past, within the window, malformed),
2 bad input. The --json file is written only when the argument is given.
"""

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

SCOPES = ("200-projects", "300-areas", "400-knowledge")
FIELD = re.compile(r"^valid_until\s*:\s*(.*?)\s*$")
COMMENT = re.compile(r"\s+#.*$")


def frontmatter_field(text):
    """Return (value, line_number) for valid_until, or None.

    Frontmatter starts on line 1 with --- and ends at the next ---. A note with a
    blank line or a heading first has no frontmatter, so the field is not read.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    end = None
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            end = index
            break
    if end is None:
        return None
    for index in range(1, end):
        match = FIELD.match(lines[index])
        if match:
            value = COMMENT.sub("", match.group(1)).strip().strip("'\"")
            return value, index + 1
    return None


def parse_date(value):
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


def find_expiring(vault, days=14, today=None):
    """Return a list of finding dicts, sorted by file. Never writes."""
    vault = Path(vault)
    today = today or datetime.date.today()
    findings = []
    for scope in SCOPES:
        root = vault / scope
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.md")):
            rel = path.relative_to(vault).as_posix()
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                findings.append({
                    "file": rel, "line": 1, "status": "unreadable",
                    "valid_until": None, "value": str(exc), "days": None,
                })
                continue
            got = frontmatter_field(text)
            if not got:
                continue
            value, line = got
            if value.lower() in ("", "null", "~"):
                continue
            date = parse_date(value)
            if date is None:
                findings.append({
                    "file": rel, "line": line, "status": "malformed",
                    "valid_until": None, "value": value, "days": None,
                })
                continue
            delta = (date - today).days
            if delta < 0:
                findings.append({
                    "file": rel, "line": line, "status": "expired",
                    "valid_until": date.isoformat(), "value": value, "days": delta,
                })
            elif delta <= days:
                findings.append({
                    "file": rel, "line": line, "status": "soon",
                    "valid_until": date.isoformat(), "value": value, "days": delta,
                })
    return findings


def describe(finding):
    where = finding["file"] + ":" + str(finding["line"])
    if finding["status"] == "malformed":
        return where + ": malformed valid_until: " + finding["value"]
    if finding["status"] == "unreadable":
        return where + ": unreadable: " + finding["value"]
    if finding["status"] == "expired":
        return where + ": valid_until " + finding["valid_until"] + " (expired " + str(-finding["days"]) + " days ago)"
    return where + ": valid_until " + finding["valid_until"] + " (expires in " + str(finding["days"]) + " days)"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Report notes whose valid_until is past or near.")
    parser.add_argument("--vault", default=".", help="vault root (default: current directory)")
    parser.add_argument("--days", type=int, default=14, help="window in days (default 14)")
    parser.add_argument("--json", default="", help="write the findings as JSON to this file")
    args = parser.parse_args(argv)

    vault = Path(args.vault)
    if not vault.is_dir():
        sys.stderr.write("expiry: vault not found: " + str(vault) + "\n")
        return 2
    if args.days < 0:
        sys.stderr.write("expiry: --days must be 0 or greater\n")
        return 2

    findings = find_expiring(vault, args.days)
    for finding in findings:
        print(describe(finding))
    print("expiry: " + str(len(findings)) + " finding(s) in " + ", ".join(SCOPES) +
          " (window " + str(args.days) + " days)")

    if args.json:
        out = Path(args.json)
        out.write_text(json.dumps(findings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
