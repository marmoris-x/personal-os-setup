"""Minimal, checked text edits (Part 4)."""

from testlib import PAGE, page

import edits


def test_wrong_number_is_replaced_by_the_page_number_only():
    statement = "Blender 4.1 ist die aktuelle Version."
    quote = "Die aktuelle Version ist Blender 4.2 vom 16. Juli 2024."
    ok, reason = edits.validate_edit(statement, "4.1", "4.2", quote, PAGE)
    assert ok, reason

    raw = "Einleitung.\n" + statement + "\nSchluss.\n"
    start = raw.index("4.1")
    out, changes, rejected = edits.apply_decisions(
        raw, [{"action": "replace", "start": start, "end": start + 3, "new": "4.2"}])
    assert not rejected
    assert out == "Einleitung.\nBlender 4.2 ist die aktuelle Version.\nSchluss.\n"
    assert changes == 1


def test_new_name_outside_the_quote_is_rejected():
    ok, reason = edits.validate_edit(
        "Das Programm erzeugt Videos.", "Das Programm", "Maya",
        "Blender ist kostenlos und laeuft auf Windows, macOS und Linux und die Lizenz ist die GNU GPL.", PAGE)
    assert not ok
    assert "Maya" in reason or "Name" in reason


def test_edit_longer_than_fifty_characters_is_rejected():
    new = "Eine vollkommen neue und viel zu lange Aussage ueber das Programm."
    ok, reason = edits.validate_edit("Kurz.", "Kurz.", new,
                                     "Blender ist kostenlos und laeuft auf Windows, macOS und Linux und die Lizenz ist die GNU GPL.", PAGE)
    assert not ok
    assert "lang" in reason.lower()


def test_quote_too_short_is_rejected():
    ok, reason = edits.validate_edit("Blender ist frei.", "frei", "offen",
                                     "free and open", PAGE)
    assert not ok
    assert "kurz" in reason.lower()


def test_quote_not_found_is_rejected():
    ok, reason = edits.validate_edit(
        "Blender ist kostenlos.", "kostenlos", "gratis",
        "Blender ist ein Roboter aus dem Weltraum.", PAGE)
    assert not ok
    assert "nicht gefunden" in reason.lower()


def test_table_cell_deletion_keeps_the_table_shape():
    raw = "| Name | Wert |\n|---|---|\n| A | alt |\n"
    old = "alt"
    start = raw.index(old)
    out, changes, rejected = edits.apply_decisions(
        raw, [{"action": "delete", "start": start, "end": start + len(old)}])
    assert not rejected and changes == 1
    assert out == "| Name | Wert |\n|---|---|\n| A | — |\n"
    ok, reasons = edits.format_check(raw, out, [(start, start + len(old))])
    assert ok, reasons


def test_list_item_deletion_keeps_the_other_items():
    raw = "- eins\n- zwei\n- drei\n"
    start = raw.index("- zwei")
    end = start + len("- zwei\n")
    out, changes, rejected = edits.apply_decisions(
        raw, [{"action": "delete", "start": start, "end": end}])
    assert not rejected and changes == 1
    assert out == "- eins\n- drei\n"


def test_crlf_and_final_newline_survive():
    raw = "Erster Satz.\r\nZweiter Satz.\r\n"
    old = "Zweiter Satz."
    start = raw.index(old)
    out, changes, rejected = edits.apply_decisions(
        raw, [{"action": "replace", "start": start, "end": start + len(old), "new": "Dritter Satz."}])
    assert not rejected and changes == 1
    assert out == "Erster Satz.\r\nDritter Satz.\r\n"
    ok, reasons = edits.format_check(raw, out, [(start, start + len(old))])
    assert ok, reasons


def test_format_check_catches_a_change_outside_the_span():
    raw = "A.\nB.\nC.\n"
    edited = "A.\nB geaendert.\nC.\n"
    ok, reasons = edits.format_check(raw, edited, [(0, 2)])
    assert not ok
    assert any("Zeile 2" in r for r in reasons)


def test_deleting_a_sentence_may_take_its_citation_marker():
    raw = "Erster Satz. Zweiter Satz[[1](https://example.org/a)].\n"
    start = raw.index("Zweiter")
    end = raw.index(")]", start) + 2
    out, changes, rejected = edits.apply_decisions(
        raw, [{"action": "delete", "start": start, "end": end}])
    assert not rejected and changes == 1
    ok, reasons = edits.format_check(raw, out, [(start, end)])
    assert ok, reasons


def test_wertung_names_the_deleted_fact_it_rested_on():
    deps = edits.wertung_dependencies(
        {"line": 5, "text": "Maya ist eindeutig die beste Wahl."},
        [{"line": 4, "text": "Maya erfindet Videos."},
         {"line": 20, "text": "Blender ist kostenlos."}])
    assert deps == [{"line": 4, "text": "Maya erfindet Videos.", "shared": ["maya"]}]


def test_preservation_score_is_one_for_identical_text():
    assert edits.preservation("gleich", "gleich") == 1.0
    assert edits.preservation("gleich", "anders") < 1.0
