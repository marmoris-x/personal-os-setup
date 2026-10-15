@AGENTS.md

## Downloads folders (rule from the owner, 2026-10-09)
The folders `Compressed`, `Documents`, `Images`, `Music`, `Programs` and `Videos` in
`{{HOME}}\Downloads` are the owner's permanent storage. No agent moves, deletes or tidies
anything in them without his explicit yes. Loose files directly in Downloads may be sorted as before.
They stay out of every cloud backup (Kopia) and every sync (OneDrive, Syncthing): never add them as a source.
The hook `~/.claude/hooks/downloads-guard.ps1` blocks move, rename and delete there until he says yes.
What lives only there (for example the old Calibre e-books) is his call: do not ask about copying it
to Calibre or to an external disk, he decides when he wants that.
