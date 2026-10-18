"""Fixtures shared by the research script tests: a fake work folder with two saved pages."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(os.environ.get("RESEARCH_SCRIPTS") or Path.home() / ".claude" / "skills" / "research" / "scripts")

PAGE_DE = """---
url: "https://example.org/wien"
final_url: "https://example.org/wien"
title: "Wien: Fakten"
author: "Stadt Wien"
published: "2025-03-01"
lang: "de"
fetched_at: "2026-10-06T08:00:00Z"
type: "primary"
method: "exa"
archive_url: "https://web.archive.org/web/20251001000000/https://example.org/wien"
---
# Wien

Wien ist die Hauptstadt von Österreich und hat rund 2 Millionen Einwohner.

Die Stadt gründet sich auf eine römische Siedlung namens Vindobona, die im ersten Jahrhundert entstand.

Das [Rathaus](https://example.org/rathaus) wurde **1883** fertiggestellt und steht am Ring.

Der Bürgermeister sagte: "Wir bauen – trotz aller Hürden – weiter an der Stadt".
"""

PAGE_AR = """---
url: "https://arabic.example.net/lisan(1)"
final_url: "https://arabic.example.net/lisan(1)"
title: "Lisan"
lang: "ar"
fetched_at: "2026-10-06T09:00:00Z"
type: "secondary"
---
# باب العين

الْعِلْمُ نُورٌ يَقْذِفُهُ اللَّهُ فِي قَلْبِ مَنْ يَشَاءُ

هذا كــتاب الكتابة
"""


class Work:
    """A temporary work folder: pages/, evidence/, draft/."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="research-test-")
        self.path = Path(self._tmp.name)
        for name in ("pages", "evidence", "draft"):
            (self.path / name).mkdir()
        (self.path / "pages" / "001-example.org.md").write_text(PAGE_DE, encoding="utf-8")
        (self.path / "pages" / "002-arabic.example.net.md").write_text(PAGE_AR, encoding="utf-8")

    def cleanup(self):
        self._tmp.cleanup()

    def write(self, rel, text):
        target = self.path / rel
        target.write_text(text, encoding="utf-8", newline="\n")
        return target

    def raw(self, items, name="raw-1.jsonl"):
        self.write(f"evidence/{name}", "\n".join(json.dumps(i, ensure_ascii=False) for i in items) + "\n")

    def verified(self, items):
        self.write("evidence/verified.jsonl",
                   "\n".join(json.dumps(i, ensure_ascii=False) for i in items) + "\n")


def run_script(name, *args, env=None):
    """Run a script in isolated mode. Return (exit code, stdout)."""
    proc = subprocess.run([sys.executable, "-I", "-X", "utf8", str(SCRIPTS / name), *map(str, args)],
                          capture_output=True, text=True, encoding="utf-8", timeout=120, env=env)
    return proc.returncode, proc.stdout + proc.stderr


E1 = {"id": "E1", "page": "001-example.org.md", "lines": [15, 15], "heading": "Wien",
      "text": "Wien ist die Hauptstadt von Österreich und hat rund 2 Millionen Einwohner.",
      "lang": "de", "type": "primary", "claim": "capital", "match": "exact",
      "url": "https://example.org/wien"}
E2 = {"id": "E2", "page": "001-example.org.md", "lines": [17, 17], "heading": "Wien",
      "text": "Die Stadt gründet sich auf eine römische Siedlung namens Vindobona, "
              "die im ersten Jahrhundert entstand.",
      "lang": "de", "type": "primary", "claim": "origin", "match": "exact",
      "url": "https://example.org/wien"}
E3 = {"id": "E3", "page": "001-example.org.md", "lines": [21, 21], "heading": "Wien",
      "text": 'Wir bauen – trotz aller Hürden – weiter an der Stadt',
      "lang": "de", "type": "primary", "claim": "quote", "match": "exact",
      "url": "https://example.org/wien"}
E4 = {"id": "E4", "page": "002-arabic.example.net.md", "lines": [11, 11], "heading": "",
      "text": "الْعِلْمُ نُورٌ يَقْذِفُهُ اللَّهُ فِي قَلْبِ مَنْ يَشَاءُ", "lang": "ar",
      "type": "secondary", "claim": "knowledge", "match": "exact",
      "url": "https://arabic.example.net/lisan(1)"}
