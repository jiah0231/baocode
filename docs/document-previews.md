# Offline document previews

BaoCode can open these documents from the IDE explorer and chat file links:

| Format | Read-only preview |
| --- | --- |
| Word `.docx` | Paragraphs, text emphasis, headings, tables and embedded PNG/JPEG/BMP images |
| PowerPoint `.pptx` | Slides in presentation order, positioned text and images, basic fills/borders, page navigation and reading view |
| Excel `.xlsx` | Sheet tabs, sparse cells, shared strings and saved formula results |
| `.csv`, `.tsv` | A virtualized spreadsheet view, including quoted fields and Unicode text |
| Legacy `.doc`, `.ppt`, `.xls` | An explicit explanation and the existing system-app action; save a modern-format copy to preview |

The preview is **not an Office renderer or editor**. Complex page layout,
headers and footers, nested tables, floating objects, charts, animations,
SmartArt, unsupported images and some formatting may differ or be omitted.
Formulas are never evaluated. Cached workbook values may be stale. Use the
original application for exact layout or calculation. Unsupported, encrypted,
corrupt and oversized files fail with an explanation rather than falling back
to an editable binary/text view. Git binary revisions are not silently
substituted with the current working file.

## Themes and controls

The preview shell, controls, tables and reading view use BaoCode theme tokens
and configured UI fonts. Switching themes restyles the open preview. The
optional **Original colors** view preserves document text and basic slide
colors on a paper surface; return to **Theme colors** for theme-aware contrast.
Slides support **Reading view**, previous/next buttons and arrow/PageUp/PageDown
keys. Zoom controls affect the current preview only. A **Reload** action rereads
the file without modifying it.

Large documents use lazy paragraphs and tables virtualized in both axes, so a
sparse sheet does not allocate a giant dense grid.

## Privacy and resource limits

- Parsing is local, in memory, on a background isolate. Remote project files
  use the existing authorized host byte channel, not a local path look-alike.
- No public document service, online Office viewer, WebView or converter is
  involved. Embedded links, linked images, external relationships, macros,
  embedded HTML and scripts are not followed or executed.
- The source is read-only. Preview errors and switching tabs cannot overwrite
  the original document. No archive content is extracted to disk.
- Input is limited to 32 MiB. ZIP directories, actual inflation, XML depth,
  text, cells and embedded-image dimensions also have separate limits. The
  UI discards results from cancelled or superseded loads.

## Implementation and license

The user-facing capability was inspired by
[NoteBoard](https://github.com/CrazyFigure/NoteBoard), whose document plugins
also separate a read-only viewer from source files. No NoteBoard source is
copied: those plugins are AGPL-3.0-only, while BaoCode is GPL-3.0-only.

This is an independent Flutter/Dart implementation using the MIT-licensed
[`archive`](https://pub.dev/packages/archive) and
[`xml`](https://pub.dev/packages/xml) packages. Their notices are included by
Flutter's dependency license collection. Neither a commercial Office SDK nor
an Office installation is needed for the supported modern formats.
