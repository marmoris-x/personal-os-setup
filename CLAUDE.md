@AGENTS.md

# Notes for Claude Code in this repo

The rules, the check commands and the layout are in `AGENTS.md` above. Only what is specific to
Claude Code stands here.

- The repo is opened as a project, so the working directory is the repo root.
  `install.ps1` is right there; everything else is one level down in `setup/`.
- Do not run `install.ps1` without `-TargetRoot` while working on the repo: that is a live
  install on the machine you are sitting on. The safe form is
  `pwsh install.ps1 -TargetRoot <empty dir> -NonInteractive`.
- A guard hook blocks deleting whole folders and discarding uncommitted git work. Follow its
  message; never add the confirmation marker yourself.
- Before you report a task as finished, run `pwsh setup/tools/verify-all.ps1` and paste its
  output. Its last line must be exactly `VERIFY-ALL: ALL CHECKS PASSED`.
- Subagents: spawn them as plain subagents, never as named teammates — a named teammate loses
  its MCP servers and its `disallowedTools`.
