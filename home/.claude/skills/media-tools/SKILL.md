---
name: media-tools
description: Download, convert and inspect media and documents on this Windows PC. Use when the user says "Lade dieses Video als MP3", "YouTube herunterladen", "in MP3 umwandeln", "Tonspur extrahieren", "konvertieren", "Metadaten", "Dokument zu Markdown", "PDF zusammenfügen", "PDF zusammenfuegen", "Archiv entpacken" or asks for a video, audio file, archive, image conversion, ebook conversion or document conversion. Holds the exact command and the install rule for each case.
---

# Media tools

Short recipes for this PC. The commands are copied from the official documentation named
beside them; run them as they stand. Nothing here is a new rule beyond the task that created
this skill.

## What is installed, and what is not

Permanent, one copy each, all through winget:

| Tool | Package | What it is for |
|---|---|---|
| `ffmpeg`, `ffprobe` | `yt-dlp.FFmpeg` (comes with `yt-dlp.yt-dlp`) | audio, video, images, metadata |
| `yt-dlp` | `yt-dlp.yt-dlp` | downloads from YouTube and other sites |
| `deno` | `DenoLand.Deno` | what yt-dlp needs for YouTube (EJS) |

Everything else runs on demand and is not installed:

- `uvx --from "markitdown[all]" markitdown <file>` - Word, Excel, PowerPoint, HTML and PDF to
  Markdown. The `[all]` matters: without it the docx converter is missing.
- `uvx docling convert <file> --to md --output <dir>` - scanned PDFs and PDFs with complex
  tables. Uses the CPU build of PyTorch; the first run downloads a lot.
- `uv run --with pypdf python <script>` - PDF merge, split, rotate.

Already on the PC and only used: calibre's `ebook-convert`, Shutter Encoder, LosslessCut,
WinRAR.

Install on the first real need, only after the user says yes: Pandoc (Markdown to Word),
ExifTool (photo metadata). Never install a second ffmpeg, yt-dlp, Whisper, MarkItDown or
Docling; never install jq, ripgrep, Everything's `es.exe`, fd, MediaInfo, HandBrakeCLI,
ImageMagick, 7-Zip, qpdf, Ghostscript or OCRmyPDF for these jobs.

## Folders

- `{{DEV}}\Temp\media` - every download and media scratch file. The yt-dlp config
  `%APPDATA%\yt-dlp\config.txt` already sets `-P "{{DEV}}\Temp\media"`, so a download lands
  there without a path argument. This folder is shared scratch, not a task folder: never
  delete it or its files during a task cleanup.
- `{{HOME}}\Downloads\Videos` and `{{HOME}}\Downloads\Music` - permanent storage.
  A file goes there only when the user says "behalten", and then only that named file.
- `{{DEV}}\Projects\<name>\media\raw\` - irreplaceable originals of a project. Backed up by
  Kopia, never on GitHub.

After a tool was installed during the running session, reload PATH before calling it:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
```

## YouTube and other downloads

Source: https://github.com/yt-dlp/yt-dlp#usage-and-options

```powershell
yt-dlp <url>                                  # best quality, into {{DEV}}\Temp\media
yt-dlp -f "bv*+ba/b" <url>                    # best video + best audio, merged
yt-dlp -x --audio-format mp3 <url>            # audio only, as MP3
yt-dlp --embed-metadata --embed-thumbnail <url>
```

The config already sets the folder, so a download lands there without a path argument.

## Audio and video with ffmpeg

Source: https://ffmpeg.org/ffmpeg.html

```powershell
ffmpeg -i input.mp4 -vn -c:a libmp3lame -q:a 2 output.mp3     # extract the audio track
ffmpeg -i input.mkv -c copy output.mp4                        # remux, no re-encode
ffmpeg -i input.mp4 -vf "scale=1280:-1" output.mp4            # resize, keep the ratio
```

Inspect a file instead of installing MediaInfo (source: https://ffmpeg.org/ffprobe.html):

```powershell
ffprobe -v error -show_entries format=duration,size,bit_rate -of default=noprint_wrappers=1 input.mp4
```

## Documents to Markdown

A normal PDF: read it directly with the Read tool, no converter. For `.docx`, `.xlsx`,
`.pptx`, HTML or a PDF that must become text:

```powershell
uvx --from "markitdown[all]" markitdown <file> -o <file.md>
```

Source: https://github.com/microsoft/markitdown

A scanned PDF or a PDF with complex tables (slower, uses Docling):

```powershell
uvx docling convert <file> --to md --output <dir>
```

Source: https://docling-project.github.io/docling/

Both write the Markdown to a file. For a long document do not read the whole file: Grep for
the terms you need, then Read only those line ranges. The same rule as for a long web page.

## PDF merge, split, rotate

```powershell
uv run --with pypdf python merge_pdfs.py
```

```python
from pypdf import PdfWriter

writer = PdfWriter()
for path in ["a.pdf", "b.pdf"]:
    writer.append(path)
writer.write("merged.pdf")
writer.close()
```

Source: https://pypdf.readthedocs.io/en/stable/user/merging-pdfs.html

For split and rotate use `PdfReader` and `PdfWriter` from the same library; the linked page
and its neighbours show the calls. No PDF tool is installed.

## Archives

ZIP with PowerShell, source:
https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.archive/compress-archive

```powershell
Compress-Archive -LiteralPath <path> -DestinationPath <file.zip>
Expand-Archive -LiteralPath <file.zip> -DestinationPath <dir>
```

`Compress-Archive` has a 2 GB limit. For a larger ZIP use the built-in `tar.exe`:

```powershell
tar.exe -a -c -f <file.zip> <dir>
```

RAR and 7z with the installed WinRAR (tested once: add and extract return 0):

```powershell
& "$env:ProgramFiles\WinRAR\WinRAR.exe" x <archive.rar> <dest>\
& "$env:ProgramFiles\WinRAR\WinRAR.exe" a <archive.rar> <file>
```

Source: https://www.win-rar.com/command-line.html

## Images

Source: https://ffmpeg.org/ffmpeg.html

```powershell
ffmpeg -i input.png -vf "scale=1280:-1" output.jpg
ffmpeg -i input.jpg output.webp
```

ffmpeg converts and resizes JPG, PNG and WebP. ImageMagick is not needed.

## Ebooks with calibre

```powershell
ebook-convert input.epub output.mobi
```

Source: https://manual.calibre-ebook.com/generated/en/ebook-convert.html

calibre is already installed at `C:\Program Files\Calibre2\ebook-convert.exe` and on PATH.

## Pandoc and ExifTool, only on first real need

Ask the user first; then install one copy per user with winget and verify the package ID in
the output of `winget search`:

```powershell
winget install --id JohnMacFarlane.Pandoc -e --scope user
pandoc input.md -o output.docx
```

Source: https://pandoc.org/installing.html and https://pandoc.org/MANUAL.html

```powershell
winget install --id OliverBetz.ExifTool -e --scope user
exiftool image.jpg
```

Source: https://exiftool.org/install.html

## "behalten"

A move into `Downloads\Videos` or `Downloads\Music` happens only after the user says
"behalten" for that file. The `downloads-guard` hook blocks every such move without that yes.
After the yes, the move is allowed; never move a file the user did not name, and never treat
an earlier yes as permission for a later file.

## Media project template

Do not create this before the user starts a media project. When that happens, create:

```text
<project>\
  media\raw\      originals, backed up by Kopia, never on GitHub
  media\work\     intermediate files, neither backed up nor on GitHub
  output\         finished files, neither backed up nor on GitHub
  cache\
```

`.gitignore` in the project root:

```gitignore
media/
output/
```

`.kopiaignore` in the project root (it must sit inside the snapshot source; Kopia does not
read a dot-ignore file outside it, https://github.com/kopia/kopia/issues/3737):

```text
media/work/
output/
cache/
```

Never add a global exclusion of `*.wav`, `*.mp3` or `*.mp4`: the voice recordings in the
vault's `inbox\audio` are originals. No Git LFS.

The morning tracker lists every file above 1 GB under `{{DEV}}\Projects` that is outside
`media\raw\` and not ignored by a `.kopiaignore`, plus the total size of all `media\raw`
folders. The morning report shows the large files; the user decides where they belong.
