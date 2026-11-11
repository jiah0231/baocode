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

## Opt-in selected-range experiment with supported Chromium identity

`-IA2 -ChromiumBoundIA2` selects a separate diagnostic implementation. It does
not call the old bridge or change that bridge's failure return. The ordinary
`-IA2` mode remains unchanged. Only the isolated public fixture is permitted.

The new path binds the exact original safe UIA focus/path and its documented
UniqueId to a retained service-owned IAccessibleText/IAccessible2/IAccessible.
All three canonical IUnknown pointers must match. It records the service's
negative Chromium node ID, containing HWND, original native process IDs and
readonly focused Pane role/state. Every candidate validation reacquires the
bounded native focus-only chain, checks the same chain length/role/state, unwraps
the fresh terminal service and requires its canonical IUnknown to equal the
retained service. Similar MSAA wrappers alone never suffice. Both retained and
fresh core ID/HWND values, owning PIDs, safe states and exact-focus UniqueId must
still match before admission and after all metadata calls.

The experiment then uses the existing single shared selected-read implementation:
exactly one noncollapsed IA2 selection, explicit bounded offsets, endpoint/identity
rechecks before text, exactly one get_text call, and full post-read validation
before text logging. The expected phrase is evaluated only after admission; it
is never used as an identity shortcut. All original production icon/raw-UIA
assertions remain unchanged, so a correct diagnostic IA2 string alone cannot
turn this into a production or release success.

This remains a fixed public-fixture investigation. Browser identity/profile/URI
are verified at setup, and retained process lifetime/creation time/HWND/PID and
foreground are rechecked during execution. The experiment does not claim to
prove immutable document contents or every navigation race. Its source-mutation
tests do not replace runtime safety tests. No translation request is sent.

## Opt-in one-level selected embedded-object experiment

The prior bound-container test returned U+FFFC at the current IA2 selection,
with an abstract-sized extent, while its identity checks all passed. The new
`-IA2 -ChromiumBoundIA2 -SelectedEmbeddedIA2` mode follows exactly that one
currently selected embedded object using the official Hypertext APIs. This is
an independent fixed-public-fixture diagnostic, not a product fallback.

This mode explicitly permits a maximum of two selected-text calls total, one
per stage. The first reads at most one currently selected character using all
root identity/selection validation and must return U+FFFC in this run. The second
reads at most4096 characters from the child object's own current selection,
only after all relationship/safety checks. Budgets are consumed before calls,
never reset, and old single-read modes remain mutually exclusive and unchanged.

Only get_hyperlinkIndex(parentSelectionStart) followed by get_hyperlink(index)
is used. No hyperlink count, child enumeration, anchor/anchorTarget, action or
full-document getter is used. Link endpoints must exactly equal the current
parent selection; the link/text/core/own-accessible interfaces must share a
canonical identity distinct from the parent. The child must be native Text
role, explicitly readonly, in the original native source HWND/PID, and free of
MSAA protected/invisible/offscreen/unavailable states and IA2 editable/defunct
states. Unknown state/HRESULT/role rejects before child selection getters.

Every child validation freshly re-resolves the same selected offset and link,
requires the same child canonical identity/index and unchanged parent selection,
and rechecks retained/fresh child role/state/ID/HWND/PIDs plus the complete
original root identity/focus/UniqueId binding. The child is not claimed to have
keyboard focus or UIA password validation; its native checks and exact selected
relationship are explicit, separately reviewed guards. Another child U+FFFC is
unsupported at depth one; this probe never recurses.

Added official Action/Hyperlink/Hypertext IDLs use the same pinned revision and
license/hash checks. Their MIDL headers are generated in dependency order.
Text output is logged only after full post-read checks. Stable IDs/offsets do
not prove immutable content or general navigation safety. Production raw-UIA
and icon assertions remain unchanged regardless of diagnostic child text.

## Opt-in exact semantic paragraph selection

`-SelectedParagraphIA2` requires all three existing explicit diagnostic switches
and selects a separate role predicate. It does not allow arbitrary Grouping.
The already identity-bound, uniquely selected child must report MSAA Grouping,
IAccessible2::role S_OK with exactly IA2_ROLE_PARAGRAPH, explicit readonly state,
and successful noneditable/nondefunct IA2 states. The semantic role is captured
and checked again on retained and freshly resolved interfaces during every
child validation. The original native-Text-only mode remains the default branch.

Chromium explicitly maps a semantic paragraph to MSAA Grouping but separately
reports IA2_ROLE_PARAGRAPH. This supplies a role distinction absent from MSAA;
it does not prove that the actual Edge child is a paragraph or that its selection
will be correct. The experiment observes that metadata and only conditionally
proceeds, using the same exact selected relationship, one-level limit and two
stage/read budget. No other selected-object or product guard changes.

The official AccessibleRole.idl from the existing pinned LinuxA11y revision is
included with license/hash verification and generated with MIDL. The code uses
the official enum, not a handwritten numeric role.

https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/accessibility/platform/ax_platform_node_win.cc
https://raw.githubusercontent.com/LinuxA11y/IAccessible2/c9ae003d9c85eb707716928de97e055f5b77189c/api/AccessibleRole.idl


## Paragraph counterexample and explicit endpoint metadata mode

Commit 196472e205dbfda2cc38feaaf420d3929a4585bb, first run
https://github.com/jiah0231/baocode/actions/runs/42948756454, confirmed the unique
child's readonly IA2 paragraph role. The source/selection checks passed, but
its current 1025..1035 slice returned `e a multim` while the screenshot showed
`VAD method`. This paragraph text fallback is rejected, not a product fix.

`-SelectedEndpointMetadataIA2` is a new explicit diagnostic mode that requires
`-SelectedParagraphIA2` (and its existing prerequisites). It replaces the child
paragraph text-read branch; it does not run alongside it. The parent one-character
U+FFFC read remains solely to establish the existing exact selected-child binding.
New endpoint and paragraph text calls in this mode are both zero.

Only the bound paragraph is queried for IAccessible2_3 and
IAccessibleTextSelectionContainer. Both interfaces must have the paragraph's
canonical IUnknown. At most two explicit snapshots call each selection getter
once, with full current root/paragraph validation around each stage. Only S_OK
and exactly one range with nonnull endpoints are accepted. Returned endpoints
are checked for canonical interface identity, native owner, ID, role and safe
readonly states. Only readonly Text or the canonical already-bound paragraph is
admitted for metadata. No generic Grouping expansion or enumeration is used.

The raw anchor/active identities must match the container start/end identities
after accounting for startIsActive; complete metadata must agree within and
between snapshots. Raw offsets are NOT compared to hypertext offsets because
non-leaf raw positions can be child indexes. They must never be passed to text
getters. An endpoint mismatch/cropping, multiple range, unsafe or changing
object, different endpoint objects, collapsed/unbounded selected range or
unsupported interface stops this mode. No traversal tries to explain a mismatch.

The single-object check includes the already-bound paragraph, not just Text-role
endpoints. A stable result is not proof that a Text-role endpoint was found.
Even a successful metadata result is not evidence that text matches the screen
and does not authorize endpoint text reads. Any later text read needs separate
review with direct hypertext coordinates and complete source/selection guards.
The original UIA expected-text and production-icon assertions are unchanged.

Official IDLs are unmodified, pinned to the same LinuxA11y commit as before:
- api/Accessible2_2.idl: e87fa6f8feda4a4fdcd4bf0faeb8cba1249afff91d33b84e60234ca86bdcf898
- api/Accessible2_3.idl: 2dcb0d4a9301df2deed9db0d1c7c251c7d840acd565f2d2d6fa1800cd4d90f12
- api/AccessibleTextSelectionContainer.idl: f829fb3079cb35e0490c85e2b13efb2b85c89b99ef7efe37539f21f185d93765

Returned arrays release their owned interface references and then use
CoTaskMemFree. To avoid trusting an abnormal count for unbounded cleanup, only
counts 0..64 are iterated; larger/negative replies are rejected and their block
is freed without dereferencing elements. Any remaining COM references live only
until this bounded, disposable probe exits. No response objects outside the
sole accepted range are queried for metadata.

The additional source-shape verifier rejects 66 mutations, including endpoint
text calls and tree traversal. It is not runtime privacy or race-safety testing.
No product fallback, main-branch change, gate bypass, merge or publication is
part of this diagnostic.


## Independent selection-container metadata experiment

The first endpoint-interface run f99612ad5155962c7e3b2edb0fcbce7f79480168 /
42950366644 stopped because QI(IAccessible2_3) on the bound paragraph returned
E_NOINTERFACE. No endpoint snapshot or second-interface query occurred. This
did not establish that the independent selection-container interface is absent.

Official AccessibleTextSelectionContainer.idl directly extends IUnknown and
permits this interface on objects supporting IAccessibleText/Hypertext, including
a document subtree. Its read-only get_selections returns endpoint text objects
and their own character offsets, but the returned selection can be cropped to
the queried subtree. Current Chromium main's implementation is source rationale,
not proof that the tested Edge version exposes that interface.

The separately opted-in `-SelectionContainerOnlyMetadataIA2` requires the existing
metadata mode for its pinned generated-header prerequisites. The call branch is
mutually exclusive with the IAccessible2_3 experiment. It does not repeat that
failed query, and it still excludes paragraph and endpoint text reads.

Only QI on the same already-bound paragraph is attempted. Canonical identity
must match. At most two get_selections snapshots require S_OK, exactly one
nonnull range, complete parent/root identity guards, safe endpoint metadata,
single identical endpoint object, and stable state, direction and bounded
nonempty offsets. No endpoint outside the returned current selection is sought.
The previously reviewed metadata and cleanup helpers are unchanged.

This is intentionally not the old two-interface consistency check with a weaker
acceptance claim: it reports croppingUnverified=1, does not establish physical
selection completeness, and is not a text-source admission. The single endpoint
can still be the already-bound paragraph rather than a Text-role object. A
failure stops without another object, API retry, proxy registration, traversal,
text read or system change. Existing UIA and icon correctness assertions remain.

The added structural verifier rejects 55 mutations (249 total across all five
suites); it does not establish runtime correctness or race/privacy safety.
