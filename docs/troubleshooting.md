# Troubleshooting

Nothing here is Windows-only unless the row says so. The paths are written in the Windows
spelling; on macOS and Linux `%USERPROFILE%` is `~` and `/` is the separator.

## Installing

| Symptom | Cause | Solution |
|---|---|---|
| `personal.yaml is missing: …` | No personal values on this machine yet | Start `install.ps1` once **without** `-NonInteractive` (asks and creates the file) or copy `setup/config/personal.example.yaml` and fill it in |
| `TargetRoot is not empty` | The test mode installs only into empty folders (protection against writing into real directories) | Take a new empty folder — or the same one if a `.install-state/install-journal.json` already lies there (then it is its own repeat run) |
| `pwsh is missing` | PowerShell 7 is not installed and could not be installed | Windows: `powershell -ExecutionPolicy Bypass -File bootstrap.ps1`. macOS and Linux: `./bootstrap.sh`. Both bring PowerShell 7 along |
| `manifest.yaml invalid: …` | An entry violates the schema | Correct the named entry; `pwsh setup/tools/check.ps1` shows it as well |
| `manifest.yaml invalid: … the file it promises is missing in the repo` | A component installs content that nobody wrote (measured: `pwsh-profile-unix` promised `home/.config/powershell/profile.ps1`) | Write the file, or remove the component from `setup/manifest.yaml`. Never point the entry at another file to silence it |
| `repo folder missing` / `repo file missing` | The manifest points at something that is not (any more) in the mirror folders `home/`, `vault/` and `dev/` | On the source machine run `pwsh setup/export.ps1`, commit, then `git pull` on the target machine |
| Packages `WARN unknown distribution` (Linux) | `/etc/os-release` names a distribution that is not one of the tested ones | The stage prints the full package list and stops; install it with that distribution's own tool, then `install.ps1 -Resume -SkipWinget` |
| Packages `WARN Homebrew is missing` (macOS) | Homebrew is not installed | Install it from <https://brew.sh>, then `install.ps1 -Resume` |
| Task/firewall/LongPaths "skipped" (Windows) | These stages need administrator rights | Open an admin PowerShell, `install.ps1 -Resume` — only the open stages run. On macOS the launch agent and on Linux the systemd user timer need no root |
| Second run says "new …" instead of "same …" | Files were changed by hand between the runs | Intended: the installer replaces with backup. Bring them back with `setup/restore.ps1` if it was wrong |

## Checking

| Symptom | Cause | Solution |
|---|---|---|
| `verify` FAIL "differs" for `template` | Rendered text does not match, usually because of a changed placeholder or expected value | `-Verbose` look into the file; on the source machine export, commit, target `git pull` + `install -Resume` |
| `verify` FAIL "unknown placeholders" | A file uses `{{…}}` that is not in the fixed list (ADR 0003) | Add the placeholder to the `setup/lib/placeholders.ps1` vocabulary (plus export style) or fix the typo |
| `verify` FAIL for winget / "system check not executed" | winget or `claude` are missing in PATH | Install the programs; without system checks `-SkipSystemChecks` checks only files |
| `verify` FAIL "preview missing" (test install) | The package stage wrote no preview | Test installs only preview the OS stages. If a distribution is unknown (Linux) or Homebrew is missing (macOS), that stage stops with WARN and writes nothing — fix that first |
| `verify` FAIL for `crawl4ai`, install `ERROR` for `crawl4ai`, a `WARNING crawl4ai unavailable` line in a research run, or a Crawl4AI line in the morning report | Crawl4AI is installed but its browser does not start. Found 2026-10-25: the Playwright browser folder (`ms-playwright`) was empty for two days and every research page silently went to the paid fallback services | Run `~/.claude/life-os/crawl4ai-repair.ps1`: it installs the browser into Crawl4AI's own folder (`PLAYWRIGHT_BROWSERS_PATH`, Windows `%LOCALAPPDATA%\crawl4ai-browsers`), runs the self-test and exits 0 only when it prints `crawl4ai=ok`. Never a bare `crawl4ai-setup`: it fills Playwright's shared `ms-playwright` folder, which another Playwright installation can empty again. The morning run calls the repair once by itself; the install stage and `verify` run the same self-test |
| Roundtrip test reports deviations | Repo state and live state have drifted apart | `pwsh setup/export.ps1`; if the deviation is intended: let the entry work with `append`/`drop_lines` (the test skips such entries and counts them) |
| `check.ps1` prints `SKIP test-…` (macOS, Linux) | Part of the guard suites tests Windows command lines and the live Windows guard text | Nothing to fix: the line names the reason. Those suites run on the Windows job in CI |

## CI

| Symptom | Cause | Solution |
|---|---|---|
| Run red at `setup/tools/ci-smoke.ps1` | The install, the verify or the second install failed on that system | The step prints the full output of the failing run since 2.2.0. Reproduce it with the same three commands; a Linux-only failure needs a Linux machine or container, the two other systems cannot be simulated |
| Run red at `setup/tools/check.ps1` | Analyzer error, Pester case or guard suite | Run the same command locally; the output names file and rule |
| Run red at the privacy scan | A personal value got into the repo | `pwsh setup/tools/privacy-scan.ps1` locally, clean up the masked findings, commit again. Do **not** widen the exception rules to "let it through" |
| Run red at gitleaks | Key-like character string in the commit | Look at the finding; rotate real keys immediately; false positives only with a reason in `.gitleaks.toml` |
| The macOS job did not run | It runs on a release tag, once a week and by hand only (minutes there cost ten times a Linux minute) | `gh workflow run ci` starts it |

## Guards

| Symptom | Cause | Solution |
|---|---|---|
| "BLOCKED: …" before a command | A guard has judged — usually correctly | Read the message, use the allowed alternative (e.g. `add-to-archive.ps1`), ask the owner. Do not bypass, do not repeat with variants |
| A really necessary step is blocked | No allowed form exists | Documented short window: pause exactly **one** guard (file away, note the hash, work, file back, compare hash, block test, suite), log everything. Details: `docs/guards.md` |
| Commit is rejected (pre-commit) | gitleaks or the privacy scanner found something — or the tool is missing (fail-closed) | Clean up the finding; if gitleaks/pwsh is missing, install it instead of `--no-verify` |

## Emergency brake

Everything the **last** install run replaced is brought back by `pwsh -File setup/restore.ps1` with
hash check. Files that the run newly created remain — simply delete them if not wanted. The
installer itself never deletes anything.
