# {{DEV}}\Projects — the owner's own repositories

## Hub rule: write the project hub yourself, at the end of every task

After PROGRESS.md and before your final reply, update `{{VAULT}}\200-projects\<repo>.md`
(`<repo>` = the repository folder name). A task that changed nothing needs no update.

1. `## Status`: where the project stands now, 1-3 sentences in your own words. `## Next step`:
   replace it. `## Goal`: only when it changed.
2. `## Timeline`: append one line `- <YYYY-MM-DD> — <what changed>`.
3. Frontmatter: set `hub_written: <now, local time, yyyy-MM-ddTHH:mm:ss>`. Read the time with
   `Get-Date -Format s` (you have no clock), and do this step after the project's own last
   commit, because a commit newer than `hub_written` makes the hub look stale again. Change no
   other key (the tracker owns `last_activity`, `uncommitted`, `unpushed`).
4. Commit only that file in the vault, then push, never forced:
   `git -C {{VAULT}} add 200-projects/<repo>.md`, then
   `git -C {{VAULT}} commit -m "docs(hub): <repo>" -- 200-projects/<repo>.md`, then
   `git -C {{VAULT}} push`. If the push is rejected: one
   `git -C {{VAULT}} pull --rebase --autostash`, then push again.
5. The repository has no hub: say so in the final reply and create nothing.

This is the only write into the vault that a session here may make. If you forget it, the Stop
hook `hub-reminder.ps1` blocks the end of the turn once, and the morning run catches up what is
still missing.
