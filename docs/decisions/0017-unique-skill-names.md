# 17. Unique skill names across harnesses

Date: 2026-10-18

## Status

Accepted.

## Context

OpenCode loads global skills from three folders: `~/.config/opencode/skills`,
`~/.claude/skills` and `~/.agents/skills` (https://opencode.ai/docs/skills/, read 2026-10-18).
The page names the locations but not what happens when two of them define the same skill name;
its troubleshooting section only says "Ensure skill names are unique across all locations".
That makes duplicates undefined behaviour rather than a documented precedence. Codex reads user
skills from `~/.agents/skills` alone, so only OpenCode sees both trees.

The setup carries the same skill twice on purpose: once for Claude Code
(`~/.claude/skills/<name>`) and once as the harness-neutral copy (`~/.agents/skills/<name>`).
`docs-import` and `quick-research` existed in both trees under the same name.

## Decision

A harness-neutral copy whose name also exists under `~/.claude/skills` carries the suffix
`-portable` in its folder and in its frontmatter `name:`, because OpenCode requires the name to
match the directory. Claude Code keeps `docs-import` and `quick-research`; the other harnesses
see `docs-import-portable` and `quick-research-portable`. A skill that exists only in
`~/.agents/skills` (for example `web-research`) keeps its name unchanged.

The same change creates `~/.codex/AGENTS.md` from the installed global rules when Codex is
present and the file is missing. An existing file is never touched.

## Consequences

- No two skill folders visible to one harness share a name. The trigger descriptions differ in
  wording, so a model in either harness still finds the right skill.
- A new neutral copy needs a name check before it is added: if the name also exists under
  `~/.claude/skills`, it gets `-portable`.
- The `-portable` skills do their work inline (no Claude Code subagents) and call the same
  Python scripts by their installed path under `~/.claude/skills/research/scripts/`.
