"""Tests for verify_evidence.py: good input passes, every check is made to fail on purpose."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import E1, E2, E4, Work, run_script  # noqa: E402


def load(work, name):
    path = work.path / "evidence" / name
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


class VerifyEvidence(unittest.TestCase):
    def setUp(self):
        self.work = Work()
        self.addCleanup(self.work.cleanup)

    def verify(self, items, *extra):
        self.work.raw(items)
        return run_script("verify_evidence.py", self.work.path, *extra)

    def test_exact_quote_passes_with_line_numbers(self):
        code, out = self.verify([{"page": E1["page"], "text": E1["text"], "claim": "capital"}])
        self.assertEqual(code, 0, out)
        item = load(self.work, "verified.jsonl")[0]
        self.assertEqual((item["id"], item["match"], item["lines"]), ("E1", "exact", [15, 15]))
        self.assertEqual(item["url"], "https://example.org/wien")

    def test_changed_word_fails(self):  # the check goes red on purpose
        bad = E1["text"].replace("Hauptstadt", "Metropole")
        code, out = self.verify([{"page": E1["page"], "text": bad}])
        self.assertEqual(code, 1, out)
        self.assertIn("not found in the saved page", load(self.work, "failed.jsonl")[0]["reason"])

    def test_unicode_and_whitespace_are_normalised(self):
        odd = E1["text"].replace(" ist ", " ist\n ")
        code, out = self.verify([{"page": E1["page"], "text": odd}])
        self.assertEqual(code, 0, out)

    def test_markdown_syntax_in_page_is_matched_as_stripped(self):
        text = "Das Rathaus wurde 1883 fertiggestellt und steht am Ring."
        code, out = self.verify([{"page": E1["page"], "text": text}])
        self.assertEqual(code, 0, out)
        self.assertEqual(load(self.work, "verified.jsonl")[0]["match"], "markdown-stripped")

    def test_tatweel_is_ignored_and_diacritics_are_flagged(self):
        plain = "هذا كتاب الكتابة"
        code, _ = self.verify([{"page": E4["page"], "text": plain}])
        self.assertEqual(code, 0)
        self.assertEqual(load(self.work, "verified.jsonl")[0]["match"], "exact")
        no_marks = "العلم نور يقذفه الله في قلب من يشاء"
        code, _ = self.verify([{"page": E4["page"], "text": no_marks}])
        self.assertEqual(code, 0)
        self.assertEqual(load(self.work, "verified.jsonl")[0]["match"], "diacritics-insensitive")

    def test_path_trick_in_page_name_fails(self):
        code, out = self.verify([{"page": "../../secret.md", "text": "one two three four"}])
        self.assertEqual(code, 1, out)
        self.assertIn("not a plain file name", load(self.work, "failed.jsonl")[0]["reason"])

    def test_missing_page_fails(self):
        code, _ = self.verify([{"page": "999-none.md", "text": "one two three four"}])
        self.assertEqual(code, 1)
        self.assertIn("file not found", load(self.work, "failed.jsonl")[0]["reason"])

    def test_too_short_and_empty_fail(self):
        code, _ = self.verify([{"page": E1["page"], "text": "Wien ist"},
                               {"page": E1["page"], "text": "  "}])
        self.assertEqual(code, 1)
        reasons = [f["reason"] for f in load(self.work, "failed.jsonl")]
        self.assertEqual(len(reasons), 2)

    def test_duplicates_are_dropped_and_ids_are_sequential(self):
        items = [{"page": E1["page"], "text": E1["text"]}, {"page": E1["page"], "text": E1["text"]},
                 {"page": E2["page"], "text": E2["text"]}]
        code, _ = self.verify(items)
        self.assertEqual(code, 0)
        self.assertEqual([v["id"] for v in load(self.work, "verified.jsonl")], ["E1", "E2"])

    def test_terminology_line_is_not_counted_as_failed_evidence(self):
        items = [{"page": E1["page"], "text": E1["text"]}, {"term_variants": {"de": [["Wien", 3]]}}]
        code, out = self.verify(items, "--strict")
        self.assertEqual(code, 0, out)
        self.assertEqual(load(self.work, "failed.jsonl"), [])

    def test_strict_exits_1_when_any_item_fails(self):
        items = [{"page": E1["page"], "text": E1["text"]},
                 {"page": E1["page"], "text": "this sentence is not on the page at all"}]
        code, _ = self.verify(items)
        self.assertEqual(code, 0)
        code, _ = self.verify(items, "--strict")
        self.assertEqual(code, 1)

    def test_broken_json_is_an_error_not_a_crash(self):
        self.work.write("evidence/raw-1.jsonl", "{not json}\n")
        code, out = run_script("verify_evidence.py", self.work.path)
        self.assertEqual(code, 1)
        self.assertIn("not valid JSON", out)

    def test_no_page_text_in_the_output(self):
        _, out = self.verify([{"page": E1["page"], "text": E1["text"]}])
        self.assertNotIn("Hauptstadt", out)


class CheckDraft(unittest.TestCase):
    def setUp(self):
        self.work = Work()
        self.addCleanup(self.work.cleanup)
        self.work.verified([E1, E2])

    def draft(self, text):
        path = self.work.write("draft/draft.md", text)
        return run_script("verify_evidence.py", self.work.path, "--check-draft", path)

    def test_good_fragments_pass(self):
        comment = '<!-- compose {"ids": ["E1"], "frags": [["E1", "Wien ist die Hauptstadt von Österreich"]]} -->'
        code, out = self.draft(f"Wien ist die Hauptstadt von Österreich, so steht es dort. [[E1]]\n{comment}\n")
        self.assertEqual(code, 0, out)

    def test_comment_separated_by_a_blank_line_belongs_to_its_paragraph(self):
        # the writer keeps separating the system comment; the comment still counts
        # for the paragraph above it, whatever the number of blank lines
        comment = '<!-- compose {"ids": ["E1"], "frags": [["E1", "Wien ist die Hauptstadt von Österreich"]]} -->'
        code, out = self.draft(f"Wien ist die Hauptstadt von Österreich, so steht es dort. [[E1]]\n\n{comment}\n")
        self.assertEqual(code, 0, out)
        code, out = self.draft(f"Wien ist die Hauptstadt von Österreich, so steht es dort. [[E1]]\n\n\n  \n{comment}\n")
        self.assertEqual(code, 0, out)

    def test_comment_with_a_list_glued_to_it_belongs_to_the_paragraph_above(self):
        # the first r3 draft: the separated comment is glued to the list that follows;
        # it still belongs to the paragraph above it, the list becomes its own block
        comment = '<!-- compose {"ids": ["E1"], "frags": [["E1", "Wien ist die Hauptstadt von Österreich"]]} -->'
        text = (f"Wien ist die Hauptstadt von Österreich, so steht es dort. [[E1]]\n\n"
                f"{comment}\n- Ein Listenpunkt dazu. [[E1]]\n")
        code, out = self.draft(text)
        self.assertEqual(code, 0, out)

    def test_fragment_not_in_evidence_fails(self):
        comment = '<!-- compose {"ids": ["E1"], "frags": [["E1", "Wien ist die schönste Stadt"]]} -->'
        code, out = self.draft(f"Wien ist die schönste Stadt. [[E1]]\n{comment}\n")
        self.assertEqual(code, 1)
        self.assertIn("not a word sequence of evidence E1", out)

    def test_fragment_not_in_paragraph_fails(self):
        comment = '<!-- compose {"ids": ["E1"], "frags": [["E1", "hat rund 2 Millionen Einwohner"]]} -->'
        code, out = self.draft(f"Ein ganz anderer Satz steht hier. [[E1]]\n{comment}\n")
        self.assertEqual(code, 1)
        self.assertIn("is not in the paragraph", out)

    def test_adapted_word_form_needs_the_original_marked(self):
        comment = ('<!-- compose {"ids": ["E2"], "frags": [["E2", "Die Stadt gründete sich auf eine römische Siedlung"]],'
                   ' "forms": [["E2", "gründete", "gründet"]]} -->')
        code, out = self.draft(f"Die Stadt gründete sich auf eine römische Siedlung. [[E2]]\n{comment}\n")
        self.assertEqual(code, 0, out)
        unmarked = comment.replace(', "forms": [["E2", "gründete", "gründet"]]', "")
        code, out = self.draft(f"Die Stadt gründete sich auf eine römische Siedlung. [[E2]]\n{unmarked}\n")
        self.assertEqual(code, 1)

    def test_different_word_is_not_a_form(self):
        comment = ('<!-- compose {"ids": ["E2"], "frags": [["E2", "Die Stadt baut auf eine römische Siedlung"]],'
                   ' "forms": [["E2", "baut", "gründet"]]} -->')
        code, out = self.draft(f"Die Stadt baut auf eine römische Siedlung. [[E2]]\n{comment}\n")
        self.assertEqual(code, 1)
        self.assertIn("is not a form of", out)

    def test_unknown_evidence_id_fails(self):
        comment = '<!-- compose {"ids": ["E9"], "frags": []} -->'
        code, out = self.draft(f"Irgendein Satz. [[E9]]\n{comment}\n")
        self.assertEqual(code, 1)
        self.assertIn("E9", out)

    def test_bad_comment_json_is_reported(self):
        code, out = self.draft('Ein Satz.\n<!-- compose {"ids": [ -->\n')
        self.assertEqual(code, 1)
        self.assertIn("ERROR", out)
        code, out = self.draft('Ein Satz.\n<!-- compose {"ids": "E1"} -->\n')
        self.assertEqual(code, 1)
        self.assertIn("needs an", out)


if __name__ == "__main__":
    unittest.main()
