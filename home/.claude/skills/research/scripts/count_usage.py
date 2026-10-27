"""Count model tokens and DeepSeek cost from harness transcripts, once per request.

Usage: count_usage.py [--json] [--since DATE|DATETIME] [--until DATE|DATETIME]
                      [--offpeak-date YYYY-MM-DD ...] PATH [PATH ...]

PATH is a transcript file or a folder; a folder is searched for *.jsonl, so one session
transcript, its subagents/agent-*.jsonl and a Workflow run's transcriptDir can be given
together. Pass ~/.claude/projects/<project> to count every session of a project.

Why this exists: Claude Code writes one model response as several transcript lines, one per
content block (thinking, text, tool_use), and every line carries the full `usage` of the
request. Summing the lines counts each request about 2.7 times (measured 2026-10-27).
Rule: one request = one key (message.id, requestId); a line without requestId falls back to
message.id alone. Per key the line with the highest output_tokens is kept, because
output_tokens grows while the answer streams and the input and cache fields are identical.
Prior art: ccusage keeps the most complete line per key
(https://github.com/ccusage/ccusage/issues/938). The script prints the raw line sum next to
the deduplicated sum, so the difference stays visible. Every measurement uses this script.

Cache misses are split into three kinds, per transcript file and model in time order (a model
switch inside one file starts a new chain). A miss is the uncached part of a prompt
(input + cache_write). cold_start: the first request of a chain; its prompt is not cached
yet (a shared prefix such as the system prompt may still be read from the cache, so only the
miss tokens count). prefix_break: a later request whose cache_read is below 90 % of the
previous request's whole prompt; the shortfall (at most its misses) is the break. It has no
time criterion: a cache that expired during a pause is a break too, so read it as "the cache
did not carry over", not as "the prefix changed". new_content: every other miss, text that
was appended since the previous request.

Rows are grouped by agent type and model. The agent type is "main" for a session transcript
and the agentType of the sibling agent-*.meta.json for an agent transcript. A request's
time is the timestamp of its first line; a request without a timestamp is priced at peak.
--since and --until take a UTC date (YYYY-MM-DD, the whole day) or a UTC time
(YYYY-MM-DDTHH:MM[:SS]); both ends are inclusive and decide by that first line, so a request
is kept or dropped whole. Pass a session file instead of its folder to count the main
session alone.

USD is priced at each request's own time; USD@peak prices every request at peak rates, the
worst case that the research cost limit and the earlier ADR 0018 tables use.
Prices are DeepSeek's, per 1M tokens, https://api-docs.deepseek.com/quick_start/pricing
(read 2026-10-27); one price table for every date, so an old request is priced at today's
rates. Peak is 01:00-04:00 and 06:00-10:00 UTC, Monday to Friday; the page also
excludes Chinese public holidays, which this script cannot know: pass them as --offpeak-date.
cache_write is priced like a cache miss (DeepSeek reports none). Only DeepSeek models are
priced. A model starting with claude- is Anthropic: tokens, no USD. Any other model is
"unknown": tokens, no USD, never a guess. The legacy names deepseek-v4-flash and
deepseek-v4-flash-vision-exp are billed at the Flash price (note 1 on that page).
`<synthetic>` lines are harness messages, not requests; journal.jsonl holds no usage.
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

# USD per 1M tokens: (cache hit, cache miss, output); (off-peak, peak)
PRICES = {
    "flash": {"hit": (0.003, 0.006), "miss": (0.15, 0.3), "out": (0.6, 1.2)},
    "pro": {"hit": (0.022, 0.044), "miss": (0.66, 1.32), "out": (1.98, 3.96)},
}
FLASH_NAMES = {"deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"}
PRO_NAMES = {"deepseek-v4-pro"}
PEAK_HOURS = (range(1, 4), range(6, 10))
FIELDS = ("input", "cache_read", "cache_write", "output")


def price_class(model):
    if model in FLASH_NAMES:
        return "flash"
    if model in PRO_NAMES:
        return "pro"
    if model.startswith("claude-"):
        return "anthropic"
    return "unknown"


def provider(model):
    if model.startswith("deepseek"):
        return "deepseek"
    if model.startswith("claude-"):
        return "anthropic"
    return "other"


def parse_time(text):
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)
    except (AttributeError, ValueError):
        return None


def parse_bound(text, end):
    """A --since/--until value as a UTC moment; a bare date means its first or last instant."""
    if len(text) == 10:
        moment = parse_time(text + "T00:00:00Z")
        if moment is not None and end:
            moment = moment.replace(hour=23, minute=59, second=59, microsecond=999999)
        return moment
    return parse_time(text if text.endswith("Z") or "+" in text[10:] else text + "Z")


def is_peak(moment, offpeak_dates):
    if moment is None:
        return True  # no timestamp: the worst case, never a cheaper guess
    if moment.weekday() > 4 or moment.date().isoformat() in offpeak_dates:
        return False
    return any(moment.hour in hours for hours in PEAK_HOURS)


def usd_of(model, moment, tokens, offpeak_dates, all_peak=False):
    """Dollars for one request, or None when the model is not a priced DeepSeek model.

    all_peak prices the request at peak rates whatever its time: the worst case, which the
    research cost limit and the earlier ADR 0018 tables use.
    """
    table = PRICES.get(price_class(model))
    if table is None:
        return None
    slot = 1 if all_peak or is_peak(moment, offpeak_dates) else 0
    miss = tokens["input"] + tokens["cache_write"]
    return (miss * table["miss"][slot] + tokens["cache_read"] * table["hit"][slot]
            + tokens["output"] * table["out"][slot]) / 1_000_000


def agent_type_of(path):
    if not path.name.startswith("agent-"):
        return "main"
    meta = path.with_suffix(".meta.json")
    try:
        return json.loads(meta.read_text(encoding="utf-8")).get("agentType") or "agent"
    except (OSError, ValueError, AttributeError):
        return "agent"


def transcript_files(paths):
    found = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            found.extend(p for p in sorted(path.rglob("*.jsonl")) if p.name != "journal.jsonl")
        elif path.is_file():
            found.append(path)
        else:
            sys.exit(f"count_usage: no such file or folder: {raw}")
    return found


def read_lines(files):
    """Yield (chain, agent, model, key, moment, tokens) for every assistant line with usage."""
    for path in files:
        agent = agent_type_of(path)
        with open(path, encoding="utf-8", errors="replace") as handle:
            for number, text in enumerate(handle):
                if '"usage"' not in text:
                    continue
                try:
                    record = json.loads(text)
                except ValueError:
                    continue
                message = record.get("message") if isinstance(record, dict) else None
                if not isinstance(message, dict) or record.get("type") != "assistant":
                    continue
                usage = message.get("usage")
                if not isinstance(usage, dict):
                    continue
                model = message.get("model") or "unknown"
                if model == "<synthetic>":
                    continue
                message_id = message.get("id")
                request_id = record.get("requestId")
                key = (message_id, request_id) if message_id else (request_id, None) if request_id \
                    else (str(path), number)
                tokens = {
                    "input": usage.get("input_tokens") or 0,
                    "cache_read": usage.get("cache_read_input_tokens") or 0,
                    "cache_write": usage.get("cache_creation_input_tokens") or 0,
                    "output": usage.get("output_tokens") or 0,
                }
                yield f"{path}|{model}", agent, model, key, parse_time(record.get("timestamp")), tokens


def empty_totals():
    return {"requests": 0, "lines": 0, **{field: 0 for field in FIELDS}, "usd": 0.0,
            "usd_peak": 0.0, "unpriced_tokens": 0,
            "misses": {kind: {"requests": 0, "tokens": 0, "usd": 0.0, "usd_peak": 0.0}
                       for kind in MISS_KINDS}}


def add(total, tokens, model, moment, offpeak_dates):
    """Add one request or line to a totals dict; usd by its own time, usd_peak all at peak."""
    for field in FIELDS:
        total[field] += tokens[field]
    usd = usd_of(model, moment, tokens, offpeak_dates)
    if usd is None:
        total["unpriced_tokens"] += sum(tokens[field] for field in FIELDS)
    else:
        total["usd"] += usd
        total["usd_peak"] += usd_of(model, moment, tokens, offpeak_dates, all_peak=True)


MISS_KINDS = ("cold_start", "new_content", "prefix_break")


def classify_misses(requests):
    """Set request["misses"] = {kind: tokens} for every request, per chain in time order."""
    chains = {}
    for request in requests:
        chains.setdefault(request["chain"], []).append(request)
    epoch = datetime.min.replace(tzinfo=timezone.utc)
    for chain in chains.values():
        chain.sort(key=lambda r: (r["moment"] or epoch, r["order"]))
        previous = None
        for request in chain:
            tokens = request["tokens"]
            miss = tokens["input"] + tokens["cache_write"]
            kinds = dict.fromkeys(MISS_KINDS, 0)
            if previous is None:
                kinds["cold_start"] = miss
            else:
                expected = sum(previous[f] for f in ("input", "cache_read", "cache_write"))
                if tokens["cache_read"] < 0.9 * expected:
                    kinds["prefix_break"] = min(miss, expected - tokens["cache_read"])
                kinds["new_content"] = miss - kinds["prefix_break"]
            request["misses"] = kinds
            previous = tokens


def add_misses(total, request, offpeak_dates):
    """Add a request's miss tokens, and what they cost as plain cache misses, to a totals dict."""
    table = PRICES.get(price_class(request["model"]))
    for kind, tokens in request["misses"].items():
        entry = total["misses"][kind]
        entry["tokens"] += tokens
        entry["requests"] += 1 if tokens else 0
        if table:
            entry["usd"] += tokens * table["miss"][1 if is_peak(request["moment"], offpeak_dates) else 0] / 1_000_000
            entry["usd_peak"] += tokens * table["miss"][1] / 1_000_000


def hit_rate(tokens):
    reads = tokens["input"] + tokens["cache_read"] + tokens["cache_write"]
    return tokens["cache_read"] / reads if reads else None


def count(files, since, until, offpeak_dates):
    requests = {}  # key -> kept request
    raw_lines = []
    for chain, agent, model, key, moment, tokens in read_lines(files):
        raw_lines.append((key, model, moment, tokens))
        kept = requests.get(key)
        if kept is None:
            requests[key] = {"agent": agent, "model": model, "moment": moment, "tokens": tokens,
                             "chain": chain, "order": len(requests)}
            continue
        if moment and (kept["moment"] is None or moment < kept["moment"]):
            kept["moment"] = moment
        if tokens["output"] > kept["tokens"]["output"]:
            kept.update(agent=agent, model=model, tokens=tokens)

    # Miss kinds look at the request before in its file, so classify before the window cuts.
    # The window keeps or drops a whole request, by its first line, never half of one.
    classify_misses(requests.values())
    requests = {key: request for key, request in requests.items()
                if not request["moment"] or not ((since and request["moment"] < since)
                                                 or (until and request["moment"] > until))}
    raw_lines = [line for line in raw_lines if line[0] in requests]

    raw = empty_totals()
    raw["lines"] = len(raw_lines)
    for _key, model, moment, tokens in raw_lines:
        add(raw, tokens, model, moment, offpeak_dates)

    dedup = empty_totals()
    rows = {}
    for request in requests.values():
        parts = (request["tokens"], request["model"], request["moment"], offpeak_dates)
        add(dedup, *parts)
        add_misses(dedup, request, offpeak_dates)
        dedup["requests"] += 1
        row = rows.setdefault((request["agent"], request["model"]), {
            "agent": request["agent"], "model": request["model"],
            "provider": provider(request["model"]), "price_class": price_class(request["model"]),
            **empty_totals()})
        add(row, *parts)
        add_misses(row, request, offpeak_dates)
        row["requests"] += 1
    dedup["lines"] = raw["lines"]
    del raw["misses"]  # a miss kind needs the one kept request per key; the raw sum has none

    rows = sorted(rows.values(), key=lambda r: (r["agent"], r["model"]))
    for row in rows:
        row["hit_rate"] = hit_rate(row)
        if row["price_class"] in ("anthropic", "unknown"):
            row["usd"] = row["usd_peak"] = None
    dedup["hit_rate"] = hit_rate(dedup)
    raw["hit_rate"] = hit_rate(raw)

    providers = {}
    for row in rows:
        entry = providers.setdefault(row["provider"], {**empty_totals(), "hit_rate": None})
        entry["requests"] += row["requests"]
        for field in FIELDS:
            entry[field] += row[field]
        entry["usd"] += row["usd"] or 0.0
        entry["usd_peak"] += row["usd_peak"] or 0.0
        entry["unpriced_tokens"] += row["unpriced_tokens"]
        for kind in MISS_KINDS:
            for field in ("requests", "tokens", "usd", "usd_peak"):
                entry["misses"][kind][field] += row["misses"][kind][field]
    for entry in providers.values():
        entry["hit_rate"] = hit_rate(entry)
    return {"raw": raw, "dedup": dedup, "rows": rows, "providers": providers}


def fmt_usd(value):
    return "-" if value is None else f"{value:.4f}"


def fmt_rate(value):
    return "-" if value is None else f"{value * 100:.1f}%"


def print_table(data):
    head = ("agent", "model", "req", "input", "cache_read", "cache_write", "output", "hit", "USD", "USD@peak")
    table = [head] + [(r["agent"], r["model"], str(r["requests"]), f"{r['input']:,}",
                       f"{r['cache_read']:,}", f"{r['cache_write']:,}", f"{r['output']:,}",
                       fmt_rate(r["hit_rate"]), fmt_usd(r["usd"]),
                       fmt_usd(r["usd_peak"])) for r in data["rows"]]
    widths = [max(len(row[i]) for row in table) for i in range(len(head))]
    for row in table:
        print("  ".join(cell.ljust(widths[i]) if i < 2 else cell.rjust(widths[i])
                        for i, cell in enumerate(row)))
    print()
    for name in ("raw", "dedup"):
        total = data[name]
        unit = "lines" if name == "raw" else "requests"
        label = "raw line sum" if name == "raw" else "deduplicated"
        count_value = total["lines"] if name == "raw" else total["requests"]
        print(f"{label:<13} {count_value:>9,} {unit:<8} input {total['input']:,}  "
              f"cache_read {total['cache_read']:,}  cache_write {total['cache_write']:,}  "
              f"output {total['output']:,}  USD {total['usd']:.4f}  "
              f"USD@peak {total['usd_peak']:.4f}")
    raw, dedup = data["raw"], data["dedup"]
    if dedup["requests"]:
        tokens_raw = sum(raw[f] for f in FIELDS)
        tokens_dedup = sum(dedup[f] for f in FIELDS)
        ratio = f"{tokens_raw / tokens_dedup:.2f}x" if tokens_dedup else "-"
        print(f"raw/deduplicated: {raw['lines'] / dedup['requests']:.2f}x lines, {ratio} tokens")
    for name, entry in sorted(data["providers"].items()):
        print(f"provider {name}: {entry['requests']:,} requests, hit {fmt_rate(entry['hit_rate'])}, "
              f"USD {entry['usd']:.4f} (@peak {entry['usd_peak']:.4f}), unpriced tokens {entry['unpriced_tokens']:,}")
    for name, entry in sorted(data["providers"].items()):
        total = sum(entry["misses"][kind]["tokens"] for kind in MISS_KINDS)
        if total:
            parts = ", ".join(f"{kind} {entry['misses'][kind]['tokens']:,} "
                              f"({entry['misses'][kind]['tokens'] / total * 100:.1f}%, "
                              f"{entry['misses'][kind]['requests']:,} requests)"
                              for kind in MISS_KINDS)
            print(f"misses {name}: {total:,} tokens: {parts}")
    if dedup["unpriced_tokens"]:
        print(f"unpriced (no DeepSeek price): {dedup['unpriced_tokens']:,} tokens, counted without USD")


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("paths", nargs="+", help="transcript files or folders")
    parser.add_argument("--json", action="store_true", help="print the result as JSON")
    parser.add_argument("--since", help="keep requests from this UTC date or time on")
    parser.add_argument("--until", help="keep requests up to this UTC date or time")
    parser.add_argument("--offpeak-date", action="append", default=[], metavar="YYYY-MM-DD",
                        help="a day that is off-peak all day, e.g. a Chinese public holiday")
    args = parser.parse_args()
    for value in args.offpeak_date:
        if len(value) != 10 or parse_time(value + "T00:00:00Z") is None:
            sys.exit(f"count_usage: not a date (YYYY-MM-DD): {value}")
    bounds = []
    for value, end in ((args.since, False), (args.until, True)):
        moment = parse_bound(value, end) if value else None
        if value and moment is None:
            sys.exit(f"count_usage: not a UTC date or time: {value}")
        bounds.append(moment)
    data = count(transcript_files(args.paths), bounds[0], bounds[1], set(args.offpeak_date))
    if args.json:
        print(json.dumps(data, indent=2))
    else:
        print_table(data)


if __name__ == "__main__":
    main()
