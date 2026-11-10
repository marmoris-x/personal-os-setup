"""A supported verdict is rechecked when the claim is a judgment or contains an absolute."""

import json
from types import SimpleNamespace

from testlib import write_jsonl

import check_sources as cs


def row(pid, claim, verdict="gestuetzt", evidence="ok"):
    return {"id": pid, "line": 1, "number": 1, "url": "https://example.org/a",
            "claim": claim, "verdict": verdict, "quote": "a quote long enough here",
            "note": "", "evidence": evidence}


def ids_in_recheck(work):
    ids = []
    for path in sorted((work / "recheck").glob("batch-*.json")):
        batch = json.loads(path.read_text(encoding="utf-8"))
        ids += [c["id"] for s in batch["sources"] for c in s["claims"]]
    return ids


def run(tmp_path, rows):
    write_jsonl(tmp_path / "verdicts.jsonl", rows)
    code = cs.cmd_recheck(SimpleNamespace(workdir=str(tmp_path), per_agent=6))
    assert code == 0
    return ids_in_recheck(tmp_path)


def test_absolute_word_sends_supported_verdict_to_recheck(tmp_path):
    assert run(tmp_path, [row("P1", "Blender ist immer kostenlos."),
                          row("P2", "Blender ist kostenlos.")]) == ["P1"]


def test_value_judgment_sends_supported_verdict_to_recheck(tmp_path):
    assert run(tmp_path, [row("P1", "Das ist die einzig realistische Beurteilung."),
                          row("P2", "Blender ist kostenlos.")]) == ["P1"]


def test_word_boundary_does_not_match_inside_another_word(tmp_path):
    assert run(tmp_path, [row("P2", "Die Nische ist klein.")]) == []


def test_absolute_list_matches_word_stems():
    assert cs.has_absolute_word("Das gilt ausschließlich für Windows.")
    assert cs.has_absolute_word("ausschließliche Nutzung")
    assert cs.has_absolute_word("vollständige Kontrolle")
    assert cs.has_absolute_word("fundamentale Barrieren")
    assert cs.has_absolute_word("die Gesetzen des Marktes")
    assert cs.has_absolute_word("ein Monopolist")
    assert cs.has_absolute_word("Die Analyse kollabiert nach drei Monaten.")
    assert not cs.has_absolute_word("Die Nische ist klein.")


def test_short_absolutes_match_only_as_whole_words():
    assert cs.has_absolute_word("je mehr, desto besser")
    assert cs.has_absolute_word("alle Nutzer")
    assert cs.has_absolute_word("keiner der Fälle")
    assert cs.has_absolute_word("jedes Mal")
    for lookalike in ("jedoch", "allerdings", "allein", "niedrig"):
        assert not cs.has_absolute_word(lookalike), lookalike


def test_four_lookalikes_do_not_send_supported_to_recheck(tmp_path):
    assert run(tmp_path, [
        row("P1", "Das Tool ist jedoch langsam."),
        row("P2", "Das Tool ist allerdings langsam."),
        row("P3", "Das Tool ist allein schon wegen der Lizenz gut."),
        row("P4", "Die Schwelle ist niedrig."),
    ]) == []


def test_colon_or_semicolon_sends_supported_to_recheck(tmp_path):
    assert sorted(run(tmp_path, [
        row("P1", "Das Tool ist schnell; es ist auch stabil."),
        row("P2", "Das Tool ist schnell: Es ist stabil."),
    ])) == ["P1", "P2"]


S002 = ("Die Annahme, dass der bloße Zugang zu modernen Basismodellen und generativen "
        "Programmierwerkzeugen finanzschwachen Solo-Entwicklern einen marktfähigen "
        "Wettbewerbsvorteil verschafft, widerspricht den ökonomischen Gesetzen des "
        "Softwaremarktes.")
S020 = ("Venture-Capital-Analysen von Firmen wie Andreessen Horowitz und Defiant VC betonen "
        "einhellig: Der Wert eines Software-Unternehmens liegt nicht im generierten Code, "
        "sondern ausschließlich in proprietären Datenworkflows, Systemintegrationen und "
        "bestehenden Distributionskanälen.")
S021 = ("Etablierte Großkonzerne besitzen die bestehenden Kundenkanäle; wenn ein Feature "
        "trivial mittels LLM reproduzierbar ist, integriert ein etablierter Monopolist dieses "
        "Feature in seine bestehende Suite und schließt Startups vom Markt ab.")
S026 = ("KI-Werkzeuge erzeugen sogenannten „Vibe Code“, der isoliert syntaktisch valide "
        "wirkt und lokale Tests besteht, jedoch nach 3 bis 9 Monaten an fehlender Architektur, "
        "duplizierter Geschäftslogik und Abhängigkeitskonflikten kollabiert.")
S040 = ("Die optimistische Haltung ignoriert fundamentale ökonomische Barrieren, operative "
        "Fehlerquoten und die mathematischen Realitäten von Software-Wartung und Systembetrieb.")


def test_five_comparison_sentences_all_go_to_recheck(tmp_path):
    ids = run(tmp_path, [row("P002", S002), row("P020", S020), row("P021", S021),
                         row("P026", S026), row("P040", S040)])
    assert sorted(ids) == ["P002", "P020", "P021", "P026", "P040"]


def test_three_simple_sentences_stay_out(tmp_path):
    assert run(tmp_path, [
        row("P1", "Blender ist kostenlos und läuft auf Windows, macOS und Linux."),
        row("P2", "Die aktuelle Version ist Blender 4.2 vom 16. Juli 2024."),
        row("P3", "Der Quellcode steht unter der Apache License 2.0."),
    ]) == []
