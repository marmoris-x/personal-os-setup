---
paths:
  - "**/*.{cs,csproj,sln,razor,xaml}"
---

# C# and .NET

## Correctness

- `async void` cannot be awaited and its exceptions crash the process instead of reaching the
  caller. Use `async Task`. The only accepted place for `async void` is an event handler.
- Return `Task` from async methods, and await every one of them. A forgotten await runs the
  work in the background and the error surfaces somewhere unrelated.
- Dispose anything that implements `IDisposable` - files, streams, connections, `HttpClient`
  responses. `using var x = ...` is the short form and covers exceptions too.
- Do not create a new `HttpClient` per request. Sockets stay open and the process runs out.
  Use `IHttpClientFactory`, or one static instance.
- `==` on strings compares the text, which is fine in C# - but `ReferenceEquals` and
  `string.Intern` surprises are not. For anything culture-dependent (sorting, upper-casing,
  comparing user text), pass `StringComparison.Ordinal` or `OrdinalIgnoreCase` explicitly.
- Build long strings in a loop with `StringBuilder`. `+=` copies the whole string every time.

## Security

- Never build SQL by joining strings or interpolating. Use parameters
  (`cmd.Parameters.AddWithValue`) or an ORM.
- Never `Process.Start` with a string that contains input. Pass a `ProcessStartInfo` with
  `ArgumentList`, or use `ProcessStartInfo.ArgumentList.Add`.
- `BinaryFormatter` is removed and unsafe. For data, use `System.Text.Json`.
- Never log a connection string, a token or a password. Log the fact that one was used.
- Validate input at the boundary with a model and its attributes, not somewhere in the middle.

## Conventions of this setup

- Restore and build with `dotnet restore` and `dotnet build`. Never edit `obj/` or `bin/` by
  hand - they are generated and are overwritten.
- A check command is `dotnet build` plus `dotnet test`, or a script under `tools/`.
- Package names come from nuget.org, copied, never typed from memory.

## Common traps

- Nullable reference types are warnings, not errors, until the project treats them as errors.
  Do not silence a warning with `!`; fix the null case or make the type non-nullable.
- `catch (Exception) { }` swallows everything, including the mistake you are looking for. Log
  it at least, or catch the specific type.
- `DateTime.Now` carries the machine's timezone. Use `DateTimeOffset.UtcNow` for anything
  stored or compared across machines.
- `int` division truncates: `5 / 2` is `2`. Use `double`, `decimal` or `Math.DivRem`
  deliberately.
- In `xaml` and `razor`, a binding to a missing property fails silently at runtime. It is not
  a compile error.
