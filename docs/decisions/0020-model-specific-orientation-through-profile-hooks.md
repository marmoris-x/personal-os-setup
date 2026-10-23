# 20. Model-specific orientation through profile hooks

Date: 2026-10-23

## Status

Accepted.

## Context

The owner writes one orientation file of about 12,000 to 14,000 characters that tells DeepSeek
sessions how this environment is laid out. It must load by itself at the start of every
DeepSeek session and every subagent, it must not depend on an agent choosing to read it, and it
must not appear in the OpenRouter profile or in plain `claude`.

## Decision

Hooks registered only in the DeepSeek profile file. Every DeepSeek start uses that file (the
`claude-ds` function, `morning.ps1` and `batch-run.ps1`), so the hooks run in DeepSeek sessions
only. Why the other mechanisms were ruled out:

- A file in `~/.claude/rules/` without `paths` loads in every profile ("Rules without a `paths`
  field are loaded unconditionally", https://code.claude.com/docs/en/memory).
- `claudeMdExcludes` cannot do it: the base `settings.json` applies to `claude-ds` too, and
  "Lists merge instead of overriding" (https://code.claude.com/docs/en/settings). A profile can
  add an exclusion but never remove one.
- `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` with `--add-dir` applies to every added
  directory of the session, so the vault rules and a second copy of the global CLAUDE.md could
  load into setup sessions.
- `--append-system-prompt-file` reaches the main session only and misses `morning.ps1` and
  `batch-run.ps1`, which call `claude --settings ...` directly. It stays the fallback.

How it works:

| What | Where |
|---|---|
| The owner's file | `~/.claude/orientation/deepseek.md`, mirrored to `home/.claude/orientation/deepseek.md` |
| The hook | `~/.claude/hooks/deepseek-orientation.ps1 -Part <1\|2\|3>` |
| The registration | `profiles/deepseek.json` (template: `profiles-template/deepseek.json`): `SessionStart` with matcher `startup\|clear\|compact`, and `SubagentStart` without a matcher, three handlers each |

- No `resume` in the matcher: a resumed conversation already holds the text.
- The size limit is per hook: each `additionalContext` string is capped at 10,000 characters and
  measured on its own, and Claude receives all values of the hooks of one event
  (https://code.claude.com/docs/en/hooks). So the file goes out in up to three parts of at most
  9,500 characters, 28,500 in total.
- Hooks of one event run in parallel, so the order of the parts is not guaranteed. Each part
  starts with `[Orientation part N of M - all parts together form one document]`; the label counts
  toward the 9,500.
- All three calls split the file the same way: at lines that start with `## `, greedy in file
  order; a section that is too long at blank lines; a paragraph that is still too long at the
  last line break. A line is never cut. A file that needs more than three parts, or has one line
  longer than a part, injects nothing and shows one German warning to the owner.
- A missing, empty or placeholder-only file prints nothing. The hook never blocks: every failure
  exits 0.
- The hook runs under Windows PowerShell 5.1 (`powershell.exe`, as the other hooks) and is
  ASCII-only. The warning text uses `\u` escapes.

## Measured (2026-10-23, Claude Code 2.1.309, test file of 14,133 characters)

Headless runs with `claude --settings <profile> -p`, the test file given through
`PERSONAL_OS_ORIENTATION_FILE`:

| Case | Result |
|---|---|
| DeepSeek, main session asked for the two marker words | Both words, 0 tool calls |
| DeepSeek, a subagent asked the same | Both words, 0 tool calls in the subagent's transcript; the context came through `SubagentStart`. Control run without the file: "I don't know" |
| DeepSeek after a forced compaction (`--resume <id> -p "/compact"`, 27,167 to 10,753 tokens, the `SessionStart:compact` hooks fired) | Both words known, 0 tool calls. Not proof on its own: the summary may carry the words |
| OpenRouter profile | Neither word |
| Plain `claude` (no profile, one question, no tools) | Neither word, 0 tool calls; the run cost 0.17 USD |
| `rm -rf` of a path that does not exist, DeepSeek profile | Blocked by `block-dangerous.ps1`; the path still does not exist |
| Placeholder file, `/context` | Identical to a session without the file (Messages 864 tokens) |
| File of 33,852 characters | Warning "Orientierungsdatei zu lang: 33.852 Zeichen, höchstens 28.500", nothing injected, the model does not know the marker word |

## Consequences

- The file is public in this repository once the owner has written it. The privacy scan and
  gitleaks cover it, and `tests/AgentFileBudget.Tests.ps1` holds it to 28,500 characters.
- The owner's file is pushed in a second step, after the owner confirmed it is finished; until
  then only a placeholder line lives in `~/.claude/orientation/deepseek.md`.
- Adding a fourth part later means a fourth handler in both events and a new ceiling; the 10,000
  character cap per hook is the reason for the split, not a choice.
