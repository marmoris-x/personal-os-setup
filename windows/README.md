# windows

Machine-level setup that is **configured**, not copied. Nothing in here lands as a file on the
target machine; `install.ps1` reads these files and acts on them in its fixed stages.

| File | Stage | What happens |
|---|---|---|
| `winget-core.json` | `winget` | the programs every machine needs (`winget import`) |
| `winget-optional.json` | `winget` | the extra programs, only with `-WithOptional` |
| `windows/scheduled-tasks/life-os-morning.xml.tmpl` | `task` | registers the scheduled task "Life OS Morning"; the placeholders are rendered from `personal.yaml` and the current user |

The scheduled-task template points at `%USERPROFILE%\.claude\life-os\morning.ps1`, which
`install.ps1` has already written by the time the task stage runs. It refuses to run the agent
when there is nothing to do, and takes a lock so two runs never overlap.

Why these are not manifest components: they are not files that get written, so the manifest
(which describes what a target machine receives file by file) has no place for them. The
reasoning stands in `docs/decisions/0013-install-stages.md`.

This `README.md` is documentation and is never installed.
