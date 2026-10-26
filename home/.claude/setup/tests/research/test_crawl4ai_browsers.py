"""Tests for the own browser folder of Crawl4AI (crawl4ai_fetch.py): nothing starts a browser.

2026-10-23/25: Crawl4AI shared Playwright's one browser folder (ms-playwright) with every other
Playwright installation on the PC, and Playwright deletes a browser version when no client
needs it any more. The helper now points PLAYWRIGHT_BROWSERS_PATH at a folder of its own.
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import SCRIPTS  # noqa: E402

sys.path.insert(0, str(SCRIPTS))
import crawl4ai_fetch  # noqa: E402


class BrowsersPath(unittest.TestCase):
    def test_windows_default_is_local_app_data_crawl4ai_browsers(self):
        with mock.patch.object(sys, "platform", "win32"), \
                mock.patch.dict(os.environ, {"LOCALAPPDATA": r"C:\Users\x\AppData\Local"}), \
                mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CRAWL4AI_BROWSERS_PATH", None)
            self.assertEqual(Path(crawl4ai_fetch.browsers_path()),
                             Path(r"C:\Users\x\AppData\Local") / "crawl4ai-browsers")

    def test_the_default_is_never_playwrights_shared_folder(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CRAWL4AI_BROWSERS_PATH", None)
            self.assertNotIn("ms-playwright", crawl4ai_fetch.browsers_path())

    def test_an_explicit_override_wins(self):
        with mock.patch.dict(os.environ, {"CRAWL4AI_BROWSERS_PATH": "/some/where"}):
            self.assertEqual(crawl4ai_fetch.browsers_path(), "/some/where")


class ChildEnvironment(unittest.TestCase):
    def run_main(self, outer):
        """Runs main() with crawl() replaced; returns the variable as the crawl would see it."""
        seen = {}

        async def fake_crawl(urls, timeout_s, concurrency, write_result):
            seen["value"] = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")

        with tempfile.TemporaryDirectory(prefix="c4-env-") as tmp:
            urls, out = Path(tmp) / "urls.json", Path(tmp) / "out.jsonl"
            urls.write_text(json.dumps(["https://example.com/"]), encoding="utf-8")
            env = {"CRAWL4AI_BROWSERS_PATH": str(Path(tmp) / "own")}
            if outer is not None:
                env["PLAYWRIGHT_BROWSERS_PATH"] = outer
            with mock.patch.dict(os.environ, env), \
                    mock.patch.object(crawl4ai_fetch, "crawl", fake_crawl):
                if outer is None:
                    os.environ.pop("PLAYWRIGHT_BROWSERS_PATH", None)
                crawl4ai_fetch.main([str(urls), str(out)])
            return seen["value"], str(Path(tmp) / "own")

    def test_the_crawl_runs_with_the_own_folder(self):
        value, own = self.run_main(None)
        self.assertEqual(value, own)

    def test_a_shared_folder_from_outside_is_replaced(self):
        value, own = self.run_main(r"C:\Users\x\AppData\Local\ms-playwright")
        self.assertEqual(value, own)


if __name__ == "__main__":
    unittest.main()
