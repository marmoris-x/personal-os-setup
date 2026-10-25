"""Tests for project_sync.py: hubs of finished projects whose repo path does not exist.

Run from this folder:
    python -I -X utf8 -m unittest test_project_sync -v
"""

import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import project_sync  # noqa: E402


def write_hub(vault, folder, name, status, repo):
    path = vault / folder / f"{name}.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    repo_line = f"repo: {repo}\n" if repo is not None else ""
    path.write_text(f"---\ntype: project\nstatus: {status}\ndate: 2026-09-01\n{repo_line}---\n# {name}\n",
                    encoding="utf-8")
    return path


def run_main(vault, projects):
    out = StringIO()
    argv = ["project_sync.py", "--vault", str(vault), "--projects", str(projects)]
    with mock.patch.object(sys, "argv", argv), redirect_stdout(out):
        code = project_sync.main()
    return code, out.getvalue()


class DoneHubWithMissingRepo(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.vault = self.root / "vault"
        self.projects = self.root / "Projects"
        self.projects.mkdir()
        (self.vault / "200-projects").mkdir(parents=True)
        (self.vault / "900-inactive").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_done_hub_with_nonexistent_repo_path_is_a_finding(self):
        write_hub(self.vault, "200-projects", "gone", "done", str(self.projects / "gone"))
        code, out = run_main(self.vault, self.projects)
        self.assertEqual(code, 1)
        self.assertIn("FINDING gone: hub is done but its repo path does not exist", out)

    def test_done_hub_in_900_inactive_with_nonexistent_repo_path_is_a_finding(self):
        write_hub(self.vault, "900-inactive", "old", "done", str(self.projects / "old"))
        code, out = run_main(self.vault, self.projects)
        self.assertEqual(code, 1)
        self.assertIn("FINDING old: hub is done but its repo path does not exist", out)

    def test_done_hub_with_null_repo_is_fine(self):
        write_hub(self.vault, "900-inactive", "old", "done", "null")
        code, out = run_main(self.vault, self.projects)
        self.assertEqual(code, 0, out)

    def test_done_hub_with_existing_repo_path_is_fine(self):
        repo = self.projects / "alive"
        repo.mkdir()
        subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
        write_hub(self.vault, "900-inactive", "alive", "done", str(repo))
        code, out = run_main(self.vault, self.projects)
        self.assertNotIn("repo path does not exist", out)

    def test_active_hub_with_nonexistent_repo_path_is_not_this_finding(self):
        write_hub(self.vault, "200-projects", "plan", "active", str(self.projects / "plan"))
        code, out = run_main(self.vault, self.projects)
        self.assertNotIn("repo path does not exist", out)


if __name__ == "__main__":
    unittest.main()
