"""Tests for save_pages.py with a fake network: nothing leaves this machine."""

import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import SCRIPTS, Work  # noqa: E402

sys.path.insert(0, str(SCRIPTS))
import save_pages  # noqa: E402
from common import read_page  # noqa: E402

KEYS = {name: "placeholder " + name.split("_")[0].lower() for name in
        ("EXA_API_KEY", "YDC_API_KEY", "TAVILY_API_KEY", "FIRECRAWL_API_KEY", "TINYFISH_API_KEY")}
LONG = "Dies ist ein langer Text über Wien und seine Geschichte. " * 12


class FakeNet:
    """Routes the calls of save_pages.http by URL. Each handler may be a dict or a callable."""

    def __init__(self):
        self.calls = []
        self.exa = lambda body: {"results": [], "statuses": []}
        self.you = lambda body: []
        self.tavily = lambda body: {"results": [], "failed_results": []}
        self.firecrawl = lambda body: {"success": True, "data": {}}
        self.tinyfish = lambda body: {"results": [], "errors": []}
        self.jina = lambda url: {"data": {}}
        self.wayback = lambda url: {"archived_snapshots": {}}

    def __call__(self, method, url, headers=None, body=None, timeout=60, retry=True):
        self.calls.append((method, url, headers, body))
        if url.startswith("https://api.exa.ai/contents"):
            return 200, self.exa(body)
        if url.startswith("https://ydc-index.io"):
            return 200, self.you(body)
        if url.startswith("https://api.tavily.com"):
            return 200, self.tavily(body)
        if url.startswith("https://api.firecrawl.dev"):
            return 200, self.firecrawl(body)
        if url.startswith("https://api.fetch.tinyfish.ai"):
            return 200, self.tinyfish(body)
        if url.startswith("https://r.jina.ai/"):
            return 200, self.jina(url)
        if url.startswith("https://archive.org/wayback"):
            return 200, self.wayback(url)
        raise AssertionError(f"unexpected call {url}")

    def urls(self, prefix):
        return [c[1] for c in self.calls if c[1].startswith(prefix)]


def exa_ok(*pages):
    def handler(body):
        wanted = set(body["urls"])
        return {"results": [{"id": u, "url": u, "title": t, "text": txt, "author": "A. Author",
                             "publishedDate": "2025-01-02"} for u, t, txt in pages if u in wanted],
                "statuses": [{"id": u, "status": "success"} for u, _, _ in pages if u in wanted]}
    return handler


class SavePages(unittest.TestCase):
    def setUp(self):
        self.work = Work()
        self.addCleanup(self.work.cleanup)
        (self.work.path / "candidates").mkdir()
        for old in (self.work.path / "pages").glob("*.md"):
            old.unlink()
        self.net = FakeNet()
        patches = [mock.patch.object(save_pages, "http", self.net),
                   mock.patch.dict(os.environ, KEYS),
                   mock.patch.object(save_pages.shutil, "which", return_value=None),
                   mock.patch.object(save_pages.time, "sleep")]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def candidates(self, *items, name="p1.jsonl"):
        lines = [json.dumps({"pass": "P1", "type": "primary", "lang": "de", **i}) for i in items]
        self.work.write(f"candidates/{name}", "\n".join(lines) + "\n")

    def run_script(self, *extra):
        out = io.StringIO()
        with redirect_stdout(out):
            code = save_pages.main([str(self.work.path), *extra])
        return code, out.getvalue()

    def index(self):
        return json.loads((self.work.path / "pages" / "index.json").read_text(encoding="utf-8"))

    # --- URLs

    def test_clean_url_removes_tracking_fragment_and_refuses_private_targets(self):
        c = save_pages.clean_url
        self.assertEqual(c("HTTPS://Example.org/a/?utm_source=x&b=1&fbclid=z#frag"), "https://example.org/a?b=1")
        self.assertEqual(
            c("https://www.reddit.com/r/x/comments/y/z/?solution=abc&js_challenge=1&jsc_token=dd&jsc_orig_r=&keep=1"),
            "https://www.reddit.com/r/x/comments/y/z?keep=1")
        for bad in ("http://localhost/x", "http://192.168.1.5/x", "http://127.0.0.1/", "ftp://example.org/x",
                    "https://user:pw@example.org/", "http://169.254.169.254/latest", "file:///c:/x",
                    "http://printer.local/"):
            self.assertIsNone(c(bad), bad)

    def test_candidates_are_deduplicated_ranked_and_capped(self):
        self.candidates({"url": "https://a.org/x?utm_medium=m", "type": "secondary"},
                        {"url": "https://a.org/x", "type": "primary"}, {"error": "no url here"},
                        {"url": "http://localhost/y"}, {"url": "https://b.org/1", "type": "experience"})
        self.candidates({"url": "https://c.org/1", "pass": "P2", "type": "secondary"},
                        {"url": "https://d.org/1", "pass": "P2", "type": "primary"}, name="p2.jsonl")
        items, dropped = save_pages.load_candidates(self.work.path / "candidates", 3)
        self.assertEqual(len(items), 3)
        self.assertEqual(items[0]["url"], "https://a.org/x")
        self.assertEqual(items[0]["type"], "primary")
        self.assertEqual(items[1]["url"], "https://d.org/1")  # the other pass is interleaved
        self.assertEqual(dropped, ["http://localhost/y"])

    # --- fetching and saving

    def test_exa_page_is_saved_with_header_and_index(self):
        self.candidates({"url": "https://example.org/wien", "title": "Wien"})
        self.net.exa = exa_ok(("https://example.org/wien", "Wien: Fakten", LONG))
        self.net.wayback = lambda url: {"archived_snapshots": {"closest": {
            "available": True, "url": "http://web.archive.org/web/2025/https://example.org/wien", "timestamp": "2025"}}}
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("saved 1 of 1", out)
        header, body, _ = read_page(self.work.path / "pages" / "001-example.org.md")
        self.assertEqual((header["title"], header["method"], header["type"], header["author"]),
                         ("Wien: Fakten", "exa", "primary", "A. Author"))
        self.assertEqual(header["archive_url"], "https://web.archive.org/web/2025/https://example.org/wien")
        self.assertTrue(body.startswith("Dies ist ein langer Text"))
        self.assertRegex(header["fetched_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(self.index()[0]["status"], "saved")
        self.assertEqual(self.net.calls[0][3]["maxAgeHours"], 24)

    def test_http_200_with_a_per_url_error_falls_back_to_the_next_service(self):
        self.candidates({"url": "https://example.org/a"}, {"url": "https://example.org/b"})
        self.net.exa = lambda body: {"results": [
            {"id": "https://example.org/a", "url": "https://example.org/a", "text": LONG}],
            "statuses": [{"id": "https://example.org/a", "status": "success"},
                         {"id": "https://example.org/b", "status": "error", "error": {"tag": "CRAWL_NOT_FOUND"}}]}
        self.net.you = lambda body: [{"url": "https://example.org/b", "title": "B", "markdown": LONG + " B"}]
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        methods = {i["url"]: i["method"] for i in self.index()}
        self.assertEqual(methods, {"https://example.org/a": "exa", "https://example.org/b": "you"})

    def test_fallback_chain_reaches_tavily_firecrawl_and_tinyfish(self):
        urls = [f"https://example.org/{n}" for n in "tfx"]
        self.candidates(*({"url": u} for u in urls))
        self.net.tavily = lambda body: {"results": [{"url": urls[0], "raw_content": LONG + "t"}],
                                        "failed_results": [{"url": urls[1], "error": "blocked"}]}
        self.net.firecrawl = lambda body: {"success": True, "data": {
            "markdown": LONG + "f", "metadata": {"statusCode": 200, "title": "FC", "url": urls[1]}}} \
            if body["url"] == urls[1] else {"success": True, "data": {
                "markdown": "not found", "metadata": {"statusCode": 404}}}
        self.net.tinyfish = lambda body: {"results": [{"url": urls[2], "text": LONG + "x", "final_url": urls[2],
                                                       "title": "TF", "author": None, "published_date": None}],
                                          "errors": []}
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual({i["method"] for i in self.index()}, {"tavily", "firecrawl", "tinyfish"})

    def test_page_status_404_from_firecrawl_is_a_failure(self):
        self.candidates({"url": "https://example.org/gone"})
        self.net.firecrawl = lambda body: {"success": True, "data": {
            "markdown": LONG, "metadata": {"statusCode": 404}}}
        code, out = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("FAILED https://example.org/gone", out)
        self.assertIn("page status 404", out)

    def test_too_short_text_is_a_failure(self):
        self.candidates({"url": "https://example.org/short"})
        self.net.exa = exa_ok(("https://example.org/short", "S", "Nur ein Satz."))
        code, out = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("shorter than", out)

    def test_mirror_with_the_same_text_is_saved_once(self):
        self.candidates({"url": "https://example.org/a"}, {"url": "https://mirror.net/a"})
        self.net.exa = exa_ok(("https://example.org/a", "A", LONG), ("https://mirror.net/a", "A", LONG))
        code, out = self.run_script()
        self.assertEqual(code, 0)
        statuses = sorted(i["status"] for i in self.index())
        self.assertEqual(statuses, ["duplicate", "saved"])
        self.assertEqual(len(list((self.work.path / "pages").glob("*.md"))), 1)

    def test_reddit_is_read_only_through_the_content_services(self):
        self.candidates({"url": "https://www.reddit.com/r/wien/comments/abc/thread/", "type": "experience"})
        code, out = self.run_script()
        self.assertEqual(code, 1)
        self.assertEqual(self.net.urls("https://r.jina.ai/"), [])
        self.assertIn("not readable", out)
        self.net.calls.clear()
        self.net.you = lambda body: [{"url": body["urls"][0], "title": "T", "markdown": LONG}]
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.index()[0]["method"], "you")

    def test_jina_gets_only_plain_public_urls(self):
        self.candidates({"url": "https://example.org/plain"}, {"url": "https://example.org/x?token=abc"})
        self.net.jina = lambda url: {"data": {"content": LONG, "title": "J", "url": url[len("https://r.jina.ai/"):]}}
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.net.urls("https://r.jina.ai/"), ["https://r.jina.ai/https://example.org/plain"])
        self.assertTrue(any("looks private" in i.get("error", "") for i in self.index()))

    def test_a_refusing_service_is_dropped_for_the_run_and_the_others_continue(self):
        self.candidates({"url": "https://example.org/a"})
        real = self.net

        def refuse_exa(method, url, headers=None, body=None, timeout=60, retry=True):
            if url.startswith("https://api.exa.ai"):
                raise save_pages.ServiceDown("HTTP 402")
            return real(method, url, headers, body, timeout, retry)

        real.you = lambda body: [{"url": "https://example.org/a", "markdown": LONG}]
        with mock.patch.object(save_pages, "http", refuse_exa):
            code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("exa: stopped for this run (HTTP 402)", out)

    def test_missing_keys_are_skipped_and_no_key_is_ever_printed_or_saved(self):
        self.candidates({"url": "https://example.org/a"})
        self.net.exa = exa_ok(("https://example.org/a", "A", LONG))
        with mock.patch.dict(os.environ, {"YDC_API_KEY": ""}):
            code, out = self.run_script()
        self.assertIn("you: no key in the environment, skipped", out)
        everything = out + "".join(p.read_text(encoding="utf-8") for p in (self.work.path / "pages").iterdir())
        for secret in KEYS.values():
            self.assertNotIn(secret, everything)
        self.assertEqual(self.net.calls[0][2]["x-api-key"], KEYS["EXA_API_KEY"])  # but it was sent

    def test_wayback_failure_does_not_fail_the_run(self):
        self.candidates({"url": "https://example.org/a"})
        self.net.exa = exa_ok(("https://example.org/a", "A", LONG))

        def down(url):
            raise save_pages.ServiceDown("HTTP 503")

        self.net.wayback = down
        with mock.patch.object(self.net, "wayback", down):
            code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIsNone(self.index()[0]["archive_url"])

    def test_wayback_refusal_is_noted_and_not_repeated(self):
        self.candidates(*({"url": f"https://example.org/{n}"} for n in "abcd"))
        self.net.exa = exa_ok(*((f"https://example.org/{n}", n.upper(), LONG + n) for n in "abcd"))

        def refuse(url):
            raise save_pages.ServiceDown("HTTP 429")

        self.net.wayback = refuse
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("wayback: not asked again in this run (HTTP 429)", out)
        self.assertEqual(len(self.net.urls("https://archive.org/")), 3)

    def test_successful_wayback_asks_are_paced(self):
        self.candidates({"url": "https://example.org/a"})
        self.net.exa = exa_ok(("https://example.org/a", "A", LONG))
        self.net.wayback = lambda url: {"archived_snapshots": {}}
        with mock.patch.object(save_pages.time, "sleep") as sleep:
            code, out = self.run_script()
        self.assertEqual(code, 0, out)
        sleep.assert_any_call(save_pages.WAYBACK_PAUSE)

    def test_a_soft_404_page_is_not_saved_as_a_page(self):
        self.candidates({"url": "https://example.org/gone"})
        text = "Suche nach ...\n\n# Seite nicht gefunden\n\nDie von Ihnen gewählte Seite wurde nicht gefunden (HTTP Fehler 404). " * 2
        self.net.exa = exa_ok(("https://example.org/gone", "Verwaltung", text))
        code, out = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("looks like an error page", out)

    def test_a_soft_404_buried_in_navigation_is_found_by_its_heading(self):
        nav = "\n".join(f"*   [Menüpunkt {n}](https://example.org/{n})" for n in range(60))
        text = nav + "\n\n# Seite nicht gefunden\n\nBitte benutzen Sie die Suche.\n\n" + nav
        self.assertGreater(len(text), 1500)
        self.assertTrue(save_pages.looks_like_error_page(text))
        self.assertFalse(save_pages.looks_like_error_page("# Wien\n\n" + LONG * 3))

    def test_a_long_page_that_mentions_404_is_kept(self):
        self.candidates({"url": "https://example.org/http"})
        self.net.exa = exa_ok(("https://example.org/http", "HTTP", "Der Statuscode 404 bedeutet ... " + LONG * 4))
        code, out = self.run_script()
        self.assertEqual(code, 0, out)

    def test_a_403_for_one_url_does_not_stop_the_service(self):
        self.candidates({"url": "https://example.org/a"}, {"url": "https://example.org/b"})
        calls = []

        def firecrawl(body):
            calls.append(body["url"])
            if body["url"].endswith("/a"):
                return {"success": False, "error": "site not supported"}
            return {"success": True, "data": {"markdown": LONG, "metadata": {"statusCode": 200}}}

        self.net.firecrawl = firecrawl
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(len(calls), 2)
        self.assertNotIn("stopped for this run", out)

    def test_nothing_usable_is_an_error(self):
        self.candidates({"url": "http://localhost/x"})
        code, out = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("ERROR no usable candidates", out)

    def test_broken_candidate_file_is_an_error_not_a_crash(self):
        self.work.write("candidates/p1.jsonl", "{broken\n")
        code, out = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("not valid JSON", out)


class FakeResponse:
    def __init__(self, status, payload=None, headers=None):
        self.status_code, self._payload, self.headers = status, payload, headers or {}
        self.text = "text body"

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


class HttpLayer(unittest.TestCase):
    """The real save_pages.http against a fake requests: which status ends a service."""

    def call(self, responses, **kwargs):
        import requests
        seq = iter(responses)

        def fake(method, url, **kw):
            item = next(seq)
            if isinstance(item, Exception):
                raise item
            return item

        with mock.patch.object(requests, "request", fake), mock.patch.object(save_pages.time, "sleep") as sleep:
            try:
                return save_pages.http("POST", "https://x.example/", **kwargs), sleep
            except save_pages.ServiceDown as exc:
                return str(exc), sleep

    def test_401_and_402_end_the_service(self):
        for status in (401, 402):
            self.assertEqual(self.call([FakeResponse(status)])[0], f"HTTP {status}")

    def test_403_and_a_persistent_500_are_that_urls_failure(self):
        self.assertEqual(self.call([FakeResponse(403, {"error": "x"})])[0], (403, {"error": "x"}))
        self.assertEqual(self.call([FakeResponse(500)] * 3)[0][0], 500)

    def test_429_is_retried_with_retry_after_and_then_ends_the_service(self):
        (result, sleep) = self.call([FakeResponse(429, None, {"Retry-After": "7"}), FakeResponse(200, {"ok": 1})])
        self.assertEqual(result, (200, {"ok": 1}))
        sleep.assert_called_with(7.0)
        self.assertEqual(self.call([FakeResponse(429)] * 3)[0], "HTTP 429")

    def test_retry_after_is_capped_and_without_retry_there_is_one_try(self):
        (_, sleep) = self.call([FakeResponse(429, None, {"Retry-After": "9999"}), FakeResponse(200, {})])
        sleep.assert_called_with(30)
        self.assertEqual(self.call([FakeResponse(429), FakeResponse(200, {})], retry=False)[0], "HTTP 429")

    def test_network_errors_are_retried_a_fixed_number_of_times(self):
        import requests
        errs = [requests.ConnectionError("x")] * 3
        result, sleep = self.call(errs)
        self.assertIn("network error", result)
        self.assertEqual(sleep.call_count, 3)


if __name__ == "__main__":
    unittest.main()
