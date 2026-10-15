# ADR 0007 – No Claude Code plugin; files stay files

- Date: 2026-10-11
- Status: decided

## Context

Claude Code plugins can bundle skills, agents, commands, hooks, MCP servers and output styles
(`.claude-plugin/plugin.json`). Checked limitations (brief 9.4, model
`affaan-m/everything-claude-code`): a `CLAUDE.md` in the plugin is **not** loaded, rules cannot
be distributed via plugin; plugin hooks move to a new folder on updates — the guards here,
however, work with fixed paths and their own test suites.

## Decision

Everything stays normal files under `~/.claude` (copied, not packaged as a plugin). There is no
`.claude-plugin/` in the repo. A plugin would only make sense once it can distribute rules and
hook paths are stable; then this decision will be re-examined.

## Alternatives

- Local plugin with a marketplace in the repo: would simplify installation, but costs the
  disadvantages named above and brings no added value for a one-person PC.

## Consequences

- The installation stays "copy files + call CLIs" — honest, traceable, testable.
- Skill/agent/rule updates run through `setup/export.ps1` like everything else.
