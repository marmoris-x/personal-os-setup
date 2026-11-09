"""A pack verdict is expanded to one row per cited number."""

import json

from testlib import SCRIPTS  # noqa: F401

import check_sources as cs


def test_statement_verdict_becomes_one_row_per_number(tmp_path):
    (tmp_path / "statements.jsonl").write_text(json.dumps({
        "sid": "S001", "line": 3, "text": "Aussage.", "numbers": [1, 2],
        "url": "https://example.org", "section": ""}) + "\n", encoding="utf-8")
    claims = {"P001": {"id": "P001", "line": 3, "number": 1, "claim": "Aussage."},
              "P002": {"id": "P002", "line": 3, "number": 2, "claim": "Aussage."}}
    merged = {"S001": {"verdict": "gestuetzt", "quote": "q" * 20, "note": "", "pass": "pass1"}}
    merged, claims = cs.expand_statement_results(tmp_path, merged, claims)
    assert set(merged) == {"P001", "P002"}
    assert all(v["verdict"] == "gestuetzt" for v in merged.values())


def test_uncited_statement_verdict_is_kept_visible(tmp_path):
    (tmp_path / "statements.jsonl").write_text(json.dumps({
        "sid": "S004", "line": 9, "text": "Eine unzitierte Aussage.", "numbers": []}) + "\n",
        encoding="utf-8")
    merged = {"S004": {"verdict": "nicht_belegt", "quote": "", "note": "", "pass": "pass1"}}
    merged, claims = cs.expand_statement_results(tmp_path, merged, {})
    assert merged == {}
    rows = [json.loads(l) for l in
            (tmp_path / "uncited-verdicts.jsonl").read_text(encoding="utf-8").splitlines()]
    assert rows[0]["sid"] == "S004"
    assert rows[0]["verdict"] == "nicht_belegt"
