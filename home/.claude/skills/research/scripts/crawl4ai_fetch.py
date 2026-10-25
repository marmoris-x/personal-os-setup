"""Crawl a JSON list of URLs with Crawl4AI in ONE browser session.

Usage:
  <crawl4ai venv python> crawl4ai_fetch.py <urls.json> <out.jsonl> [--timeout 60] [--concurrency 5]

Reads a JSON array of URLs, crawls all of them in one browser session with `arun_many` and
the `MemoryAdaptiveDispatcher`, stealth enabled, and writes one UTF-8 JSON line per URL:
  {"url": ..., "ok": true, "status": 200, "markdown": ...}
  {"url": ..., "ok": false, "status": 403, "error": ...}
The page text goes to the file only; the console gets one ASCII summary line. Exit 0 when the
output file was written, 2 on a usage error.

Source: https://docs.crawl4ai.com/advanced/multi-url-crawling/ @ 2026-10-15 (streaming example)
Source: https://docs.crawl4ai.com/advanced/undetected-browser/ @ 2026-10-11 (enable_stealth)
Changed: one output line per requested URL, written as soon as its crawl returns; a per-page
timeout and an overall deadline; concurrency capped at 5; UTF-8 file output; the optional
console monitor is left out so stdout stays one summary line.
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path


def page_text(result):
    """The markdown of a CrawlResult as a plain string (the property is string-compatible)."""
    markdown = getattr(result, "markdown", None)
    if markdown is None:
        return ""
    raw = getattr(markdown, "raw_markdown", None)
    return raw if isinstance(raw, str) else str(markdown)


def record_for(url, result):
    """One JSON object for one requested URL."""
    status = getattr(result, "status_code", None)
    text = page_text(result)
    ok = bool(getattr(result, "success", False)) and status is not None and status < 400 \
        and bool(text.strip())
    if ok:
        return {"url": url, "ok": True, "status": status, "markdown": text}
    error = getattr(result, "error_message", None) or (f"HTTP {status}" if status else "no text")
    return {"url": url, "ok": False, "status": status, "error": error}


def url_key(url):
    return (url or "").strip().rstrip("/")


async def crawl(urls, timeout_s, concurrency, write_result):
    """The official streaming example: one browser, arun_many, MemoryAdaptiveDispatcher."""
    from crawl4ai import (AsyncWebCrawler, BrowserConfig, CacheMode, CrawlerRunConfig,
                          MemoryAdaptiveDispatcher)

    browser_config = BrowserConfig(headless=True, verbose=False, enable_stealth=True)
    run_config = CrawlerRunConfig(
        cache_mode=CacheMode.BYPASS,
        stream=True,
        verbose=False,
        page_timeout=max(1, int(timeout_s * 1000)),
    )
    # The docs example uses memory_threshold_percent=70.0. Measured on this PC 2026-10-18:
    # it idles around 78% used (a browser is always open), so the dispatcher entered memory
    # pressure mode after the first wave, stopped starting pages, and the batch stalled at
    # 5 of 30 URLs. The library defaults (90/95/85) leave room above the idle level; the
    # 30 s wait cap turns a real pressure event into per-URL failures instead of a 600 s
    # stall. The overall deadline in main() still bounds the whole batch.
    dispatcher = MemoryAdaptiveDispatcher(
        memory_threshold_percent=90.0,
        critical_threshold_percent=95.0,
        recovery_threshold_percent=85.0,
        check_interval=1.0,
        max_session_permit=max(1, min(concurrency, 5)),
        memory_wait_timeout=30.0,
    )
    async with AsyncWebCrawler(config=browser_config) as crawler:
        async for result in await crawler.arun_many(urls=urls, config=run_config,
                                                    dispatcher=dispatcher):
            write_result(result)


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("urls")
    parser.add_argument("out")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--concurrency", type=int, default=5)
    args = parser.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        urls = json.loads(Path(args.urls).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"ERROR {type(exc).__name__}: {exc}")
        return 2
    if not isinstance(urls, list) or not urls or not all(isinstance(u, str) for u in urls):
        print("ERROR the URL file must hold a non-empty JSON array of strings")
        return 2
    requested = {url_key(url): url for url in urls}
    seen = set()

    def original_url(result):
        for candidate in (getattr(result, "url", ""), getattr(result, "redirected_url", "")):
            if candidate and url_key(candidate) in requested:
                return requested[url_key(candidate)]
        return getattr(result, "url", "") or urls[0]

    # One page may ignore its own timeout; the overall deadline keeps the batch finite and the
    # lines already written stay in the file (streaming example, one record per result).
    budget = args.timeout * max(1, -(-len(urls) // max(1, min(args.concurrency, 5)))) + 60
    ok_count = 0
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        def write_result(result):
            nonlocal ok_count
            url = original_url(result)
            record = record_for(url, result)
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
            fh.flush()
            seen.add(url_key(url))
            if record["ok"]:
                ok_count += 1

        try:
            asyncio.run(asyncio.wait_for(
                crawl(urls, args.timeout, args.concurrency, write_result), timeout=budget))
        except asyncio.TimeoutError:
            pass
        except Exception as exc:  # the browser or the import failed: report it per URL
            reason = f"{type(exc).__name__}: {exc}"
            for url in urls:
                if url_key(url) not in seen:
                    fh.write(json.dumps({"url": url, "ok": False, "status": None, "error": reason},
                                        ensure_ascii=False) + "\n")
                    seen.add(url_key(url))
        for url in urls:
            if url_key(url) not in seen:
                fh.write(json.dumps({"url": url, "ok": False, "status": None,
                                     "error": f"overall timeout after {int(budget)} s"},
                                    ensure_ascii=False) + "\n")
    ok = ok_count
    print(f"crawl4ai: {ok} ok, {len(urls) - ok} failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
