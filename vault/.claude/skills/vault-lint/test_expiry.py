"""Tests for expiry.py: fixture notes with past, soon, far, missing and malformed valid_until.

Run from this folder:
    python -I -X utf8 -m unittest test_expiry -v
"""

import datetime
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import expiry  # noqa: E402


def write_note(vault, relpath, frontmatter, body="# Note\n"):
    path = vault / relpath
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "---\n" + frontmatter + "---\n" + body
    path.write_text(text, encoding="utf-8")
    return path


def iso(days_from_today):
    return (datetime.date.today() + datetime.timedelta(days=days_from_today)).isoformat()


class ExpiryScan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vault = Path(self.tmp.name)
        for folder in ("200-projects", "300-areas", "400-knowledge"):
            (self.vault / folder).mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_past_date_is_expired(self):
        write_note(self.vault, "200-projects/past.md", "type: project\nstatus: active\ndate: 2026-01-01\nvalid_until: " + iso(-10) + "\n")
        findings = expiry.find_expiring(self.vault, 14)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["status"], "expired")
        self.assertEqual(findings[0]["file"], "200-projects/past.md")
        self.assertEqual(findings[0]["valid_until"], iso(-10))
        self.assertLess(findings[0]["days"], 0)

    def test_soon_date_is_reported_with_days(self):
        write_note(self.vault, "300-areas/soon.md", "type: person\nstatus: active\ndate: 2026-01-01\nvalid_until: " + iso(3) + "\n")
        findings = expiry.find_expiring(self.vault, 14)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["status"], "soon")
        self.assertEqual(findings[0]["days"], 3)

    def test_far_date_is_not_reported(self):
        write_note(self.vault, "400-knowledge/far.md", "type: note\nstatus: active\ndate: 2026-01-01\nvalid_until: " + iso(100) + "\n")
        self.assertEqual(expiry.find_expiring(self.vault, 14), [])

    def test_missing_field_is_not_reported(self):
        write_note(self.vault, "200-projects/none.md", "type: project\nstatus: active\ndate: 2026-01-01\n")
        self.assertEqual(expiry.find_expiring(self.vault, 14), [])

    def test_malformed_date_is_a_finding(self):
        write_note(self.vault, "200-projects/bad.md", "type: project\nstatus: active\ndate: 2026-01-01\nvalid_until: next spring\n")
        findings = expiry.find_expiring(self.vault, 14)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["status"], "malformed")
        self.assertEqual(findings[0]["value"], "next spring")
        self.assertIsNone(findings[0]["days"])

    def test_quoted_date_is_parsed(self):
        write_note(self.vault, "200-projects/quoted.md", "type: project\nstatus: active\ndate: 2026-01-01\nvalid_until: '" + iso(2) + "'\n")
        findings = expiry.find_expiring(self.vault, 14)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["valid_until"], iso(2))

    def test_folder_outside_the_scope_is_ignored(self):
        write_note(self.vault, "500-sources/past.md", "type: note\nstatus: active\ndate: 2026-01-01\nvalid_until: " + iso(-10) + "\n")
        self.assertEqual(expiry.find_expiring(self.vault, 14), [])

    def test_days_limit_is_respected(self):
        write_note(self.vault, "200-projects/soon3.md", "type: project\nstatus: active\ndate: 2026-01-01\nvalid_until: " + iso(3) + "\n")
        write_note(self.vault, "200-projects/soon10.md", "type: project\nstatus: active\ndate: 2026-01-01\nvalid_until: " + iso(10) + "\n")
        findings = expiry.find_expiring(self.vault, 7)
        self.assertEqual([f["file"] for f in findings], ["200-projects/soon3.md"])

    def test_frontmatter_must_start_on_line_one(self):
        path = self.vault / "200-projects/late.md"
        path.write_text("\n---\ntype: project\nvalid_until: " + iso(-1) + "\n---\n", encoding="utf-8")
        self.assertEqual(expiry.find_expiring(self.vault, 14), [])


class ExpiryCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vault = Path(self.tmp.name)
        (self.vault / "200-projects").mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, argv):
        out, err = StringIO(), StringIO()
        code = 0
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = expiry.main(argv)
            except SystemExit as exc:
                code = int(exc.code or 0)
        return code, out.getvalue(), err.getvalue()

    def test_exit_1_and_file_and_date_on_stdout(self):
        write_note(self.vault, "200-projects/past.md", "type: project\nvalid_until: " + iso(-2) + "\n")
        code, out, err = self.run_cli(["--vault", str(self.vault)])
        self.assertEqual(code, 1)
        self.assertIn("200-projects/past.md", out)
        self.assertIn(iso(-2), out)

    def test_exit_0_when_nothing_expires(self):
        write_note(self.vault, "200-projects/far.md", "type: project\nvalid_until: " + iso(100) + "\n")
        code, out, err = self.run_cli(["--vault", str(self.vault)])
        self.assertEqual(code, 0)
        self.assertIn("expiry: 0", out)

    def test_json_output_matches_the_lines(self):
        write_note(self.vault, "200-projects/soon.md", "type: project\nvalid_until: " + iso(2) + "\n")
        out_json = self.vault / "expiry.json"
        code, out, err = self.run_cli(["--vault", str(self.vault), "--json", str(out_json)])
        self.assertEqual(code, 1)
        data = json.loads(out_json.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["file"], "200-projects/soon.md")
        self.assertEqual(data[0]["days"], 2)

    def test_malformed_date_still_exits_1(self):
        write_note(self.vault, "200-projects/bad.md", "type: project\nvalid_until: someday\n")
        code, out, err = self.run_cli(["--vault", str(self.vault)])
        self.assertEqual(code, 1)
        self.assertIn("malformed", out.lower())


if __name__ == "__main__":
    unittest.main()
