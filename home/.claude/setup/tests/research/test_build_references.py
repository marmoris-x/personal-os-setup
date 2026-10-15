"""Tests for build_references.py: numbering, links with text fragments, the list, failures."""

import json
import re
import sys
import unittest
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import E1, E2, E3, E4, Work, run_script  # noqa: E402

DRAFT = """# Wien

Wien ist die Hauptstadt von Österreich. [[E1]] Der Anfang war römisch. [[E2]]

Ein arabisches Wort. [[E4]] Wieder zu Wien. [[E1]]

Zwei Belege derselben Seite. [[E1]][[E2]]
"""


class BuildReferences(unittest.TestCase):
    def setUp(self):
        self.work = Work()
        self.addCleanup(self.work.cleanup)
        self.work.verified([E1, E2, E3, E4])

    def build(self, draft=DRAFT, lang="de", *extra):
        self.work.write("draft/draft.md", draft)
        code, out = run_script("build_references.py", self.work.path, "--draft", "draft/draft.md",
                               "--out", "draft/article.md", "--lang", lang, "--accessed", "2026-10-06", *extra)
        article = (self.work.path / "draft" / "article.md")
        return code, out, article.read_text(encoding="utf-8") if article.exists() else ""

    def test_numbers_follow_first_appearance_and_same_source_keeps_its_number(self):
        code, out, article = self.build()
        self.assertEqual(code, 0, out)
        numbers = re.findall(r"\[(\d+)\]\(https", article)
        self.assertEqual(numbers[:4], ["1", "1", "2", "1"])
        self.assertIn("2 sources", out)

    def test_adjacent_markers_of_one_source_collapse_to_one_number(self):
        _, _, article = self.build()
        last = article.split("Zwei Belege derselben Seite.")[1].split("\n")[0]
        self.assertEqual(len(re.findall(r"\[\d+\]\(", last)), 1, last)

    def test_link_has_a_text_fragment_taken_from_the_page(self):
        _, _, article = self.build()
        link = re.search(r"\[1\]\((https://example\.org/wien#:~:text=[^)]*)\)", article).group(1)
        self.assertTrue(unquote(link.split("text=")[1]).startswith("Wien ist die Hauptstadt"))
        self.assertIn(",", link.split("text=")[1])  # start,end because the text is long

    def test_fragment_encodes_hyphen_comma_and_ampersand(self):
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text(page.read_text(encoding="utf-8") + "\nSüd-Ost, Rock & Pop sind hier zu Hause.\n",
                        encoding="utf-8")
        item = {**E1, "text": "Süd-Ost, Rock & Pop sind hier zu Hause."}
        self.work.verified([item])
        _, _, article = self.build("Satz. [[E1]]\n")
        link = re.search(r"\[1\]\(([^)]*)\)", article).group(1)
        fragment = link.split("text=")[1]
        for raw in ("-", ",", "&", " "):
            self.assertNotIn(raw, fragment)
        self.assertIn("%2D", fragment)
        self.assertIn("%26", fragment)

    def test_text_not_in_the_page_gives_a_link_without_fragment_and_a_warning(self):
        bad = {**E1, "text": "Dieser Satz steht nirgends auf der gespeicherten Seite, sicher nicht."}
        self.work.verified([bad])
        code, out, article = self.build("Satz. [[E1]]\n")
        self.assertEqual(code, 0, out)
        self.assertIn("WARNING [[E1]]: start words not found", out)
        self.assertIn("[1](https://example.org/wien)", article)
        self.assertNotIn("#:~:", article)

    def test_marker_without_evidence_is_removed_with_a_warning(self):
        code, out, article = self.build("Satz. [[E1]] Noch ein Satz. [[E77]]\n")
        self.assertEqual(code, 0)
        self.assertIn("[[E77]] has no verified evidence", out)
        self.assertNotIn("[[E77]]", article)

    def test_parentheses_in_the_url_are_encoded_in_the_link_only(self):
        _, _, article = self.build("Wort. [[E4]]\n")
        self.assertRegex(article, r"\[1\]\(https://arabic\.example\.net/lisan%281%29#:~:text=")
        self.assertIn("https://arabic.example.net/lisan(1)", article.split("references:start")[1])

    def test_german_list_has_labels_date_archive_and_local_copy(self):
        _, _, article = self.build()
        block = article.split("<!-- references:start -->")[1]
        self.assertIn("## Quellen", block)
        self.assertIn("[1] Stadt Wien. Wien: Fakten. example.org. 2025-03-01.", block)
        self.assertIn("Quellenart: Primärquelle.", block)
        self.assertIn("Abgerufen 2026-10-06.", block)
        self.assertIn("Archiv: https://web.archive.org/web/20251001000000/https://example.org/wien", block)
        self.assertIn("Lokale Kopie: [001-example.org.md](pages/001-example.org.md)", block)
        # source 2 is Arabic, answer language German: the language is named; no author and no date
        self.assertIn("Sprache: العربية.", block)
        self.assertIn("Lisan. arabic.example.net. ohne Datum.", block)

    def test_english_labels_and_marker_position(self):
        _, _, article = self.build("Satz. [[E1]]\n\n<!-- references -->\n\nSchluss.\n", "en")
        self.assertIn("## References", article)
        self.assertLess(article.index("references:start"), article.index("Schluss."))
        self.assertIn("Accessed 2026-10-06.", article)
        self.assertIn("Language: Deutsch.", article)  # the page is German, the answer English

    def test_source_count_placeholder_is_filled(self):
        _, _, article = self.build(DRAFT + "\nZusammen {{N_SOURCES}} Quellen.\n")
        self.assertIn("Zusammen 2 Quellen.", article)
        self.assertNotIn("{{", article)

    def test_pages_prefix_is_used_for_the_local_copy(self):
        _, _, article = self.build(DRAFT, "de", "--pages-prefix", "../../500-sources/research/x/pages/")
        self.assertIn("(../../500-sources/research/x/pages/001-example.org.md)", article)

    def test_missing_verified_file_is_an_error(self):
        (self.work.path / "evidence" / "verified.jsonl").unlink()
        code, out, _ = self.build()
        self.assertEqual(code, 1)
        self.assertIn("ERROR", out)

    def test_writer_numbers_are_removed_from_the_draft(self):
        code, out, article = self.build("Ein Satz. [[E1]] [1] Noch einer. [[E1]] [1]\n")
        self.assertEqual(code, 0, out)
        self.assertIn("2 numbers the writer wrote removed", out)
        self.assertIsNone(re.search(r"\[\d+\](?!\()", article.split("<!-- references:start -->")[0]))

    def test_group_of_numbers_is_sorted_ascending(self):
        code, out, article = self.build("# T\n\nStart. [[E1]]\n\nDann [[E4]] [[E1]] hier.\n")
        self.assertEqual(code, 0, out)
        self.assertIn("1 reference groups put into ascending order", out)
        group = article.split("Dann")[1].split("\n")[0]
        self.assertLess(group.index("[1]("), group.index("[2]("))
        self.assertRegex(group, r"\[1\]\([^)]*\)\[2\]\(")

    def test_iso_timestamp_date_and_domain_author_are_normalized(self):
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text(page.read_text(encoding="utf-8")
                        .replace('published: "2025-03-01"', 'published: "2025-03-01T12:00:00.000Z"')
                        .replace('author: "Stadt Wien"', 'author: "example.org"'), encoding="utf-8")
        _, _, article = self.build()
        block = article.split("<!-- references:start -->")[1]
        self.assertIn("[1] Wien: Fakten. example.org. 2025-03-01.", block)
        self.assertNotIn("T12:00:00", block)
        self.assertNotIn("example.org. Wien: Fakten. example.org.", block)

    def test_source_type_falls_back_to_the_evidence(self):
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text("\n".join(line for line in page.read_text(encoding="utf-8").split("\n")
                                  if not line.startswith("type:")), encoding="utf-8")
        _, _, article = self.build()
        self.assertIn("Quellenart: Primärquelle.", article.split("<!-- references:start -->")[1])

    def test_source_type_falls_back_to_index_and_candidates(self):
        # header type removed, evidence types emptied: only index.json and the candidates carry it
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text("\n".join(line for line in page.read_text(encoding="utf-8").split("\n")
                                  if not line.startswith("type:")), encoding="utf-8")
        self.work.verified([{**E1, "type": ""}, {**E2, "type": ""}, {**E4, "type": ""}])
        (self.work.path / "candidates").mkdir()
        # the candidate URL keeps the tracking parameter and the trailing slash the header lost
        self.work.write("candidates/p1.jsonl", json.dumps(
            {"url": "https://example.org/wien/?utm_source=x", "title": "Wien: Fakten", "lang": "de",
             "source_type": "primary", "pass": "P1"}, ensure_ascii=False) + "\n")
        code, out, article = self.build()
        self.assertEqual(code, 0, out)
        self.assertIn("Quellenart: Primärquelle.", article.split("<!-- references:start -->")[1])
        self.assertNotIn("no source type", out)
        # from index.json alone
        (self.work.path / "candidates" / "p1.jsonl").unlink()
        self.work.write("pages/index.json", json.dumps(
            [{"url": "https://example.org/wien", "file": "001-example.org.md", "type": "primary"}],
            ensure_ascii=False) + "\n")
        code, out, article = self.build()
        self.assertEqual(code, 0, out)
        self.assertIn("Quellenart: Primärquelle.", article.split("<!-- references:start -->")[1])
        self.assertNotIn("no source type", out)

    def test_no_source_type_anywhere_warns_and_leaves_the_label_out(self):
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text("\n".join(line for line in page.read_text(encoding="utf-8").split("\n")
                                  if not line.startswith("type:")), encoding="utf-8")
        self.work.verified([{**E1, "type": ""}, {**E2, "type": ""}, {**E4, "type": ""}])
        code, out, article = self.build()
        self.assertEqual(code, 0, out)
        self.assertIn("page 001-example.org.md: no source type in the page header, its evidence "
                      "or the candidates", out)
        entry = next(line for line in article.split("<!-- references:start -->")[1].split("\n")
                     if line.startswith("[1] "))
        self.assertNotIn("Quellenart", entry)

    def test_site_slogan_and_domain_segments_leave_the_title(self):
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text(page.read_text(encoding="utf-8").replace(
            'title: "Wien: Fakten"', 'title: "Wien: Fakten | example.org - The heart of the internet"'),
            encoding="utf-8")
        _, _, article = self.build()
        self.assertIn("Wien: Fakten. example.org.", article.split("<!-- references:start -->")[1])

    def test_tracking_parameters_never_reach_the_article(self):
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text(page.read_text(encoding="utf-8")
                        .replace('url: "https://example.org/wien"',
                                 'url: "https://example.org/wien?utm_source=a&solution=b"')
                        .replace('final_url: "https://example.org/wien"',
                                 'final_url: "https://example.org/wien?utm_source=a&solution=b"'),
                        encoding="utf-8")
        _, _, article = self.build()
        self.assertNotIn("utm_source", article)
        self.assertNotIn("solution=", article)


if __name__ == "__main__":
    unittest.main()
