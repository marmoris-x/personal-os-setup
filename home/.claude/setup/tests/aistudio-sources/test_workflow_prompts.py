"""Part 1 of the cost task: the workflow and the fallback use the same cheap prompt rules."""

import os
from pathlib import Path

SKILL = Path(os.environ.get("AISTUDIO_SKILL")
             or Path.home() / ".claude" / "skills" / "aistudio-sources")
WORKFLOW = (SKILL / "aistudio-sources.workflow.js").read_text(encoding="utf-8")
SKILL_MD = (SKILL / "SKILL.md").read_text(encoding="utf-8")


def test_one_read_rule_guards_all_six_checking_roles():
    assert "Read every page once" in WORKFLOW
    # definition plus check (also used by recheck), existing, web-verify, audit, edit
    assert WORKFLOW.count("READ_RULE") >= 6
    assert "one-read rule applies unchanged" in SKILL_MD
    assert "Read every page once" in SKILL_MD


def test_mechanical_steps_are_merged_per_phase():
    assert "label: 'web-check-audit-plan'" in WORKFLOW
    assert "label: 'edit-web-filter-audit-plan'" in WORKFLOW
    assert "label: 'web-check'" not in WORKFLOW
    assert "label: 'audit-plan'" not in WORKFLOW
    assert "label: 'edit-web-filter'" not in WORKFLOW


def test_every_agent_wave_waits_for_the_first_agent():
    # check, recheck, existing, web, web-verify, audit, edit, edit-web, edit-web-check, edit-audit
    assert WORKFLOW.count("await wave(") >= 9
    assert "setTimeout(resolve, 10000)" in WORKFLOW
    assert "await parallel(" not in WORKFLOW


def test_long_output_stays_out_of_the_main_conversation():
    assert "never read back into the main conversation" in SKILL_MD
    assert "write the output file with one Write" in WORKFLOW


def test_supported_needs_every_element_and_the_judgment():
    assert "states every element of the statement" in WORKFLOW
    assert "states every element of the statement" in SKILL_MD
