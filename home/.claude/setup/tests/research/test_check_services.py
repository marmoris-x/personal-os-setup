"""Tests for check_services.py: counts the calls in the transcripts, never a self-report."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import run_script  # noqa: E402


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

    def run_check(self):
        return run_script("check_services.py", "--session-id", self.session,
                          "--projects-dir", str(self.projects))

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
        self.assertIn("missing: parallel serper exa-key tavily you-free firecrawl tinyfish you", out)

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

    def test_unknown_session_is_an_error(self):
        code, out = run_script("check_services.py", "--session-id", "does-not-exist",
                               "--projects-dir", str(self.projects))
        self.assertEqual(code, 2, out)
        self.assertIn("ERROR no transcripts", out)


if __name__ == "__main__":
    unittest.main()
