"""Near-miss quotes are repaired in code before the recheck (Part 2 step 1)."""

from testlib import page

import check_sources as cs


def row(quote, number=1):
    return {"id": "P1", "number": number, "verdict": "gestuetzt", "quote": quote,
            "note": "", "pass": "pass1", "page": None, "evidence": "not_found",
            "quote_line": None}


def test_a_retyped_word_is_replaced_with_the_page_span(tmp_path):
    p = page(tmp_path)
    rows = [row("Blender ist kostenlos und laeuft auf Window, macOS und Linux und die "
                "Lizenz ist die GNU GPL.")]
    repaired, notes = cs.repair_quotes(rows, {1: {"page": str(p)}})
    assert repaired == 1
    assert "Windows" in rows[0]["quote"]
    assert rows[0]["evidence"] == "ok"
    assert notes


def test_a_reversal_is_not_smuggled_in(tmp_path):
    text = ('---\nurl: "https://example.org/x"\n---\n'
            "Blender ist nicht kostenlos.\n")
    p = page(tmp_path, "reverse.md", text)
    rows = [row("Blender ist kostenlos.")]
    repaired, notes = cs.repair_quotes(rows, {1: {"page": str(p)}})
    assert repaired == 0
    assert rows[0]["quote"] == "Blender ist kostenlos."


def test_more_than_thirty_percent_different_is_left_alone(tmp_path):
    p = page(tmp_path)
    rows = [row("Voellig andere Worte ohne jeden Bezug zur Seite.")]
    repaired, _ = cs.repair_quotes(rows, {1: {"page": str(p)}})
    assert repaired == 0


def test_a_repair_that_joins_words_stays_too_short(tmp_path):
    text = ('---\nurl: "https://example.org/x"\n---\n'
            "Blender is free-and-open-source today.\n")
    p = page(tmp_path, "joined.md", text)
    rows = [row("Blender is free and open source")]
    repaired, _ = cs.repair_quotes(rows, {1: {"page": str(p)}})
    assert repaired == 1
    assert rows[0]["quote"] == "Blender is free-and-open-source"
    assert rows[0]["evidence"] == "too_short"
