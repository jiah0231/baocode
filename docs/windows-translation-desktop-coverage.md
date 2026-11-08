# Windows desktop selection coverage

Global capture is a Windows system feature, not a browser extension. It uses the
foreground application's accessibility provider. Different desktop applications
can expose different selected ranges, even when they use the same rendering
engine. A native Edit/RichEdit fixture is not Microsoft Office coverage, an Edge
HTML page is not PDF-reader coverage, and Console Host is not Windows Terminal.

## Read the per-run evidence

The presence of this suite is not proof that Notepad, PDF readers, terminals,
Office or WPS work. Consult the exact source commit's `desktop-coverage.json`
artifact for observed outcomes and application versions. Existing native-control,
clipboard, mouse-entry, Edge HTML and compiled-window tests remain separate
checks. This document describes the measurement contract, not a universal support
claim or a substitute for a completed Windows run.

## Real application probes

`tool/ci/windows_translation_desktop_smoke.ps1` compiles
`windows_translation_desktop_smoke.cpp` with the Windows SDK and runs it only on
an explicitly enabled disposable Windows Actions desktop. It neither installs
applications nor touches user documents, accounts, or external pages. Every
source is synthetic and includes an unselected decoy. The harness calls the
production `translation_selection::Capture` header without changing production
code, forcing accessibility flags, scanning document text, or sending Ctrl+C.

- **Windows Notepad:** open a local synthetic TXT in the installed `notepad.exe`,
  then select its first line with Ctrl+Home and Shift+End. An exact result must
  exclude the second line. Native selection offsets or post-capture UIA selection
  metadata independently establish that a selection existed. Classic and modern
  Notepad versions must be identified from the actual run, not assumed equivalent.
- **Edge built-in PDF reader:** open a genuine local PDF with selectable text in
  a fresh Edge profile. A magenta fixture mark locates the rendered line without
  relying on toolbar coordinates. Real pointer input selects the line. A visible
  selection-background change verifies the gesture. Capture is attempted without
  prewarming UIA. An unrendered PDF or an unverified gesture is a failure, never a
  safe-unsupported or passed application. Background networking is disabled and
  HTTP(S) is directed to an unused loopback proxy. No remote origin is requested.
- **Windows Console Host:** create a separate console process containing only
  static synthetic output, enable Quick Edit, and select one exact row by mouse.
  The fixture's `GetConsoleSelectionInfo` verifies the expected selection rectangle.
  The visible window must belong to real `conhost.exe`. No command shell runs and
  no Ctrl+C is injected. This is not a Windows Terminal test.
- **Word, WPS Writer, VS Code, Adobe Reader/Acrobat, and Windows Terminal:** inspect
  known installation/App Paths locations only. Installed applications are reported
  `notTested`; missing applications are `notAvailable`. No new application is
  installed or activated and no product-support claim is inferred.

The read-only suite records native copy-fallback eligibility but does not exercise
that fallback. `nativeCopyFallback: eligibleButNotExercised` means the production proof and
`SafeControl` check allow native copying, but that path still needs an
application-specific test. A proof rejected by the helper is separately reported
as `proofRejectedBySafetyChecks`; `copyProof` alone is not final eligibility.
A UIA-only `safeUnsupported` outcome is not a claim that the full production
flow, including its optional fallback, cannot capture from that application.
The existing clipboard fixture remains a separate safety/behavior check.

## Outcome contract

Each attempted application writes a JSON record. `desktop-coverage.json` combines
those records, the exact commit, runner image, application versions and observation
time. For captured applications, `sourceImagePath` comes from the actual source
window process and `version` is read from that executable. `launcherVersion` is
kept separately; a System32 Notepad launcher stub is not the captured Notepad
version. Unavailable version metadata remains unknown. Inventory-only versions
are labeled `versionSource: inventoryExecutable`. Both initial `attempts` and
`finalAttempts` are recorded for capture diagnostics. `desktop-coverage.md` and the Actions step summary show the same outcomes.
Synthetic source-window PNG/BMP evidence is retained for diagnosis.

| Outcome | Meaning |
| --- | --- |
| `exactCaptured` | Production capture returned exactly the selected synthetic line, excluding the decoy, with an unchanged clipboard. No broad whitespace trimming is permitted; a trailing line delimiter may be excluded. |
| `safeUnsupported` | A selection was independently verified, capture returned `unsupported` and no source, and the clipboard stayed unchanged. This is **not** successful translation support. |
| `failed` | Wrong text, unexpected clipboard change/copy eligibility, runtime capture error, unverified selection, failed application setup, or missing evidence. |
| `notAvailable` | The application executable was not found. No capture was attempted. |
| `notTested` | The application was found but only inventoried. No capture was attempted. |

PDF and Console Host must never produce native-copy eligibility. A timeout,
changed focus, `noSelection` for a verified selection, or a wrong `ok` result is
`failed`, not `safeUnsupported`. Returning exit code zero from an exploration run
does not upgrade any per-application outcome.

## Connect to CI

After the existing MSVC developer environment setup, run in a Windows job with
`BAOCODE_DISPOSABLE_UI_TEST: '1'`:

```powershell
./tool/ci/windows_translation_desktop_smoke.ps1 `
  -OutputDirectory build/translation-desktop-coverage
```

Upload `build/translation-desktop-coverage/` as an artifact with `if: always()` so
failed runs retain their JSON, selected synthetic PDF, logs and screenshots.
The suite does not need a Flutter build and must not replace existing native,
clipboard, browser or actual application-window gates. Its `failed` cases return a
nonzero status; honest unsupported or uninstalled exploratory targets remain in
the matrix without being called supported.

After an application is proven to capture exactly on the relevant image/version,
it may be promoted to an exact-capture gate:

```powershell
./tool/ci/windows_translation_desktop_smoke.ps1 `
  -OutputDirectory build/translation-desktop-coverage `
  -RequireExactCapture @('notepad')
```

An exact-capture gate fails if the application is absent, unsupported, untested or
fails. Do not enable this example gate based on the fixture implementation alone.
The runner is Windows-specific. macOS/Linux system-wide selection, OCR, elevated
windows and arbitrary custom controls remain outside this coverage.
