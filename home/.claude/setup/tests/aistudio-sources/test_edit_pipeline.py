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


def test_an_audit_rejected_edit_keeps_supported_text_and_deletes_unsupported_text(tmp_path):
    p = page(tmp_path)
    work = tmp_path / "work"
    work.mkdir()
    answer = tmp_path / "answer.md"
    answer.write_text(
        "# Test\n\n"
        "Blender ist kostenlos[[1](https://example.org/blender)].\n"
        "Maya erfindet Videos.\n",
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
    supported = next(s for s in statements if s["text"].startswith("Blender"))
    invented = next(s for s in statements if s["text"].startswith("Maya"))
    (work / "fix").mkdir(exist_ok=True)
    decisions = [
        {"sid": supported["sid"], "action": "replace",
         "start": supported["start"] + supported["text"].index("kostenlos"),
         "end": supported["start"] + supported["text"].index("kostenlos") + len("kostenlos"),
         "new": "gratis", "number": 1,
         "quote": "Blender ist kostenlos und laeuft auf Windows, macOS und Linux und die Lizenz ist die GNU GPL."},
        {"sid": invented["sid"], "action": "replace",
         "start": invented["start"] + invented["text"].index("Maya"),
         "end": invented["start"] + invented["text"].index("Maya") + 4,
         "new": "Blender", "number": 1,
         "quote": "Blender ist kostenlos und laeuft auf Windows, macOS und Linux und die Lizenz ist die GNU GPL."},
    ]
    write_jsonl(work / "fix" / "decisions.jsonl", decisions)
    assert run("edit-check", answer, "--workdir", work,
               "--decisions", work / "fix" / "decisions.jsonl").returncode == 0

    write_jsonl(work / "verdicts.jsonl", [
        {"id": "P001", "line": supported["line"], "number": 1,
         "claim": supported["text"], "verdict": "gestuetzt", "quote": "",
         "note": "", "evidence": "ok"}])
    # edit-filter removes an audited-out replacement from valid-edits.jsonl.
    write_jsonl(work / "fix" / "valid-edits.jsonl", [])
    write_jsonl(work / "fix" / "audit-rejected.jsonl", [
        {"sid": supported["sid"], "action": "replace",
         "start": supported["start"] + supported["text"].index("kostenlos"),
         "end": supported["start"] + supported["text"].index("kostenlos") + len("kostenlos"),
         "new": "gratis", "reason": "Der Beleg traegt die Aenderung nicht."},
        {"sid": invented["sid"], "action": "replace",
         "start": invented["start"] + invented["text"].index("Maya"),
         "end": invented["start"] + invented["text"].index("Maya") + 4,
         "new": "Blender", "reason": "Der Beleg nennt Maya nicht."}])

    proc = run("edit-apply", answer, "--workdir", work)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    edited = (tmp_path / "answer - bearbeitet.md").read_text(encoding="utf-8")
    assert "Blender ist kostenlos" in edited
    assert "Maya" not in edited
    report = json.loads((work / "fix" / "edit-report.json").read_text(encoding="utf-8"))
    assert report["rejected_audit"]
    assert report["fallback_deletes"][0]["sid"] == invented["sid"]
    prose = (work / "fix" / "edit-report.md").read_text(encoding="utf-8")
    assert "Vom Audit abgelehnte" in prose


def test_a_web_page_that_proves_an_uncited_statement_keeps_it(tmp_path):
    work = tmp_path / "work"
    (work / "fix").mkdir(parents=True)
    write_jsonl(work / "statements.jsonl", [
        {"sid": "S001", "line": 3, "start": 0, "end": 10, "text": "Unbelegt.",
         "numbers": []},
        {"sid": "S002", "line": 4, "start": 11, "end": 20, "text": "Zitiert.",
         "numbers": [1]}])
    write_jsonl(work / "fix" / "valid-edits.jsonl", [
        {"sid": "S001", "action": "delete", "start": 0, "end": 10},
        {"sid": "S002", "action": "delete", "start": 11, "end": 20}])
    (work / "fix" / "edit-web-pages.json").write_text(
        json.dumps({"S001": [{"url": "https://example.org/x", "page": "x.md"}]}),
        encoding="utf-8")
    write_jsonl(tmp_path / "audit.jsonl", [
        {"sid": "S001", "verdict": "gestuetzt", "note": "Die Seite nennt den Satz."}])

    proc = run("edit-web-filter", "--workdir", work,
               "--file", tmp_path / "audit.jsonl")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    rows = [json.loads(l) for l in
            (work / "fix" / "valid-edits.jsonl").read_text(encoding="utf-8").splitlines()]
    assert rows[0]["action"] == "none"
    assert rows[1]["action"] == "delete"
    report = json.loads((work / "fix" / "edit-web-report.json").read_text(encoding="utf-8"))
    assert report["checked"] == 1 and report["kept"][0]["sid"] == "S001"


def test_edit_plan_excludes_a_wertung(tmp_path):
    work = tmp_path / "work"
    work.mkdir()
    write_jsonl(work / "statements.jsonl", [
        {"sid": "S001", "line": 3, "start": 0, "end": 10, "text": "Ein Fakt.",
         "numbers": [1], "kind": "fact", "section": "", "self_contained": "Ein Fakt."},
        {"sid": "S002", "line": 4, "start": 11, "end": 20, "text": "Eine Meinung.",
         "numbers": [1], "kind": "wertung", "section": "", "self_contained": "Eine Meinung."}])
    (work / "sources.json").write_text(json.dumps({"sources": [
        {"number": 1, "url": "https://example.org/a", "page": "a.md"}]}), encoding="utf-8")

    proc = run("edit-plan", "--workdir", work, "--per-agent", 6)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    tasks = []
    for path in sorted((work / "fix" / "edit-tasks").glob("batch-*.json")):
        tasks += json.loads(path.read_text(encoding="utf-8"))["tasks"]
    assert [t["sid"] for t in tasks] == ["S001"]
