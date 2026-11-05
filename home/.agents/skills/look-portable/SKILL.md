---
name: look-portable
description: Read one picture or video with the Portkey quick pool (Gemini 3.5 Flash-Lite) and answer a question about it. Explicit invocation only - @look-portable in OpenCode, $look-portable in Codex.
---

The owner wants this file read: $ARGUMENTS

## Use it

```powershell
pwsh -NoProfile -File "$HOME\.claude\skills\look\scripts\look.ps1" -Path "<path>" [-Ask "<question>"]
```

- The default question describes everything: objects, every text verbatim, colours, layout, and
  what cannot be read.
- One file per call, one question. Formats `.png`, `.jpg`, `.jpeg`, `.webp`, `.mp4`; at most 18 MB
  after base64. The file is never resized or converted.
- The pool is the owner's Portkey quick config (`PORTKEY_CONFIG_QUICK`) with the key
  `PORTKEY_API_KEY`; the resolution comes from that config, the script sends none of its own.
- The answer is printed first, then one success line:
  `model=... target=... retries=... seconds=... trace=...`.
- Exit codes: 0 ok, 2 bad input, 3 refused path, 4 too large, 5 missing environment variable,
  6 HTTP error or timeout, 7 another model answered.

## Refused paths (checked on the real path, before anything is read)

- the OneDrive folder (Windows known folder), `~/.claude`, `~/.ssh`, `~/.codex`;
- `Downloads\Compressed`, `Downloads\Documents`, `Downloads\Images`, `Downloads\Music`,
  `Downloads\Programs`, `Downloads\Videos`;
- every folder segment named `600-archive`;
- every path segment containing `ausweis`, `pass`, `svnr`, `versicherung`, `bank`, `konto`,
  `iban`, `befund`, `arzt` or `bescheid` (case-insensitive).

Junctions, symbolic links, 8.3 short names and trailing dots are resolved through the file
handle, so a link cannot walk around the list. A refused path is the owner's boundary: do not
work around it.

## The rule for the answer

Gemini only describes; the decision stays with the session and with me. Small print, codes and
numbers follow Gemini's reading; layout and controls follow the session's own. When the two
disagree, say so plainly.
