"""A supported verdict is rechecked when the claim is a judgment or contains an absolute."""

import json
from types import SimpleNamespace

from testlib import write_jsonl

import check_sources as cs


def row(pid, claim, verdict="gestuetzt", evidence="ok"):
    return {"id": pid, "line": 1, "number": 1, "url": "https://example.org/a",
            "claim": claim, "verdict": verdict, "quote": "a quote long enough here",
            "note": "", "evidence": evidence}


def ids_in_recheck(work):
    ids = []
    for path in sorted((work / "recheck").glob("batch-*.json")):
        batch = json.loads(path.read_text(encoding="utf-8"))
        ids += [c["id"] for s in batch["sources"] for c in s["claims"]]
    return ids


def run(tmp_path, rows):
    write_jsonl(tmp_path / "verdicts.jsonl", rows)
    code = cs.cmd_recheck(SimpleNamespace(workdir=str(tmp_path), per_agent=6))
    assert code == 0
    return ids_in_recheck(tmp_path)


def test_absolute_word_sends_supported_verdict_to_recheck(tmp_path):
    assert run(tmp_path, [row("P1", "Blender ist immer kostenlos."),
                          row("P2", "Blender ist kostenlos.")]) == ["P1"]


def test_value_judgment_sends_supported_verdict_to_recheck(tmp_path):
    assert run(tmp_path, [row("P1", "Das ist die einzig realistische Beurteilung."),
                          row("P2", "Blender ist kostenlos.")]) == ["P1"]


def test_word_boundary_does_not_match_inside_another_word(tmp_path):
    assert run(tmp_path, [row("P2", "Niemand kann das bestreiten.")]) == []


def test_absolute_list_is_word_based():
    assert cs.has_absolute_word("Das gilt ausschließlich für Windows.")
    assert cs.has_absolute_word("Die Analyse kollabiert nach drei Monaten.")
    assert not cs.has_absolute_word("Niemand hat das gesagt.")
