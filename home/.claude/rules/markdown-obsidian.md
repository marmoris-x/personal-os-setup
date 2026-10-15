---
paths:
  - "**/*.md"
  - "**/*.mdx"
---

# Markdown and Obsidian

## Structure

- YAML frontmatter must start on the very first line with `---` and close with `---`. One
  blank line, a heading or a BOM before it and it is no longer frontmatter - Obsidian shows it
  as text and other tools ignore it.
- A heading level should not be skipped (`#` then `###`). The table of contents and most
  linters depend on the order.
- Do not reflow or re-wrap existing paragraphs, and do not rename files or folders, unless
  asked. In a vault, a rename touches every link that points at the note.

## Links, in a vault and outside it

- Obsidian's `[[Note name]]` links are an Obsidian feature. GitHub, VS Code and most renderers
  show them as plain text. Inside the vault they are right; in a repository that other people
  or other tools read, prefer `[Note name](Note%20name.md)`.
- Obsidian updates links when a note is renamed **inside Obsidian**. A rename done in the
  terminal or by a script does not - every `[[...]]` and every relative path pointing at that
  file then breaks silently. Prefer renaming in Obsidian, or search for the old name first.
- A `|`, `#`, `^`, `[` or `]` in a file name breaks wikilinks. Keep names plain.

## Code and nested blocks

- A fenced block opened with N backticks ends only at a line with N or more backticks and
  nothing else. To show a code block inside a code block, the outer fence needs more
  backticks than the inner one - otherwise the outer block ends early and everything after
  it is read as prose. So a code block that itself contains code blocks opens with four
  backticks, and after every such change you run the project's fence check and read its result.
  If the project has none, count the opening and closing fences yourself.
- A fence may be indented by up to three spaces, which is what happens inside a list item.
  A check that only looks for backticks at column zero misses those blocks entirely.
- Always name the language after the opening backticks. An unnamed block gets no syntax
  highlighting and no check can validate it.

## Obsidian features that are not Markdown

- Callouts (`> [!note]`), Dataview queries (```` ```dataview ````), `%%comments%%` and the
  `![[embed]]` syntax are Obsidian-only. They render as raw text everywhere else. That is fine
  inside the vault and wrong in a document meant to be read outside it.
- Tags written as `#tag` in the text are also ordinary text elsewhere. Tags in the frontmatter
  are the portable form.
