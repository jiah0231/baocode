# BaoCode's embedded NoteBoard viewers

This directory embeds the original read-only viewers from [NoteBoard](https://github.com/CrazyFigure/NoteBoard), not a reimplementation of their layouts. Upstream commit: **43be834d892541d3fda51cab6e5496371331e341**.

## What is included

All eight standalone read-only preview plugins are built locally:

| Plugin | Extensions |
| --- | --- |
| Word | `.doc`, `.docx` |
| Excel | `.xls`, `.xlsx` |
| PowerPoint | `.ppt`, `.pptx` |
| PDF | `.pdf` |
| CAD | `.dwg`, `.dxf` |
| EPUB | `.epub` |
| Notability | `.note` |
| Goodnotes | `.goodnotes` |

The original toolbars, zoom behaviour, PowerPoint thumbnails, Excel selections and sheet tabs, PDF text layer, EPUB navigation and reading controls remain in the original modules. `vendor/noteboard/source-files.json` records each original Git blob hash. The build fails if a vendored file changes without a deliberate source update.

The surrounding NoteBoard application, workspace, file synchronisation, plugin download UI, editable boards and bitable workbench are not activated. BaoCode keeps its own file management, existing editors and image/text viewers. The workbench source and test are retained as part of the upstream source snapshot, but are not included in any runtime module.

## Exact source and bundle transport

Six large original bundle/archive files are stored as ordered binary parts under `transport/` so ordinary repository tools can carry them. No source or license content is removed or recompressed. From the repository root, first run:

```sh
python tool/ci/reassemble_preview_assets.py
python tool/ci/reassemble_preview_assets.py --verify-only
```

The first command restores the original paths, including the complete LibreDWG and DWF corresponding-source tarballs. Every part is checked by byte size, SHA-256 and Git blob hash; each complete result must match its separately pinned original size and SHA-256. Existing mismatched files are rejected, not overwritten. The second command verifies both original files and parts without creating files. The original archive hashes and repositories remain in `corresponding_source/manifest.json`; full bundle hashes remain in `assets/office_preview/manifest.json`. Reconstruct these files before building BaoCode, running the viewer tests, or extracting the corresponding-source archives. The public application source at its exact release commit contains all parts, manifests and the reconstruction script. Windows candidate and release jobs run reconstruction before any tests, then verify unchanged original bytes after rebuilding the offline bundles.

## Rebuild and test

Use Node.js 24.12 or newer. From this directory:

```sh
npm ci --ignore-scripts
npm run build
node test-upstream.mjs
node --test test_vendor_integrity.mjs
```

`package-lock.json` pins the complete npm graph and integrity hashes. `npm ci` requires access to the package registries while developing; the finished application does not download viewer libraries or fonts at runtime. SheetJS 0.20.3 comes from its official `cdn.sheetjs.com` tarball rather than the old npm `xlsx` release.

The generated runtime files are in `assets/office_preview`. All eight viewer modules are separate local ES modules and are only imported when needed. PDF workers, standard fonts and CMaps are embedded. CAD workers and its WASM are also embedded. The build produces `manifest.json` with byte sizes and SHA-256 values, plus complete `THIRD_PARTY_NOTICES.txt` for shipped code, bundled dependencies, fonts and inline icons.

`test-upstream.mjs` runs the unchanged upstream tests. It creates an ignored local `node_modules` junction/symlink at the original plugin path because two upstream CAD tests resolve their WASM files relative to that directory. The original test fixtures and their upstream provenance are preserved.

## Host interface

The WebView2 host loads `https://baocode-document.invalid/index.html`. All requests are served from an exact native asset allowlist, except `/document`, which supplies only the selected document's in-memory bytes. It does not expose the filesystem or an HTTP listener.

After `{type:"ready"}`, native code sends:

```js
{type: "load", kind: "word", name: "example.docx", url: "/document"}
{type: "theme", theme: {background: "#fff", foreground: "#202124", border: "#ddd", dark: false, sourceUrl: "https://github.com/jiah0231/baocode/tree/<build-commit>/tool/office_preview"}}
```

`kind` accepts a plugin ID or any listed extension. Always pass the original basename: the upstream plugin distinguishes DOC from DOCX, PPT from PPTX and DWG from DXF using that name. Native events are strictly `{type:"ready"}`, `{type:"loaded"}`, `{type:"error",message:"..."}`, `{type:"reload"}` or `{type:"openExternal"}`. The last two carry no path, URL or command: they invoke the existing Flutter callbacks for this already-selected document only, after it has loaded. Rendering helpers are not exposed to native eval.

Browser tests can call `window.BaoOfficeViewer.load({kind,name,bytes:Uint8Array})`, `setTheme(...)`, `destroy()`, and inspect the open Shadow DOM through `BaoOfficeViewer.root`. More detailed test events are emitted only as `bao-office-event` browser events. Native code does not accept those additional fields.

The adapter handles cancellation, delayed mounts, disposal, notifications, reading-state subscriptions and the source/license dialog. It keeps the original toolbar actions, renderer, fonts and paper colours. `compact-toolbar.mjs` adds a toolbar-only style adaptation inside the plugin Shadow DOM: duplicate filenames are hidden, desktop controls stay 24px even in narrow panes, and refresh/open icons share that same row. True coarse-pointer devices retain 32px targets. The fixed actions move to compact Flutter fallback icons while loading or showing an error. Wrapped toolbar groups remain reachable in very narrow panes. Theme changes set only the declared NoteBoard UI variables. Word's optional “阅读排版” toggle intentionally reflows content exactly as in the original plugin; it is not enabled by default.

## Offline and privacy boundary

No Office Online, upload conversion service, external font loader or AI service is used. The native allowlist and browser CSP deny external requests and navigations, including documents' remote images, fonts and hyperlinks. Upstream Office external relationships and EPUB HTML/CSS are additionally sanitised. Documents remain read-only; macros and formulas are not executed. CAD parsing uses local workers and WASM. The upstream audited glue transformation disables JavaScript string execution without enabling `unsafe-eval`; `wasm-unsafe-eval` is only for WASM compilation.

The native file-size/security preflight may be stricter than the original plugins. The adapter's upper bounds mirror the upstream host (100 MiB Word/Excel, 512 MiB PPT/PDF, 50 MiB other plugins); an application preflight can reject earlier. This port currently feeds selected file bytes rather than exposing NoteBoard's on-demand filesystem PDF range API. Do not advertise the original 512 MiB PDF streaming memory profile without separately validating native range transport.

## Honest compatibility limits

Using the same code means preserving its limitations as well as its controls:

- Word and PowerPoint retain the original renderer's page geometry and author styles. Missing fonts, unsupported objects and complex pagination can still differ from Microsoft Office. The app does not silently download replacement fonts.
- The original NoteBoard Excel plugin preserves values, saved formula results, sheet dimensions, merges, selection and navigation. It uses its theme-based grid, not full Excel author font/fill/border fidelity, and does not render workbook charts or pictures. It does not calculate formulas or execute macros.
- PDF has no OCR; selection requires an existing text layer. The original plugin limits pages to 2000.
- CAD is a bounded 2D viewer. Complex entities, SHX fonts, external references and large-scene/WebGL limits remain upstream limitations.
- EPUB supports ordinary EPUB 2/3 reflowable books; DRM-protected content is refused. Fixed-layout books may differ.
- `.note` and `.goodnotes` are incomplete read-only compatibility parsers. Their original visible warnings remain. For faithful complete notes, export PDF from the originating app.

## Licensing and corresponding source

The original NoteBoard files remain **AGPL-3.0-only**, with their unmodified license under `vendor/noteboard/LICENSE`. BaoCode-specific host and build adapters in this directory are also AGPL-3.0-only. This does not replace the surrounding application's GPL-3.0-only license. The GPLv3/AGPLv3 combination provisions, including the applicable AGPL section 13 source-availability requirements, must be respected when distributing or operating the combined work.

The application About page provides the exact application source revision; the embedded viewer has a visible “源码与许可” entry and accepts that same immutable source URL from its host. Do not replace this with a nonexistent `main`-branch path. Every public build must keep the corresponding source available alongside its binaries, including this directory, native/Dart host changes, lockfiles, source archives and build instructions. Source availability is not satisfied by distributing only these generated JavaScript assets.

`corresponding_source/` supplies the full pinned CAD dependency archives, not merely links to compiled npm files:

- `cad-viewer-0.8.3.tar.gz`: `flyfish-dev/cad-viewer` commit `6366d2f7b1013cd5c300008c3c3fbf017ca9aace`, AGPL-3.0-only.
- `dwf-viewer-0.6.7.tar.gz`: its AGPL-3.0-only transitive implementation source, commit `5c7eebd01648b95536f9f97a3ce3300213be0dfd`. The DWF viewer is not exposed as an additional supported format, and its separate WASM is not shipped.
- `libredwg-web-0.7.9.tar.gz`: commit `b70b5573a6bf2345e5fb10f2adff7fb74a8123c5`, including the LibreDWG C implementation, headers, C++ Embind bindings, configuration and build scripts, GPL-3.0-only.
- `jsmn-85695f3.tar.gz`: the exact `jsmn` submodule source at `85695f3d5903b1cd5b4030efe50db3b4f5f3c928`, MIT.

The LibreDWG archive's WASM and unmodified glue were verified byte-for-byte against the npm files embedded by the CAD viewer. Their Git blob IDs are `18ee41cf35544c8e5a000680e7e709e728f4ed1f` and `988fa7e0ee6f66a052e3ee1a8f5f0e380ea3087d`. `corresponding_source/manifest.json` records exact archive hashes and sizes. The upstream release does not pin an exact Emscripten compiler version, so a new C-to-WASM build is not claimed to be bit-for-bit identical.

To rebuild the underlying WASM, extract the LibreDWG archive, put the extracted jsmn source in its `jsmn/` subdirectory, install the normal Emscripten/autotools/pnpm build tools, then follow `bindings/javascript/README.md` and its pinned `package.json` scripts (`autogen.sh`, `build:prepare`, `build:obj`, `build:wasm`, `copy`, `build`). The original build flags include memory growth and `-s INITIAL_MEMORY=1GB -s MAXIMUM_MEMORY=4GB`; large CAD files can therefore require significant address space and memory. NoteBoard's unchanged `cad/cspRuntime.mjs` transforms the exact known glue during JS packaging and fails closed if its expected hash changes.

Other libraries retain their original permissive or dual licenses: docx-preview and PDF.js (Apache-2.0), SheetJS CE (Apache-2.0), Web-PPT and msdoc-viewer (MIT), JSZip (MIT/GPL alternatives), DOMPurify (Apache-2.0/MPL alternatives), Lucide icons (ISC), and the individual bundled PDF font/CMap notices. See the generated full notice file, not just this summary.

## Modification record

2026-11-05: Imported the pinned NoteBoard preview sources without changes; supplied a BaoCode WebView2 message/file bridge and theme mapping; bundled all renderers, workers, fonts and WASM as local assets; added exact source/hash inventories and tests; added an in-app source/license entry. The surrounding NoteBoard React/Tauri application is not copied or emulated. No upstream copyrights or licenses have been removed or relabelled.


2026-11-06: Added BaoCode-only compact toolbar styling and fixed refresh/open actions. The pinned upstream modules, original document rendering, source/permission notices and source/license entry remain unchanged.
