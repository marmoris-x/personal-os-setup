---
name: reuse-first
description: >
  Find and copy a proven solution before writing your own code. Use whenever you are about to
  write a new script, function, hook, skill, parser, converter, helper, wrapper or tool, when a
  task needs something that other people have almost certainly already solved well, or when the
  user says "reuse", "vendor", "gibt es das schon", "nimm das fertige" or asks why something was
  written from scratch. Searches this repository and {{DEV}}\External, GitHub, the package
  registries, the curated lists and the official docs, clones the best fit shallowly, copies only
  the files that are needed, marks the source and runs it. Load this before typing the first line
  of a new script or tool, including a small one.
---

<!-- Source: https://github.com/anthropics/skills @ dbd4588f9e1033efb41dad4bef2f7947c8993d44 -
     the frontmatter and progressive-disclosure rules this file follows. The procedure is the
     owner's (agent-upgrade-task.md, Part 2). -->

# reuse-first

The rule behind this skill stands in the global `CLAUDE.md` ("Research first, memory second"):
before writing more than a few lines yourself, look for a proven solution first. This skill is
the procedure for it. Work in the user's language at the end; the skill itself is English.

## Why

A file that somebody else has run for years beats one written fresh in five minutes: it already
knows the edge cases, and checking costs a few seconds. What makes the copy useful is that it
stays recognisable as a copy - hence the source line and the ban on tidying it up.

## 1. Name the need in one sentence

Write down what the thing must do, in one line, before searching: "a Windows toast from
PowerShell when a long command has finished". That line is the search key. Search for the
behaviour, not for the name you had in mind.

## 2. Search, in this order

1. This repository and `{{DEV}}\External` - grep first, it is free.
2. GitHub: `gh search repos`, `gh search code`. Read the stars and the last push date, and read
   both twice from two sources (the repository page and the registry): a value that came through
   a caching layer is not a value.
3. The package registries (PyPI, npm, PSGallery) - and copy a package name from the registry page
   instead of typing it, because a name that is one letter off is a known attack.
4. Curated lists (`awesome-*`) for the same problem.
5. The official documentation or example folder of the product you are working with.

Stop at the first source that answers. Note the URL and the commit of everything you consider.

## 3. Pick and say why, in one line

Pick the best fit for this machine - Windows 11 with PowerShell 7 - not the best in general. One
line: "X, because it is plain PowerShell, still maintained, and shows a toast without a module."

## 4. Copy only what is needed

```powershell
git clone --depth 1 <url> {{DEV}}\Temp\<task>\<name>
```

Then copy the single files you need into the project. Never take a foreign `.git/`, `.github/`
workflows, CI configs, lock files or build output. Change only what makes it fit: import paths,
names that clash, file locations, configuration values, environment variables. No refactoring,
reformatting, renaming, "modernising" or added error handling - a copy that was tidied up can no
longer be updated from its source. Put one comment at the top of the copied file:

```
Source: <url> @ <commit>
Changed: <what, one line>     # only when something had to move
```

## 5. Run it and report

Run it: the test, the build or the project's check command. Then report three things, one line
each - the source URL with its commit, what had to be changed, the check result.

## 6. Nothing usable? Then write it

Say so in one line and write your own. "I looked and found nothing" is a result; silence is not.

## Limits

- A copy that does not run is not a copy. If it does not run after a few attempts, go back to
  step 2 with a sharper sentence in step 1.
- A one-line edit of an existing function is not this skill's business.
- Anything taken from a source stays recognisable: no silent renames, no "while I am here".
