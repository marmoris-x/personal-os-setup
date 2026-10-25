"""Tests for the pure parts of crawl4ai_fetch.py: no browser is started."""

import os
import subprocess
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import SCRIPTS  # noqa: E402

sys.path.insert(0, str(SCRIPTS))
import crawl4ai_fetch  # noqa: E402


def result(raw, fit, status=200, success=True):
    return SimpleNamespace(markdown=SimpleNamespace(raw_markdown=raw, fit_markdown=fit),
                           status_code=status, success=success, error_message=None)


class RecordFor(unittest.TestCase):
    def test_the_record_keeps_raw_markdown_and_adds_fit_markdown(self):
        record = crawl4ai_fetch.record_for("https://example.org/a", result("RAW TEXT", "FIT TEXT"))
        self.assertEqual(record["markdown"], "RAW TEXT")
        self.assertEqual(record["fit_markdown"], "FIT TEXT")
        self.assertTrue(record["ok"])

    def test_no_fit_markdown_when_the_filter_gave_nothing(self):
        for fit in (None, "", "   "):
            record = crawl4ai_fetch.record_for("https://example.org/a", result("RAW TEXT", fit))
            self.assertEqual(record["markdown"], "RAW TEXT")
            self.assertNotIn("fit_markdown", record)

    def test_a_failed_page_has_no_fit_markdown(self):
        record = crawl4ai_fetch.record_for("https://example.org/a", result("RAW", "FIT", status=403, success=False))
        self.assertFalse(record["ok"])
        self.assertNotIn("fit_markdown", record)

    def test_the_markdown_generator_uses_the_pruning_filter(self):
        # crawl4ai lives only in its own uv venv; without it this check cannot run
        import save_pages
        python = save_pages.find_crawl4ai_python()
        if not python:
            self.skipTest("the Crawl4AI venv is not installed")
        code = "import crawl4ai_fetch; print(type(crawl4ai_fetch.markdown_generator().content_filter).__name__)"
        env = dict(os.environ, PYTHONPATH=str(SCRIPTS), PYTHONUTF8="1")
        done = subprocess.run([python, "-c", code], capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(done.stdout.strip(), "PruningContentFilterLXML", done.stderr[-300:])


if __name__ == "__main__":
    unittest.main()
