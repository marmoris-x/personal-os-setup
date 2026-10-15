"""Tests for store_results.py: what goes where in the vault, and what is refused."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import E1, E2, E3, E4, Work, run_script  # noqa: E402

DRAFT = """# Wien kurz erklärt

Wien ist die Hauptstadt von Österreich. [[E1]]
<!-- compose {"ids": ["E1"], "frags": [["E1", "Wien ist die Hauptstadt von Österreich"]]} -->

<!-- references -->
"""
SLUG = "wien-kurz-erklaert"
DAY = "2026-10-06"


class StoreResults(unittest.TestCase):
    def setUp(self):
        self.work = Work()
        self.addCleanup(self.work.cleanup)
        self.vault = tempfile.TemporaryDirectory(prefix="research-vault-")
        self.addCleanup(self.vault.cleanup)
        self.work.verified([E1, E2, E3, E4])
        self.work.write("question.md", "# Was ist Wien?\n")
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text(page.read_text(encoding="utf-8") + "\n![tracker](https://evil.example/pixel.png)\n",
                        encoding="utf-8")
        self.prefix = f"../../500-sources/research/{DAY}-{SLUG}/pages/"

    def article(self, prefix=None):
        self.work.write("draft/draft.md", DRAFT)
        code, out = run_script("build_references.py", self.work.path, "--draft", "draft/draft.md", "--out",
                               "draft/article.md", "--lang", "de", "--pages-prefix", prefix or self.prefix)
        self.assertEqual(code, 0, out)

    def store(self, *extra, slug=SLUG):
        return run_script("store_results.py", self.work.path, "--article", "draft/article.md", "--slug", slug,
                          "--date", DAY, "--answer-lang", "de", "--source-langs", "de,ar",
                          "--vault", self.vault.name, *extra)

    def test_files_land_in_the_right_places(self):
        self.article()
        code, out = self.store()
        self.assertEqual(code, 0, out)
        v = Path(self.vault.name)
        note = (v / "400-knowledge" / "research" / f"{DAY}-{SLUG}.md").read_text(encoding="utf-8")
        self.assertTrue(note.startswith("---\ntype: note\n"))
        for line in ("answer_language: de", "source_languages: [de, ar]", "sources_count: 1",
                     "review_by: '2027-01-04'"):
            self.assertIn(line, note)
        self.assertNotIn("<!-- compose", note)
        self.assertIn("# Wien kurz erklärt", note)
        evidence = (v / "500-sources" / "research" / f"{DAY}-{SLUG}" / "evidence.md").read_text(encoding="utf-8")
        self.assertIn("## E1", evidence)
        self.assertIn("> Wien ist die Hauptstadt von Österreich", evidence)
        self.assertIn("trust: untrusted", evidence)
        self.assertNotIn("## E3", evidence)  # not used by the text
        index = (v / "400-knowledge" / "research" / "_index.md").read_text(encoding="utf-8")
        self.assertIn(f"[[{DAY}-{SLUG}|Wien kurz erklärt]]", index)

    def test_only_cited_pages_are_copied_and_images_are_removed(self):
        self.article()
        code, out = self.store()
        self.assertIn("1 images removed", out)
        pages = list((Path(self.vault.name) / "500-sources" / "research" / f"{DAY}-{SLUG}" / "pages").glob("*.md"))
        self.assertEqual([p.name for p in pages], ["001-example.org.md"])
        self.assertNotIn("evil.example", pages[0].read_text(encoding="utf-8"))

    def test_article_with_bare_reference_numbers_is_refused(self):
        # the r1 defect: [1](url) [1] - the number stands again as plain text; the
        # last station before the vault refuses such a text instead of passing it on
        self.work.write("draft/manual.md",
                        "# Wien kurz erklärt\n\nWien ist die Hauptstadt. [1](https://example.org/wien) [1]\n")
        code, out = run_script("store_results.py", self.work.path, "--article", "draft/manual.md", "--slug",
                               SLUG, "--date", DAY, "--answer-lang", "de", "--source-langs", "de",
                               "--vault", self.vault.name)
        self.assertEqual(code, 1, out)
        self.assertIn("bare reference number", out)
        self.assertFalse((Path(self.vault.name) / "400-knowledge").exists())
        # a bare number inside a quote is source wording and no defect
        self.article()
        article_path = self.work.path / "draft" / "article.md"
        quoted = article_path.read_text(encoding="utf-8").replace(
            "Wien ist die Hauptstadt von Österreich.", 'Er sagte: "Kapitel [7] ist neu".')
        article_path.write_text(quoted, encoding="utf-8")
        code, out = self.store()
        self.assertEqual(code, 0, out)

    def test_nothing_is_overwritten(self):
        self.article()
        self.assertEqual(self.store()[0], 0)
        code, out = self.store()
        self.assertEqual(code, 1)
        self.assertIn("not overwritten", out)

    def test_bad_slug_and_bad_language_are_refused(self):
        self.article()
        for slug in ("Wien Kurz", "../x", "a-b-c-d-e-f-g", "wien_kurz"):
            with self.subTest(slug):
                code, out = self.store(slug=slug)
                self.assertEqual(code, 1, out)
                self.assertIn("slug must be", out)
        code, out = run_script("store_results.py", self.work.path, "--article", "draft/article.md", "--slug", SLUG,
                               "--date", DAY, "--answer-lang", "de;rm", "--source-langs", "de", "--vault", self.vault.name)
        self.assertEqual(code, 1)
        self.assertIn("not a language code", out)

    def test_a_link_to_a_page_that_is_not_in_the_work_folder_is_refused(self):
        self.article()
        (self.work.path / "pages" / "001-example.org.md").unlink()
        code, out = self.store()
        self.assertEqual(code, 1)
        self.assertIn("not in the work folder", out)
        self.assertFalse((Path(self.vault.name) / "400-knowledge").exists())

    def test_wrong_local_copy_prefix_is_refused(self):
        self.article(prefix="pages/")
        code, out = self.store()
        self.assertEqual(code, 1)
        self.assertIn("local copy links must point to", out)

    def test_second_note_goes_to_the_top_of_the_index(self):
        self.article()
        self.store()
        self.article(prefix=f"../../500-sources/research/{DAY}-zweite-frage/pages/")
        self.assertEqual(self.store(slug="zweite-frage")[0], 0)
        index = (Path(self.vault.name) / "400-knowledge" / "research" / "_index.md").read_text(encoding="utf-8")
        lines = [line for line in index.splitlines() if line.startswith("- [[")]
        self.assertEqual(len(lines), 2)
        self.assertIn("zweite-frage", lines[0])
        self.assertLess(index.index("# Research"), index.index("- [["))  # entries sit below the intro

    def test_long_note_warns(self):
        self.article()
        path = self.work.path / "draft" / "article.md"
        path.write_text(path.read_text(encoding="utf-8") + "\nZeile\n" * 400, encoding="utf-8")
        code, out = self.store()
        self.assertEqual(code, 0)
        self.assertIn("WARNING the note has", out)


if __name__ == "__main__":
    unittest.main()
