# Your repositories — which of them your agent (Claude Code) gets

> **Update version 9:** Ponytail is replaced by **Superpowers** (see `report-workflow-and-security.md`). New additions: Project CodeGuard, security-guidance and gitleaks.

"Agent harness" = the program that lets the AI work; in your case Claude Code.

**Global** = applies in every session, including in the Personal OS.
**Per project** = only in the code folder where you need it.

As of 2026-09-23. Checked: the README of every repository, plus independent measurements by JetBrains where they exist.

---

## Part 1 — For the agent harness

### Recommended

| Repository | What it is | Where |
|---|---|---|
| **{{GITHUB_ACCOUNT}}/discord-setup-agent** (yours) | Your MCP workspace that manages Discord servers through Claude Code. | **Per project**, only in this folder. Globally it would load 139 tools into every session. |
| typescript-lsp, pyright-lsp (official plugins, already active) | Give the agent an understanding of TypeScript and Python code: definitions, type errors. | Leave them **global**. |

### Helper tool, not for the agent itself

| Repository | What it is | When to use it |
|---|---|---|
| **NVIDIA/SkillSpector** | Security scanner for third-party skills and plugins. I have already checked Ponytail with it: no findings. | Only before you install a new skill. |

### Optional, when the need arises

| Repository | What it is | Where |
|---|---|---|
| **VoltAgent/awesome-design-md**, **getdesign.md** | Collections of `DESIGN.md` files in the style of well-known brands. Put one file into a project and the agent builds the interface to match. | **Per project**, for website or app interfaces (for example your website). |
| **mvanhorn/last30days-skill** | Research skill: summarizes what happened on a topic in the last 30 days on Reddit, arXiv, Techmeme and so on. Several sources for free, no key needed. | **Global**, if you research trends often. Overlaps with the Exa-based research stack. |
| **Graphify-Labs/graphify** | Turns a codebase into a map you can query. The code is analyzed locally. | **Per project**, only for large codebases written by others. Your projects are too small for it. |
| **microsoft/markitdown** | Converts PDF, Word and Excel into Markdown so the agent can read them. | **Global** as a command-line tool, only once you need something like that. |
| **santifer/career-ops** | Job search that runs in Claude Code: rate job offers, adapt your CV. | **Its own project folder**, only when you are looking for a job. |

### Not recommended

| Repository | What it is | Why not |
|---|---|---|
| **DietrichGebert/ponytail** | Plugin: the agent writes less and simpler code (JetBrains: −10% cost, −15% code). | **Superseded** — replaced by Superpowers in update version 9 (note at the top of this file). Do not install it again. |
| **JuliusBrussee/caveman** | Makes the agent answer in telegram style. | JetBrains measured −8.5% instead of the advertised −65%. Costs ~1,000 extra tokens per message. And you want clear explanations, not shorthand. |
| **rtk-ai/rtk** | Shortens the output of console commands. | JetBrains measured **+7.6% cost**, so it is more expensive. |
| **headroomlabs-ai/headroom** | A layer in between that compresses tool output. | In the comparison test (run by the Caveman author): 6.7% savings, 3 out of 18 answers wrong. Telemetry on by default. |
| **musistudio/claude-code-router** | Redirects Claude Code to other models. | You no longer need it: `claude-ds` and `claude-or` do that. |
| **affaan-m/ECC** | Huge bundle: 68 agents, 292 skills, its own hooks and rules. | Would overwrite your tidy system and take up space in every session. |
| **poshan0126/dotclaude** | Template for a `.claude` folder. | Yours is finished now. Only for reading. |
| **shanraisshan/claude-code-best-practice** | Collection of tips. | Reading material, nothing to install. |
| **stavarengo/claude-code-docs** | Copy of the Claude Code documentation. | The original documentation is more up to date. |
| **DeusData/codebase-memory-mcp** | Code memory as an MCP server. | Meant for large codebases. |
| **garrytan/gbrain** | "Brain" for OpenClaw/Hermes agents. | Built for other agents. Your vault serves this purpose. |
| **anthropics/claude-for-legal** | Plugins for legal work. | For law firms and legal departments. |
| **browser-use/video-use** | Edit videos with an agent. | Needs a paid ElevenLabs key. |
| **nexu-io/open-design** | Standalone design app with an agent behind it. | A separate program, not part of Claude Code. Only for design work. |
| **deepseek-ai/awesome-deepseek-integration** | List of links to programs that use DeepSeek. | Just a list. |
| **Karpathy gist "llm-wiki"** | Idea: an AI maintains a Markdown wiki. | That is exactly what your Personal OS already is. |

---

## Part 2 — Nothing to do with the agent harness

### Your own projects

The four below are the ones this 2026-09-23 review looked at. The complete list lives in the
vault under `200-projects/` (one note per project) and in `docs/HANDOFF-session-6.md`.

| Repository | What it is |
|---|---|
| {{GITHUB_ACCOUNT}}/buttercup | Browser extension: transcribe and summarize videos |
| {{GITHUB_ACCOUNT}}/variable-searcher | Your website: search BotGhost variables |
| {{GITHUB_ACCOUNT}}/tampermonkey-scripts | Your userscripts for YouTube, Google, marketplaces and more |
| {{GITHUB_ACCOUNT}}/stranslate-plugins | Plugins for the translation program STranslate (.NET) |

### Programs for the PC

| Repository | What it is | Note |
|---|---|---|
| OpenWhispr | Dictation on the PC | Already installed |
| OpenCut-app/OpenCut | Free video editing, an alternative to CapCut | Only for video work |
| Ekaanth/OpenCut-AI | OpenCut plus AI: edit by text, clone voices | Only for video work |
| debpalash/OmniVoice-Studio | Clone voices, dub videos, create audiobooks | Only when needed |
| riponcm/Jharu | Cleans up developer caches (npm, pip, Docker …) | Handy when the disk is full |
| vudsen/ai-disk-cleaner | Clean up the hard disk with AI help | Uses an AI model; Jharu is enough |
| openrecall/openrecall | Takes screenshots all the time to make everything searchable | **Privacy risk**, not recommended |

### Browser

| Repository | What it is |
|---|---|
| chathub-dev/chathub | Several AI chatbots side by side in the browser |
| eiler2005/ai-tab-optimizer | Turns many open tabs into a searchable collection (needs an AI model) |
| vaddisrinivas/gtabs | Sorts Chrome tabs into groups (needs an AI model) |

### Phone

| Repository | What it is |
|---|---|
| raviumeshkulkarni-web/Fluence-Android | Speech-to-text keyboard for Android |
| Whisperian (Play Store) | Dictation app for Android |

### Learning

| Repository | What it is |
|---|---|
| codecrafters-io/build-your-own-x | Guides to rebuild well-known programs yourself (Git, database, shell …) |
