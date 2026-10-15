# TROUBLESHOOTING -- Verified Bugs and Fixes

Every entry here is verified against official Anthropic docs and/or GitHub
issues (as of: June 2026; Bugs 5-10 added July 2026; Bugs 11-12 and the
Version 5 native-feature review added later in July 2026). Unconfirmed or
invented claims from other sources were deliberately NOT carried over.

---

## Bug 1: claude.exe only shows the Bun help menu

**Symptom:** Running `claude` in the terminal shows "Bun is a fast JavaScript
runtime..." instead of the actual Claude Code interface. `claude --version`
reports a 1.x.x number (a Bun version) instead of 2.x.x (a Claude Code
version).

**Cause (verified, GitHub issues #40544, #67801, #69884, #63402):** Claude
Code ships on Windows as a compiled Bun binary (`bun build --compile`). A
race condition during installation or auto-update can leave an empty Bun
runtime in place of the real Claude Code binary at
`{{HOME_CMD}}\.local\bin\claude.exe`.

**Fix:** Run `repair-claude-code.ps1` (included in this package). It backs
up sessions/settings first, then removes the broken binary via the OFFICIAL
paths and reinstalls.

**Official paths (from code.claude.com/docs/en/setup):**
```powershell
Remove-Item -Path "{{HOME_ENV}}\.local\bin\claude.exe" -Force
Remove-Item -Path "{{HOME_ENV}}\.local\share\claude" -Recurse -Force
```

**If the reinstall still shows Bun (Issue #69884, fallback):**
```powershell
npm install -g @anthropic-ai/claude-code
Copy-Item "$env:APPDATA\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe" `
  "{{HOME_ENV}}\.local\bin\claude.exe" -Force
```

---

## Bug 2: AutoDream gets permanently stuck after a crash

**Symptom:** AutoDream (`autoDreamEnabled: true`) stops consolidating your
`MEMORY.md`, with no error message and no log entry.

**Cause (verified, GitHub Issue #50694):** AutoDream writes a lock file
containing its own process ID. If the dream process is hard-killed (for
example by Windows Modern Standby while a laptop sleeps), the lock file is
left behind with a dead PID. AutoDream does NOT check whether that PID is
still alive -- every future consolidation refuses to run as long as the lock
file exists.

**Correction vs. circulating guides:** The correct path is
```
~/.claude/projects/<your-project>/memory/.consolidate-lock
```
NOT `.local\state\claude` (which some guides incorrectly cite, and which is
not the source of this specific bug).

**Fix:** Manually delete the lock file if AutoDream is suspiciously quiet:
```powershell
Get-ChildItem "{{HOME_ENV}}\.claude\projects\*\memory\.consolidate-lock" `
  -ErrorAction SilentlyContinue | Remove-Item -Force
```
Then manually trigger `/dream` in a Claude Code session, or just say
"consolidate my memory files".

**Status:** Still open as of June 2026 (no official fix merged).

---

## Bug 3: Auto-update on Windows can corrupt the binary

**Observation (verified across several independent issues: #51954, #61676,
#54639, #42776, #63397, #45896):** Windows locks running .exe files at the
filesystem level. If Claude Code is still running during a background update
(or a VS Code plugin/Cowork service holds a lock), the binary swap can fail
-- ranging from "the file disappears entirely" to "the Bun bug from item 1".

**Your decision:** You deliberately chose `DISABLE_AUTOUPDATER: "0"`
(auto-updates on), because your system is currently fresh and stable. That's
an informed tradeoff -- if you see the Bun bug again, `repair-claude-code.ps1`
is the way back, no full reinstall needed.

**If you change your mind:**
```json
"DISABLE_AUTOUPDATER": "1"
```
Only stops the background check. `claude update` still works manually.
(Source: official docs, code.claude.com/docs/en/setup)

---

## Bug 4: Hooks run through Git Bash, not PowerShell -- even with defaultShell: "powershell"

**Important correction to my own earlier setup:** The official hooks
documentation (code.claude.com/docs/en/hooks) says, verbatim:

> "Shell form runs when args is absent. The command string is passed to
> a shell: sh -c on macOS and Linux, **Git Bash on Windows**, or
> PowerShell when Git Bash isn't installed."

This means: `defaultShell: "powershell"` in your settings.json ONLY controls
the shell used for manual `!`-commands typed in the input field -- NOT how
hooks are executed. If Git for Windows is installed (very likely in your
case), all hook commands run through Git Bash by default, not PowerShell.

**Why your hooks worked anyway:** Every hook command in this package calls
`{{PWSH_HOST}}` explicitly as its own standalone command (e.g.
`{{PWSH_HOST}} -NoProfile -File C:/path/script.ps1`). Git Bash executes this
string, but in doing so simply starts the {{PWSH_HOST}} process as a child
process -- which then runs completely natively. This works BECAUSE the
commands don't use PowerShell-specific inline syntax that Git Bash would
misinterpret.

**Additional hardening in this package:** settings.json now uses the "exec
form" (`command` + an `args` array instead of a single string). This sidesteps
the shell-selection problem entirely -- there is no shell interpretation left
at all, the process is started directly. See settings.json, the "hooks"
section.

---

## Bug 5: block-dangerous.ps1 could be bypassed via flag order

**Symptom:** No visible error -- the script simply let certain variants of
the very commands it was supposed to block slip through, with identical
real-world effect.

**Cause (verified with a custom test covering 44 cases, see below):** The
old regex patterns assumed a fixed flag order. `rm -rf` was recognized,
`rm -fr` (identical effect, flags simply swapped) was not. Likewise
`git clean -fd` was recognized, `git clean -df` was not. `git push --force
origin main` was recognized, `git push origin main --force` or the shorter
`git push -f origin main` was not. `git reset --hard origin/main` was
recognized, the equally destructive `git reset --hard` with no target was
not. In addition, the rule against remote-script execution was missing
`irm` (Invoke-RestMethod) entirely -- the most common PowerShell shorthand
for exactly what `curl | bash` is on Linux. `irm https://... | iex` and the
common `iex (irm https://...)` both slipped through completely unchecked.

**Fix:** The patterns in `block-dangerous.ps1` were replaced with
order-independent versions (lookaheads that check "all the pieces appear
somewhere in the same command", instead of demanding a fixed sequence),
`irm` and `Invoke-RestMethod` were added, and the target check for `git
reset --hard` was removed (it now blocks regardless of target). Verified
against 26 must-block and 18 must-not-block test cases (including chained,
harmless commands like `rm x.txt; grep -r foo .`, so that the broader new
patterns don't introduce false positives).

**Known, deliberately accepted limitation:** The git-push rule still only
checks the three common branch names main/master/develop, not arbitrary team
conventions (e.g. "release").

---

## Bug 6: settings.json deny rules only applied to Bash, not PowerShell

**Symptom:** No visible error -- the `permissions.deny` entries in
`settings.json` (`Bash(rm -rf *)`, `Bash(git reset --hard*)`, etc.) looked
like complete coverage, but weren't.

**Cause (verified against the official permissions documentation and GitHub
Issue #57013, which confirms the existence of a dedicated `PowerShell(...)`
rule syntax):** Permission rules are defined per tool name. `Bash(...)`
rules apply exclusively to the Bash tool. Since this setup uses PowerShell as
the primary shell (`CLAUDE_CODE_USE_POWERSHELL_TOOL=1`), most shell commands
never went through the Bash tool at all, and therefore never went through
these deny rules either. `block-dangerous.ps1` was, in effect, the ONLY line
of defense against these commands -- no independent second layer at the
permission level, unlike what would have existed for Bash commands.

**Fix:** Added parallel `PowerShell(...)` deny rules to `settings.json`
(Remove-Item -Recurse -Force, sudo, Format-Volume, git push --force, git
reset --hard, git clean -fd), so PowerShell commands are now checked at two
independent levels -- permission rule AND hook.

---

## Bug 7: protect-files.ps1 did not protect its own security configuration

**Symptom:** No visible error -- a theoretical gap, no observed misbehavior.

**Cause:** `protect-files.ps1` protected `.env`, `settings.json`, `.ssh`, and
`.aws` from being overwritten, but not `CLAUDE.md`, the hook scripts
themselves (`.claude\hooks\*.ps1`), or the rule files
(`.claude\rules\*.md`). An agent that, through a mistake or through a
prompt-injection payload from an external file/webpage, gets nudged into
"simplifying" `block-dangerous.ps1` or rewriting CLAUDE.md could in theory
disable its own last line of defense, with nothing stopping it.

**Fix:** Three additional, purely additive protection patterns added to
`protect-files.ps1` (CLAUDE.md, `.claude\hooks\`, `.claude\rules\`). Nothing
pre-existing was removed or changed.

---

## Addendum 8: autoMode.classifyAllShell was not used

**Observation (verified against Claude Code release notes v2.1.193):** As of
v2.1.193, the Auto Mode safety classifier, by default, only reviewed shell
commands that already looked like an obvious arbitrary-code-execution
pattern -- routine commands skipped the classifier entirely. The new
`autoMode.classifyAllShell` setting instead routes EVERY Bash/PowerShell
command through the classifier, at the cost of somewhat higher latency.

**Why this matters for this setup:** Given the regex gaps found in Bug 5, an
additional, independent check by the safety classifier is worthwhile --
especially since Auto Mode already hard-blocks certain destructive git
operations by default (including `git reset --hard` and `git clean -fd`)
unless they were explicitly requested. `classifyAllShell: true` makes that
net finer-meshed.

**Fix:** Added `"autoMode": {"classifyAllShell": true}` to `settings.json`.

---

## Bug 9: Stop and Notification hooks blocked for 5 seconds per call

**Symptom:** No error, but unnecessary waiting -- at the end of EVERY turn
(Stop hook) and on every idle notification (Notification hook), a noticeable
~5-second delay before control returned.

**Cause:** `stop-notify.ps1` and `notification-idle.ps1` show a Windows
balloon notification and then call `Start-Sleep -Seconds 5` so the
notification stays visible before cleaning itself up
(`$notify.Dispose()`). `Start-Sleep` is an inherently blocking call for the
script itself. The comment in `stop-notify.ps1` claimed "non-blocking",
which was never true for the hook process itself -- without `"async": true`
in the hook configuration, Claude Code waits for the process to end before
continuing. Confirmed via the official async-hooks announcement (January 25,
2026, available from Claude Code v2.1.23 onward) and GitHub Issue #23383,
which shows the exact same `"async": true` configuration style for a Stop
hook in production use.

**Fix:** Added `"async": true` to both hook entries in `settings.json`
(Stop and Notification), matching the pattern already used for the
PreCompact hook. The scripts themselves did not need to change -- the
5-second notification display time stays the same, Claude Code just no
longer waits for it.

---

## Bug 10: repair-claude-code.ps1 checked the Bun version against untrimmed text

**Symptom:** No observed misbehavior, but a potential silent false "all
clear" depending on the exact formatting of the `--version` output.

**Cause:** `$versionOutput = & $claudeExe --version 2>&1 | Out-String` can,
depending on the PowerShell version, come back with leading or trailing
whitespace or line breaks. The check pattern `'^1\.\d'` requires an exact
match starting at character 0. The on-screen display already used
`$($versionOutput.Trim())`, but the actual detection,
`$versionOutput -match '^1\.\d'`, did not -- with leading whitespace, a
genuinely broken Bun installation could have incorrectly passed as "no
problem detected".

**Fix:** Added `.Trim()` before both regex checks (the initial check and the
post-reinstall check).

---

## Bug 11: protect-files.ps1 blocked creating a CLAUDE.md in ANY project

**Symptom:**
```
Write(CLAUDE.md)
  Error: PreToolUse:Write hook error: [...protect-files.ps1]: BLOCKED:
  '{{DEV}}\Projects\<project>\CLAUDE.md' is a protected file.
```
Happened even for a brand-new project that had no CLAUDE.md yet.

**Cause:** The Bug 7 self-protection fix (see above) added the pattern
`'CLAUDE\.md$'` to stop an agent from rewriting the GLOBAL
`~/.claude/CLAUDE.md`. The pattern was not anchored to the `.claude\`
folder, so it matched a CLAUDE.md ANYWHERE, including the project-root
CLAUDE.md that every individual project is supposed to have per
`schemas.md` ("`<project>/CLAUDE.md` -- Project instructions"). Every
project's own CLAUDE.md was silently being treated as if it were the
protected global one.

**Fix:** Anchored the pattern to `'\.claude[\\/]CLAUDE\.md$'`, so it only
matches a CLAUDE.md that sits directly inside a `.claude\` folder (i.e. the
global `{{HOME}}\.claude\CLAUDE.md`) -- the same anchoring style
already used for the `settings.json` entries in the same list. Project-root
CLAUDE.md files (which live next to, not inside, `.claude\`) are no longer
matched and can be created/edited normally again.

---

## Bug 12: tools.md referenced `TeamCreate`/`TeamDelete`, which no longer exist

**Symptom:** None yet observed in this specific setup, but if Claude Code
(or DeepSeek, following the documented pattern) had ever tried to call
`TeamCreate` to set up an agent team the way `tools.md` described, the call
would simply fail -- the tool doesn't exist anymore, in any version this
setup could realistically be running.

**Cause (verified against the official Claude Code changelog, v2.1.178,
June 15 2026):** `tools.md` was accurate for the version it was originally
written against (v2.1.173). Five versions later, v2.1.178 removed
`TeamCreate` and `TeamDelete` entirely: every session with
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` set now has ONE implicit team from
the moment the flag is on, with no separate create/teardown step. You spawn
a named teammate by calling `Agent` with a `name` parameter directly from
the main session; cleanup happens automatically when the session exits.
Since `DISABLE_AUTOUPDATER: "0"` keeps this setup auto-updating, it has
almost certainly been running a version past 2.1.178 for a while without
`tools.md` reflecting it.

**Fix:** Rewrote the "Agent Teams" section of `tools.md` to describe the
current `Agent(name=...)` + `SendMessage` pattern, and added a verified
security detail while in there: a message a teammate receives via
`SendMessage` from another Claude session never carries user authority --
Auto Mode and other teammates must treat a relayed "approval" as untrusted
input, not as confirmation from the user.

---

## Bug 13: powershell.md's "UTF-8 without BOM" example actually wrote a BOM

**Symptom:** None yet observed in this specific setup -- this pattern was
documented as a reference example in `rules/powershell.md` but was never
actually called from any of the 7 hook scripts, so it hadn't caused a live
bug yet. It would have, the first time anything copied that "example."

**Cause (verified against Microsoft's own .NET API docs for
`UTF8Encoding.GetPreamble`):**
```powershell
# The OLD (wrong) line:
[System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)
```
was labeled "UTF-8 without BOM", but `[System.Text.Encoding]::UTF8` is the
one specific UTF8Encoding instance in .NET that IS configured to emit the
3-byte BOM (`0xEF 0xBB 0xBF`) -- confirmed word-for-word by Microsoft's own
docs: "All other UTF8Encoding objects are configured to return an empty
array rather than a valid BOM" (i.e. every instance EXCEPT this singleton
omits the BOM). This is the exact opposite of what the comment claimed.

**Why this matters for this setup specifically:** Bug 4 already established
that PowerShell 5.1 reads `.ps1` files without a BOM using the system ANSI
codepage, and that getting encoding wrong on a hook script is a real, sharp
edge here. A reference pattern that silently adds an unexpected BOM to
anything that used it -- including a `.ps1` file being formatted by the new
PowerShell branch in `format-by-type.ps1` (see Version 6 below) -- was worth
catching before it was ever actually invoked, not after.

**Fix:** Corrected the example in `rules/powershell.md` to construct an
explicit no-BOM encoding instance instead of using the singleton:
```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($file, $content, $utf8NoBom)
```
The new `.ps1` formatting branch in `format-by-type.ps1` (Version 6) uses
this corrected pattern from the start.

---

## Version 4 change (not a bug -- a deliberate user choice): only .claude is protected

**What changed:** Per explicit user request, this configuration no longer
blocks anything except deletion of the `.claude` folder or its contents.
Force-push, hard-reset, `sudo`, piping a remote script into a shell, and
deleting any file/folder other than `.claude` are all now unconditionally
allowed.

**What still blocks something, and why:**
1. `block-dangerous.ps1` -- now only checks for deletion commands
   (`rm`/`Remove-Item`/`rmdir`/`del`/`git clean -fdx`) combined with either
   an explicit `.claude` path, or a "delete literally everything" shape
   (bare home dir, bare drive root, bare `/`) that would take `.claude` down
   as a side effect even without naming it.
2. Raw disk-wipe tools (`Format-Volume`, `mkfs`, `dd` to a device) are still
   refused unconditionally -- these cannot be scoped to "spare one folder",
   so there was no way to honor "protect .claude" and "allow this" at the
   same time.
3. `protect-files.ps1` is now a documented no-op (see the file itself) and
   is no longer registered as a hook in `settings.json` at all -- it had no
   remaining job once "editing/adding to .claude is fine, only deletion
   isn't" was the rule, since Edit/Write/MultiEdit never delete a file.
4. `settings.json`'s `permissions.deny` list is now empty. `autoMode.
   classifyAllShell` was switched from `true` to `false`, removing the
   "route every single shell command through the extra classifier pass"
   behavior added in the Version 3 audit.

**What can NOT be turned off by this configuration, and is worth knowing
about:** Claude Code's own built-in Auto Mode classifier (documented at
code.claude.com/docs/en/permission-modes) independently hard-blocks a fixed
list of destructive git/infrastructure operations -- `git reset --hard`,
`git checkout -- .`, `git restore .`, `git clean -fd`, `git stash drop`/
`clear`, and `terraform`/`pulumi`/`cdk destroy` -- "unless you explicitly
asked for them in this session." This is enforced by Claude Code itself, not
by anything in `settings.json` or in a hook, so this ZIP cannot disable it.
Two practical consequences: (a) if one of these commands gets refused
despite everything above, explicitly saying in the same session "yes, run
`git reset --hard` now" is what typically satisfies the classifier, not a
config change; (b) this classifier is Anthropic-cloud-backed infrastructure,
the same category as `/code-review ultra` (see CLAUDE.md section 11) --
whether it engages reliably at all when running against the DeepSeek
backend through the Anthropic-compatible proxy is unverified, not confirmed
either way.

---

## Version 5 (July 2026): native Claude Code feature adoption in tools.md

**Context:** A parallel research session (web search only, without access
to the official docs used for this fix) suggested 6 recent Claude Code
changes worth adopting. Every one of the 6 was rechecked directly against
the official changelog before anything was written down, rather than
trusting the prior summary at face value. Result: 5 of 6 confirmed correct
(two of those five needed a date correction or an added caveat); 1
(`sandbox.credentials`) intentionally skipped, per explicit instruction,
since this setup does not set `sandbox.enabled`.

**Confirmed and added to `tools.md` (and, where actionable, to the actual
config):**
1. **`fallbackModel` setting** -- v2.1.166, June 6 2026 (this date matched
   the prior research exactly). Added `"fallbackModel":
   ["deepseek-v4-flash"]` to `settings.json`. Documented the turn-scoped vs.
   session-scoped distinction (overload/unavailable = one turn only; "model
   not found" = rest of the session), and flagged as unverified whether the
   DeepSeek gateway signals overload in a way Claude Code's fallback logic
   actually recognizes.
2. **Streaming idle watchdog on by default for all providers** -- v2.1.196,
   June 29 2026. Documented in `deepseek.md`, including the
   gateway-specific nuance that `API_FORCE_IDLE_TIMEOUT` is a SECOND,
   independently-active 5-minute timeout for exactly this setup's kind of
   connection (custom `ANTHROPIC_BASE_URL`), and how to tell this failure
   mode apart from the already-documented HTTP 400 crash.
3. **`AskUserQuestion` no longer auto-continues by default** -- v2.1.200,
   July 3 2026 (this date also matched the prior research exactly). Before
   this version (v2.1.198/199), it silently auto-continued after 60 seconds
   by default -- the opposite of what this setup wants. Documented the
   opt-in `askUserQuestionTimeout` setting in `tools.md` for anyone who does
   want an idle timeout on genuinely unattended overnight runs.
4. **Subagents run in the background by default** -- v2.1.198, July 1 2026.
   Documented the default flip in `tools.md` AND in `schemas.md` (the
   `background:` frontmatter field's description was still describing the
   old default). Also documented `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS`
   (default 10 minutes), which is directly relevant given this setup's
   documented DeepSeek crash -- a background subagent going silent because
   of it is now caught by this watchdog instead of hanging forever.

**Corrected -- the underlying fact checks out, but the date in the prior
research did not:**
5. "A malformed hook entry in settings.json no longer crashes the whole
   file" is real, but dates to **v2.1.122, April 28 2026** -- not a
   June/July 2026 change as first reported. Since every version this setup
   has ever run is already well past 2.1.122, this protection has quietly
   been in place the entire time. Mentioned in `tools.md` for accuracy;
   nothing to configure.

**Deliberately skipped, per explicit instruction:**
6. `sandbox.credentials` (v2.1.187, June 23 2026 -- confirmed real, exists
   exactly as described) -- not added, because this setup does not set
   `sandbox.enabled`, so it would have no effect.

**Also found and fixed while re-verifying `tools.md` for general currency
(not part of the original 6-item list -- see Bug 12 above):** the "Agent
Teams" section still listed `TeamCreate`/`TeamDelete`, both removed in
v2.1.178.

---

## Version 6: re-verified .claude blocking, added PowerShell formatting + fuller notification coverage

**Re-verification of the Version 4 promise ("only .claude deletion is
blocked"):** re-ran the exact regex logic from the current
`block-dangerous.ps1` against realistic create/edit commands targeting
`.claude` (`New-Item`, `Set-Content`, `Add-Content`, `echo >`, `touch`,
`Copy-Item`, creating a new subfolder) -- every one of them comes back
`allowed`, because none of them match the deletion patterns at all; the
check for "is this even a deletion" short-circuits before anything about
`.claude` is even considered. Separately, `protect-files.ps1` is fully
disabled (see its own file header) and isn't registered in `settings.json`'s
`hooks` at all anymore, and the native `Write`/`Edit`/`MultiEdit` tools
aren't matched by any `PreToolUse` hook here either (only `Bash` and
`PowerShell` are). Net result: nothing in this configuration currently
blocks creating or editing anything inside `.claude`, through any path --
native tools or shell commands. If this is still being seen in practice,
the most likely explanation is that the actual `~/.claude/` folder on disk
hasn't been updated with the latest files from this package yet, rather
than a gap in the logic itself.

**Added: PowerShell auto-formatting in `format-by-type.ps1`.** The file
already covered JS/TS/JSON/CSS/HTML/MD/YAML (Prettier), Python (ruff/black),
Go (gofmt), Rust (rustfmt), and C#/.NET (dotnet format) -- notably absent
was PowerShell itself, despite this entire project being PowerShell. Added
a `.ps1` branch using `Invoke-Formatter` from PSScriptAnalyzer, the
Microsoft/community-standard PowerShell formatter. Same graceful-degradation
pattern as every other branch: does nothing if PSScriptAnalyzer isn't
installed (`Install-Module -Name PSScriptAnalyzer -Scope CurrentUser` to add
it), never blocks, never surfaces an error to the turn. Uses the corrected
no-BOM write-back from Bug 13 above, since it's writing `.ps1` content back
to disk.

**Added: `hooks/notification-events.ps1`, a new Notification hook.** The
existing `notification-idle.ps1` only covers the `idle_prompt` notification
type. The official hooks reference documents several more, two of which are
now genuinely relevant to this setup and weren't being surfaced at all:
- `permission_prompt` -- fires when Claude Code's own built-in Auto Mode
  classifier hard-blocks something regardless of this setup's hooks (see the
  Version 4 section above). Previously, the only way to notice was to be
  looking at the terminal at that exact moment.
- `agent_needs_input` / `agent_completed` (require v2.1.198+) -- fire for
  background sessions. Now that subagents run in the background by default
  as of v2.1.198 (see `tools.md`), and with agent teams enabled, background
  work is the common case rather than the exception.

Registered as a second entry under `settings.json`'s existing `Notification`
hooks (matcher `permission_prompt|agent_needs_input|agent_completed`),
alongside the untouched `idle_prompt` entry. Rather than hardcode text per
event type, the new script reads the actual `message`/`title` Claude Code
already sends for each notification (see the official "Notification input"
schema) -- so it keeps working correctly if Anthropic adds another
notification type later, with no changes needed here. Uses a different icon
and a distinct 3-beep fallback pattern from `notification-idle.ps1`'s
2-beep and `stop-notify.ps1`'s 1-beep, so all three stay distinguishable
without reading any text.

---

## Version 7: two informational (never-blocking) audit-log hooks added

Requested by the user, scoped deliberately: "only for the global `.claude`
folder in the user profile, not broader." Two separate mechanisms were
needed, because they cover genuinely different situations:

**`hooks/config-change-audit.ps1`** -- a new `ConfigChange` hook, matcher
`user_settings` only. Fires when `{{HOME}}\.claude\settings.json`
changes from OUTSIDE the current Claude Code session (you edit it by hand
in a text editor, or another process touches it). Deliberately does NOT
cover `project_settings`/`local_settings` (any individual project's OWN
`.claude/settings.json`) or `skills` -- out of scope per the explicit
"global folder only" instruction, and there are no skills defined yet
either way.

**`hooks/claude-edit-audit.ps1`** -- a new hook added as a SECOND entry in
the existing `PostToolUse` `Edit|Write|MultiEdit` matcher, alongside
`format-by-type.ps1` (both now run for every edit/write/create; they don't
interact). This is the one that actually answers the original request from
a few turns back ("I want to know if something changes in `.claude`, I
just don't want to be blocked for it") -- `ConfigChange` only watches
`settings.json` changing from outside a session; this hook is what catches
Claude's OWN creates/edits to `CLAUDE.md`, the hook scripts themselves, and
the rule files, during a normal turn, which is the far more common case.
Filters out anything not under `{{HOME}}\.claude\` before doing
anything else -- zero log growth, zero overhead for ordinary project work
elsewhere.

**Both hooks:**
- Write to a single shared log, `{{HOME}}\.claude\audit.log` -- one
  place to check, not two.
- Never block anything, under any circumstance. `ConfigChange` hooks CAN
  return `{"decision": "block"}` to stop a settings change from applying;
  neither of these scripts ever does, since that would contradict this
  setup's Version 4 "don't block me, just tell me" decision.
- Use the corrected no-BOM write-back from Bug 13, since both append to a
  plain-text file.
- Run `"async": true`, same reasoning as the other non-blocking
  notification/backup hooks (see Bug 9): a log append should never make a
  turn wait.

**Not done, and why:** broadening either hook beyond the global `.claude`
folder to cover other projects too -- explicitly declined. Reasoning:
actual project code is presumably already under Git, which already
provides a complete change history (`git log`/`git diff`) for anything
tracked; a redundant log-everything hook would mostly just add noise there.
`.claude` itself typically isn't Git-tracked, which is exactly why a manual
log adds real value there specifically, and nowhere else it wasn't already
being asked for.

**Outcome, 2026-09-28 (version 12.0): both hooks switched off.** They ran
for three weeks and nobody ever opened `audit.log` once. The premise above
had also stopped being true in the meantime: `~/.claude` was made the private
repository `claude-config`, so `.claude` *is* Git-tracked now, and every edit
inside it shows up in `git log` with its diff while `docs/CHANGELOG.md` names
every change with its reason. A second, unread copy of the same facts is
cost without benefit. The scripts were moved to `setup/_removed/` with a
README, not deleted -- nothing inside a `.claude` folder is ever deleted.
The notification hooks (`stop-notify.ps1`, `notification-idle.ps1`,
`notification-events.ps1` -- Bug 9 here) are unaffected and still run. See
`docs/CHANGELOG.md` section 39.

---

## Verifying your setup

```powershell
# Model check
claude
/status

# Skills/context check
/doctor
/context
/memory

# Bun-bug check (should show a 2.x.x number, NOT 1.x.x)
claude --version
```
