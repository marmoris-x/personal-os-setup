"""Tests for the German folder-name check in graph_health.py.

Run from this folder:
    python -I -X utf8 test_names.py -v
"""

import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import graph_health  # noqa: E402


def make_folder(vault, relpath):
    path = vault / relpath
    path.mkdir(parents=True, exist_ok=True)
    return path


class GermanFolderNames(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vault = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_auftraege_is_reported(self):
        make_folder(self.vault, "000-meta/auftraege")
        findings = graph_health.find_german_folder_names(self.vault)
        self.assertEqual([f["path"] for f in findings], ["000-meta/auftraege"])
        self.assertIn("auftraege", findings[0]["reason"])

    def test_orders_is_not_reported(self):
        make_folder(self.vault, "000-meta/orders")
        self.assertEqual(graph_health.find_german_folder_names(self.vault), [])

    def test_umlaut_folder_is_reported(self):
        make_folder(self.vault, "000-meta/Übergabe")
        findings = graph_health.find_german_folder_names(self.vault)
        self.assertEqual(len(findings), 1)
        self.assertIn("German character", findings[0]["reason"])

    def test_decomposed_umlaut_is_reported(self):
        name = unicodedata.normalize("NFD", "Übergabe")
        make_folder(self.vault, "000-meta/" + name)
        findings = graph_health.find_german_folder_names(self.vault)
        self.assertEqual(len(findings), 1)
        self.assertIn("German character", findings[0]["reason"])

    def test_content_folders_are_exempt(self):
        make_folder(self.vault, "300-areas/gesundheit")
        make_folder(self.vault, "500-sources/lernmaterial")
        make_folder(self.vault, "600-archive/unterlagen")
        make_folder(self.vault, "900-inactive/alt")
        make_folder(self.vault, "inbox/eingang")
        make_folder(self.vault, "outbox/ausgang")
        make_folder(self.vault, "trash/papierkorb")
        self.assertEqual(graph_health.find_german_folder_names(self.vault), [])

    def test_content_file_names_are_not_scanned(self):
        (self.vault / "200-projects").mkdir()
        (self.vault / "200-projects/auftraege.md").write_text(
            "# x\n", encoding="utf-8")
        self.assertEqual(graph_health.find_german_folder_names(self.vault), [])

    def test_pycache_is_skipped(self):
        make_folder(self.vault, "000-meta/scripts/__pycache__/auftraege")
        self.assertEqual(graph_health.find_german_folder_names(self.vault), [])

    def test_german_word_in_a_dated_slug_is_reported(self):
        make_folder(self.vault, "400-knowledge/research/2026-11-02-auftraege")
        findings = graph_health.find_german_folder_names(self.vault)
        self.assertEqual(
            [f["path"] for f in findings],
            ["400-knowledge/research/2026-11-02-auftraege"])

    def test_english_research_slug_is_not_reported(self):
        make_folder(self.vault, "400-knowledge/research/2026-11-02-motion-studio-notes")
        self.assertEqual(graph_health.find_german_folder_names(self.vault), [])

    def test_empty_vault_is_clean(self):
        self.assertEqual(graph_health.find_german_folder_names(self.vault), [])


if __name__ == "__main__":
    unittest.main()
