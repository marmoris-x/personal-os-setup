# Third-party material in this repository

This repository is MIT licensed (see [LICENSE](../LICENSE)). This page lists what was taken
from someone else, where it came from and under which license it stands, so that a reader can
tell the two apart and so that the attribution the sources ask for is where it belongs.

**This list is maintained by hand and cannot be complete by construction.** No check can prove
that a snippet nobody wrote down is absent; the acceptance run tests the FORM of this page (a
path that exists, a source address and a license per entry), never its completeness. If you
find something here that is not listed, that is a defect - please say so.

| Where | What was taken | Source | License |
|---|---|---|---|
| `home/.claude/skills/research/references/style-rules.md` | the English style sections and their example sentences, condensed by hand from the repository below; no code | https://github.com/blader/humanizer (commit 225a6f39) | MIT |
| `home/.claude/skills/research/scripts/ai_patterns.py` | the English word, phrase and connector lists, copied as that repository gives them | https://github.com/blader/humanizer (commit 225a6f39) | MIT |
| `vault/.claude/skills/json-canvas/SKILL.md` | the whole skill, vendored; the lock file `vault/skills-lock.json` names the source | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/obsidian-bases/SKILL.md` | the whole skill, vendored; named in `vault/skills-lock.json` | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/obsidian-cli/SKILL.md` | the whole skill, vendored; named in `vault/skills-lock.json` | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/obsidian-markdown/SKILL.md` | the whole skill, vendored; named in `vault/skills-lock.json` | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/json-canvas/references/EXAMPLES.md` | the reference file of that skill, vendored with it | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/obsidian-bases/references/FUNCTIONS_REFERENCE.md` | the reference file of that skill, vendored with it | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/obsidian-markdown/references/CALLOUTS.md` | the reference file of that skill, vendored with it | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/obsidian-markdown/references/EMBEDS.md` | the reference file of that skill, vendored with it | https://github.com/kepano/obsidian-skills | MIT |
| `vault/.claude/skills/obsidian-markdown/references/PROPERTIES.md` | the reference file of that skill, vendored with it | https://github.com/kepano/obsidian-skills | MIT |
| `home/.claude/statusline.ps1` | thirteen colour assignments (eleven distinct RGB triples, measured 2026-10-15) of the Catppuccin Mocha palette, hard-coded and named in a comment | https://github.com/catppuccin/catppuccin | MIT |
| `docs/inspiration.md` | the survey of role models: ideas were adopted from microsoft/WindowsDeveloperConfig, chezmoi, ballred/obsidian-claude-pkm, louisfb01/obsidian-agent-vault-template and kepano/obsidian-skills - nothing was copied verbatim | https://github.com/microsoft/WindowsDeveloperConfig, https://github.com/twpayne/chezmoi, https://github.com/ballred/obsidian-claude-pkm, https://github.com/louisfb01/obsidian-agent-vault-template, https://github.com/kepano/obsidian-skills | MIT |
| `docs/inspiration.md` | johncwaters/claude-setup: an idea was adopted, nothing was copied - the repository carries no license | https://github.com/johncwaters/claude-setup | no license |
| `docs/inspiration.md` | affaan-m/ECC: behaviour was confirmed against it, nothing was copied; the repository names no license | https://github.com/affaan-m/ECC | no license |
| `dev/External/README.md` | one block quote of three lines from Anthropic's documentation, marked as a quote with its date; the rest of the page is a paraphrase | https://code.claude.com/docs/en/memory | not MIT - quoted documentation, see the note |
| `home/.claude/TROUBLESHOOTING.md` | one block quote of three lines from Anthropic's documentation, announced as verbatim | https://code.claude.com/docs/en/hooks | not MIT - quoted documentation, see the note |
| `windows/configuration.winget` | the file follows Microsoft's authoring documentation for the winget configuration schema; the credit stands in its header | https://learn.microsoft.com/windows/package-manager/configuration/ | not MIT - names and schema only, see the note |
| `vault/.obsidian/plugins/obsidian-git/data.json` | the settings file of a third-party Obsidian plugin; the plugin's code itself is deliberately not vendored (ADR 0008) | https://github.com/Vinzent03/obsidian-git | MIT |
| `macos/Brewfile`, `windows/winget-core.json`, `windows/winget-optional.json` | package names and versions from the Homebrew and winget registries | https://brew.sh, https://learn.microsoft.com/windows/package-manager/ | factual name lists, no license claim |

## Two notes a reader should not have to dig for

**Attribution of the vendored skills was missing.** The four skills under `vault/.claude/skills/`
are vendored from `kepano/obsidian-skills` (MIT). Their files carry no attribution header, and
the MIT license asks for the notice to travel with the copy. This page is that notice, and
`vault/skills-lock.json` names the source commit. The files were not edited, because that lock
file records a hash of each skill and a changed file would no longer match it.

**Anthropic and Microsoft documentation.** Quoted or paraphrased documentation text is not
MIT-licensed material and is not covered by this repository's MIT license. What stands here are
short quotations with their source and date, and the factual names of commands, settings and
schema fields. If you reuse those passages, read the source's own terms.
