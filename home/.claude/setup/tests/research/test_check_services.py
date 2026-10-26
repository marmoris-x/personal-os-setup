"""Tests for check_services.py: counts the calls in the transcripts, never a self-report."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import run_script  # noqa: E402

KEY_NAMES = ("EXA_API_KEY", "YDC_API_KEY", "TAVILY_API_KEY", "FIRECRAWL_API_KEY",
             "TINYFISH_API_KEY", "SERPER_API_KEY")
ALL_KEYS = {name: "placeholder" for name in KEY_NAMES}


def tool_line(name, command=None):
    part = {"type": "tool_use", "name": name}
    if command is not None:
        part["input"] = {"command": command}
    return json.dumps({"type": "assistant",
                       "message": {"role": "assistant", "content": [part]}})


def text_line(text):
    return json.dumps({"type": "assistant",
                       "message": {"role": "assistant",
                                   "content": [{"type": "text", "text": text}]}})


class CheckServices(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="research-svc-")
        self.addCleanup(self._tmp.cleanup)
        self.projects = Path(self._tmp.name) / "projects"
        self.session = "test-session-1"
        proj = self.projects / "proj"
        (proj / self.session / "subagents").mkdir(parents=True)
        self.main = proj / f"{self.session}.jsonl"
        self.sub = proj / self.session / "subagents" / "agent-a.jsonl"
        self.main.write_text("", encoding="utf-8")
        self.sub.write_text("", encoding="utf-8")
        self.env = {key: value for key, value in os.environ.items() if key not in KEY_NAMES}

    def run_check(self, keys=None):
        env = dict(self.env)
        env.update(ALL_KEYS if keys is None else keys)
        return run_script("check_services.py", "--session-id", self.session,
                          "--projects-dir", str(self.projects), env=env)

    def test_all_nine_from_calls_pass(self):
        first = [
            tool_line("mcp__exa__web_search_exa"),
            tool_line("mcp__parallel__web_search"),
            tool_line("mcp__exa-key__web_search_exa"),
            tool_line("mcp__tavily__tavily_search"),
            tool_line("mcp__you-free__you-search"),
        ]
        second = [
            tool_line("mcp__firecrawl__firecrawl_search"),
            tool_line("mcp__you__you-search"),
            tool_line("PowerShell", "Invoke-RestMethod \"https://api.search.tinyfish.ai?query=x\""),
            tool_line("Bash", "curl -X POST https://google.serper.dev/search"),
        ]
        self.main.write_text("\n".join(first) + "\n", encoding="utf-8")
        self.sub.write_text("\n".join(second) + "\n", encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("all nine services used", out)

    def test_missing_services_go_red(self):  # the check goes red on purpose
        self.main.write_text(tool_line("mcp__exa__web_search_exa") + "\n", encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("missing: parallel exa-key tavily you-free firecrawl tinyfish you", out)
        self.assertNotIn("serper", out.split("missing:", 1)[1])

    def test_a_service_without_a_key_is_skipped_not_missing(self):
        # No key means no call; that is a correct run, not a missing service.
        lines = [tool_line("mcp__exa__web_search_exa"), tool_line("mcp__parallel__web_search"),
                 tool_line("mcp__exa-key__web_search_exa"), tool_line("mcp__you-free__you-search"),
                 tool_line("mcp__firecrawl__firecrawl_search"), tool_line("mcp__you__you-search"),
                 tool_line("PowerShell", "https://api.search.tinyfish.ai?query=x"),
                 tool_line("Bash", "https://google.serper.dev/search")]
        self.main.write_text("\n".join(lines) + "\n", encoding="utf-8")
        code, out = self.run_check(keys={"TAVILY_API_KEY": ""})
        self.assertEqual(code, 0, out)
        self.assertIn("tavily 0 (skipped: no key)", out)
        self.assertNotIn("missing:", out)

    def test_serper_is_the_reserve_not_a_missing_service(self):
        lines = [tool_line("mcp__exa__web_search_exa"), tool_line("mcp__parallel__web_search"),
                 tool_line("mcp__exa-key__web_search_exa"), tool_line("mcp__tavily__tavily_search"),
                 tool_line("mcp__you-free__you-search"), tool_line("mcp__firecrawl__firecrawl_search"),
                 tool_line("mcp__you__you-search"),
                 tool_line("PowerShell", "https://api.search.tinyfish.ai?query=x")]
        self.main.write_text("\n".join(lines) + "\n", encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn("serper 0 (reserve)", out)
        self.assertNotIn("missing:", out)

    def test_self_report_is_not_a_call(self):
        # the agent result text names services; it must not count as use
        self.main.write_text(
            text_line('{"services_used": ["exa", "you"], "services_failed": []}') + "\n",
            encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("exa 0", out)
        self.assertIn("you 0", out)

    def test_you_free_does_not_count_as_you(self):
        self.main.write_text(tool_line("mcp__you-free__you-search") + "\n", encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("you-free 1", out)
        self.assertIn("you 0", out)

    def test_balance_call_is_no_use(self):
        self.main.write_text(tool_line("mcp__you__you-balance") + "\n", encoding="utf-8")
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn("you 0", out)

    # --- Crawl4AI is reported like a service, read from pages/index.json of the work folder

    def run_check_with_workdir(self, index_text):
        work = Path(self._tmp.name) / "work"
        (work / "pages").mkdir(parents=True, exist_ok=True)
        if index_text is not None:
            (work / "pages" / "index.json").write_text(index_text, encoding="utf-8")
        env = dict(self.env)
        env.update(ALL_KEYS)
        self.main.write_text(tool_line("mcp__exa__web_search_exa") + "\n", encoding="utf-8")
        return run_script("check_services.py", "--session-id", self.session,
                          "--projects-dir", str(self.projects), "--workdir", work, env=env)

    def test_crawl4ai_ok_is_reported_from_the_index(self):
        code, out = self.run_check_with_workdir(json.dumps({"crawl4ai_ok": True, "crawl4ai_reason": None, "pages": []}))
        self.assertIn("crawl4ai ok", out.splitlines())
        self.assertNotIn("UNAVAILABLE", out)

    def test_crawl4ai_unavailable_is_reported_with_its_reason_and_goes_red(self):
        index = json.dumps({"crawl4ai_ok": False, "crawl4ai_reason": "Executable doesn't exist", "pages": []})
        code, out = self.run_check_with_workdir(index)
        self.assertIn("crawl4ai UNAVAILABLE: Executable doesn't exist", out.splitlines())
        self.assertEqual(code, 1, out)  # the search services missing are also red here, so look at the line

    def test_crawl4ai_alone_is_red_exactly_when_unavailable(self):
        work = Path(self._tmp.name) / "only"
        (work / "pages").mkdir(parents=True)
        index = work / "pages" / "index.json"
        for payload, want_code, want_line in (
                ({"crawl4ai_ok": False, "crawl4ai_reason": "boom", "pages": []}, 1, "crawl4ai UNAVAILABLE: boom"),
                ({"crawl4ai_ok": True, "crawl4ai_reason": None, "pages": []}, 0, "crawl4ai ok"),
                ({"crawl4ai_ok": None, "crawl4ai_reason": None, "pages": []}, 0, "crawl4ai unknown"),
                ([], 0, "crawl4ai unknown")):  # an index of an older run has no flag
            index.write_text(json.dumps(payload), encoding="utf-8")
            env = {k: v for k, v in self.env.items() if k != "CLAUDE_CODE_SESSION_ID"}
            code, out = run_script("check_services.py", "--workdir", work, env=env)
            first = out.strip().splitlines()[0]
            self.assertEqual(code, want_code, out)
            self.assertTrue(first == want_line or first.startswith(want_line + " ("), out)

    def test_crawl4ai_without_an_index_is_unknown_not_ok(self):
        code, out = self.run_check_with_workdir(None)
        self.assertTrue(any(line.startswith("crawl4ai unknown") for line in out.splitlines()), out)

    def test_keys_mode_lists_each_key_as_set(self):
        # The research skill calls this at the start: a missing key must be visible there,
        # not only at the end when a pass silently skipped a service.
        env = dict(self.env)
        env.update(ALL_KEYS)
        code, out = run_script("check_services.py", "--keys", env=env)
        self.assertEqual(code, 0, out)
        for name in KEY_NAMES:
            self.assertIn(f"{name} set", out)

    def test_keys_mode_reports_a_missing_key(self):
        env = dict(self.env)
        env.update(ALL_KEYS)
        env.pop("TINYFISH_API_KEY", None)
        code, out = run_script("check_services.py", "--keys", env=env)
        self.assertEqual(code, 1, out)
        self.assertIn("TINYFISH_API_KEY MISSING", out)
        self.assertIn("EXA_API_KEY set", out)

    def test_unknown_session_is_an_error(self):
        code, out = run_script("check_services.py", "--session-id", "does-not-exist",
                               "--projects-dir", str(self.projects), env=self.env)
        self.assertEqual(code, 2, out)
        self.assertIn("ERROR no transcripts", out)

    def test_workflow_transcript_dir_is_counted(self):
        # The main session sees the Workflow tool call, not the agents' calls; the run's
        # transcriptDir holds those. Both must be counted or the caps read wrong.
        first = [
            tool_line("mcp__exa__web_search_exa"),
            tool_line("mcp__parallel__web_search"),
            tool_line("mcp__exa-key__web_search_exa"),
            tool_line("mcp__tavily__tavily_search"),
            tool_line("mcp__you-free__you-search"),
        ]
        second = [
            tool_line("mcp__firecrawl__firecrawl_search"),
            tool_line("mcp__you__you-search"),
            tool_line("PowerShell", "https://api.search.tinyfish.ai?query=x"),
            tool_line("Bash", "curl -X POST https://google.serper.dev/search"),
        ]
        self.main.write_text("\n".join(first) + "\n", encoding="utf-8")
        workflow = Path(self._tmp.name) / "workflow-run"
        workflow.mkdir()
        (workflow / "agent-1.jsonl").write_text("\n".join(second) + "\n", encoding="utf-8")
        env = dict(self.env)
        env.update(ALL_KEYS)
        code, out = run_script("check_services.py", "--session-id", self.session,
                               "--projects-dir", str(self.projects),
                               "--transcript-dir", str(workflow), env=env)
        self.assertEqual(code, 0, out)
        self.assertIn("all nine services used", out)

    def test_workflow_dir_alone_needs_no_session(self):
        workflow = Path(self._tmp.name) / "workflow-only"
        workflow.mkdir()
        lines = [
            tool_line("mcp__exa__web_search_exa"),
            tool_line("mcp__parallel__web_search"),
            tool_line("mcp__exa-key__web_search_exa"),
            tool_line("mcp__tavily__tavily_search"),
            tool_line("mcp__you-free__you-search"),
            tool_line("mcp__firecrawl__firecrawl_search"),
            tool_line("mcp__you__you-search"),
            tool_line("Bash", "https://api.search.tinyfish.ai?query=x"),
            tool_line("Bash", "https://google.serper.dev/search"),
        ]
        (workflow / "agent-2.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
        env = dict(self.env)
        env.update(ALL_KEYS)
        env.pop("CLAUDE_CODE_SESSION_ID", None)
        code, out = run_script("check_services.py", "--transcript-dir", str(workflow), env=env)
        self.assertEqual(code, 0, out)
        self.assertIn("all nine services used", out)


if __name__ == "__main__":
    unittest.main()
