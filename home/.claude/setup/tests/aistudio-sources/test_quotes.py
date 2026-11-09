"""Quote length is part of the proof (Part 1 step 2)."""

import pytest

from testlib import CITE, page  # noqa: F401

import check_sources as cs


def test_three_word_quote_is_too_short(tmp_path):
    p = page(tmp_path)
    state, _ = cs.evidence_state("gestuetzt", "free and open", str(p))
    assert state == "too_short"


def test_short_quote_with_a_digit_is_accepted(tmp_path):
    p = page(tmp_path)
    state, _ = cs.evidence_state("gestuetzt", "Apache License 2.0", str(p))
    assert state == "ok"


def test_ten_word_quote_is_accepted(tmp_path):
    p = page(tmp_path)
    quote = "Die aktuelle Version ist Blender 4.2 vom 16. Juli 2024"
    state, _ = cs.evidence_state("gestuetzt", quote, str(p))
    assert state == "ok"


def test_quote_over_forty_words_is_rejected(tmp_path):
    p = page(tmp_path)
    quote = " ".join(["Blender"] * 41)
    state, _ = cs.evidence_state("gestuetzt", quote, str(p))
    assert state == "too_long"


def test_short_quote_for_nicht_belegt_is_not_a_proof_problem():
    assert cs.evidence_state("nicht_belegt", "free and open", None)[0] == "no_page"
