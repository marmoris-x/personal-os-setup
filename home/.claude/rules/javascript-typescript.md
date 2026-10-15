---
paths:
  - "**/*.{js,jsx,mjs,cjs,ts,tsx,mts,cts}"
---

# JavaScript and TypeScript

## Correctness

- Use `===` and `!==`. `==` converts types first, so `"1" == 1` is true and `[] == false` is
  true. The one accepted exception is `x == null`, which also catches `undefined`.
- `await` inside a loop runs one after the other. When the calls are independent, collect them
  and use `Promise.all` - otherwise 20 requests take 20 round trips.
- An unhandled promise rejection ends the process on current Node versions. Every `async`
  call needs an `await`, a `.catch`, or a deliberate reason not to care.
- `JSON.parse` on anything that came from outside gives you `any`. Check the fields you use
  before you use them; a missing field is `undefined`, not an error.
- In TypeScript, `as` and `!` silence the compiler without making the value safe. If a type
  error looks wrong, the type is usually right and the code is not.
- Numbers: `0.1 + 0.2` is not `0.3`. Compare money and measurements with a tolerance, or work
  in whole cents.

## Security

- Never `eval`, `new Function` or `setTimeout` with a string, and never with input. They run
  whatever they are given.
- `child_process.exec` runs the string through a shell, so a `;` or a backtick in the input
  becomes a second command. Use `execFile` or `spawn` with an argument list, and never build
  the command by joining strings.
- `server.listen(port)` without a host binds to every network interface. For local work that
  means anyone on the same network can reach it. Pass `"127.0.0.1"`.
- Never put a key in front-end code or in an environment variable that starts with `NEXT_PUBLIC_`
  or `VITE_`. Everything the browser gets is public.
- Read `process.env` values as strings and validate them at start-up, not at first use.

## Conventions of this setup

- With a lock file present, install with `npm ci`. It installs exactly what the lock file says
  and never rewrites it; `npm install` may.
- A check command lives in `package.json` under `scripts` (usually `check`, `lint`, `test`).
  Run it before saying a change is done.
- Do not commit `node_modules`, `dist` or `.next`.

## Common traps

- `for...in` walks inherited properties. Use `Object.keys`, `for...of` or `Object.entries`.
- `this` in a plain function depends on how it is called. Arrow functions take it from the
  surrounding scope - usually what you want in a callback.
- `Array.sort()` converts to strings by default, so `[10, 9].sort()` is `[10, 9]`. Pass a
  comparison function.
- Date handling: `new Date("2026-09-28")` is parsed as UTC midnight, so in a timezone behind
  UTC the local date is the day before.
