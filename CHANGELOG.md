# Changelog

Every change is recorded here with date and reason. Version 2.0.0 is the successor of the
old Blueprint package (1.x); its `printed-vs-live.ps1` mirroring is from now on replaced by the
`setup/export.ps1` route in this repo. The current version is the newest git tag; there is no
`VERSION` file any more.

## 3.0.1 (2026-10-15)

Removed license material (2026-10-15).

The first `ci` run that ever got past GitHub's billing gate (38711843191) reached steps no earlier
run had reached, and found three defects. All three are fixed here.

| What | Why |
|---|---|
| `tests/PersonalLayer.Tests.ps1` | The reader test pinned the literal `'false'` for `published` in `repo.yaml`, so recording the release turned it red on ubuntu and on macOS (`Expected: 'false' But was: 'true'`) while it had been green a minute earlier. The test is about the READER, so it now takes the value out of the file and demands only that it is one of the two states check S accepts. Red-proved on a clone: as released 27 passed / 0 failed, `published: maybe` 26/1, key removed 26/1 |
| `setup/tools/verify-all.ps1` | `$script:checkCount` still said 33 after check T left. The acceptance line prints only when the result count equals it, so the run would have printed the partial line for ever and could never have said ALL CHECKS PASSED. It is 32 now - 21 lettered checks plus 11 numbered ones, counted both ways |
| `setup/tools/ci-full-setup.ps1` | `full-setup (macos-latest)` was red with `life-os-venv - venv present but incomplete: faster-whisper is not installed`. `ctranslate2==4.8.2` publishes no macOS arm64 wheel, so the venv cannot be built on `macos-latest` and nothing about that improves on a machine with nobody logged in. The install stage already reports the same failure as a WARN under "what a machine nobody has logged into cannot do"; the verify did not know the limit. It is named in `$script:expectedFails` now, with the detail text it must match, so a venv that breaks for another reason still turns the job red |

## 3.0.0 (2026-10-15) – this construction kit is a public repository now

The kit is shared: `personal-os-setup` is public since this version. It is a **new repository
with one commit**, not the old one switched to public. Why that route and not a history
rewrite: the tree *and* the history carried the archive category list and an authority
abbreviation, GitHub shows "Actions history and logs" of a repository that becomes public to
everyone, and the commit identities are noreply addresses already - so a fresh history loses
nothing and the old one stays where it is. The full history and every tag live on in the
private repository `personal-os-setup-history`; the local clone reaches it through a remote
named `history`. The decision, with its alternatives, is
[docs/decisions/0016-public-repository.md](docs/decisions/0016-public-repository.md).

The category list left the repository. It was a `ValidateSet` in `add-to-archive.ps1` - eight
German folder names that say what the owner keeps - and it now comes from the personal layer at
run time, like every other personal value (ADR 0004). The repository ships an invented example
instead. The same list is a denylist source for the privacy scan, so a name that comes back is
found in the tree, in the staged changes and in the history.

| What | Why |
|---|---|
| `SECURITY.md` | A public repository needs a way to report a problem |
| `setup/config/repo.yaml` | The state the repository must be in - visibility and security settings - as a value a reader sees and check S tests, instead of the word "private" in the check |
| `setup/lib/personal.ps1` | One reader for the personal layer, and one rule builder (`ConvertTo-TermRule`) for both scans. The archive script carries the same reader, because it also runs in Windows PowerShell 5.1, where `powershell-yaml` is not installed; `tests/PersonalLayer.Tests.ps1` feeds both the same files and requires the same answer. The builder's word boundaries are load-bearing: without them a three-letter folder name matched the same three letters inside `programs` and reported hits in eighty files (measured) |
| `home/.claude/setup/powershell/add-to-archive.ps1` | `-Category` is no longer a `ValidateSet`: it is checked against the personal layer, and the refusal names no category - a log must not learn them either |
| `home/.claude/setup/tests/*.ps1` | Invented fixture names instead of the real categories, the authority abbreviations and the life-area note names |
| `setup/tools/privacy-scan.ps1` | Loads the category list as denylist terms, and matches case-insensitively - the header promised that since the first version, and no call passed `RegexOptions` (measured) |
| `setup/tools/archive-name-scan.ps1` | Reads every folder name under the vault's archive and life-area folders at run time and looks for them in a candidate tree and its commit messages; prints the count and the place of a hit, never a name. In a git tree it judges what git would hand over, so its ignored scratch cannot report a hit for every name there is. Its report counts commits, not the lines of their messages: a one-commit repository with a 32-line body was reported as "32 commit message(s)" (measured 2026-10-15, pinned by a Pester case) |
| `docs/guards.md` | The suite table says 42 cases for `test-add-to-archive.ps1`, the two new ones included (a `-ConfigPath` outside the test folder and a malformed `archive_categories` block are both refused) |
| `setup/tools/verify-all.ps1` | Check 2 became check S (visibility matches `repo.yaml`, settings on) and checks Q, R, U and V joined it: the category list is in no version of the repository, no vault folder name leaks, the Actions settings hold, and the newest CI log carries no personal value |
| `README.md`, `bootstrap.ps1`, `bootstrap.sh`, `macos/Brewfile`, `windows/configuration.winget`, `docs/`, `CLAUDE.md`, `vault/README.md` | The statements that called this repository private are corrected, and the link to a repository that was never public is now a pointer at this one's own README |

## 2.3.7 (2026-10-14) – the PATH regression of 2.3.2, fixed

The tag run of 2.3.2 (38596029049) came back with **five green jobs and one red**: `full-setup
(windows-latest)` stopped the run with `PROBLEM: the live verify reports an unexpected failure:
own-tools - not in PATH: uv, trufflehog`. The cause was the new helper of 2.3.2 itself.

| What | Why |
|---|---|
| `setup/lib/platform.ps1`: `Get-PlatformToolDirs` returns `$dirs.ToArray()` - without the comma | `return , $dirs.ToArray()` hands back ONE value, the array itself. The caller loops over it, and the one element stringified with the output field separator: the runner's log shows `PATH carries C:\Users\runneradmin\.local\bin C:\Users\runneradmin\AppData\Local\Microsoft\WinGet\Links: False (exists: True True)` - one nonsense PATH entry instead of two real ones. So the verify step saw neither folder and reported the programs as missing although the install had just written them. Fixed by dropping the comma (the caller wraps the call in `@()`, which keeps the one-element case an array) |
| `tests/Platforms.Tests.ps1`: `the PATH folders of a machine (Get-PlatformToolDirs)` | Every entry must be a path, not a list of paths, and Windows must hand back two entries where the Unix systems hand back one. Red against 2.3.2 as pushed: `Expected 2, because Windows adds winget's Links folder for the portable-package shims, but got 1`; green after the fix: 21 tests in the file, 0 failed. The nesting was invisible to every other check because it only shows on a machine that reaches the second folder - and only the Windows full-setup job does that |

The closing sentence of the 2.3.2 section ("the tag marks this state: the one whose acceptance
run passes") was written before that tag's own CI run had finished, and it is wrong: for the
state it names, checks I, J, O and 12 were re-measured green one by one, but the **whole**
acceptance run was never repeated - and its Windows CI job did not pass. Corrected here rather
than left standing.

Six tags tell the story of this state, and one of them is a mistake that stays visible - the
section is named after the newest of them, so a reader looking up the current version finds it:

| Tag | Points at | What it marks |
|---|---|---|
| `v2.3.2` | db384de | the three acceptance findings - and the regression this section fixes |
| `v2.3.3` | db384de | **nothing of its own.** The command that created it also ran the commit, the pre-commit privacy scan refused the commit (a twelve-digit job id in a test comment read as a social-security number), and the tag was pushed before that refusal was seen. A pushed tag is not rewritten, so it stays where it is and this line is what a reader finds |
| `v2.3.4` | 274c6b7 | the fix itself |
| `v2.3.5` | 8daf5ef | the fix, with the correction of the 2.3.2 closing sentence and this table - the state whose CI run (38600151914) is green on all three systems, Windows full-setup included |
| `v2.3.6` | 0eca20d | the three documentation corrections of review 21: a pointer that named 2.3.3 while this table names v2.3.4, the sentence "the acceptance run passed for that state on this machine" (only the single checks I, J, O and 12 were ever re-measured for it), and "Three tags tell the story" over a four-row table |
| `v2.3.7` | the commit that carries this section | the same record with this table, the renamed heading and every tag named once |

**The tag run of v2.3.7 is not green, and the code is not the reason.** Run 38603546434 came
back with five jobs green - `checks (ubuntu-latest)`, `checks (windows-latest)`, `macos`,
`full-setup (ubuntu-latest)` and `full-setup (windows-latest)` - and one red:
`full-setup (macos-latest)` was marked failed after seven seconds with **no steps and no
runner**. GitHub's own annotation says why: *"The job was not started because recent account
payments have failed or your spending limit needs to be increased."* A dispatched run for the
same commit (38606914874) failed the same way in all six jobs, and every job of it carries that
annotation. So this is the account's Actions budget, not the repository. The same job on this
code passed twice before: run 38600151914 (v2.3.5) and run 38603383577 (v2.3.6), both with all
six jobs green. The next green run after the account's billing is in order marks this state
with a tag of its own.

## 2.3.2 (2026-10-14) – what the acceptance run found

The full-setup work of 2.3.1 was green in CI on all three systems, and the CI jobs do not run
the acceptance run: `setup/tools/verify-all.ps1` needs a work root, a live profile and this
checkout, so it runs on a real machine. Its run of 2026-10-14 (work root
`C:\Dev\Temp\cross-platform`, 25 of 28 checks green) found three defects in that outer layer.

| What | Why |
|---|---|
| `setup/lib/platform.ps1`: new `Get-PlatformToolDirs`; `setup/tools/ci-full-setup.ps1` asks it for the PATH folders instead of spelling them out | Acceptance check I (no Windows literal outside the Windows module) failed with `1 hit(s) [setup/tools/ci-full-setup.ps1:190 <- env-localappdata]`: the WinGet Links fix of 2.3.1 put a Windows folder name into a file the check reads as part of the engine. The folder belongs in the platform module, which is the one file that may carry one system's answers - and its hit count (22, now 24) stays visible in the check's own output. Red: the acceptance run above; green after the move: `0 hit(s)`, check I PASS |
| `setup/tools/verify-all.ps1` check J: the one intended file change is documented with its reason | The test install renders `home/.claude/life-os/requirements.txt` differently from the v2.1.2 baseline. That file is repo-authored - the manifest marks it `doc-only` and the recursive export excludes it ("it has no live source of its own") - and it carries the three CUDA markers since 2.3.1. Red: `1 changed, 0 added, 0 gone; ... NOT DOCUMENTED: differs: HOME/.claude/life-os/requirements.txt`; green: `1 changed ... 1 documented intended change(s)` |
| `setup/tools/verify-all.ps1` check O: a job may carry the idempotency proof in either of two steps | The new `full-setup` jobs prove the second install changes nothing with their own step (`Full setup on this machine (live install, verify, second install)`, running `ci-full-setup.ps1` on the live machine), and the check demanded the `ci-smoke.ps1` step name in every job - so it reported three problems on a run in which all three full-setup jobs were green. Red proof of the new branch: the same check text, driven against run 38586687140 - where `full-setup (windows-latest)` really failed - reports `full-setup (windows-latest): the idempotency step concluded failure` and FAILs; against the green tag run all six jobs are read and it passes. The step conclusion, not the step name alone, decides |

The tag `v2.3.2` marks this state. All three were found by
`verify-all.ps1` itself, which is the layer the CI jobs cannot cover - and none of them would
have shown up in a green CI. What this state did NOT survive: its own tag run, whose Windows
full-setup job found a regression in the new helper - corrected in the 2.3.7 section below.

## 2.3.1 (2026-10-14) – what the first full-setup run found

The `full-setup` job of 2.3.0 ran the real OS stages on all three systems for the first time
(run 38579290413, commit 823103a). It found three defects in the Windows package stage, one in
the Life OS venv stage and two things a runner cannot do; the ones that are machine limits are
named with their reason from now on, and the job stays red for anything else.

| What | Why |
|---|---|
| `setup/platform/windows.ps1`: `windows/configuration.winget` never goes to `winget import` any more | Measured on the runner: `winget configure` failed, the fallback put the declarative file into the import loop, and `winget import` - which reads JSON - failed on a YAML file for a reason that had nothing to do with the machine. The JSON import lists are the fallback; the declarative file is either configured or reported |
| `setup/platform/windows.ps1`: a failed `winget configure` comes back as WARN with winget's own words and the manual step | The old stage read `$LASTEXITCODE` after the loop had moved on and reported "winget import exit 0" for a step that had failed, after a configure branch that recorded its failure into a variable nothing printed. Measured on the runner: the JSON lists installed all 12 programs, the live verify was green on `winget-core` - so a failing declarative route is a named limitation of the run, not a missing program |
| `tests/Platforms.Tests.ps1`: `the Windows package stage`, driven against a stub `winget` (configure fails, import succeeds - the runner's answers) | The behaviour needs Windows, so the test brings the machine: the stub writes every call into a log, and the two tests state that the declarative file never reaches `winget import` and that a failed configure is a WARN carrying the reason. Red proof against a clone of the previous revision: 13 passed, 2 failed (the log shows `import|...\configuration.winget`, and the status was OK) |
| `install.ps1`: the Life OS venv stage reads pip's exit code; a failed install is a WARN with pip's own words | Measured in the same run on macos-latest: pip printed three ERROR lines ("No matching distribution found for nvidia-cublas-cu12==12.9.2.10") and the stage still reported OK - nobody asked pip how it ended. `tests/Install.Tests.ps1` now holds the shape (red proof in a clone: 9 passed, 2 failed) |
| `home/.claude/life-os/requirements.txt`: the three `nvidia-*-cu12` pins carry `; sys_platform != "darwin"` | They are the CUDA runtime wheels of the venv frozen on Windows, and no such wheel exists for macOS on Apple Silicon; pip stops at the first wheel it cannot find, so the whole venv stayed empty there. Windows and Linux keep them unchanged. Checked with pip's own requirement parser (27 lines, three markers, no non-ASCII byte) |
| `setup/tools/ci-full-setup.ps1`: the `task-life-os-morning` entry is gone; the script prints which PATH entries the runner session is missing and adds them for the verify steps | The entry printed STALE: windows-latest registers the scheduled task WITH its logon trigger (the runner session is elevated), so the reason written into the list was wrong. The PATH part: a CI step inherits the PATH its own process started with, so `~/.local/bin` (the release installs) and on Windows the WinGet Links folder were missing even though a login shell has them - the verify then reported "not in PATH" for programs the install had just written |
| The expectation list is now the two MCP checks, on all three systems | That is what the run left over; everything else a runner cannot do is reported by the stages themselves with their reason |
| `setup/lib/releases.ps1`: `Convert-ReleaseText`; `linux.ps1` and `windows.ps1` read the checksum file through it | Found by the SECOND full-setup run (2026-10-14, run 38584744785) on ubuntu-latest: GitHub serves a checksum file as `application/octet-stream`, `Invoke-WebRequest` hands back a byte array, and the `[string]` parameter of `Find-ReleaseChecksum` refused it - "Cannot convert value to type System.String". The live install ended there: it printed 6 of its 15 stage lines, so nine of them never ran. Reproduced on Windows with the same call: the byte array fails the binding, `Convert-ReleaseText` returns the UTF-8 text |
| `install.ps1`: `Invoke-PlatformStage` wraps the stage call in a try/catch | The same run showed the consequence of not having it: one stage threw and the whole install ended, so the stages after it never ran and the live verify reported only the aftermath (`own-tools - not in PATH`). One stage failing is one ERROR line now; the stage is not journaled as done, so `-Resume` tries it again. `tests/Releases.Tests.ps1` and `tests/Install.Tests.ps1` hold both shapes (red in the clone at a9a7ddd: 19 passed, 4 failed) |
| `macos/Brewfile`: the two `tap` lines are gone; `macos.ps1` reports the lines brew marks as `Error:`/`Warning:` first | Also from the second full-setup run: `brew bundle` exited 1 with exactly one failed dependency, and the live verify said which one - `missing: tap homebrew/bundle`. Every formula and both casks were present, so the tap line itself was the failure, and `brew tap` never lists a default tap (measured: it listed homebrew/cask, not homebrew/bundle). `brew bundle` is built into Homebrew and casks come from the cask API, so neither tap is needed; a third-party tap would stay. The failure detail now prefers brew's own `Error:` line over the last three lines, which named neither the entry nor the reason. `tests/Platforms.Tests.ps1` 'the macOS package stage' (red in the clone at a9a7ddd: 13 passed, 5 failed) |
| The Life OS venv on macOS was green in the second run (`life-os-venv OK`, no pip error line) | That is the measurement for the marker fix above: with the CUDA pins off darwin, pip installs the venv completely there |

The independent review of this state (review 18, `C:\Dev\Temp\cross-platform\review-18.md`)
measured four open HIGH findings; two of them (the macOS tap check, the missing WinGet Links
folder) the commits above already fix, and both are proven green by a real run on all three
systems. The other two and its MEDIUM list are fixed here:

| What | Why |
|---|---|
| `install.ps1`: a failed pip no longer journals the venv stage as done, the stage catches its own throw, and the whisper-model call is checked too | Review 18 measured all three: the manual step's own `-Resume` printed `SKIP from journal` because `Save-Journal` sat outside the if/else (the stage looked done after a failure); a throw in the inline venv stage still ended the whole run (no `Invoke-PlatformStage` wrapper reaches it); and `-WithWhisperModel` reported OK when the model call failed - the same class the pip fix had just closed |
| `setup/verify.ps1`: `life-os-venv` asks the venv for one of its packages (`pip show faster-whisper`) instead of only checking the file | Review 18: a venv whose pip install failed still has its python, so a run could end `INSTALL-OK` and carry an empty venv past a green verify |
| `setup/lib/releases.ps1`: `Get-GitHubApiHeaders`; `linux.ps1` and `windows.ps1` use it, and the `full-setup` job exports `GH_TOKEN: ${{ github.token }}` | Measured on windows-latest (run 38585747962): `own-tools WARN download failed: 403 (rate limit exceeded)` in the first install, while the SECOND install of the same run installed trufflehog fine. Anonymous API calls are limited per IP and a runner shares its address; with a token the limit is per token. Without a token the call stays anonymous, exactly as before, and the value never reaches a report |
| `windows.ps1`: the ERROR detail carries the configure reason next to the import failure | Review 18: on an ERROR the detail named only the import, so the reason the declarative route did not run was lost exactly when the report mattered |
| `tests/Install.Tests.ps1`: the "stage that throws" test now really calls the function (with stubs) instead of grepping the source | Review 18 measured that the text witness stayed GREEN on a copy where the try/catch had been replaced by a comment and dead code - a test that passes on the broken code is worse than none |
| `tests/Platforms.Tests.ps1`: the stub `winget` answers from little files, and two tests cover the branches that had none (an old winget's `not a recognized command`, and a JSON import that really fails) | Review 18 (M3): the branch that separates OK from WARN had no test at all, and the stub could only play one answer |

Red proof for all of it in one run: the three test files against a clone at a9a7ddd give
**34 passed, 10 failed** (`logs/red-review-fixes.log`), and green here - `check.ps1` with
72 Pester tests, `CHECK-OK`.

Two corrections the review is right about, kept visible instead of quietly fixed:
**no tag v2.3.0** - that state was never green on a real machine (its own CI run was red), so it
stays a CHANGELOG section and the tag `v2.3.1` marks the state that is proven; and the red/green
logs of this task were taken with Pester 6.2.0 (the version installed here) while the repo pins
5.9.1 - the reviewer re-ran every one of them under the pinned version and confirmed them.

## 2.3.0 (2026-10-14) – the real setup runs in CI

The OS stages (package source, scheduled job, sync service, backup tool) had never been
exercised anywhere: `ci-smoke.ps1` installs into an empty `-TargetRoot`, and a target install
only renders PREVIEW files for them. A new CI job runs the installer WITHOUT `-TargetRoot` on a
machine nobody owns, so these stages run for real for the first time – and everything that
cannot work there is named with its reason instead of being left out.

| What | Why |
|---|---|
| `setup/tools/ci-full-setup.ps1` (new) and the `full-setup` job in `.github/workflows/ci.yml` (weekly, on tags, by hand; windows-latest, ubuntu-latest, macos-latest) | It runs `install.ps1` live, then `verify.ps1` twice (files only, then the whole machine) and a second live install that must report `new 0, replaced 0`. It refuses to run without `CI=1`: on a real machine this would change live files, which the acceptance run forbids |
| The runner script names, per system, every check a machine nobody has logged into cannot satisfy (no person for the sign-ins, an unelevated Windows session, no GUI session for launchd, no Claude Code) – and each entry must also match the TEXT of that check | A skip that is only a name would swallow a real failure. A failure with different words still turns the job red, and an entry that stops firing is printed as STALE, so the list cannot quietly drift away from the machine |
| The script writes its own `personal.yaml` with vault and dev inside the runner's home | `Get-PlatformRoots` uses `vault_path`/`dev_root` verbatim, so the test fixture's `C:\vault-dummy` would become a folder of that name inside the checkout on Linux. The vault and Dev locations are the person's decision (D4) – on a runner there is no person, so the throw-away paths stay inside the throw-away account |
| `setup/platform/macos.ps1`: `Get-MacosLaunchAgentLabel`; install and verify ask for the label through it | A live `verify.ps1` on macOS could never be green: the install stage writes and loads `com.personal-os.life-os-morning.plist`, while the verify check handed launchctl the manifest's `name` ("Life OS Morning"). Measured in a clone of the previous revision: the repository has `macos/launchagents/com.personal-os.life-os-morning.plist.tmpl` and no `Life OS Morning.plist.tmpl`. Found by building the job above – it is the first thing that runs a live verify on macOS |
| `setup/tools/verify-all.ps1`: `-WorkRoot` is the caller's folder; the acceptance line requires that the folder EXISTS and lies OUTSIDE the repository it certifies | One work root per task instead of one for all of them, so the report, the fingerprint pair and the reviews of a task live in that task's folder. The old pin on the literal default came from review 7 (a caller's folder certified itself); the new clause keeps what is objective – evidence inside the tree under test is refused, and the run prints the work root its evidence came from. The default stays `C:\Dev\Temp\folder-structure` |
| `setup/tools/verify-all.ps1`: check I reads `setup/tools/ci-full-setup.ps1` too | The file list of that check is an enumeration, and the new runner script – which runs on all three systems – was not in it. Red proof: a seeded Windows drive path in the file makes the check report `1 hit(s) [setup/tools/ci-full-setup.ps1:2 <- drive-back]` and fail; without it, 26 files, 0 hits |
| `tests/Platforms.Tests.ps1`: the launch agent label IS the file name of its template, and both stages ask for it through the one function | The two tests state the invariant that was broken and a witness for the shape (`$Context['TaskName']` was the manifest name, never the launchd label). Red proof against a clone of the previous revision carrying the new tests: 11 passed, 2 failed |
| `setup/lib/releases.ps1` (new): the value in a package file is the END of the asset name, the checksum comes from `<asset>.sha256` or from a `checksums.txt`, a release with neither is not installed, and `strip_components` says how many path parts an archive carries | The first full-setup run (2026-10-14) found this on both systems that have a release install. Linux: "trufflehog: linux_amd64.tar.gz is not part of release v3.99.2" - the release names its asset `trufflehog_3.99.2_linux_amd64.tar.gz`, the old exact comparison found nothing, and the live verify then failed on "not in PATH: uv, trufflehog". Windows: the same stage looked for `windows_amd64.zip` while the release publishes `..._windows_amd64.tar.gz` (which carries `trufflehog.exe` at the top level; unpacked with `tar.exe`, shipped since Windows build 17063). `tests/Releases.Tests.ps1` holds the rules against the recorded asset lists of both releases, without network; red proof: 5 of 10 tests fail with the old logic seeded into a clone |
| `linux/packages.yaml`: `uv` as a release (asset suffix, `binary: uv`, `strip_components: 1`) | The live verify wants `uv` in PATH and `linux.ps1` claimed it came from this file, which did not name it. `uv` has no distribution package (measured 2026-10-14: not in apt on Ubuntu 24.04/26.04; Debian's packaging is still in progress, astral-sh/uv issue 13640). Its archive packs `uv` and `uvx` into `uv-x86_64-unknown-linux-gnu/` |
| `setup/platform/macos.ps1`: `Test-PackageStage` asks `brew tap` about the Brewfile's `tap` lines | The live verify reported `missing: homebrew/bundle, homebrew/cask` - those are taps, and `brew leaves` can never list a tap, so it counted its own Brewfile as missing packages. A live verify on a real Mac could not be green either |
| `macos.ps1`, `linux.ps1`, `windows.ps1`: a failing package step names the decisive lines of its own output in the report (`brew bundle`, `flatpak install`, `winget configure`/`winget import`) | The first run reported only "brew bundle exit 1 - see the transcript" and "install the Flatpak apps by hand" - and a transcript is written on the machine that ran the install, which nobody can read afterwards on a CI machine. A failure that names no reason cannot be fixed |
| `setup/tools/ci-full-setup.ps1`: the per-system expectation list shrank to the two MCP checks | The first run measured that `systemctl --user enable --now personal-os-morning.timer` (ubuntu-latest) and `launchctl bootstrap gui/<uid>` (macos-latest) both work for the runner user, so both entries printed STALE - which is what that word is for. The list also now prints whether the runner's PATH carries `~/.local/bin`, where the release installs put their programs (a real machine gets that from its shell profile, not from a CI step) |

## 2.2.3 (2026-10-14) – the witness also guards the shell script

| What | Why |
|---|---|
| `tests/LineEndings.Tests.ps1` fails when a tracked `*.sh` file carries CRLF | `* -text` (2.2.1) also dropped the old `*.sh text eol=lf` rule, and no check missed it: the independent review measured that `bash -n` exits 0 on a CRLF copy of `bootstrap.sh`, so the syntax check would not catch it either. A shell script with CRLF ends its shebang line with a carriage return and fails on macOS and Linux. `bootstrap.sh` is LF today (`git ls-files --eol`: `i/lf w/lf`); the new test keeps it that way |
| Two numbers in the 2.2.1 entry corrected | The review re-measured them and was right: the old attributes made 283 attribute lines convert, not 132 (`git check-attr text eol` over all 220 tracked files; every file carried at least one), and 76 files are CRLF in the working tree, not 77 (the commit 0569796 changed 77 files including `.gitattributes`). Both re-measured here before writing them down |

## 2.2.2 (2026-10-14) – the start check finds its own shell

| What | Why |
|---|---|
| `setup/tools/verify-all.ps1`: check M looks for bash on the PATH first and then in the documented Git-for-Windows locations (`%ProgramFiles%\Git\bin`, `%ProgramFiles%\Git\usr\bin`, `%ProgramFiles(x86)%\...`, `%LOCALAPPDATA%\Programs\Git\bin`), and prints the resolved path | Measured 2026-10-14: `pwsh -File verify-all.ps1` from a plain PowerShell window made check M fail with "no bash found" although bootstrap.sh is perfectly fine - Git for Windows puts `git.exe` into `Git\cmd` (which its installer adds to the PATH) and bash only into `Git\bin` and `Git\usr\bin` (which it does not). A check that passes only where the caller's PATH happens to carry bash guards nothing. The shim rule stays: a bash resolving into the work root, into Temp or into the repository is refused, and when nothing is found the check still fails (proven on a seeded copy) |

## 2.2.1 (2026-10-14) – A checkout is the working tree

Found by the independent review of 2.2.0 (finding F5) and fixed the same day.

| What | Why |
|---|---|
| `.gitattributes`: `* -text` replaces `* text=auto`, `*.ps1 text eol=crlf`, `*.sh text eol=lf`, `*.bat text eol=crlf`; the 76 files that are CRLF in the working tree are stored that way again (the working tree itself does not change; the commit changed 77 files, `.gitattributes` among them) | The rules promised CRLF for `*.ps1` while the working tree carries LF for 113 of the 132 mirrored files, so `git clone` and `git archive` produced other bytes than this tree and acceptance check J called 113 files changed that differ in line endings alone - on the route the rules prescribe for red proofs and the README for a new machine. Measured on a clone of the same revision: before `113 changed, 0 added, 0 gone`, after `0 changed, 0 added, 0 gone`. `-text` means git never converts, so a copy of this repository is byte-identical to the tree it was committed from, on every system |

## 2.2.0 (2026-10-14) – One system, three operating systems

Windows, macOS and Linux from the same repository. The Windows behaviour is unchanged: a test
install is byte-identical to the v2.1.2 one (acceptance check J), and the live machine is
untouched.

| What | Why |
|---|---|
| `setup/platforms.yaml` – every manifest component mapped to `windows`, `macos` and `linux`, with a mandatory reason where it does not exist there | Decision D3. One file answers where a component lives and how it is installed; the engine reads it and never guesses (check H) |
| `setup/lib/platform.ps1` – detects the system (`Get-PlatformId`) and answers the platform half of the placeholder vocabulary; `setup/platform/windows.ps1`, `macos.ps1`, `linux.ps1` hold the stage verbs (`Invoke-PackageStage`, `Invoke-SchedulerStage`, `Invoke-SyncStage`, `Get-BackupStage`, `Invoke-OwnToolsStage`, `Invoke-OsExtrasStage`) | Decision D2. No file of the portable engine branches on the operating system any more; the three platform modules are the only allowed home of its literals (check I) |
| New placeholders `{{PWSH_HOST}}`, `{{PWSH_EXE}}`, `{{PWSH_PATH}}`, `{{HOME_ENV}}`, `{{HOME_CMD}}`, `{{TEMP_ENV}}`, `{{TMP_ENV}}`, `{{LIFEOS_*}}`, `{{KOPIA_*}}`, `{{OBSIDIAN_APP}}`; `export.ps1` pairs the live text with the token, `install.ps1` renders it back per system | The mirror stays byte-comparable with the live system AND becomes portable: on Windows every pair is its own inverse, so no live file changes. The platform pairs are replaced case-sensitively (`-creplace`) because `%userprofile%` inside a guard's detection regex is not `%USERPROFILE%` |
| `windows/configuration.winget` (WinGet Configuration) is now the declarative package route, with `windows/winget-*.json` kept as the fallback for a winGet older than 1.6.2631 | Decision D5. Declarative and idempotent; `tests/Platforms.Tests.ps1` keeps both files naming the same programs. The second administrator run does NOT disappear – Microsoft's own example gives every package resource `securityContext: elevated` |
| `macos/Brewfile` and `linux/packages.yaml` (apt and dnf names, the Kopia repositories, Flatpak for Obsidian, trufflehog from its GitHub release with the SHA256 checked) | Decision D5. Every name was checked against the distribution's own index on 2026-10-14; three names deliberately are not in the lists because they do not exist there |
| `bootstrap.ps1` and `bootstrap.sh` in the repo root, README section "Start from zero" | Decision D12 and G2: one documented start command per system. The bootstrap installs git, gh and PowerShell 7 with the native package manager, lets the person sign in, clones the repository and hands over to `install.ps1` |
| The scheduled morning job: Task Scheduler (unchanged), `macos/launchagents/*.plist.tmpl` with `RunAtLoad` + `StartCalendarInterval`, `linux/systemd/*.service.tmpl` + `*.timer.tmpl` with `Persistent=true` and `OnStartupSec` | Decision D6. Missed runs are caught up on all three: `StartWhenAvailable`, launchd's calendar catch-up, `Persistent=true` |
| Sync and backup as engine stages: SyncTrayzor (Windows), `brew services start syncthing` (macOS), `systemctl --user enable --now syncthing.service` (Linux); Kopia/KopiaUI from the package source on all three, with the repository connection and its password left to the person | Decisions D7 and D8 |
| `home/.claude/hooks/*` and `home/.claude/settings.json` render their PowerShell host and the home variable per system; the live Windows files stay byte-identical (the hook command stays `powershell.exe`, rendered from `{{PWSH_HOST}}`) | Decisions D10 and G6. The exec form is what matters: no default shell decides. Changing the live wiring would break the unchanged-Windows rule, so the host is a rendered value instead of a rewrite |
| `setup/tools/install-fingerprint.ps1` and `tests/fixtures/install-baseline-v2.1.2.json` | The v2.1.2 install, recorded before the first line of this work: 132 files, paths and dates normalised. Acceptance check J compares against it |
| `setup/tools/ci-smoke.ps1`; the CI matrix now runs `windows-latest` and `ubuntu-latest` on every push and `macos-latest` on tags, the weekly schedule and manual dispatch; `shellcheck` and `bash -n` check `bootstrap.sh` | Decisions G7 and the macOS minute cost. Every job runs the smoke step first and prints `IDEMPOTENT-OK`; acceptance check O reads the conclusion of that step out of the run's JSON, and check N wants the newest run to carry both matrix jobs and a macOS job that really ran |
| `macos/`, `linux/` mirror folders; `docs/platforms.md` | The tree grew by the two folders the platform map points at |
| `docs/decisions/0015-portable-engine-instead-of-chezmoi.md` | Decision D1: keep the engine, with the reasoning, the compared options and the triggers that would change the answer |
| `AGENTS.md` gains the section "Platform first"; `CLAUDE.md` starts with `@AGENTS.md` | Decisions D11 and G5: one shared file for every agent, and the six rules an agent must follow before it installs anything |
| The acceptance run `setup/tools/verify-all.ps1` grew checks H to O: the platform map is complete for all three systems AND every file it promises exists, the portable engine carries no Windows literals, a Windows test install is byte-identical to v2.1.2, the hooks are in exec form with the right host, `AGENTS.md` and `docs/platforms.md` agree with the manifest, the two bootstrap files are there and executable, and the newest CI run carries the two matrix jobs and the smoke step | Every new part needs a check that fails without it, or it is a promise without a witness. H, I and J were proven red on a seeded copy first (AGENTS.md, rule 3) |
| `home/.config/powershell/profile.ps1` — the pwsh profile for macOS and Linux — and `Test-RepoContentPresent` in `setup/lib/manifest.ps1` | The platform map promised that file and nobody had written it; on Windows nobody noticed, because the component is `unsupported` there and the file stage skipped it before it looked. The schema now refuses any component whose content is missing in the repo, on every system, and check H asks per system |
| `setup/verify.ps1` accepts the package preview under the name the system writes (`winget-packages.txt`, `brew-bundle.txt`, `linux-packages.txt`) | It asked for the Windows name on all three systems and called a preview that was there "missing" |
| `setup/tools/ci-smoke.ps1` prints the failing step's output to the job log | It was collected into the function's return value, so the ubuntu job showed one truncated exception line and the cause had to be reproduced by hand |
| `docs/install-with-an-agent.md`, `docs/troubleshooting.md` and the README section "After install" answer per system | They said "Windows machine" while the kit installs on three, and named admin rights, packages and first starts as if there were only one answer |

## 2.1.2 (2026-10-13) – Empty folders come from the manifest

| What | Why |
|---|---|
| New component `dev-dirs` (`DEV`, `DEV/Projects`, `DEV/Temp`); two new `vault-dirs` entries (`VAULT/000-meta/todo-archive`, `VAULT/500-sources/research`) | A fresh PC must get the same folder structure the machine has today. The list was measured against the live system first; only structure and work folders were taken - folders that programs create, content shelves and folders with private names stay out on purpose (the measured full lists live in the acceptance work folder) |
| The 13 `.gitkeep` placeholder files left `vault/`; the manifest schema now allows the bare root token (`DEV`); `Get-TargetPathFor` in `install.ps1` and `setup/verify.ps1` resolves a root-only entry | One mechanism instead of two: the manifest defines the folders - no marker file fakes them. `.gitkeep` was never installed anyway; git keeps the files in the history |
| `tests/Structure.Tests.ps1`: a proof that installs into a test sandbox and asserts every `dirs:` entry exists there, plus the rule that no placeholder file (`.gitkeep`, `.keep`, `.placeholder`) lives in a mirror; `tests/Manifest.Tests.ps1` drops the old "every dir entry carries a file" rule; the broken fixture seeds a foreign root (`XX/example`) that must stay rejected | The old test kept manifest and marker together; the new one proves the manifest alone carries the folders - and that the schema still rejects what it should |
| `docs/structure.md` names which folders arise via `dirs:` and why | The written form of the structure, without the marker detour |

## 2.1.1 (2026-10-13) – The round trip holds on every day

| What | Why |
|---|---|
| `vault/000-meta/backup.md` carries a fixed date instead of `{{INSTALL_DATE}}`; the manifest entry `vault-meta-backup-doc` lost its `INSTALL_DATE` pair; the journal-date machinery left `setup/export.ps1` | A partial install run (`install.ps1 -Components` - the 2.1.0 admin step did exactly that) stamps a new INSTALL_DATE into the journal without re-rendering every file; the export could then not reverse the date in the live file and reported it changed - `drift-check.ps1` went red for real on 2026-10-13 |
| New test in `tests/Roundtrip.Tests.ps1`: no file the export mirrors may carry a render-time placeholder (`{{INSTALL_DATE}}`, `{{USER_SID}}`, `{{START_BOUNDARY}}`); the byte-for-byte round trip renders with a fixed old date instead of today | The round trip must hold on every day, not only on the day the live file was rendered - with today's date the test would have failed on any later day |
| `docs/decisions/0003-placeholders.md` addendum | The rule in the decision record: render-time placeholders live only in install-once skeletons, which the export never mirrors |

## 2.1.0 (2026-10-12) – Final folder layout

| What | Why |
|---|---|
| Root reduced to 8 folders and 8 files; `install.ps1` is the only entry point | A visitor should see in ten seconds what this is and what to run |
| `targets/HOME` → `home/`, `targets/DOCUMENTS` → `home/Documents/`, `targets/VAULT` → `vault/`, `targets/DEV` → `dev/` | The mirror folders are named after where they install to |
| `export.ps1`, `verify.ps1`, `restore.ps1`, `manifest.yaml`, `config/`, `tools/`, `lib/`, `githooks/` → `setup/` | One home for the tooling instead of three places for scripts |
| `winget/` + `scheduled-tasks/` → `windows/` | Machine setup that is configured, not copied, in one folder |
| `sandbox/` → `tests/sandbox/`, `docs/adr/` → `docs/decisions/`, `docs/phone.md` → `docs/phone-setup.md`, `AGENT-INSTALL.md` → `docs/install-with-an-agent.md` | One place per kind of document |
| The two naming rules (repo folder per target root, dot-stored names) now live only in `setup/lib/manifest.ps1`; `store_as: "gitignore"` entries are gone | One rule applied everywhere, instead of a field that a new entry can forget |
| `morgen.ps1` → `morning.ps1`, `aufraeumen.ps1` → `cleanup.ps1`, `life-os-morgen` → `life-os-morning`, task "Life OS Morgen" → "Life OS Morning" | The repo is English; the installed names follow so live system and repo stay identical |
| `life-os/requirements-life-os.txt` → `home/.claude/life-os/requirements.txt` | Next to the code that needs it |
| `vault/000-meta/{index,log,todo}.md` → `*.md.tmpl`, emptied | Working notes became starter templates (skeleton rule) |
| Removed from the repo: `000-meta/auftraege/`, `000-meta/{agent-tooling,verified-assumptions,folder-sorting,graph-health}.md`, two research results under `setup/tests/research/notes-10-3/`, `vault/000-meta/backup.md` reduced to rule text | The repo installs a system, not the owner's data |
| `VERSION` dropped, `.export-state.json` → `%USERPROFILE%\.personal-os\state\` | The version comes from the tag and this file; run state is local, not content |
| New checks: `check-structure.ps1`, `check-language.ps1`, `Structure.Tests.ps1`, `Format-Strings.Tests.ps1` (every `-f` template standing in the source has to parse — a `{0,>2}` made the acceptance run unrunnable while CI stayed green), and `verify-all.ps1` points A–H (H is a live dry run of `install.ps1`: a helper only the live path calls had been missing for months without any check noticing) | The layout, the skeleton rule, the language and the format strings stay true by themselves |
| Independent review rounds over the finished state, repeated until a round found nothing at the top two levels (the round-by-round record stands in `PROGRESS.md`); every finding fixed and re-measured, each fix proved red on a seeded defect first. What they found: the acceptance run itself could not run (`{0,>2}`), check 3 called trufflehog with a URL it cannot use, check C knew neither the Windows form of a path nor ignored files, check 7 accepted any workflow, check B could not see an untracked file, check 1 accepted open work under another marker, check 10 counted hook files instead of the hooks the settings name, check 11 read the wrong verdict line of a review file, check 10 and `check.ps1` shared one render folder; later rounds closed every route to the acceptance line itself (a foreign work root and repo root, a redirected USERPROFILE, a clone of the repository, tools answering from PATH), round 10 found the torn vault history that the history row below records as repaired, and the rounds after the repair confirmed it | A check that can pass while the thing it claims is broken is worse than no check: the acceptance run is the only thing that says "done", so it is the thing that has to be attacked hardest |
| Repository history: the vault mirror's move (`targets/VAULT` → `vault/`) is recorded as a rename; the two move commits were rebuilt so that the first keeps the old vault subtree and the second records the rename - every other commit tree, and the end state, are byte-identical to the original history (the pre-repair commits stay reachable on the branch `rescue/pre-history-repair`) | The task's rule is `git mv`, so every file keeps its history; the first attempt had recorded the vault move as a delete plus an add, which `--follow` cannot bridge - acceptance check D measured it red until the repair |
| `docs/decisions/0014-final-layout.md` | The layout, the naming rules and the skeleton rule in one record |

## 2.0.0 (2026-10-11) – First complete version

| What | Why |
|---|---|
| Manifest, export, install, verify, restore, scanner, CI | The system should become reproducible from one source instead of from printed instructions |
| Guards copyable (hooks + suites from `claude-config`) | The system's check culture travels along |
| Vault skeleton, Life OS, backup and sync templates | Everything non-programmatic of the system is described |
| Personal values in `~/.personal-os/personal.yaml`, denylist local | Nothing personal in the repo, not even in the history |
