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

## Optional IA2 selected-range diagnostic

Add `-IA2` to build with Windows SDK MIDL and enable `edge_pdf_ia2_probe.h`. Include the `ia2_vendor` folder when copying these files. Official IDLs are pinned to LinuxA11y/IAccessible2 commit c9ae003d9c85eb707716928de97e055f5b77189c, including local file hash validation.

After recording the real icon/click result, a raw UIA BEFORE_IA2 snapshot is taken, the IA2 path runs, and a raw UIA AFTER_IA2 snapshot is taken. Each comparison uses the current focused control and its first safe Document ancestor along at most four Control parents, never the first broad Document in the window. The IA2 path examines only the current focused source control and at most four Control parents. It uses LegacyIAccessiblePattern → GetIAccessible (CHILDID_SELF only) → direct QI or IServiceProvider QueryService. It reads text only for exactly one noncollapsed IA2 selection, with explicit nonnegative offsets and a maximum 4096-character span. It verifies exact source ancestry, native HWND/process identity, focus identity, candidate PID, password/offscreen/protected state, exact accessible COM identity, and selection count/endpoints before and after. Returned text is logged only after validation. Only start and end-minus-one character extents are queried. No name/value/document/full-text APIs, selection mutation, descendant text scans, or translation network request are used. If the Legacy bridge yields no text read, an optional native focus-only bridge starts at AccessibleObjectFromWindow(exact source HWND, OBJID_CLIENT), follows at most eight get_accFocus dispatch/self objects, rejects child-ID-only variants, and normally reads only a final focused Document or readonly Text object. Safe unsupported roles can receive QI/QueryService metadata inspection only, without selection getters. A fixed-public-PDF readonly, focused Pane is eligible only when ElementFromIAccessible(terminal, CHILDID_SELF) succeeds with a non-null UIA element that CompareElements proves exactly equals the original bound UIA focus. SafeElement and the original Group/Document focus path must also pass. This exact mapping is repeated during every native candidate validation before and after reading; a shared HWND/PID, ancestor match, null mapping or failed comparison never suffices. Every native object retains exact window/process and safe state; the full chain of COM identities and roles is reacquired before and after the sole shared selected-text read. The UIA focus must be Document/Text or the observed PDF Group with a bounded, stable Group/Document-only path to its first Document, excluding edit/combo/button/unknown controls. Queried IA2 text must share COM identity with its validated accessible object.

UIA source PID may be a renderer PID, so it is bound and revalidated rather than assumed equal to the native window owner PID. The MSAA native-window bridge must still return a window rooted at the exact browser, owned by its original window process. Missing metadata fails closed. Same selection offsets cannot prove immutable document identity across navigation; this is a fixed-public-fixture diagnostic, never a production extraction template.

No IA2 proxy is installed or registered. CoGetPSClsid is queried read-only to report the currently registered proxy CLSID/HRESULT. Legacy GetIAccessible also logs pointer presence: S_OK/null means a missing bridge, not a QI failure. QI/QueryService HRESULTs are logged individually. Interface failure does not prove Edge lacks IA2 because cross-process marshaling may need a proxy. The existing external 60-second process watchdog is the runtime bound; synchronous COM calls have no claimed in-process deadline guarantee. IA2 results do not change production behavior, default test results or release gates.

If re-created native focus chains fail strict COM identity/role/state equality, the probe logs per-node equality flags. It may revalidate the original terminal's source/state and bound UIA focus, then inspect QI/QueryService and exact UIA mapping metadata only. That rejection branch always returns without invoking any selection getter or text read, regardless of favorable metadata. This distinguishes wrapper identity instability from unavailable interfaces without weakening text admission. An identity mismatch alone does not prove page navigation or lack of IA2 support.


## Service-owned accessible mapping (metadata only)

QueryService is allowed to return a different COM object. On a rejected unstable
native chain, an isolated helper queries the retained terminal's existing
IAccessibleText service result for its own IAccessible. The two service-owned
interfaces must expose equal non-null canonical IUnknown pointers. The helper
then checks both objects' source HWND/PID/state, logs the service role/state,
and repeats ElementFromIAccessible(serviceAccessible, CHILDID_SELF) and exact
CompareElements(originalBoundFocus) twice against the same retained service
object. Full original focus/path and password/offscreen/PID safety remain
checked. Only HRESULTs and identity/state booleans are logged. No selection,
text, extents, name/value, or descendant read is added. The helper returns no
interface and cannot call a text admission function. The rejected outer branch
still returns unconditionally, even if all service mapping metadata succeeds.

Direct QI failure is an inconclusive capability result, not evidence Edge lacks
IA2. ElementFromIAccessible can be limited when the application implements both
native UIA and MSAA. A positive result would support a separately reviewed
identity strategy; it would not clear the current failed chain guard, establish
correct text, or change production/release status. The existing timeout, public
fixture hash, isolated profile, and unchanged expected-text failure are retained.

References:
- https://accessibility.linuxfoundation.org/a11yspecs/ia2/docs/html/_general_info.html
- https://learn.microsoft.com/en-us/windows/win32/com/rules-for-implementing-queryinterface
- https://learn.microsoft.com/en-us/windows/win32/winauto/getting-an-accessible-object-interface-pointer
- https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation-elementfromiaccessible

## Chromium documented UniqueId identity comparison

The generic service-owned ElementFromIAccessible mapping failed in both
observations on Edge 156 at commit 0388fc4. A separate metadata-only helper now
compares Chromium's documented custom UniqueId property on ONLY the already
bound exact UIA focus with IAccessible2::uniqueID on the retained service
object. No ItemContainer search, tree scan or guessed runtime-ID field is used.

The helper uses the official GUID CC7EEB32-4B62-4F4C-AFF6-1C2E5752AD8E, name
UniqueId and UIAutomationType_String. Microsoft requires both client and
provider to register custom properties at runtime. IUIAutomationRegistrar's
registration is process-global metadata that expires with the diagnostic
process, not persistent Windows registry/DLL/typelib/proxy installation. The
helper registers only this documented property once and never hard-codes a
numeric property ID. A UiaLookupId-only experiment is omitted because it cannot
prove a usable registration for a separate client process.

The IAccessible2 interface must share non-null canonical IUnknown identity
with both the retained IAccessibleText and its own IAccessible. Only get_uniqueID
and get_windowHandle are read. HWND/root/process and existing safe source/focus
checks bracket each of two observations on the retained object. The exact UIA
focus value must be a nonempty VT_BSTR of at most 11 characters, fully equal to
the decimal signed IA2 ID; there is no extra sign negation. Arbitrary returned
strings are never logged. Positive matching/stable ID metadata alone does not
allow a selected-text read, clear the failed native chain, establish navigation
race safety, or change release status. The outer branch returns unconditionally.

Accessible2.idl, AccessibleRelation.idl and AccessibleStates.idl use the same
pinned LinuxA11y/IAccessible2 revision as the existing text IDL. All three retain
their licenses and source bytes. MIDL generates official core/dependency headers;
no handwritten vtable or proxy registration is used.

- https://chromium.googlesource.com/chromium/src/+/HEAD/docs/accessibility/browser/custom_uia_properties.md
- https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/accessibility/browser/ia2_to_uia.md
- https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-regcustompropseventpatterns
