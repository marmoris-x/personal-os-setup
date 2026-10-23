# Media projects

Conventions for a project that works with video, audio or large images. No such project
exists yet; this page is the template an agent follows when the first one starts. The
`media-tools` skill (`~/.claude/skills/media-tools/`, portable copy in
`~/.agents/skills/media-tools-portable/`) holds the commands and the install rule.

## The folders

```text
<project>\
  media\raw\      irreplaceable originals
  media\work\     intermediate files
  output\         finished files
  cache\          regenerable data
```

- `media\raw\` is backed up by Kopia and never goes to GitHub.
- `media\work\`, `output\` and `cache\` are neither backed up nor on GitHub.
- `C:\Dev\Temp\media` is shared media scratch for downloads and one-off work, not part of a
  project. It is never deleted during a task cleanup.
- A finished file the owner wants to keep goes into `Downloads\Videos` (video) or
  `Downloads\Music` (audio), and only after the owner says "behalten" for that file.

## The two ignore files

`.gitignore` in the project root:

```gitignore
media/
output/
```

`.kopiaignore` in the project root:

```text
media/work/
output/
cache/
```

The `.kopiaignore` must sit inside the project folder: Kopia reads a dot-ignore file only
inside the snapshot source (https://github.com/kopia/kopia/issues/3737). The raw originals
stay in the backup on purpose, so `.kopiaignore` does not list `media/raw/`.

No Git LFS. GitHub blocks files over 100 MiB and recommends repositories under 1 GB
(https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github).

Never add a global exclusion of `*.wav`, `*.mp3` or `*.mp4`: the voice recordings in the
vault's `inbox\audio` are originals.

## The safety net

There is no `--max-file-size` limit on the Kopia source. A limit would silently drop a large
original in `media\raw\`, such as a long 4K recording. Instead, `project-tracker.ps1` lists:

- every file above 1 GB under `C:\Dev\Projects` that is outside `media\raw\` and not ignored
  by a `.kopiaignore`;
- the total size of all `media\raw\` folders.

Only when such a file exists, the morning report adds one line
`Große Datei im Backup (außerhalb media\raw): <path>`. The owner then decides where the file
belongs; the agent does not move it on its own.
