"""End to end: every statement, one deletion, one number replacement, formatting kept."""

import json
import subprocess
import sys

from testlib import PAGE, SCRIPTS, page, write_jsonl


def run(*args):
    return subprocess.run(
        [sys.executable, "-I", "-X", "utf8", str(SCRIPTS / "correct_sources.py"),
         *map(str, args)], capture_output=True, text=True, encoding="utf-8")


def test_uncited_sentence_is_deleted_and_number_replaced(tmp_path):
    p = page(tmp_path)
    work = tmp_path / "work"
    work.mkdir()
    answer = tmp_path / "answer.md"
    answer.write_text(
        "# Test\n\n"
        "Blender ist kostenlos[[1](https://example.org/blender)].\n"
        "Maya erfindet Videos.\n"
        "Blender 4.1 ist die aktuelle Version[[1](https://example.org/blender)].\n",
        encoding="utf-8", newline="")
    (work / "sources.json").write_text(json.dumps({"sources": [
        {"number": 1, "url": "https://example.org/blender", "page": str(p)}]}),
        encoding="utf-8")
    (work / "pages.json").write_text(json.dumps({"sources": [
        {"number": 1, "url": "https://example.org/blender", "page": str(p),
         "status": "ok"}]}), encoding="utf-8")

    proc = run("statements", answer, "--workdir", work)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    statements = [json.loads(l) for l in
                  (work / "statements.jsonl").read_text(encoding="utf-8").splitlines()]
    invented = next(s for s in statements if s["text"].startswith("Maya"))
    wrong = next(s for s in statements if "4.1" in s["text"])
    assert invented["kind"] == "fact"

    decisions = [
        {"sid": invented["sid"], "action": "delete", "start": invented["start"],
         "end": invented["end"]},
        {"sid": wrong["sid"], "action": "replace",
         "start": wrong["start"] + wrong["text"].index("4.1"),
         "end": wrong["start"] + wrong["text"].index("4.1") + 3, "new": "4.2",
         "number": 1,
         "quote": "Die aktuelle Version ist Blender 4.2 vom 16. Juli 2024."},
    ]
    (work / "fix").mkdir(exist_ok=True)
    write_jsonl(work / "fix" / "decisions.jsonl", decisions)

    for command in ("edit-check", "edit-apply"):
        args = [command, answer, "--workdir", work]
        if command == "edit-check":
            args += ["--decisions", work / "fix" / "decisions.jsonl"]
        proc = run(*args)
        assert proc.returncode == 0, proc.stdout + proc.stderr

    edited = (tmp_path / "answer - bearbeitet.md").read_text(encoding="utf-8")
    assert "Maya" not in edited
    assert "Blender 4.2 ist die aktuelle Version" in edited
    assert "Blender ist kostenlos" in edited
    assert edited.endswith("\n")
    report = json.loads((work / "fix" / "edit-report.json").read_text(encoding="utf-8"))
    assert report["format_ok"] is True, report
    assert report["preservation"] > 0.8
    assert len(report["changed"]) == 2
    assert any(c["before"] == "4.1" and c["after"] == "4.2" and c["quote"]
               for c in report["changed"])
    prose = (work / "fix" / "edit-report.md").read_text(encoding="utf-8")
    assert "4.1" in prose and "4.2" in prose and "Beleg" in prose
