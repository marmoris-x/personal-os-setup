"""Tests for count_usage.py: one request = one key, the line with the most output counts once."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import run_script  # noqa: E402

TUESDAY_PEAK = "2026-10-27T{{MORNING_TIME}}:00.000Z"
TUESDAY_OFF = "2026-10-27T11:00:00.000Z"
SUNDAY_PEAK_HOUR = "2026-10-25T{{MORNING_TIME}}:00.000Z"
MILLION = 1_000_000


def line(msg, req, out, model="deepseek-flash", ts=TUESDAY_PEAK, inp=0, hit=0, write=0, block="text"):
    record = {"type": "assistant", "timestamp": ts,
              "message": {"id": msg, "model": model, "role": "assistant",
                          "content": [{"type": block}],
                          "usage": {"input_tokens": inp, "cache_read_input_tokens": hit,
                                    "cache_creation_input_tokens": write, "output_tokens": out}}}
    if req is not None:
        record["requestId"] = req
    return json.dumps(record)


class CountUsage(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="count-usage-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.session = self.root / "session.jsonl"

    def write(self, path, lines):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def run_json(self, *extra):
        code, out = run_script("count_usage.py", "--json", *extra, self.root)
        self.assertEqual(code, 0, out)
        return json.loads(out)

    def test_three_lines_one_key_count_once_with_the_last_value(self):
        self.write(self.session, [
            line("m1", "r1", 5, inp=100, hit=900),
            line("m1", "r1", 20, inp=100, hit=900),
            line("m1", "r1", 50, inp=100, hit=900),
        ])
        data = self.run_json()
        self.assertEqual(data["dedup"]["requests"], 1)
        self.assertEqual(data["dedup"]["output"], 50)
        self.assertEqual(data["dedup"]["input"], 100)
        self.assertEqual(data["dedup"]["cache_read"], 900)
        self.assertEqual(data["raw"]["lines"], 3)
        self.assertEqual(data["raw"]["output"], 75)
        self.assertEqual(data["raw"]["input"], 300)

    def test_the_highest_output_wins_even_when_it_comes_first(self):
        self.write(self.session, [line("m1", "r1", 50), line("m1", "r1", 20)])
        self.assertEqual(self.run_json()["dedup"]["output"], 50)

    def test_two_keys_count_twice(self):
        self.write(self.session, [line("m1", "r1", 10, inp=1), line("m2", "r2", 30, inp=2)])
        data = self.run_json()
        self.assertEqual(data["dedup"]["requests"], 2)
        self.assertEqual(data["dedup"]["output"], 40)
        self.assertEqual(data["dedup"]["input"], 3)

    def test_a_line_without_request_id_falls_back_to_the_message_id(self):
        self.write(self.session, [line("m1", None, 5), line("m1", None, 9), line("m2", None, 1)])
        data = self.run_json()
        self.assertEqual(data["dedup"]["requests"], 2)
        self.assertEqual(data["dedup"]["output"], 10)

    def test_peak_and_off_peak_prices(self):
        self.write(self.session, [
            line("m1", "r1", 0, inp=MILLION, ts=TUESDAY_PEAK),
            line("m2", "r2", 0, inp=MILLION, ts=TUESDAY_OFF),
            line("m3", "r3", 0, inp=MILLION, ts=SUNDAY_PEAK_HOUR),
        ])
        data = self.run_json()
        self.assertAlmostEqual(data["dedup"]["usd"], 0.3 + 0.15 + 0.15)

    def test_peak_window_edges_and_request_time_is_the_first_line(self):
        self.write(self.session, [
            line("m1", "r1", 0, inp=MILLION, ts="2026-10-27T01:00:00.000Z"),   # peak starts
            line("m2", "r2", 0, inp=MILLION, ts="2026-10-27T04:00:00.000Z"),   # peak over
            line("m3", "r3", 0, inp=MILLION, ts="2026-10-27T10:00:00.000Z"),   # peak over
            line("m4", "r4", 0, inp=MILLION, ts="2026-10-27T03:59:59.000Z"),   # first line of r4
            line("m4", "r4", 1, inp=MILLION, ts="2026-10-27T04:00:01.000Z"),
        ])
        data = self.run_json()
        # r4 also has one output token at 1.2 USD per 1M, hence 5 places
        self.assertAlmostEqual(data["dedup"]["usd"], 0.3 + 0.15 + 0.15 + 0.3, places=5)

    def test_usd_peak_prices_every_request_at_peak_rates(self):
        self.write(self.session, [line("m1", "r1", 0, inp=MILLION, ts=TUESDAY_OFF)])
        data = self.run_json()
        self.assertAlmostEqual(data["dedup"]["usd"], 0.15)
        self.assertAlmostEqual(data["dedup"]["usd_peak"], 0.3)
        self.assertAlmostEqual(data["raw"]["usd_peak"], 0.3)

    def test_all_three_token_prices_and_the_pro_model(self):
        self.write(self.session, [line("m1", "r1", MILLION, model="deepseek-v4-pro",
                                       inp=MILLION, hit=MILLION)])
        self.assertAlmostEqual(self.run_json()["dedup"]["usd"], 1.32 + 0.044 + 3.96)

    def test_an_unknown_model_is_never_priced(self):
        self.write(self.session, [line("m1", "r1", 7, model="deepseek-future-x", inp=MILLION)])
        data = self.run_json()
        row = data["rows"][0]
        self.assertEqual(row["price_class"], "unknown")
        self.assertIsNone(row["usd"])
        self.assertEqual(data["dedup"]["usd"], 0)
        self.assertEqual(data["dedup"]["unpriced_tokens"], MILLION + 7)

    def test_an_anthropic_model_gets_tokens_and_no_dollars(self):
        self.write(self.session, [line("m1", "r1", 7, model="claude-sonnet-5-5", inp=3, hit=10, write=5)])
        data = self.run_json()
        row = data["rows"][0]
        self.assertEqual(row["provider"], "anthropic")
        self.assertIsNone(row["usd"])
        self.assertEqual((row["input"], row["cache_read"], row["cache_write"], row["output"]), (3, 10, 5, 7))

    def test_agent_type_comes_from_the_meta_file_and_main_otherwise(self):
        self.write(self.session, [line("m1", "r1", 1)])
        agent = self.root / "session" / "subagents" / "agent-aaa.jsonl"
        self.write(agent, [line("m2", "r2", 2)])
        agent.with_suffix(".meta.json").write_text(json.dumps({"agentType": "web-researcher"}), encoding="utf-8")
        data = self.run_json()
        by_agent = {row["agent"]: row["output"] for row in data["rows"]}
        self.assertEqual(by_agent, {"main": 1, "web-researcher": 2})

    def test_journal_and_synthetic_lines_are_skipped(self):
        self.write(self.session, [line("m1", "r1", 4), line("m2", "r2", 0, model="<synthetic>")])
        self.write(self.root / "wf" / "journal.jsonl", [line("m3", "r3", 99)])
        data = self.run_json()
        self.assertEqual(data["dedup"]["requests"], 1)
        self.assertEqual(data["dedup"]["output"], 4)

    def test_since_keeps_only_later_requests(self):
        self.write(self.session, [line("m1", "r1", 1, ts="2026-10-19T12:00:00.000Z"),
                                  line("m2", "r2", 2, ts="2026-10-20T12:00:00.000Z")])
        data = self.run_json("--since", "2026-10-20")
        self.assertEqual(data["dedup"]["requests"], 1)
        self.assertEqual(data["dedup"]["output"], 2)

    def test_since_and_until_take_a_time_of_day_and_a_whole_day(self):
        self.write(self.session, [line("m1", "r1", 1, ts="2026-10-20T08:00:00.000Z"),
                                  line("m2", "r2", 2, ts="2026-10-20T09:00:00.000Z"),
                                  line("m3", "r3", 4, ts="2026-10-20T10:00:00.000Z"),
                                  line("m4", "r4", 8, ts="2026-10-21T23:59:00.000Z")])
        data = self.run_json("--since", "2026-10-20T08:30", "--until", "2026-10-20T10:00:00")
        self.assertEqual(data["dedup"]["output"], 2 + 4)
        data = self.run_json("--until", "2026-10-21")
        self.assertEqual(data["dedup"]["output"], 15)

    def test_misses_split_into_cold_start_new_content_and_prefix_break(self):
        self.write(self.session, [
            line("m1", "r1", 5, inp=1000, ts="2026-10-27T11:00:00.000Z"),
            line("m2", "r2", 5, inp=200, hit=1000, ts="2026-10-27T11:01:00.000Z"),
            line("m3", "r3", 5, inp=1200, hit=0, ts="2026-10-27T11:02:00.000Z"),
            line("m4", "r4", 5, inp=300, hit=1500, ts="2026-10-27T11:03:00.000Z"),
        ])
        misses = self.run_json()["dedup"]["misses"]
        self.assertEqual(misses["cold_start"]["tokens"], 1000)
        self.assertEqual(misses["prefix_break"]["requests"], 1)
        self.assertEqual(misses["new_content"]["requests"], 2)
        self.assertEqual(misses["prefix_break"]["tokens"], 1200)
        self.assertEqual(misses["new_content"]["tokens"], 200 + 300)
        self.assertAlmostEqual(misses["cold_start"]["usd"], 1000 * 0.15 / MILLION)

    def test_each_file_has_its_own_cold_start_and_order_is_by_time(self):
        agent = self.root / "session" / "subagents" / "agent-aaa.jsonl"
        self.write(self.session, [line("m2", "r2", 5, inp=10, hit=100, ts="2026-10-27T11:01:00.000Z"),
                                  line("m1", "r1", 5, inp=100, ts="2026-10-27T11:00:00.000Z")])
        self.write(agent, [line("m3", "r3", 5, inp=50, ts="2026-10-27T11:00:30.000Z")])
        misses = self.run_json()["dedup"]["misses"]
        self.assertEqual(misses["cold_start"]["tokens"], 150)
        self.assertEqual(misses["new_content"]["tokens"], 10)
        self.assertEqual(misses["prefix_break"]["tokens"], 0)

    def test_a_model_switch_inside_one_file_is_a_cold_start_not_a_break(self):
        self.write(self.session, [
            line("m1", "r1", 5, inp=1000, ts="2026-10-27T11:00:00.000Z"),
            line("m2", "r2", 5, inp=900, model="claude-sonnet-5-5", ts="2026-10-27T11:01:00.000Z"),
            line("m3", "r3", 5, inp=10, hit=1000, ts="2026-10-27T11:02:00.000Z"),
        ])
        misses = self.run_json()["dedup"]["misses"]
        self.assertEqual(misses["cold_start"]["tokens"], 1000 + 900)
        self.assertEqual(misses["prefix_break"]["tokens"], 0)
        self.assertEqual(misses["new_content"]["tokens"], 10)

    def test_the_same_message_with_two_request_ids_counts_twice(self):
        self.write(self.session, [line("m1", "r1", 5), line("m1", "r2", 5)])
        self.assertEqual(self.run_json()["dedup"]["requests"], 2)

    def test_every_peak_edge_and_the_weekend(self):
        cases = [("2026-10-27T00:59:59.000Z", 0.15), ("2026-10-27T06:00:00.000Z", 0.3),
                 ("2026-10-27T09:59:59.000Z", 0.3), ("2026-10-27T05:30:00.000Z", 0.15),
                 ("2026-10-23T{{MORNING_TIME}}:00.000Z", 0.3),   # Friday
                 ("2026-10-24T{{MORNING_TIME}}:00.000Z", 0.15)]  # Saturday
        self.write(self.session, [line(f"m{i}", f"r{i}", 0, inp=MILLION, ts=ts)
                                  for i, (ts, _) in enumerate(cases)])
        self.assertAlmostEqual(self.run_json()["dedup"]["usd"], sum(usd for _, usd in cases))

    def test_a_request_without_a_timestamp_is_priced_at_peak(self):
        record = json.loads(line("m1", "r1", 0, inp=MILLION, ts=TUESDAY_OFF))
        del record["timestamp"]
        self.write(self.session, [json.dumps(record)])
        self.assertAlmostEqual(self.run_json()["dedup"]["usd"], 0.3)

    def test_prefix_break_is_the_shortfall_and_the_ninety_percent_edge_holds(self):
        self.write(self.session, [
            line("m1", "r1", 1, inp=1000, ts="2026-10-27T11:00:00.000Z"),
            line("m2", "r2", 1, inp=100, hit=1000, ts="2026-10-27T11:01:00.000Z"),   # prompt 1100
            line("m3", "r3", 1, inp=1700, hit=300, write=300, ts="2026-10-27T11:02:00.000Z"),
            line("m4", "r4", 1, inp=10, hit=2070, ts="2026-10-27T11:03:00.000Z"),    # prompt 2300
            line("m5", "r5", 1, inp=10, hit=2069, ts="2026-10-27T11:04:00.000Z"),    # prompt 2079
            line("m6", "r6", 1, inp=100, hit=0, ts="2026-10-27T11:05:00.000Z"),      # context shrank
        ])
        misses = self.run_json()["dedup"]["misses"]
        # r3: expected 1100, cache_read 300 is below 990, shortfall 800, misses 1700 + 300 = 2000
        # r4: expected 2300, cache_read 2070 is exactly 90 %, no break
        # r5: expected 2080, cache_read 2069 is above 90 %, no break
        # r6: expected 2079, cache_read 0, shortfall 2079 but only 100 misses: the break is 100
        self.assertEqual(misses["prefix_break"]["tokens"], 800 + 100)
        self.assertEqual(misses["prefix_break"]["requests"], 2)
        self.assertEqual(misses["new_content"]["tokens"], 100 + (2000 - 800) + 10 + 10)
        self.assertEqual(misses["cold_start"]["tokens"], 1000)

    def test_provider_totals_and_the_plain_table(self):
        self.write(self.session, [line("m1", "r1", 4, inp=10, hit=90),
                                  line("m2", "r2", 6, model="claude-sonnet-5-5", inp=1, hit=9)])
        data = self.run_json()
        self.assertEqual(data["providers"]["deepseek"]["requests"], 1)
        self.assertEqual(data["providers"]["anthropic"]["requests"], 1)
        self.assertAlmostEqual(data["providers"]["deepseek"]["hit_rate"], 0.9)
        self.assertEqual(data["providers"]["anthropic"]["usd"], 0)
        code, out = run_script("count_usage.py", self.root)
        self.assertEqual(code, 0, out)
        for text in ("agent", "USD@peak", "raw line sum", "deduplicated", "provider deepseek",
                     "provider anthropic", "misses deepseek"):
            self.assertIn(text, out)

    def test_since_includes_its_own_instant_and_a_request_is_kept_or_dropped_whole(self):
        self.write(self.session, [
            line("m1", "r1", 1, ts="2026-10-20T08:00:00.000Z"),   # exactly --since: kept
            line("m2", "r2", 2, ts="2026-10-20T07:59:59.000Z"),   # first line before --since: dropped
            line("m2", "r2", 9, ts="2026-10-20T08:00:05.000Z"),   # ... with all its lines
            line("m3", "r3", 3, ts="2026-10-20T08:59:00.000Z"),   # first line inside --until: kept
            line("m3", "r3", 7, ts="2026-10-20T09:00:30.000Z"),   # ... with its later line
        ])
        data = self.run_json("--since", "2026-10-20T08:00:00", "--until", "2026-10-20T09:00:00")
        self.assertEqual(data["dedup"]["requests"], 2)
        self.assertEqual(data["dedup"]["output"], 1 + 7)
        self.assertEqual(data["raw"]["lines"], 3)

    def test_the_window_does_not_turn_a_later_request_into_a_cold_start(self):
        self.write(self.session, [line("m1", "r1", 1, inp=500, ts="2026-10-19T11:00:00.000Z"),
                                  line("m2", "r2", 1, inp=40, hit=500, ts="2026-10-20T11:00:00.000Z")])
        misses = self.run_json("--since", "2026-10-20")["dedup"]["misses"]
        self.assertEqual(misses["cold_start"]["tokens"], 0)
        self.assertEqual(misses["new_content"]["tokens"], 40)

    def test_an_agent_file_without_a_meta_file_is_called_agent(self):
        self.write(self.root / "session" / "subagents" / "agent-zzz.jsonl", [line("m1", "r1", 3)])
        self.assertEqual([row["agent"] for row in self.run_json()["rows"]], ["agent"])

    def test_offpeak_date_makes_a_holiday_cheap(self):
        self.write(self.session, [line("m1", "r1", 0, inp=MILLION, ts=TUESDAY_PEAK)])
        data = self.run_json("--offpeak-date", "2026-10-27")
        self.assertAlmostEqual(data["dedup"]["usd"], 0.15)


if __name__ == "__main__":
    unittest.main()
