"""The input stays the working file, with one silent backup (Part 1 step 1)."""

import subprocess
import sys

from testlib import SCRIPTS


def run(*args):
    return subprocess.run(
        [sys.executable, "-I", "-X", "utf8", str(SCRIPTS / "resolve_sources.py"), *map(str, args)],
        capture_output=True, text=True, encoding="utf-8")


def test_original_is_written_before_the_input_changes(tmp_path):
    src = tmp_path / "answer.md"
    before = "Blender ist kostenlos.[[1](https://example.org/blender)]\n"
    src.write_text(before, encoding="utf-8", newline="")
    work = tmp_path / "work"

    proc = run(src, "--workdir", work)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert (work / "original.md").read_text(encoding="utf-8") == before
    assert "## Sources" in src.read_text(encoding="utf-8")

    proc = run(src, "--workdir", work)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert (work / "original.md").read_text(encoding="utf-8") == before
