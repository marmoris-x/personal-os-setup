"""Passage packs: split, rank, top 4, cited scope (Part 2 step 5)."""

import json

from testlib import PAGE, SCRIPTS, page  # noqa: F401  (adds the scripts folder to sys.path)

import check_sources as cs
import packs


def page_body(path):
    return cs.read_page(path)[1]


PAGE_TEXT = """# Blender

Blender ist kostenlos und laeuft auf Windows.

Die aktuelle Version ist Blender 4.2 vom 16. Juli 2024.

Die Lizenz ist die GNU GPL.

# Andere Seite

Remotion ist ein React-Framework fuer Videos.
"""


def test_split_keeps_the_heading_and_line_numbers():
    rows = packs.split_passages(PAGE_TEXT)
    assert rows[0]["heading"] == "Blender"
    assert rows[0]["line"] == 3
    assert "Blender ist kostenlos" in rows[0]["text"]


def test_exact_number_signal_ranks_the_right_passage():
    rows = packs.split_passages(PAGE_TEXT)
    ranked = packs.rank("Welche Version ist Blender 4.2?", rows)
    assert "4.2" in ranked[0]["text"]


def test_word_overlap_ranks_a_matching_passage():
    rows = packs.split_passages(PAGE_TEXT)
    ranked = packs.rank("Welche Lizenz hat Blender?", rows)
    assert "GNU GPL" in ranked[0]["text"]


def test_at_most_four_passages():
    rows = packs.split_passages(PAGE_TEXT)
    ranked = packs.rank("Blender", rows, top=4)
    assert len(ranked) <= 4


def test_pack_without_embedding_names_its_signals(tmp_path):
    rows = [dict(p, page=1) for p in packs.split_passages(PAGE_TEXT)]
    item = packs.pack_entry({"sid": "S1", "text": "Blender ist kostenlos.", "numbers": [1]},
                            rows)
    assert item["signals"] == ["exact", "bm25"]
    assert item["passages"]


def test_cited_statement_only_sees_its_pages(tmp_path):
    rows = [dict(p, page=1) for p in packs.split_passages(PAGE_TEXT)]
    rows += [dict(p, page=2) for p in packs.split_passages(PAGE_TEXT)]
    item = packs.pack_entry({"sid": "S1", "text": "Remotion ist ein React-Framework.",
                             "numbers": [1]}, rows)
    assert all(p["page"] == 1 for p in item["passages"])


def test_uncited_statement_sees_all_pages():
    rows = [dict(p, page=1) for p in packs.split_passages(PAGE_TEXT)]
    rows += [dict(p, page=2) for p in packs.split_passages("# Zweite Seite\n\nRemotion ist ein React-Framework.\n")]
    item = packs.pack_entry({"sid": "S1", "text": "Remotion ist ein React-Framework.",
                             "numbers": []}, rows)
    assert {p["page"] for p in item["passages"]} == {1, 2}


def test_embedding_signal_is_used_when_vectors_exist():
    rows = [dict(p, page=1) for p in packs.split_passages(PAGE_TEXT)]
    vectors = {"statements": {"S1": [1.0, 0.0]},
               "passages": {packs.passage_key(p): [1.0, 0.0] for p in rows}}
    item = packs.pack_entry({"sid": "S1", "text": "Blender ist kostenlos.", "numbers": [1]},
                            rows, embeddings=vectors)
    assert item["signals"] == ["exact", "bm25", "embedding"]


def test_verdict_cache_key_is_stable():
    a = packs.cache_key("Seitentext", "Aussage")
    b = packs.cache_key("Seitentext", "Aussage")
    c = packs.cache_key("Seitentext", "Andere Aussage")
    assert a == b != c


def test_cached_verdict_is_reused_and_not_asked_again(tmp_path):
    p = page(tmp_path)
    work = tmp_path / "work"
    work.mkdir()
    (work / "pages.json").write_text(json.dumps({"sources": [
        {"number": 1, "url": "https://example.org/blender", "page": str(p), "status": "ok"}]}),
        encoding="utf-8")
    statement = {"sid": "S1", "text": "Blender ist kostenlos.", "numbers": [1],
                 "self_contained": "Blender ist kostenlos."}
    key = packs.cache_key(page_body(p), statement["text"])
    (work / "verdict-cache.json").write_text(json.dumps({key: {
        "verdict": "gestuetzt", "quote": "Blender ist kostenlos und laeuft auf Windows", "note": ""}}),
        encoding="utf-8")
    entries, _passages, _batches = packs.build_packs(work, [statement])
    assert entries == 0
    rows = [json.loads(l) for l in (work / "results" / "pass0-cache.jsonl")
            .read_text(encoding="utf-8").splitlines() if l.strip()]
    assert rows == [{"sid": "S1", "verdict": "gestuetzt",
                     "quote": "Blender ist kostenlos und laeuft auf Windows", "note": ""}]


def test_validate_stores_each_final_verdict_with_its_page_text(tmp_path):
    p = page(tmp_path)
    work = tmp_path / "work"
    work.mkdir()
    (work / "pages.json").write_text(json.dumps({"sources": [
        {"number": 1, "url": "https://example.org/blender", "page": str(p), "status": "ok"}]}),
        encoding="utf-8")
    (work / "verdicts.jsonl").write_text(json.dumps({
        "number": 1, "claim": "Blender ist kostenlos.", "verdict": "gestuetzt",
        "quote": "Blender ist kostenlos und laeuft auf Windows", "note": ""}) + "\n",
        encoding="utf-8")
    assert packs.update_verdict_cache(work) == 1
    cache = json.loads((work / "verdict-cache.json").read_text(encoding="utf-8"))
    assert cache[packs.cache_key(page_body(p), "Blender ist kostenlos.")]["verdict"] == "gestuetzt"
