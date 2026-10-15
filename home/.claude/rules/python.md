---
paths:
  - "**/*.{py,pyi,ipynb}"
---

# Python

## Correctness

- A default argument is evaluated once, when the function is defined. `def add(x, items=[])`
  shares one list across every call. Use `None` and build the value inside.
- `is` compares identity, `==` compares value. `is` is right only for `None`, `True`, `False`
  and sentinels; `x is 5` may be false even when `x == 5`.
- Mutable objects as dictionary keys or in sets raise `TypeError` - use a tuple.
- Integer division is `//`, not `/`. `/` always returns a float, which is wrong for counts.
- `except Exception:` without a re-raise hides real failures. Catch what you can handle, and
  let the rest crash loudly.

## Security

- Never `eval` or `exec` on input. For data that looks like Python, use `ast.literal_eval`; for
  data from outside, use `json`.
- `pickle` runs code while loading, so an untrusted pickle file is an untrusted program. The
  same goes for `yaml.load` - use `yaml.safe_load`.
- `subprocess` with `shell=True` sends the whole string to a shell. Pass a list of arguments
  and leave `shell=False`. On Windows a `.bat` or `.cmd` file is started through `cmd.exe`
  anyway, and neither `shell=False` nor `shell=True` protects the arguments reliably: measured on
  this PC (Python 3.12 and 3.13, 2026-09-30), `x&echo` and `x|echo` ran a second command in both
  modes and `%VAR%` was expanded; only an argument containing a space was quoted and stayed
  literal. So never pass input to a `.bat` or `.cmd` file; if it must be, allow
  only a short list of safe characters (letters, digits, `.`, `_`, `-`) and reject the rest.
- SQL: use the driver's parameters (`cursor.execute(sql, params)`), never `%` or f-strings.
- `requests` without a timeout waits forever. Always pass `timeout=`.

## Conventions of this setup

- One virtual environment per project. Never install into the system Python.
- On this machine `py -3` is Python 3.13. `py -3 -m pip install <package>` installs for it.
  Several Pythons are registered side by side (`py -0p` lists them; an entry can point to a
  folder that is gone), so the pin matters: a bare `py` follows the user variable `PY_PYTHON`,
  but `py -3` follows `PY_PYTHON3`. Set both to an installed version, or `py -3` can pick a
  different version than `py`, or fail with "No suitable Python runtime found".
- For reproducible installs, pin versions in `requirements.txt`. `pip install --require-hashes`
  is the strict form and needs a hash for every dependency.
- Check the name on PyPI before installing. A near-miss spelling is the common attack.

## Common traps

- Reading a text file without `encoding="utf-8"` uses the system default, which on Windows is
  not UTF-8. Umlauts and accents break. Always pass the encoding explicitly.
- A `for` loop over a list you are also modifying skips elements. Iterate over a copy:
  `for x in list(items)`.
- `open()` without `with` leaves the file open when an exception happens. Use `with`.
- `datetime.now()` is local and naive. Use `datetime.now(timezone.utc)` when the value leaves
  the machine or gets compared across machines.
- Importing a module runs the whole file. Code that should only run as a program belongs under
  `if __name__ == "__main__":`.
