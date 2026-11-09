"""Report wording: singular/plural, no zero-only sentences, contradiction evidence (Part 1 step 7)."""

from testlib import SCRIPTS  # noqa: F401  (adds the scripts folder to sys.path)

import check_sources as cs


def test_zero_counts_do_not_print_a_zero_sentence():
    text = cs.result_sentence({})
    assert "0 " not in text
    assert "keine" in text.lower()


def test_one_is_singular():
    text = cs.result_sentence({"gestuetzt": 1})
    assert "1 Aussage wurde gestützt" in text
    assert "Aussagen" not in text


def test_two_is_plural():
    text = cs.result_sentence({"gestuetzt": 2, "widerspricht": 1})
    assert "2 Aussagen wurden gestützt" in text
    assert "1 Aussage widersprach" in text


def test_pair_counts_zero_do_not_appear():
    text = cs.pair_result_sentence(0, 0, 0, 0, 0, 0)
    assert "0 " not in text


def test_pair_counts_one_are_singular():
    text = cs.pair_result_sentence(1, 1, 0, 0, 0, 0)
    assert "1 Paar stützte" in text


def test_pair_counts_two_are_plural():
    text = cs.pair_result_sentence(3, 2, 0, 0, 1, 0)
    assert "2 Paare stützten" in text
    assert "1 Paar bezog sich" in text


def test_contradiction_names_page_and_passage():
    verdicts = [{"id": "P1", "number": 2, "verdict": "widerspricht",
                 "quote": "Blender ist nicht kostenlos."}]
    pages = {2: {"url": "https://example.org/blender"}}
    lines = cs.contradiction_lines(verdicts, pages)
    assert len(lines) == 1
    assert "https://example.org/blender" in lines[0]
    assert "Blender ist nicht kostenlos." in lines[0]


def test_report_summary_uses_singular_for_one():
    import correct_sources as csrc
    text = csrc.report_summary(1, 0, 1, 1, 1, 1)
    assert "wird 1 Quelle zitiert" in text
    assert "1 Verweis wurde ersetzt" in text
    assert "Bei 1 Aussage wurde der Verweis entfernt" in text
    assert "1 Aussage ist nur teilweise belegt" in text
    assert "Bei 1 Stelle wurde" in text


def test_report_summary_uses_plural_for_many():
    import correct_sources as csrc
    text = csrc.report_summary(3, 1, 2, 2, 2, 2)
    assert "werden 3 Quellen zitiert" in text
    assert "2 Verweise wurden ersetzt" in text
    assert "Bei 2 Aussagen wurden die Verweise entfernt" in text
    assert "2 Aussagen sind nur teilweise belegt" in text
