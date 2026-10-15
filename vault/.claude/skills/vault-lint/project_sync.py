"""Check the vault's project hub notes against the projects folder.

Usage:
  python -I -X utf8 project_sync.py [--vault {{VAULT_JSON}}] [--projects {{DEV_JSON}}\\Projects]

Rules (vault-v3 order, part 3.3):
  - every git repository directly under the projects folder has one hub note,
    in `200-projects/<name>.md` (active) or `900-inactive/<name>.md` (finished)
  - every note in `200-projects` carries a `repo:` frontmatter field (200-projects
    holds project notes only; anything else belongs elsewhere)
  - for active projects the note's last update (the latest date in its Timeline,
    else the frontmatter date) is not more than 30 days older than the
    repository's last commit; finished projects are exempt

Prints one line per project (name, location, dates) plus FINDING lines with the
reason. Exit 1 when there is at least one finding.
"""
import argparse
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

TIMELINE_DATE_RE = re.compile(r"(?m)^- (\d{4}-\d{2}-\d{2})")
FM_DATE_RE = re.compile(r"(?m)^date:\s*'?(\d{4}-\d{2}-\d{2})")
FM_STATUS_RE = re.compile(r"(?m)^status:\s*(\S+)")
FM_REPO_RE = re.compile(r"(?m)^repo:\s*(.+?)\s*$")
STALE_DAYS = 30


def git_last_commit(repo):
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "log", "-1", "--format=%ad", "--date=short"],
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None


def note_last_update(text):
    dates = TIMELINE_DATE_RE.findall(text)
    if dates:
        return max(dates)
    m = FM_DATE_RE.search(text)
    return m.group(1) if m else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", default=r"{{VAULT}}")
    parser.add_argument("--projects", default=r"{{DEV}}\Projects")
    args = parser.parse_args()
    vault = Path(args.vault)
    projects = Path(args.projects)
    notes_active = vault / "200-projects"
    notes_done = vault / "900-inactive"

    findings = 0
    for proj in sorted(p for p in projects.iterdir() if p.is_dir()):
        if not (proj / ".git").exists():
            print(f"FINDING {proj.name}: not a git repository")
            findings += 1
            continue
        note = notes_active / f"{proj.name}.md"
        where = "200-projects"
        if not note.is_file():
            note = notes_done / f"{proj.name}.md"
            where = "900-inactive"
        if not note.is_file():
            print(f"FINDING {proj.name}: no hub note (looked in 200-projects and 900-inactive)")
            findings += 1
            continue
        text = note.read_text(encoding="utf-8")
        status_match = FM_STATUS_RE.search(text)
        status = status_match.group(1) if status_match else ""
        last_commit = git_last_commit(proj)
        last_update = note_last_update(text)
        parts = [f"{proj.name}: note in {where}"]
        parts.append(f"last update {last_update or 'unknown'}")
        parts.append(f"last commit {last_commit or 'unknown'}")
        if status != "done" and last_commit and last_update:
            delta = (date.fromisoformat(last_commit) - date.fromisoformat(last_update)).days
            if delta > STALE_DAYS:
                print(f"FINDING {proj.name}: note stale by {delta} days "
                      f"(last update {last_update}, last commit {last_commit})")
                findings += 1
                continue
        print("OK " + ", ".join(parts))

    for note in sorted(notes_active.glob("*.md")):
        text = note.read_text(encoding="utf-8")
        if not FM_REPO_RE.search(text):
            print(f"FINDING {note.name}: note in 200-projects without a repo field")
            findings += 1

    print(f"findings: {findings}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
