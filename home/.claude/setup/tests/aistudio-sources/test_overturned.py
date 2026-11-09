"""The recheck's overturns are counted (Part 3)."""

import json

import check_sources as cs
from testlib import SCRIPTS  # noqa: F401


def test_overturned_counts_changed_verdicts(tmp_path):
    results = tmp_path / "results"
    results.mkdir()
    (results / "pass1-1.jsonl").write_text(
        "\n".join(json.dumps(x) for x in [
            {"id": "P1", "verdict": "nicht_belegt"},
            {"id": "P2", "verdict": "gestuetzt"},
        ]) + "\n", encoding="utf-8")
    merged = {"P1": {"verdict": "gestuetzt"}, "P2": {"verdict": "gestuetzt"}}
    claims = {"P1": {"id": "P1"}, "P2": {"id": "P2"}}
    rows = cs.overturned(tmp_path, merged, claims)
    assert rows == [{"id": "P1", "before": "nicht_belegt", "after": "gestuetzt"}]


def test_statement_verdict_is_counted_as_a_claim_overturn(tmp_path):
    results = tmp_path / "results"
    results.mkdir()
    (results / "pass1-1.jsonl").write_text(
        json.dumps({"sid": "S1", "verdict": "nicht_belegt"}) + "\n", encoding="utf-8")
    (tmp_path / "statements.jsonl").write_text(
        json.dumps({"sid": "S1", "line": 1, "text": "Aussage.", "numbers": [1]}) + "\n",
        encoding="utf-8")
    claims = {"P1": {"id": "P1", "line": 1, "number": 1, "claim": "Aussage."}}
    rows = cs.overturned(tmp_path, {"P1": {"verdict": "gestuetzt"}}, claims)
    assert rows == [{"id": "P1", "before": "nicht_belegt", "after": "gestuetzt"}]
