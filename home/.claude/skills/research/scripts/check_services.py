"""Count, from the harness transcripts, which of the nine search services a research run used.

Usage: check_services.py [--session-id ID] [--projects-dir DIR] [--transcript-dir DIR ...]

The harness writes every tool call into the session transcript
(~/.claude/projects/<project>/<session-id>.jsonl) and one transcript per subagent
(<session-id>/subagents/agent-*.jsonl). This script counts the calls per service there.
A dynamic workflow writes its agents' calls into the run's transcriptDir instead
(the `transcriptDir` line of the Workflow tool result); pass it with --transcript-dir,
once per run. The main session sees only the Workflow call, not the agents' calls, so a
count without that directory is too low. --transcript-dir alone works without a session id.
That record is independent: never trust an agent's own "services_used" line.
A keyed service whose key variable is empty is reported as "skipped: no key": it was not
supposed to be called, so it is not missing. Serper is the reserve and is reported as
"reserve": a run that does not need it is correct. Exit 0 when no callable service is
missing, 1 when one is (the caller starts a small extra pass for it), 2 on input trouble.

Tool call patterns: mcp__<server>__* for exa, exa-key, parallel, tavily, firecrawl,
you-free and you; shell commands hitting api.search.tinyfish.ai or google.serper.dev
for tinyfish and serper. A '-balance' tool call counts as no use. exa needs no key
(anonymous fallback), and parallel and you-free never need one.
Standard: ~/.claude/docs/research-standard.md section 2.
"""

import argparse
import json
import os
import sys
from pathlib import Path

SERVICES = ["exa", "parallel", "serper", "exa-key", "tavily", "you-free", "firecrawl",
            "tinyfish", "you"]
PREFIX = {
    "mcp__exa__": "exa",
    "mcp__exa-key__": "exa-key",
    "mcp__parallel__": "parallel",
    "mcp__tavily__": "tavily",
    "mcp__firecrawl__": "firecrawl",
    "mcp__you-free__": "you-free",
    "mcp__you__": "you",
}
SHELL_HINTS = {"tinyfish": "api.search.tinyfish.ai", "serper": "google.serper.dev"}
KEY_VAR = {"exa-key": "EXA_API_KEY", "tavily": "TAVILY_API_KEY", "firecrawl": "FIRECRAWL_API_KEY",
           "you": "YDC_API_KEY", "tinyfish": "TINYFISH_API_KEY"}
RESERVE = "serper"


def service_of(name, command):
    if "balance" in name:
        return None
    for prefix, service in PREFIX.items():
        if name.startswith(prefix):
            return service
    if name in ("Bash", "PowerShell") and command:
        low = command.lower()
        for service, hint in SHELL_HINTS.items():
            if hint in low:
                return service
    return None


def count_file(path, counts):
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return
    with fh:
        for line in fh:
            if '"tool_use"' not in line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            message = record.get("message") or {}
            for part in message.get("content") or []:
                if not (isinstance(part, dict) and part.get("type") == "tool_use"):
                    continue
                service = service_of(part.get("name", ""),
                                     (part.get("input") or {}).get("command", ""))
                if service:
                    counts[service] += 1


def find_files(projects_dir, session_id, transcript_dirs=()):
    files = []
    if session_id:
        for main in Path(projects_dir).glob(f"*/{session_id}.jsonl"):
            files.append(main)
        for sub in Path(projects_dir).glob(f"*/{session_id}/subagents/agent-*.jsonl"):
            files.append(sub)
    for directory in transcript_dirs:
        path = Path(directory)
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(path.glob("agent-*.jsonl")))
    # A file can be reached twice (a transcript dir inside the projects tree); count it once.
    return list(dict.fromkeys(files))


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--session-id", default=os.environ.get("CLAUDE_CODE_SESSION_ID", ""))
    parser.add_argument("--projects-dir",
                        default=str(Path.home() / ".claude" / "projects"))
    parser.add_argument("--transcript-dir", action="append", default=[],
                        help="a Workflow run's transcriptDir (repeatable); its agent-*.jsonl files count too")
    args = parser.parse_args(argv)
    if not args.session_id and not args.transcript_dir:
        print("ERROR no session id (pass --session-id or set CLAUDE_CODE_SESSION_ID, or --transcript-dir)")
        return 2
    files = find_files(args.projects_dir, args.session_id, args.transcript_dir)
    if not files:
        where = args.projects_dir if args.session_id else ", ".join(args.transcript_dir)
        print(f"ERROR no transcripts for session {args.session_id or '-'} under {where}")
        return 2
    counts = {service: 0 for service in SERVICES}
    for path in files:
        count_file(path, counts)
    status = {}
    for service in SERVICES:
        if counts[service]:
            status[service] = "used"
        elif service == RESERVE:
            status[service] = "reserve"
        elif service in KEY_VAR and not os.environ.get(KEY_VAR[service]):
            status[service] = "skipped: no key"
        else:
            status[service] = "missing"
    for service in SERVICES:
        label = "" if status[service] == "missing" else f" ({status[service]})"
        print(f"{service} {counts[service]}{label}")
    missing = [service for service in SERVICES if status[service] == "missing"]
    if missing:
        print("missing: " + " ".join(missing))
        return 1
    if all(status[service] == "used" for service in SERVICES):
        print("all nine services used")
    else:
        print("no service missing (used, skipped or reserve)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
