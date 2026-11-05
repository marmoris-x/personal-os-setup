# 23. Vision for DeepSeek sessions: a manual /look skill and a Gemini second opinion

Date: 2026-11-05

## Status

Accepted. The owner's answer at stop point 2 of the task (2026-11-05) keeps the result and
overrides the task's +4 rule: the Gemini second-opinion hook is built even though Gemini did not
win the head-to-head. The vision guard of the task's Part 4 is dropped; every model in the
DeepSeek profile is a flash model.

## Context

The task `deepseek-vision-global-task.md` (version 2) asked whether Gemini 3.5 Flash-Lite through
Portkey reads pictures better than DeepSeek Flash can, and whether the better eye should become
the default. Part 3 measured 20 main pictures and a 64-picture limit ladder (four pictures per
rung), two runs per candidate:

| Candidate | Main run 1 | Main run 2 | Ladder run 1 | Ladder run 2 | Smallest passed rung (text / contrast / shift / colour) |
|---|---|---|---|---|---|
| A - DeepSeek Flash, Read tool | 14/20 | 13/20 | 30/64 | 37/64 | 16 px / 1.5:1 / 8 px / none |
| A2 - DeepSeek Flash with 2x2 tiles | 16/20 | 13/20 | 34/64 | 38/64 | 12 px / 1.5:1 / 8 px / none |
| B - Gemini, quick pool, high | 16/20 | 16/20 | 38/64 | 40/64 | 10 px / 1.5:1 / none / none |
| C - Gemini, quick pool, ultra_high | 15/20 | 15/20 | 39/64 | 44/64 | 6 px / 1.5:1 / none / none |

The task's rule needed Gemini to be at least four pictures better than the better of A and A2 in
both runs. The gaps were 0 and 3, so Gemini does not win; the tiles (A2) did not reach 17/20 in
both runs, so they are no global fix either. A2 moved ability around (small text up, design down)
instead of raising it. Details: `C:\Dev\Temp\deepseek-vision\decision.md` and `BERICHT.md`.

The owner's decision of 2026-11-05: keep `/look` manual, and add Gemini as a second opinion after
every picture read in DeepSeek sessions. Small print, codes and numbers follow Gemini's reading;
layout and controls follow the session's own; a disagreement is said plainly.

## Decision

| What | Where | Why |
|---|---|---|
| The manual path | `~/.claude/skills/look/` with `SKILL.md` (`disable-model-invocation: true`, argument hint `<path> [question]`) and `scripts/look.ps1` | Zero tokens in sessions that never call it; the script is the single implementation of the request |
| The request | one OpenAI-compatible chat completion through the owner's Portkey quick config (`x-portkey-config`, `PORTKEY_CONFIG_QUICK`), model `gemini-3.5-flash-lite`, media part first | The owner's existing config carries the key, the target and the resolution; the script sends no `media_resolution` field of its own (owner's order 2026-11-05) |
| The second opinion | `~/.claude/hooks/gemini-second-opinion.ps1`, registered **only** in `profiles/deepseek.json` (template `profiles-template/deepseek.json`) on `PostToolUse` with matcher `Read`, timeout 70 s | It calls the same `look.ps1`, so the refusals stay one list; it adds `hookSpecificOutput.additionalContext` marked "Gemini (second opinion)" and never blocks |
| The guard | not built | The owner's order: every model entry in the profile is `deepseek-flash[1m]`, which sees; there is no `deepseek-v4-pro` session to warn about |
| The rule for the session | global `~/.claude/CLAUDE.md`, section "Pictures" | "Bei kleiner Schrift, Codes und Zahlen gilt Geminis Lesung; bei Layout und Bedienelementen die eigene. Weichen beide ab, sag es mir." |
| The portable copy | `~/.agents/skills/look-portable/` with `agents/openai.yaml` (`allow_implicit_invocation: false`) | `@look-portable` in OpenCode, `$look-portable` in Codex; same body, same refusals |
| The configuration route | no new manifest or platform component | `claude-hooks` and `claude-skills` are recursive copy components on Windows, macOS and Linux; the new files travel inside them, and `claude-profiles-template` already carries the profile template |

Rules that hold for the hook and the skill:

- The hook never blocks: the Read has already run, every path exits 0, and the only output is the
  one JSON object on success. The child `look.ps1` is stopped after 60 s at the latest; `look.ps1`
  itself uses a 50 s HTTP limit.
- The refused paths are the script's list, checked on the real path resolved through the file
  handle: the OneDrive folder, `~/.claude`, `~/.ssh`, `~/.codex`, the six permanent folders under
  `Downloads`, every `600-archive` segment, and the name parts `ausweis`, `pass`, `svnr`,
  `versicherung`, `bank`, `konto`, `iban`, `befund`, `arzt`, `bescheid`. A refused path is skipped
  before any network call.
- Gemini describes; it never decides. Every answer stays in the session, which compares it with
  its own reading and tells the owner when the two disagree.
- Pasted pictures and browser screenshots cannot be routed by a hook; for those the native eye
  and `/look` remain the way.
- Only the DeepSeek profile carries the hook; the global `settings.json` does not.

## Consequences

- `tests/Look.Tests.ps1` now asserts that the request carries no `media_resolution` field
  (red first, then 37 of 37 green); the `-Resolution` parameter and its two test cases are gone.
- `setup/tools/verify-all.ps1` knows the hook as a profile-only PostToolUse registration
  (matcher `Read`) and names the new files in check J; `tests/Install.Tests.ps1` moves the core
  count from 159 to 161 (`<162`).
- The live DeepSeek profile received the hook through `C:\Dev\Temp\deepseek-vision\profile-hook.ps1`,
  a script that prints only flags, never the profile contents; its read-back validation restores
  the original if the new file would not parse. Its live model entries are
  `opus=deepseek-v4-flash[1m]`, `sonnet=deepseek-flash[1m]`, `haiku=deepseek-flash`,
  `subagent=deepseek-flash[1m]`; the template sets all four to `deepseek-flash[1m]` per the
  owner's order, and a fresh install will produce that.
- The measured tables, the answer files and the scoring scripts stay in
  `C:\Dev\Temp\deepseek-vision\` until the owner accepts them.
