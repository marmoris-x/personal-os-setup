---
paths:
  - "**/manifest.json"
  - "**/*.user.js"
---

# Browser extensions (Manifest V3) and userscripts

## The background page is gone

- In Manifest V3 the background is a **service worker**, not a page that stays open. Chrome
  ends it after about 30 seconds of inactivity, and when it ends, every global variable is
  gone. Never keep state in a variable between events - write it to `chrome.storage`
  (`local` up to 10 MB, `sync` about 100 KB total and 8 KB per entry, `session` for the
  browser session only).
- Timers die with the worker, so `setInterval` and `setTimeout` are unreliable for anything
  recurring. Use `chrome.alarms`; the smallest interval is 0.5 minutes, and shorter values are
  ignored with a warning.
- Register event listeners **synchronously at the top level** of the worker. Register one
  inside an `async` function or a callback and the event it was meant to catch is simply
  missed.

## No remote code

- No script from a CDN, no `eval`, no `new Function`, no string passed to `setTimeout`. All
  code has to be in the extension bundle. The extension page's default content security policy
  is `script-src 'self'; object-src 'self'`, and a policy containing `'unsafe-eval'` makes the
  extension fail to install.
- When you need to run code in a page, use `chrome.scripting.executeScript` with a function and
  arguments, not a string.
- In a userscript this does not apply: `@require` from a URL is normal there, because the
  userscript manager owns the page.

## Permissions

- `permissions` lists named capabilities (`storage`, `alarms`, `scripting`), while
  `host_permissions` lists URL patterns. Some APIs need both. A misspelled entry is a load
  error, not a silent no-op.
- A missing permission shows up as `undefined` or a thrown error, so the first symptom is
  usually "cannot read property of undefined" rather than a permission message.
- Nothing is reachable from a web page by default. `web_accessible_resources` is an array of
  objects, each with `resources` and `matches`; a `matches` entry may only name the origin and
  the path must end in `/*`.
- Adding a permission that shows a warning disables the extension until the user agrees again.

## Manifest V3 replaced these, so old code breaks

- `chrome.extension.getBackgroundPage()` and `chrome.runtime.getBackgroundPage()` are gone -
  use message passing.
- `chrome.extension.*` became `chrome.runtime.*`, `browser_action` and `page_action` became
  `action`, `tabs.executeScript` became `scripting.executeScript`.
- `XMLHttpRequest` cannot run in a service worker. Use `fetch`.
- `background.scripts` and `background.persistent` no longer exist.
- `manifest_version` must be `3`. A V2 manifest does not load in Chrome and is not accepted in
  the Chrome Web Store.

## Getting it accepted in the store

- Ask for the narrowest permission that works. Broad host access (`<all_urls>`, `*://*/*`)
  lengthens the review and can get an extension rejected, and every permission has to be
  justified in the dashboard.
- `activeTab` grants access to the current tab on a click, with no warning to the user - it is
  the usual answer for "act on the page the user is looking at".
- No undeclared remote code of any kind, including in the store listing.

## Userscripts

- Use `@match` rather than `@include`. `@match` follows Chrome's match pattern rules
  (`<scheme>://<host>/<path>`, for example `https://example.com/*` or `https://*.example.com/*`)
  and only looks at scheme, host and path - query and hash are ignored. `@include` is looser
  and its behavior differs between managers.
- Write `@grant` out explicitly. Without it, Tampermonkey assumes an empty list while
  Violentmonkey runs in a sandbox with a minimal API - the same script then behaves
  differently in the two managers. `@grant none` turns the sandbox off and disables every
  `GM_*` function except `GM_info`.
- With neither `@match` nor `@include`, Violentmonkey assumes the script matches **every**
  page. Always name the pages.
- `@run-at` is only the earliest moment the script may start; with `@require` it can be later,
  because the dependencies load first.
- In Chrome, Tampermonkey needs the "Allow User Scripts" switch turned on by hand (Chrome 138
  and later). Until then, nothing runs and no error explains why.

## Safety

- Everything inside an extension or a userscript is readable by whoever installs it. Never put
  a key, a token or a password in one - there is no hidden place there.
- A userscript with `@grant none` shares the page's context, so a page can reach it. Use the
  sandboxed mode when the script handles anything sensitive.
- Both managers say plainly: install only scripts you trust. A userscript runs with nearly the
  full rights of the extension that hosts it.
