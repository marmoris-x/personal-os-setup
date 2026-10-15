r"""Find Syncthing conflict files in the vault.

Usage: python -I -X utf8 conflicts.py [--vault {{VAULT}}]

Syncthing never overwrites a file that another device changed at the same
time; it keeps both versions and renames the losing copy to
<name>.sync-conflict-<YYYYMMDD>-<HHMMSS>-<id>.<ext>. The Life OS morning run
merges such files (phase-1 order part 2.4); this check only reports them,
read-only: relative path, modification date, size.

Folders that are already handled never count: `.git` (history) and `trash/`
(the vault's graveyard - the morning run moves merged conflicts there, and a
copy that sits in trash/ must not be reported again every day).

Exit 1 when there is at least one conflict file.
"""
import argparse
import sys
from datetime import datetime
from pathlib import Path

PATTERN = "*.sync-conflict-*"


def main():
    parser = argparse.ArgumentParser(description="Find Syncthing conflict files.")
    parser.add_argument("--vault", default=r"{{VAULT}}")
    args = parser.parse_args()
    vault = Path(args.vault)
    findings = 0
    for path in sorted(vault.rglob(PATTERN)):
        parts = path.relative_to(vault).parts
        if not path.is_file() or ".git" in parts or "trash" in parts:
            continue
        stat = path.stat()
        mtime = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M")
        print("FINDING sync conflict: " + path.relative_to(vault).as_posix()
              + " (modified " + mtime + ", " + str(stat.st_size) + " bytes)")
        findings += 1
    print("findings: " + str(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
