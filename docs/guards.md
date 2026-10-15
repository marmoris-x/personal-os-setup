# Guards

The guards are hooks of Claude Code that judge before every tool call:
allow, block or ask. They lie as `.ps1` files in
`home/.claude/hooks/` and are registered via `~/.claude/settings.json`. Every
guard has its own test suite (`home/.claude/setup/tests/`) that runs from a
rendered tree (`setup/tools/check.ps1`) — 594 individual cases in total.

## The guards one by one

| Guard | Verdict | Why |
|---|---|---|
| `block-dangerous` | Blocks deleting whole folders and discarding unbacked-up Git work; exception: scratch folders (`%TEMP%`, Dev-Temp) | An agent may never inadvertently destroy user work |
| `downloads-guard` | Blocks moving/renaming/deleting in six permanent Downloads folders | Those are intended permanent storage; only the owner tidies there |
| `archive-guard` | Protects vault areas of high value (`600-archive`, `300-areas`) from mass changes | Documents and personal references are delicate |
| `onedrive-guard` | Makes the OneDrive document archive **add-only**: only list names, add one file via script, take one file out with hash check; everything else is blocked | The owner's cloud archive, not an agent's playground |
| `trifecta-guard` | Foreign web content and `600-archive` content may never meet in the same session | Protection against prompt-injection chains |
| `session-check` | Checks the basic state at session start (session-start hook) | Early warning instead of a late surprise |
| `notification-idle` / `notification-events` / `stop-notify` | Pure notifications, no verdict | Comfort, not safety |

In addition the Git pre-commit hook (`home/.githooks/pre-commit`): repo-local **fail-closed**
— if gitleaks or pwsh is missing, the commit fails instead of silently passing through. The global
hook of the source machine is copied over word for word (ADR 0012); the lesson "fail-closed" sits in the
repo-local hook.

## When a guard blocks

1. Read the message — it names the allowed alternatives (e.g. "use add-to-archive.ps1").
2. Use the alternatives or ask the owner. **Never bypass** and **never** try again with
   variants of the same command.
3. Only if a step is really necessary and no allowed form exists: pause **exactly the
   one** guard briefly — move the file out of `~/.claude/hooks/` (note the hash
   beforehand), do the work, file back, compare hash, block test, run the suite,
   record everything in the progress log. Never switch off all hooks at once.
   (This way of working comes from the build assignment, section 1.1.)
4. After every such window: show `pwsh ~/.claude/setup/tests/test-<name>.ps1` green.

## The suites

| Suite | Cases |
|---|---|
| `test-block-dangerous.ps1` (+ `-51` for Windows PowerShell 5.1) | 120 each |
| `test-downloads-guard.ps1` | 64 |
| `test-archive-guard.ps1` | 50 |
| `test-onedrive-guard.ps1` | 191 |
| `test-trifecta-guard.ps1` | 43 |
| `test-session-check.ps1` | 6 |
| `test-add-to-archive.ps1` | 42 (runs only on the archive machine, part of the acceptance) |

`setup/tools/check.ps1` runs the first seven; the eighth needs the real archive and runs in
`setup/tools/verify-all.ps1`.
