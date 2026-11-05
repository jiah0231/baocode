# Office preview QA

## Checks available without a browser

- `python tool/office_preview/test/verify_fixtures.py`
- `node --check tool/office_preview/test/visual.test.mjs`
- `node --check tool/office_preview/test/compare_pngs.mjs`
- Existing Windows Flutter CI can run
  `test/ide/document/faithful_office_preview_test.dart` and
  `test/ide/document/office_preflight_test.dart`. The first mocks the native
  channel; neither opens WebView2 or a browser.
- Upstream NoteBoard Node unit tests and Windows C++ compilation are independent
  checks. Neither establishes that a real document looks right in the app.

The `faithful-office-preview.yml` workflow performs only static input/source
checks. Its artifact states this limitation explicitly. It cannot pass or
approve screenshots that have not been captured.

## Opt-in browser scenario (not enabled in CI)

After building the production `assets/office_preview` bundle, the visual runner
uses that exact bundle, the original plugins, open Shadow DOM and the checked-in
13-file corpus. It does not substitute renderer mocks. Install only the locked
test dependencies with `npm ci --ignore-scripts --prefix tool/office_preview/test`.

In an environment where executing the already installed browser is authorized,
set `BAOCODE_RUN_VISUAL=1`, `OFFICE_VISUAL_EXECUTABLE` to that exact executable,
and optionally `OFFICE_VISUAL_OUT`, then invoke the `visual` npm script in this
directory. The browser sandbox stays enabled. A browser refusal must be reported,
not worked around with flags, alternate executables or a different environment.

The runner saves light/dark/high-contrast screenshots, page/shape/cell geometry,
browser errors, attempted external requests, fixture hashes and bundle version.
It checks real image decoding, explicit Word pagination, authored dimensions,
slide ratio/shape separation, merged spreadsheet geometry and formatted values.
The 10-theme-slide presentation is captured page by page.

It is **not** a native Windows integration test. WebView2 bounds, DPI conversion,
overlapping Flutter menus/dialogs, tab disposal and focus/clipboard behavior need
separate Windows host evidence. It also is **not** Office-reference verification:
that needs independently produced, reviewed reference images.

## Comparing independently reviewed images

`node compare_pngs.mjs reference.png actual.png output-directory` writes a diff,
an expected/actual/diff contact sheet and a numeric report. It refuses dimensions
that differ and fails if more than 0.5% of pixels change beyond channel delta 8.
This is a regression threshold, not a substitute for reviewing missing objects
or a cross-engine Office layout. A low changed-pixel ratio can hide a small but
important missing object; geometry and human inspection remain required.

Reference approval must record source renderer/version, exact fonts, viewport,
scale, input hash and a reviewer. Do not run an automatic baseline-update step.
See `test/fixtures/office_preview/README.md` for the acceptance matrix and current
upstream Excel limitations.
