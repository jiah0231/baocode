# Office preview acceptance corpus

The 10 files in `apache-poi/` are unmodified public Apache POI regression
fixtures, pinned to commit `7f4d36854109efa17152b27a5fb1b2c7d842c314`.
`manifest.json` records their original URLs, byte lengths and SHA-256 hashes.
The upstream Apache License and NOTICE are retained beside the files. Public
document author names in the original package metadata are upstream provenance,
not BaoCode user information. These files are test inputs, not app assets.

The three `authored-layout.*` files are project-owned layout contracts generated
by `tool/office_preview/test/generate_fixtures.py`. They contain synthetic data
and a project-drawn image. They complement, rather than replace, the real files.
Regenerating a fixture does not approve a visual baseline.

## What the corpus exercises

| Format | Authored contract | Real upstream coverage |
| --- | --- | --- |
| DOCX | Letter paper, 0.75-inch margins, two explicit pages, header/footer, merged table, 2:1 image, authored type/color | Mixed image encodings, floating text boxes, nested/restarted numbering, original page breaks |
| PPTX | 16:9 slide, exact left/right objects, image, merged table, chart | 10 slides, seven masters, inherited backgrounds/colors, nested groups, chart with picture background |
| XLSX | Merged A1:F2, custom row/column sizes, currency/date/percentage, two sheets, image/chart | 18 sheets, seven merges, conditional formatting, table styles, three charts |

## Two different acceptance questions

1. **NoteBoard parity:** identical upstream plugin source, same document bytes,
   viewport, font set, zoom and theme must produce the same layout and behavior
   inside BaoCode. Capture an upstream-host reference and BaoCode-host actual
   from the same locked browser/font environment. Compare content crops, not
   different application toolbars. Record upstream commit and bundle hashes.
2. **Office fidelity:** compare against separately rendered Word/PowerPoint/Excel
   pages or an approved reference PDF. Record the producer and exact version,
   installed fonts, page size, export options and reference image hashes.
   Do not use BaoCode's own output as the Office reference.

These are not interchangeable. The original NoteBoard Excel plugin preserves
merged geometry, row/column sizes and number formats but does not render cell
font/fill/border styles or workbook charts/images. NoteBoard parity must not be
reported as full Excel fidelity. Floating drawings and unsupported raster
formats also need explicit visual review in Word.

## Required visual evidence before calling the layout verified

- Fixed 1280×960 viewport, device scale 1, locale and fonts. Save the runtime
  version, fixture hash, host bundle hash, geometry JSON and full screenshot.
- DOCX: page count; paper ratio and margins; paragraph wrap; no unexpected extra
  page; merged table geometry; header/footer positions; image aspect ratio.
- PPTX: all 10 master/theme slides plus grouped/chart samples; slide dimensions;
  object bounding boxes; background/rotation/z-order; actual slide navigation.
- XLSX: merged area equals the sum of source columns/rows, custom row height,
  formatted values, tab order, selection and virtualization. Separately record
  the original plugin's missing chart/image/style support.
- Light/dark/high-contrast chrome: Word/PPT authored document colors and geometry
  stay stable; Excel follows the original plugin's theme behavior while geometry
  stays stable. Reading mode is explicitly a different, reflowed representation.
- Narrow pane and 125%/150% system scale: no app-level overflow; scrolling and
  fit-width do not distort object proportions. Native WebView placement and
  modal/overlay occlusion require Windows host evidence, not browser-only proof.
- No document-triggered external network, navigation or script execution.

## Review and comparison rules

All manifest entries currently say `not-yet-reviewed`. No reference screenshot
has been generated or approved. Static/semantic tests passing do not change that.

Use the same viewport/font/runtime to compare repeat runs. Require exact page
counts and geometry within one CSS pixel for fixed authored dimensions. For
approved image baselines, retain actual, expected and highlighted diff images;
use a small anti-aliasing tolerance (channel delta at most 8, changed pixel ratio
at most 0.5%) only after checking that it does not hide missing text/images.
Cross-engine Office comparisons require human review of overlays/contact sheets;
do not waive structural differences merely because a global similarity score is
high. Never update baselines automatically after a failing comparison.

`verify_fixtures.py` checks hashes, ZIP integrity and authored XML geometry only.
`visual.test.mjs` is an opt-in browser scenario, not part of the non-browser CI.
The browser scenario has not been run in the current restricted environment.
