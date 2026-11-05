# Offline document previews

On Windows, BaoCode embeds the original read-only NoteBoard viewer plugins from
commit `43be834d892541d3fda51cab6e5496371331e341`. It no longer reconstructs
Office documents as simplified Flutter paragraphs, text boxes or cell lists.
The original plugin source, toolbar, layout engines and interactions are bundled
locally. See [the source and build guide](../tool/office_preview/README.md).

## Formats and existing editors

- Word: `.doc`, `.docx`.
- Excel: `.xls`, `.xlsx`.
- PowerPoint: `.ppt`, `.pptx`.
- PDF, EPUB, DWG, DXF, Notability `.note` and Goodnotes `.goodnotes`.
- CSV/TSV, Markdown, source files and images keep BaoCode's existing editors.
- Other desktop platforms retain the basic modern-Office reading preview for
  now. The additional embedded formats clearly say that Windows is required.

The Windows host uses the installed Microsoft Edge WebView2 runtime, not
Microsoft Office. Missing or older runtimes fail with a retry/system-app action;
there is no online conversion fallback or automatic download.

## Themes and controls

The original NoteBoard toolbars, zoom, slide thumbnails, sheet tabs, PDF text
selection, EPUB navigation and reading controls remain. BaoCode themes change
the surrounding controls. Authored document fonts, colors and page geometry
are not replaced by the application's text layout. The original Word
**阅读排版** option still intentionally reflows content when the user chooses it.

Reload rereads the file, never writes it. Theme changes do not reload or reparse
the document. Historical binary revisions never show the current file in their
place. Native views are hidden for marked floating menus/tooltips and covered
or inactive surfaces so they do not obscure Flutter controls.

## Compatibility is NoteBoard's, not Microsoft Office's

Using the original components also preserves their limitations. Missing fonts,
unsupported Office objects and complex pagination may differ. The original
NoteBoard Excel grid does not reproduce all author fonts, fills or borders and
does not draw workbook charts or pictures. Formulas use saved results. CAD is a
bounded 2D viewer. Notability/Goodnotes are incomplete compatibility parsers and
retain their original warnings; export PDF for a complete representation.

## Privacy and limits

- Bytes are read through the existing local/remote host transport with a 32 MiB
  input bound. Archive/XML/image and CFB structural preflight runs in a serialized
  background isolate before browser parsing.
- The selected bytes are served in memory to one private WebView2 controller.
  A fixed synthetic origin exposes only the selected document and an exact
  list of bundled viewer assets. There is no HTTP listener or workspace mapping.
- External requests, navigation, popups, downloads and permissions are blocked.
  No Office Online, upload service or remote font loader is used. No generic
  native command, file access or JavaScript evaluation bridge is exposed.
- CSP disallows inline JavaScript, JavaScript `eval`, HTML frames and form
  submission. Trusted local blob workers and WASM compilation support the
  original PDF/CAD engines. DOCX HTML chunks and unsafe EPUB HTML are disabled
  or sanitized by the original plugins.
- At most four native previews are open at once. Loading has a 45-second
  deadline. Superseded reads and callbacks are ignored; disposal closes the
  controller. These bounds do not constitute a proof against every engine
  decompression or memory failure. CAD's original WASM can require substantial
  memory. The original large-file/range-reading PDF profile is not implemented.
- BaoCode does not write the source or unpack it to disk. The private WebView2
  runtime may create its own temporary profile metadata; its unique folder is
  removed when possible after closure.

## Source and licenses

The original NoteBoard sources remain AGPL-3.0-only. BaoCode's surrounding
application retains its GPL-3.0-only license under the GPLv3/AGPLv3 combination
provisions, including applicable AGPL section 13 source availability.
Third-party licenses and complete pinned CAD dependency source archives are
included. Settings → About and the embedded viewer's source/license entry show
attribution, modifications and corresponding source. Release builds embed the
exact application source commit in those links.

## Validation status

Pinned source and output hashes, unchanged upstream Node tests, deterministic
bundling and fixture provenance/geometry have local automated checks. Flutter
lifecycle/preflight tests and native Windows build checks are required for each
candidate. Browser visual scenarios are supplied, but syntax or fixture checks
must never be represented as an executed screenshot comparison.
