"""One parser for check_sources.py and correct_sources.py (Part 1 step 3)."""

import pytest

from testlib import SCRIPTS  # noqa: F401  (adds the scripts folder to sys.path)

import claims


def pairs(text, sources=None):
    return claims.extract_claims(text, sources or {})[0]


def test_abbreviation_does_not_end_a_sentence():
    got = claims.sentences("Dr. Mueller leitet das Projekt. Es endet 2026.")
    assert got == ["Dr. Mueller leitet das Projekt.", "Es endet 2026."]


def test_marker_after_full_stop_keeps_two_claims():
    text = ("Blender ist kostenlos.[[1](https://example.org/a)] "
            "Es laeuft auf Windows.[[2](https://example.org/b)]\n")
    got = pairs(text)
    assert [p["claim"] for p in got] == ["Blender ist kostenlos.", "Es laeuft auf Windows."]
    assert [p["number"] for p in got] == [1, 2]


def test_marker_before_full_stop_keeps_the_sentence():
    text = ("Blender ist kostenlos[[1](https://example.org/a)]. "
            "Es laeuft auf Windows.\n")
    got = pairs(text)
    assert len(got) == 1
    assert got[0]["claim"] == "Blender ist kostenlos."


def test_space_before_marker_is_the_same_sentence():
    text = ("Blender ist kostenlos. [[1](https://example.org/a)] "
            "Es laeuft auf Windows.[[2](https://example.org/b)]\n")
    got = pairs(text)
    assert [p["claim"] for p in got] == ["Blender ist kostenlos.", "Es laeuft auf Windows."]


def test_table_cell_gets_its_label():
    text = "| Fokus | Programmatisches 2D-Video[[1](https://example.org/a)] |\n"
    got = pairs(text)
    assert len(got) == 1
    assert got[0]["claim"] == "Fokus: Programmatisches 2D-Video"


def test_block_quote_is_one_claim():
    text = "> Ein Zitat mit Beleg[[1](https://example.org/a)]\n"
    got = pairs(text)
    assert len(got) == 1
    assert got[0]["claim"] == "Ein Zitat mit Beleg"


def test_two_markers_in_one_sentence_share_the_sentence():
    text = "A[[1](https://example.org/a)] B[[2](https://example.org/b)].\n"
    got = pairs(text)
    assert [p["number"] for p in got] == [1, 2]
    assert {p["claim"] for p in got} == {"A B."}
    line = "A[[1](https://example.org/a)] B[[2](https://example.org/b)]."
    first = line.index("[[1")
    second = line.index("[[2")
    assert claims.statement_for(line, first) == "A B."
    assert claims.statement_for(line, second) == "A B."


def test_uncited_sentence_before_a_cited_one_is_not_merged():
    text = "Eine Aussage ohne Beleg. Eine Aussage mit Beleg[[1](https://example.org/a)].\n"
    got = pairs(text)
    assert len(got) == 1
    assert got[0]["claim"] == "Eine Aussage mit Beleg."


def test_every_statement_includes_uncited_ones():
    text = ("# Abschnitt\n\n"
            "Eine unbelegte Aussage.\n"
            "Eine belegte Aussage[[1](https://example.org/a)].\n")
    got = claims.statements(text)
    assert [s["text"] for s in got] == ["Eine unbelegte Aussage.",
                                        "Eine belegte Aussage."]
    assert [s["numbers"] for s in got] == [[], [1]]
    assert got[0]["section"] == "Abschnitt"


def test_pronoun_is_resolved_from_the_previous_sentence():
    text = ("Blender ist kostenlos. Es laeuft auf Windows.\n")
    got = claims.statements(text)
    assert got[0]["self_contained"] == "Blender ist kostenlos."
    assert got[1]["self_contained"] == "Blender laeuft auf Windows."


def test_table_statement_has_label_header_and_exact_span():
    text = "| Produkt | Fokus |\n|---|---|\n| Blender | 3D-Generierung |\n"
    got = claims.statements(text)
    assert len(got) == 1
    item = got[0]
    assert item["self_contained"] == "Blender: Fokus: 3D-Generierung"
    assert item["table"] == {"label": "Blender", "header": "Fokus"}
    assert text[item["start"]:item["end"]] == "3D-Generierung"


def test_list_item_is_one_statement():
    got = claims.statements("- Blender ist kostenlos.\n- Remotion ist ein React-Framework.\n")
    assert [s["text"] for s in got] == ["Blender ist kostenlos.",
                                        "Remotion ist ein React-Framework."]


def test_opinion_is_labelled_wertung():
    got = claims.statements("Meiner Meinung nach ist Remotion die beste Wahl.\n")
    assert got[0]["kind"] == "wertung"
