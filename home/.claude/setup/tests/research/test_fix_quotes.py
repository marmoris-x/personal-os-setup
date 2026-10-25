"""Tests for fix_quotes.py: deterministic repair of quotes that are not word sequences."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import SCRIPTS, Work, run_script  # noqa: E402

sys.path.insert(0, str(SCRIPTS))
import fix_quotes  # noqa: E402
from common import COMPOSE_RE, check_fragments, load_evidence, paragraphs, parse_compose  # noqa: E402

E1 = "Beim PKW beträgt das Kilometergeld 0,50 Euro pro gefahrenem Kilometer."
E2 = "Die Betriebskosten müssen von der fahrenden Person selbst getragen werden."
E3 = "Die Kosten werden getragen."


def evidence(**texts):
    return {key: {"id": key, "text": text} for key, text in texts.items()}


def draft(paragraph, frags, ids=None, forms=None):
    compose = {"ids": ids or [frags[0][0]], "frags": frags}
    if forms:
        compose["forms"] = forms
    return paragraph + "\n<!-- compose " + json.dumps(compose, ensure_ascii=False) + " -->\n"


class FixQuotes(unittest.TestCase):
    def test_near_miss_quote_is_replaced(self):
        text = draft(
            "Beim PKW beträgt das Kilometergeld 0,50 Euro pro Kilometer. [[E1]]",
            [["E1", "Beim PKW beträgt das Kilometergeld 0,50 Euro pro Kilometer"]],
        )
        fixed, notes = fix_quotes.fix_text(text, evidence(E1=E1))

        self.assertIn(E1, fixed)
        self.assertEqual(len(notes), 1)
        self.assertIn("NOTE quote fixed", notes[0])
        block = paragraphs(fixed)[0]
        self.assertEqual(check_fragments(parse_compose(block), evidence(E1=E1),
                                         paragraph_text=block), [])

    def test_quote_below_threshold_is_left_alone(self):
        text = draft(
            "Der Arbeitgeber zahlt immer genau diesen Betrag aus. [[E1]]",
            [["E1", "Der Arbeitgeber zahlt immer genau diesen Betrag aus"]],
        )
        fixed, notes = fix_quotes.fix_text(text, evidence(E1=E1))
        self.assertEqual(fixed, text)
        self.assertEqual(notes, [])

    def test_exact_quote_is_not_touched(self):
        text = draft("Beim PKW beträgt das Kilometergeld 0,50 Euro pro gefahrenem Kilometer. [[E1]]",
                     [["E1", "Beim PKW beträgt das Kilometergeld 0,50 Euro pro gefahrenem Kilometer"]])
        fixed, notes = fix_quotes.fix_text(text, evidence(E1=E1))
        self.assertEqual(fixed, text)
        self.assertEqual(notes, [])

    def test_forms_are_used_for_the_check(self):
        text = draft(
            "Die Kosten werden getragene. [[E3]]",
            [["E3", "Die Kosten werden getragene"]],
            forms=[["E3", "getragene", "getragen"]],
        )
        fixed, notes = fix_quotes.fix_text(text, evidence(E3=E3))
        self.assertEqual(fixed, text)
        self.assertEqual(notes, [])

    def test_ninety_percent_is_enough(self):
        source = "a b c d e f g h i j"
        text = draft("a b c d e f g h i x. [[E4]]", [["E4", "a b c d e f g h i x"]])
        fixed, notes = fix_quotes.fix_text(text, evidence(E4=source))
        self.assertIn(source, fixed)
        self.assertEqual(len(notes), 1)

    def test_only_the_broken_fragment_changes(self):
        text = draft(
            "Beim PKW beträgt das Kilometergeld 0,50 Euro pro Kilometer. Die Betriebskosten "
            "müssen von der fahrenden Person selbst getragen werden. [[E1]]",
            [["E1", "Beim PKW beträgt das Kilometergeld 0,50 Euro pro Kilometer"],
             ["E2", "Die Betriebskosten müssen von der fahrenden Person selbst getragen werden"]],
            ids=["E1", "E2"],
        )
        fixed, notes = fix_quotes.fix_text(text, evidence(E1=E1, E2=E2))
        self.assertEqual(len(notes), 1)
        self.assertIn(E2, fixed)
        self.assertIn("pro gefahrenem Kilometer", fixed)

    def test_missing_evidence_is_left_alone(self):
        text = draft("Ein Satz. [[E9]]", [["E9", "Ein Satz"]], ids=["E9"])
        fixed, notes = fix_quotes.fix_text(text, evidence(E1=E1))
        self.assertEqual(fixed, text)
        self.assertEqual(notes, [])

    def test_inflected_wording_in_the_paragraph_becomes_a_declared_form(self):
        # The key-point block of the Kilometergeld run (search tuning, run A, 2026-10-25): the
        # fragment E67 is the evidence's wording ("gesetzlichen"), the bullet says "gesetzlicher".
        e67 = ("Es gibt keinen gesetzlichen Anspruch auf Kilometergeld. Ob und in welcher Hoehe "
               "der Arbeitgeber zahlt, ergibt sich aus Kollektivvertrag oder Arbeitsvertrag.")
        text = draft(
            "- Beim Fahrrad gilt seit 2025 eine Grenze. [[E7]]\n"
            "- Kein gesetzlicher Anspruch auf Kilometergeld. [[E67]]",
            [["E7", "gilt seit 2025 eine Grenze"], ["E67", "gesetzlichen Anspruch auf Kilometergeld"]],
            ids=["E7", "E67"])
        ev = evidence(E7="Beim Fahrrad gilt seit 2025 eine Grenze von 3.000 Kilometern.", E67=e67)
        before = paragraphs(text)[0]
        self.assertTrue(check_fragments(parse_compose(before), ev,
                                        paragraph_text=COMPOSE_RE.sub("", before)))

        fixed, notes = fix_quotes.fix_text(text, ev)

        block = paragraphs(fixed)[0]
        self.assertEqual(check_fragments(parse_compose(block), ev,
                                         paragraph_text=COMPOSE_RE.sub("", block)), [])
        self.assertIn("Kein gesetzlicher Anspruch auf Kilometergeld.", fixed)  # the wording stays grammatical
        self.assertEqual(parse_compose(block)["forms"], [["E67", "gesetzlicher", "gesetzlichen"]])
        self.assertEqual(len(notes), 1)
        self.assertIn("NOTE form declared", notes[0])

    def test_a_different_wording_in_the_paragraph_is_left_alone(self):
        text = draft("Ein Anspruch besteht nach Vertrag. [[E67]]",
                     [["E67", "gesetzlichen Anspruch auf Kilometergeld"]])
        ev = evidence(E67="Es gibt keinen gesetzlichen Anspruch auf Kilometergeld.")
        fixed, notes = fix_quotes.fix_text(text, ev)
        self.assertEqual(fixed, text)
        self.assertEqual(notes, [])

    def test_cli_rewrites_the_file_and_prints_the_note(self):
        work = Work()
        self.addCleanup(work.cleanup)
        work.verified([{"id": "E1", "text": E1}])
        path = work.write("draft/draft.md", draft(
            "Beim PKW beträgt das Kilometergeld 0,50 Euro pro Kilometer. [[E1]]",
            [["E1", "Beim PKW beträgt das Kilometergeld 0,50 Euro pro Kilometer"]],
        ))

        code, out = run_script("fix_quotes.py", path, "--workdir", work.path)

        self.assertEqual(code, 0)
        self.assertIn("NOTE quote fixed", out)
        fixed = path.read_text(encoding="utf-8")
        self.assertIn("pro gefahrenem Kilometer", fixed)
        block = paragraphs(fixed)[0]
        self.assertEqual(check_fragments(parse_compose(block), load_evidence(work.path),
                                         paragraph_text=block), [])


if __name__ == "__main__":
    unittest.main()
