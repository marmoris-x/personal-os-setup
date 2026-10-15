---
paths:
  - "**/*.{ps1,psm1,psd1,bat,cmd}"
---

# PowerShell and batch files

## Encoding - the trap that bites hardest

- Windows PowerShell 5.1 reads a `.ps1` file **without a BOM** in the ANSI code page, not as
  UTF-8. An umlaut or a typographic dash then either shows as garbage or breaks the parser.
  Keep script files ASCII-only, or write them with a BOM.
- The same applies to output: `Get-Content` and `Set-Content` in 5.1 write ANSI by default.
  For text files use `[IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))`
  or `-Encoding utf8` deliberately, and know which one you are getting.
- Never rewrite a file through `Get-Content | Set-Content` when it contains non-ASCII text.
  Change it with an editor or a proper file API.

## Version differences (5.1 against 7)

- `&&` and `||` do not exist in 5.1. Chain with `;`, or use `if ($LASTEXITCODE -ne 0)`.
- `curl` is an alias for `Invoke-WebRequest` in 5.1. Write `curl.exe` to mean the real tool.
- `Get-ChildItem -Depth`, `??`, `?.` and ternary `? :` need PowerShell 7.
- `ConvertFrom-Json -AsHashtable` needs 7. In 5.1 you get `PSCustomObject`.
- Check with `$PSVersionTable.PSVersion` before relying on any of these.

## Error handling

- Set `$ErrorActionPreference = 'Stop'` in a script that must not continue after a failure.
  The default, `Continue`, walks past errors and the script "succeeds" with wrong results.
- A native program's exit code does **not** raise an error. Check `$LASTEXITCODE` yourself.
- With `$ErrorActionPreference = 'Stop'`, a native program writing to stderr becomes a
  terminating error in 5.1. Wrap such calls with a relaxed preference if stderr is expected.
- `-ErrorAction SilentlyContinue` hides the error but the cmdlet still counts as failed and
  the exit code stays non-zero. To really ignore one, use `try { ... -ErrorAction Stop } catch { }`.
- A cmdlet can report a failure **without throwing**, and `$ErrorActionPreference = 'Stop'` does
  not always turn it into a terminating error. Measured 2026-10-12: `Register-ScheduledTask`
  printed "the task XML is invalid" to the host and returned normally, so the script logged
  "registered" for a task that was never created. After a call that can fail quietly, ask the
  system what happened (`Get-ScheduledTask`, `Test-Path`, a read-back) instead of trusting that
  no exception means success. `-ErrorAction Stop` on that call is necessary but not sufficient.
- `Register-ScheduledTask -Xml` takes a **string**, not a file. A leading
  `<?xml version="1.0" encoding="UTF-8"?>` then lies about the encoding of the .NET string and
  the call is refused with `(1,40)::ERROR: the encoding cannot be changed`. Drop the declaration
  (XML 1.0 makes it optional) or pass the content of a file you wrote yourself.
- A task with a **logon trigger** can only be registered by an administrator ("access denied",
  measured with the same XML that registers fine without the trigger). Anything that registers
  such a task needs a stated fallback and an honest report, not a silent downgrade.

## Writing scripts an agent runs

- Never `Read-Host`, `pause`, `Get-Credential` or `Out-GridView` in a script that runs
  unattended. Add `-Confirm:$false` where a cmdlet would ask.
- Accept parameters with a `param()` block instead of hard-coded paths, so the script is
  testable and cannot silently act on the wrong folder.
- Use `-LiteralPath` when a path may contain `[`, `]` or `*`. `-Path` treats those as
  wildcards and can hit several files at once.
- Never assign to an automatic variable: `$home`, `$pwd`, `$args`, `$input`, `$host`, `$pid`
  are read-only or reserved. A fail-closed hook that does so crashes on every call and locks
  the agent out of its own tools. Before a new hook is registered for all tools, run it once
  by hand with a harmless call and check the exit code.
- A function that returns an array of one element hands back the element, not the array
  (`return , $parts` keeps it). Test every helper with exactly one result.
- A helper that returns nothing still counts as one element inside `@(...)`: `@($null).Count`
  is 1, so a counter built as `@(Get-Hits ...).Count` is never 0 and the check it drives never
  fails. Return a plain number (`[int]`) from counting helpers.
- The comma operator binds **tighter** than `+`: `@($i, $i + $n)` builds `($i, $i)` and then
  appends `$n`. Write `@($i, ($i + $n))` - the parentheses are load-bearing.
- Inside a **method call**, an operator without parentheses splits the arguments: `$list.Add($s -replace 'a','b')` throws "no overload for method Add with 2 arguments". Write `$list.Add(($s -replace 'a','b'))` - the same care the comma rule above asks for.
- A composite format string (`'{0,2}' -f $x`) accepts `{index,alignment}` with a **digit**
  alignment. `'{0,>2}'` - a habit from other languages - throws "Input string was not in a
  correct format" at the first call, so a script that carries one dies on its first output line.
- A script that no check runs is unverified, however often it is edited: run it to its last
  line once before a task is called finished. A test that parses every `-f` template in a repo
  (`[string]::Format` with dummy arguments, one per index) turns that class of defect into a red
  test instead of a silent dead script.
- A test fixture placed inside a repository - a seeded file for a red proof - is visible to
  everyone else working there at that moment. When another checker or agent may run in the same
  minutes, put the proof in a scratch clone and point the script at it, or the foreign file
  becomes its failure.
- A Windows path handed to `pwsh` **through the Bash tool** loses its backslashes unless it is
  single-quoted: `-WorkDir {{DEV}}\Temp\x` arrives as `C:DevTempx`. PowerShell then reads that as
  a **drive-relative** path and writes the folder into the current directory on `C:` - measured
  2026-10-12, twice in one task: check.ps1 rendered its tree into `DevTempfolder-structure.../`
  inside the repository and the acceptance run's check B then reported a stray entry. Write such
  a path with forward slashes (`{{DEV_FWD}}/Temp/x`), or in single quotes, or pass it in an
  environment variable.

## Batch files

- `%VAR%` is expanded when the line is read, not when it runs. Inside a loop that needs the
  current value, use `setlocal enabledelayedexpansion` and `!VAR!`.
- `if` compares strings by default and is whitespace-sensitive: `if "%1"=="x"` needs the
  quotes on both sides, or an empty argument is a syntax error.
- A `.bat` or `.cmd` file is always started through a shell. A path with spaces needs quotes,
  and `&`, `^` and `|` in an argument change the command.
- Batch has no real error handling. Check `if errorlevel 1` after every command that matters,
  and `exit /b <code>` to pass the result on.
