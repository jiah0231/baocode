# Public Edge PDF diagnostic (disposable Windows CI only)

Files `edge_pdf_probe.cpp` and `run_edge_pdf_probe.ps1` can live together anywhere. Pass the candidate repository root; the script compiles and links the **real** `TranslationSelectionAction` implementation, without modifying it. The existing default-browser cold gate remains separate and untouched.

Requires x64 MSVC developer shell, an interactive Windows GitHub Actions desktop, Edge, and environment `GITHUB_ACTIONS=true`, `OS=Windows_NT`, `BAOCODE_DISPOSABLE_UI_TEST=1`. All three guards exist in native and PowerShell code.

Initial calibration:

```powershell
./run_edge_pdf_probe.ps1 -Repository $PWD -Output artifacts -CalibrateOnly -Zoom 100 -ScrollY 450
```

The script downloads only https://arxiv.org/pdf/2608.11260 unless `-Pdf` is provided, then verifies SHA256 `d159155dffad685a388562d1d2a4e0f869a5473be90c6c06381ab68a381451dc`. It copies the PDF into a new temporary directory and opens it in a new isolated Edge app profile. It verifies the exact document URI and unique profile on the browser owner command line before passing its PID to the native harness.

Inspect `*-calibration.bmp` and `*-stdout.log` to set physical window-relative drag coordinates. They are **not PDF points, DIPs, or client-relative coordinates**. The original PDF's page 1 is 439.37 × 666.142 points; “VAD method” occupies approximately (219.419, 558.742)–(274.212, 567.708) points. This is a locating aid, not a viewer-coordinate conversion.

```powershell
# Substitute the measured physical pixel coordinates; zero defaults are not valid test gestures.
./run_edge_pdf_probe.ps1 -Repository $PWD -Output artifacts -FromX 600 -FromY 450 -ToX 690 -ToY 450 -Zoom 100 -ScrollY 450 -Warm -ExpectedDpi 96
```

Run each zoom/scroll combination with calibration first. `-ExpectedDpi 120` requires a runner genuinely displaying the browser at 120 DPI; it fails if the actual value differs. This harness deliberately does not change OS DPI/security settings, and does not pretend browser device scale factor is physical DPI. `-ExpectedDpi 0` accepts and reports the actual window DPI. Requested PDF zoom/scroll fragments must be verified visually because viewer versions can ignore or reinterpret them.

Outputs: provenance manifest, target-only before/selected BMPs, raw selected UIA text escaped as UTF-16, raw bounding-rectangle arrays, element rectangle, physical gesture coordinates, window rectangle/DPI, and the actual production icon's visible state and physical outer rectangle. Selected text logging is diagnostic-only for this fixed public PDF. No clipboard, OCR, CDP, extension or forced accessibility switches. UIA enumeration is limited to the isolated browser's subtree. Available TextPattern element count is logged using metadata only; selected text is read from at most eight Document elements and one currently focused non-Document TextPattern element, avoiding inherited duplicate text controls.

`-Warm` explicitly primes UIA before installing the production action and before dragging. Without it, diagnostics still are **not** cold-start gate evidence: the UIA client is initialized and this is a different application fixture. The raw selected-range read happens only after the production action has had its 1500 ms observation window and icon geometry has been recorded. When the icon is visible, the probe physically clicks it and calls production CaptureClickedSelection before any independent raw UIA reads. It logs the captured text, status, bounds, area, generation, cancellation and completion state, then releases the exact accepted generation on the UI thread. No translation request is sent. Success requires both the production click capture and an independently selected range exactly equal to “VAD method”, and a visible actual icon, but does not prove icon placement is correct. Raw UIA text/geometry are collected even when the icon is absent; suppression is not evidence the root cause is fixed. Compare escaped text, screenshot and geometry manually. Missing selection/icon exits nonzero; timeout is failure.

Screenshots use `PrintWindow` on the target Edge HWND rather than desktop capture, so unrelated windows cannot appear. GPU-rendered content may be blank even if the API succeeds; inspect artifacts. The native icon is a separate window and is represented by its recorded geometry, not composited into the Edge-only image. A screenshot return value alone is not visual proof. The Edge `--app` PDF mode must also be verified in initial calibration; a first-run/dialog/error screen is a blocker, not a successful selection test.

Windows compilation/runtime has not been performed in the Linux authoring environment. `/W4 /WX` compiler diagnostics are fatal. The script retains artifact logs/screenshots on nonzero probe exit and terminates only the retained, revalidated isolated browser owner process handle. Child processes are not killed by stale PID or broad name matching.
