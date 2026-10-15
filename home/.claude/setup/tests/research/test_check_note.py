"""Tests for check_note.py. Each check is made to fail on purpose on a broken copy."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import SCRIPTS, Work, run_script  # noqa: E402

sys.path.insert(0, str(SCRIPTS))

import check_note  # noqa: E402  (unit-level checks; honours RESEARCH_SCRIPTS for mutations)

LINK_1 = "[1](https://example.org/wien)"
LINK_2 = "[2](https://example.net/zwei)"
LINK_3 = "[3](https://example.org/seite3)"
LINK_10 = "[10](https://example.org/seite10)"
ENTRY_1 = ("[1] Stadt Wien. Wien: Fakten. example.org. 2025-03-01. Quellenart: Primärquelle. "
           "Abgerufen 2026-10-06. https://example.org/wien")
ENTRY_2 = ("[2] Zweite Quelle. Titel zwei. example.net. 2025-01-01. Quellenart: Sekundärquelle. "
           "Abgerufen 2026-10-06. https://example.net/zwei")

# The saved page 001-example.org.md (fixture from testlib) is type "primary" and carries
# "Wien ist die Hauptstadt von Österreich ..." and the mayor's sentence.
BODY = f"""# Wien

Wien ist die Hauptstadt von Österreich und hat rund 2 Millionen Einwohner {LINK_1}.

Die Stadt gründet sich auf eine römische Siedlung namens Vindobona, die im ersten \
Jahrhundert entstand {LINK_1}.
"""


def build(body, entries):
    """A stored note: frontmatter, body, reference block."""
    return ("---\ntitle: \"Test\"\nlang: de\n---\n\n" + body
            + "<!-- references:start -->\n" + "\n".join(entries) + "\n<!-- references:end -->\n")


def unit_disagreement(body):
    errors, warnings = [], []
    check_note.check_disagreement(body, errors, warnings)
    return errors, warnings


class CheckNote(unittest.TestCase):
    def setUp(self):
        self.work = Work()
        self.addCleanup(self.work.cleanup)

    def check(self, note, lang="de", today="2026-10-08", *extra):
        path = self.work.write("note.md", note)
        return run_script("check_note.py", path, "--pages", self.work.path / "pages",
                          "--lang", lang, "--today", today, *extra)

    # ---------------------------------------------------------------- the whole note

    def test_good_note_passes(self):
        code, out = self.check(build(BODY, [ENTRY_1]))
        self.assertEqual(code, 0, out)
        self.assertIn("SUMMARY errors=0 warnings=0", out)

    def test_citation_without_list_entry_fails(self):
        note = build(BODY.replace(f"entstand {LINK_1}", f"entstand {LINK_2}"), [ENTRY_1])
        code, out = self.check(note)
        self.assertEqual(code, 1, out)
        self.assertIn("number [2] is cited but has no list entry", out)

    def test_list_entry_never_cited_fails(self):
        code, out = self.check(build(BODY, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 1, out)
        self.assertIn("list entry [2] is never cited", out)

    def test_numbers_must_follow_first_appearance(self):
        body = f"# T\n\nErst die andere Quelle {LINK_2}, dann die erste {LINK_1}.\n"
        code, out = self.check(build(body, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 1, out)
        self.assertIn("numbers are not in order of first appearance", out)

    def test_a_fragment_may_stand_in_a_second_copy_of_a_page(self):
        # the same URL saved twice: the first fetch truncated, the second complete
        first = ("---\nurl: \"https://example.org/wien\"\nfinal_url: \"https://example.org/wien\"\n"
                 "type: \"primary\"\n---\n# Wien\n\nWien ist die Hauptstadt.\n")
        second = ("---\nurl: \"https://example.org/wien\"\nfinal_url: \"https://example.org/wien\"\n"
                  "type: \"primary\"\n---\n# Wien\n\nDer Mayor sagte uns: \"Wir bauen weiter an der Stadt\".\n")
        self.work.write("pages/003-example.org.md", first)
        self.work.write("pages/004-example.org.md", second)
        link = ("[1](https://example.org/wien#:~:text="
                "Wir%20bauen%20weiter%20an%20der%20Stadt)")
        body = f"# T\n\nDer Mayor sagte: \"Wir bauen weiter an der Stadt\" {link}.\n"
        note = build(body, ["[1] Stadt Wien. Wien: Fakten. example.org. 2025-03-01. "
                            "Quellenart: Primärquelle. Abgerufen 2026-10-06. "
                            "https://example.org/wien"])
        code, out = self.check(note)
        self.assertEqual(code, 0, out)

    # ---------------------------------------------------------------- disagreement

    def test_disagreement_needs_two_sources(self):
        body = BODY + f"\n## Wo die Quellen abweichen\n\nNur eine Quelle nennt einen Wert {LINK_1}.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("a disagreement needs two", out)

    def test_disagreement_variant_heading_is_still_checked(self):
        # the standard writes "Where sources disagree"; a renamed heading must not slip past
        body = (BODY + f"\n## Wo die Quellen sich widersprechen\n\nNur eine Quelle nennt einen "
                f"Wert {LINK_1}.\n")
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("a disagreement needs two", out)

    def test_disagreement_with_two_sources_passes(self):
        body = (BODY + f"\n## Wo die Quellen abweichen\n\nDie eine nennt 40 Prozent {LINK_1}, "
                f"die andere 41 Prozent {LINK_2}.\n")
        code, out = self.check(build(body, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 0, out)

    def test_disagreement_value_named_for_two_sources_warns(self):
        body = (BODY + f"\n## Wo die Quellen abweichen\n\nDie eine nennt 40 Prozent {LINK_1}, "
                f"die andere ebenfalls 40 Prozent {LINK_2}.\n")
        code, out = self.check(build(body, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 0, out)
        self.assertIn("the value 40 is named for sources ['1', '2']", out)

    def test_citation_marker_number_is_not_read_as_a_value(self):
        body = ("## Wo die Quellen abweichen\n\nDie eine Seite nennt Werte " + LINK_10
                + " und bleibt dabei " + LINK_10 + ", die andere ebenso " + LINK_2 + ".\n")
        errors, warnings = unit_disagreement(body)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_a_range_stays_one_value(self):
        body = (f"## Wo die Quellen abweichen\n\nDie eine nennt 40-43 Prozent {LINK_1}, "
                f"die andere nennt 40 Prozent {LINK_2}.\n")
        errors, warnings = unit_disagreement(body)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_a_range_of_years_is_not_a_value(self):
        body = (f"## Wo die Quellen abweichen\n\nDie eine nennt 2024-2025 {LINK_1}, "
                f"die andere nennt 2024-2025 {LINK_2}.\n")
        errors, warnings = unit_disagreement(body)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    # ---------------------------------------------------------------- open questions

    def test_open_question_claim_before_the_phrase_fails(self):
        body = BODY + "\nÜber die Hauptstadt von Österreich sagen die Quellen nichts.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("the sources say nothing", out)

    def test_open_question_claim_after_the_phrase_fails(self):
        body = BODY + "\nDie Quellen nennen nichts über die Hauptstadt von Österreich.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("the sources say nothing", out)

    def test_open_question_claim_after_a_semicolon_is_not_searched(self):
        # the clause after the semicolon names what carries the point, not the claim itself
        body = BODY + ("\nZur Siedlung Vindobona sagen die Quellen nichts; die Hauptstadt "
                       "von Österreich steht in der Stadt.\n")
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    def test_open_question_true_gap_passes(self):
        body = BODY + "\nDie Quellen nennen nichts zur Bevölkerungsentwicklung im Jahr 2030.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    # ---------------------------------------------------------------- primary before secondary

    def test_quote_from_secondary_while_a_primary_page_carries_it_fails(self):
        body = (BODY + "\nDer Bürgermeister sagte: \"Wir bauen – trotz aller Hürden – weiter an "
                f"der Stadt\" {LINK_2}.\n")
        code, out = self.check(build(body, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 1, out)
        self.assertIn("stands word for word in the primary page 001-example.org.md", out)

    def test_quote_not_carried_by_a_primary_page_passes(self):
        body = (BODY + "\nEine Stimme sagte: \"Die Stadt wächst seit Jahren stetig und ohne "
                f"Unterbrechung\" {LINK_2}.\n")
        code, out = self.check(build(body, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 0, out)

    # ---------------------------------------------------------------- cut quotes

    def test_cut_quote_ending_on_a_function_word_fails(self):
        body = f"# T\n\nEr sagte zuerst: \"Wir bauen weiter und\" {LINK_1}, dann ging er.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("the sentence is cut", out)

    def test_quote_ending_on_a_soft_word_warns(self):
        body = f"# T\n\nEr sagte: \"Wir bauen weiter mit\" {LINK_1}.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)
        self.assertIn("without the sentence's own end; check for a cut", out)

    def test_quote_with_its_own_sentence_end_passes(self):
        body = f"# T\n\nEr sagte: \"Wir bauen weiter.\" {LINK_1}\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)
        self.assertIn("SUMMARY errors=0 warnings=0", out)

    def test_quote_ending_on_a_soft_word_with_its_period_passes(self):
        # "Das macht viel aus." is a complete sentence: the source's own end counts
        body = f"# T\n\nEr sagte: \"Wir bauen weiter mit.\" {LINK_1}\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)
        self.assertIn("SUMMARY errors=0 warnings=0", out)

    def test_lowered_quote_warns_when_the_page_starts_it_upper_case(self):
        body = (f"# T\n\nEine Stimme sagte: \"wien ist die Hauptstadt von Österreich\" "
                f"{LINK_1}.\n")
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)
        self.assertIn("stands only with an upper-case first letter", out)

    def test_mid_sentence_quote_may_start_lower_case(self):
        body = f"# T\n\nEs heißt, die Stadt sei \"die Hauptstadt von Österreich\" {LINK_1}.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)
        self.assertIn("SUMMARY errors=0 warnings=0", out)

    # ---------------------------------------------------------------- work notes

    def test_work_note_phrases_fail(self):
        for phrase in check_note.WORK_NOTES:
            with self.subTest(phrase):
                body = BODY + f"\nDie {phrase} endet hier.\n"
                code, out = self.check(build(body, [ENTRY_1]))
                self.assertEqual(code, 1, out)
                self.assertIn("work notes in the text", out)

    # ---------------------------------------------------------------- dates and old numbers

    def test_attribution_year_mismatch_warns(self):
        body = BODY + f"\nDer Stand 2024 ist überholt {LINK_1}.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)
        self.assertIn("the text says 'Stand 2024'", out)

    def test_old_number_without_a_year_warns(self):
        entry = ("[1] Alte Quelle. Titel eins. example.org. 2019-05-01. Quellenart: Primärquelle. "
                 "Abgerufen 2026-10-06. https://example.org/wien")
        body = f"# T\n\nDer Anteil liegt bei 25 Prozent {LINK_1}.\n"
        code, out = self.check(build(body, [entry]))
        self.assertEqual(code, 0, out)
        self.assertIn("numbers from [1] (2019) without a year in the text", out)

    def test_old_number_with_a_year_passes(self):
        entry = ("[1] Alte Quelle. Titel eins. example.org. 2019-05-01. Quellenart: Primärquelle. "
                 "Abgerufen 2026-10-06. https://example.org/wien")
        body = f"# T\n\nDer Anteil lag 2019 bei 25 Prozent {LINK_1}.\n"
        code, out = self.check(build(body, [entry]))
        self.assertEqual(code, 0, out)
        self.assertIn("SUMMARY errors=0 warnings=0", out)

    # ---------------------------------------------------------------- source types

    def test_one_website_two_source_types_fails(self):
        entries = {1: ENTRY_1, 3: "[3] Andere. Titel drei. example.org. 2025-01-01. "
                                 "Quellenart: Sekundärquelle. Abgerufen 2026-10-06. "
                                 "https://example.org/seite3"}
        errors = []
        check_note.check_source_types(entries, errors)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("example.org carries two source types", errors[0])

    def test_platform_website_may_carry_two_source_types(self):
        entries = {1: "[1] A. Titel eins. github.com. 2025-01-01. Quellenart: Primärquelle. "
                       "Abgerufen 2026-10-06. https://github.com/a",
                   2: "[2] B. Titel zwei. github.com. 2025-01-02. Quellenart: Erfahrungsbericht. "
                       "Abgerufen 2026-10-06. https://github.com/b"}
        errors = []
        check_note.check_source_types(entries, errors)
        self.assertEqual(errors, [])

    # ---------------------------------------------------------------- translations

    def test_foreign_quote_without_a_translation_fails(self):
        body = (BODY + "\nDie Quelle sagt: \"العلم نور يقذفه الله في قلب من يشاء\" "
                f"{LINK_2}.\n")
        code, out = self.check(build(body, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 1, out)
        self.assertIn("without a translation marker", out)

    def test_foreign_quote_with_a_translation_passes(self):
        body = (BODY + "\nDie Quelle sagt: \"العلم نور يقذفه الله في قلب من يشاء\" "
                "(Übersetzung: Das Wissen ist ein Licht, das Gott in das Herz legt, wen er will.) "
                f"{LINK_2}.\n")
        code, out = self.check(build(body, [ENTRY_1, ENTRY_2]))
        self.assertEqual(code, 0, out)

    # ---------------------------------------------------------------- stale claims

    def test_not_yet_claim_without_a_year_fails(self):
        body = BODY + "\nDie freie Fassung unterstützt die Karte noch nicht.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("the \"not yet\" claim needs its date", out)

    def test_not_yet_claim_with_a_year_passes(self):
        body = BODY + "\nIm Jahr 2025 unterstützte die freie Fassung die Karte noch nicht.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    def test_not_yet_without_a_capability_word_passes(self):
        body = BODY + "\nDas letzte Kapitel ist noch nicht geschrieben.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    # ---------------------------------------------------------------- language absence

    def test_absence_claim_against_a_saved_page_fails(self):
        page = ("---\nurl: \"https://beispiel.de/\"\nfinal_url: \"https://beispiel.de/\"\n"
                "type: \"secondary\"\n---\n# Beispiel\n\nDer Dienst unterstützt die Sprachen "
                "Deutsch, Englisch und Französisch.\n")
        self.work.write("pages/003-beispiel.de.md", page)
        body = BODY + "\nEine deutsche Stimme fehlt.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("calls 'deutsch' absent", out)
        self.assertIn("003-beispiel.de.md", out)

    def test_absence_claim_against_the_notes_own_text_fails(self):
        body = (BODY + "\nEine deutsche Stimme fehlt.\n\nDie Anwendung spricht jeden Text "
                "mit einer deutschen Stimme aus.\n")
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("the note's own text", out)

    def test_absence_claim_without_counter_evidence_passes(self):
        body = BODY + "\nEine deutsche Stimme nennen die Quellen nicht.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    def test_a_far_absence_word_does_not_count(self):
        # even with a page that lists German: "nicht" far from "deutsche" is no absence claim
        page = ("---\nurl: \"https://beispiel.de/\"\nfinal_url: \"https://beispiel.de/\"\n"
                "type: \"secondary\"\n---\n# Beispiel\n\nDer Dienst unterstützt die Sprachen "
                "Deutsch, Englisch und Französisch.\n")
        self.work.write("pages/003-beispiel.de.md", page)
        body = (BODY + "\nDie deutsche Fassung aus dem Jahr 1950, die in mehreren Auflagen "
                "erschien und lange als Standard galt, wurde später nicht mehr nachgedruckt.\n")
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    # ---------------------------------------------------------------- foreign runs

    def test_english_run_in_german_text_fails(self):
        body = BODY + "\nAls Kompromiss gilt Recommended balance of speed and high accuracy.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("the English run 'Recommended balance of speed and high accuracy'", out)

    def test_a_one_letter_english_word_with_english_words_fails(self):
        body = BODY + "\nDas Projekt sammelt roughly 20 commits a day.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 1, out)
        self.assertIn("the English run", out)

    def test_legal_reference_letters_are_not_english(self):
        # "L 34 a" is a legal reference: one letter alone is no proof of English
        body = BODY + "\nDer Verweis steht bei L 34 a Punkt vier.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    def test_quoted_english_is_not_a_finding(self):
        body = (BODY + "\nSie nennen es \"Recommended balance of speed and high accuracy\" "
                "(Übersetzung: ein empfohlenes Gleichgewicht).\n")
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    def test_transliterated_names_are_not_english(self):
        body = BODY + "\nDer Gelehrte al-Khalīl ibn Aḥmad starb 786.\n"
        code, out = self.check(build(body, [ENTRY_1]))
        self.assertEqual(code, 0, out)

    def test_a_word_with_diacritics_never_joins_a_run(self):
        self.assertFalse(check_note.english_run_token("ʻAlī"))
        self.assertFalse(check_note.english_run_token("Khalīl"))
        self.assertTrue(check_note.english_run_token("light"))

    def test_a_transliterated_name_stays_one_token(self):
        # with a plain ASCII tokenizer "al-Khalīl" would fall apart and feed a run
        words = check_note.WORD_TOKEN_RE.findall("al-Khalīl ibn Aḥmad")
        self.assertEqual(words, ["al-Khalīl", "ibn", "Aḥmad"])

    # ---------------------------------------------------------------- time-varying numbers

    def test_disagreement_over_a_star_count_fails(self):
        body = (BODY + "\n## Wo Quellen sich widersprechen\n\nDie eine nennt \"Stars: 19250\" "
                f"{LINK_1}, die andere \"18,600 stars\" {LINK_2}.\n")
        errors = []
        check_note.check_time_varying_disagreement(body, errors)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("Stars: 19250", errors[0])

    def test_a_star_count_with_a_date_passes(self):
        body = (BODY + "\n## Wo die Quellen abweichen\n\nGelesen am 2026-10-08: \"Stars: 19250\" "
                f"{LINK_1} gegen \"18,600 stars\" {LINK_2}.\n")
        errors = []
        check_note.check_time_varying_disagreement(body, errors)
        self.assertEqual(errors, [])

    def test_a_fork_word_alone_is_no_reading(self):
        body = (BODY + "\n## Wo die Quellen abweichen\n\nDer Windows-Fork gibt 6,8 GB an "
                f"{LINK_1}, das Original nennt 8 GB {LINK_2}.\n")
        errors = []
        check_note.check_time_varying_disagreement(body, errors)
        self.assertEqual(errors, [])

    # ---------------------------------------------------------------- cross notes

    def test_a_version_that_differs_between_notes_fails(self):
        (self.work.path / "other").mkdir()
        first = self.work.write("other/erste.md",
                                "# T\n\nDas Werkzeug pyVideoTrans steht bei v4.08 "
                                "[1](https://example.org/a).\n")
        self.work.write("other/zweite.md",
                        "# T\n\nDas Werkzeug pyVideoTrans steht bei v4.12 "
                        "[1](https://example.org/a).\n")
        errors = []
        check_note.check_cross_notes(first.read_text(encoding="utf-8"), first,
                                     self.work.path / "other", errors)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("v4.08", errors[0])
        self.assertIn("v4.12", errors[0])


LINK_3 = "[3](https://example.org/seite3)"


if __name__ == "__main__":
    unittest.main()
