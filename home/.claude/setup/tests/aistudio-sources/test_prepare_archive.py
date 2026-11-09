"""A second prepare does not inherit the previous run's positional verdicts (review finding 1)."""

from types import SimpleNamespace

import check_sources as cs


SOURCE = "https://example.org/a"


def document():
    return ("# Titel\n\n"
            "Eine Aussage[[1](%s)].\n\n"
            "## Sources\n\n"
            "1. [example.org](%s)\n" % (SOURCE, SOURCE))


def test_old_pass_results_are_moved_aside(tmp_path):
    input_file = tmp_path / "answer.md"
    input_file.write_text(document(), encoding="utf-8")
    work = tmp_path / "work"
    results = work / "results"
    results.mkdir(parents=True)
    (results / "pass1-batch-01.jsonl").write_text('{"id":"P001"}\n', encoding="utf-8")
    (results / "pass2-batch-01.jsonl").write_text('{"id":"P001"}\n', encoding="utf-8")

    code = cs.cmd_prepare(SimpleNamespace(file=str(input_file), workdir=str(work), per_agent=8))
    assert code == 0
    assert not (results / "pass1-batch-01.jsonl").exists()
    assert not (results / "pass2-batch-01.jsonl").exists()
    archived = list(results.glob("previous-*/pass2-batch-01.jsonl"))
    assert len(archived) == 1
    assert (work / "claims.jsonl").is_file()
