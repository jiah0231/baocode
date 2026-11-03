# Disposable real Chrome takeover smoke

`browser_takeover_real_chrome_test.dart` is an **opt-in CDP integration smoke**.
Its native-protocol fixture preserves the production bridge's length-framed
JSON and authenticated loopback handshake. CDP commands, acknowledgements,
events, screenshots, trusted input, session closes and reattachments are real
Chrome operations. Only native-host/extension transport, tab metadata mapping,
and the extension's watch badge are substituted.

## Runner prerequisites

- The repository's pinned Flutter SDK and resolved packages.
- A freshly extracted **official Chrome for Testing** build, not the runner's
  installed Chrome and never the user's Chrome profile.
- The exact CfT version supplied as `BAOCODE_CFT_VERSION`. The test checks the
  running browser version, but cannot establish download provenance itself.
  A runner must obtain the build from the official CfT availability JSON and
  download URL, record the selected version/URL, and record the archive hash.
- A runner that can start sandboxed headless Chrome. The test does not disable
  Chrome's sandbox or alter firewall, registry, host registration or permissions.
  Windows CI is suitable. A Linux root-only container needing `--no-sandbox` is
  not a supported fallback for this smoke.

Official download metadata: https://googlechromelabs.github.io/chrome-for-testing/

No package/browser download happens in the Dart test. It creates fresh temporary
app data, history, socket and Chrome profile directories, serves fixture pages
on `127.0.0.1`, launches Chrome with a random **loopback-only** DevTools port,
and removes its own profile when finished. All page traffic is local. Background
networking, component updates, sync and extensions are disabled for this browser.
This does not claim OS-level network isolation.

PowerShell, after obtaining the official binary:

```powershell
$env:BAOCODE_REAL_CHROME_SMOKE = '1'
$env:BAOCODE_CHROME_FOR_TESTING = '<fresh CfT directory>\chrome-win64\chrome.exe'
$env:BAOCODE_CFT_VERSION = '<exact four-part CfT version>'
flutter test test/browser/browser_takeover_real_chrome_test.dart --reporter expanded
```

The file skips unless `BAOCODE_REAL_CHROME_SMOKE=1` is explicitly set. Enabling
it without executable/version configuration is a failure, not a silent skip.
Both Windows CI workflows run it in a separate, fail-closed step after the
early synthetic gate. The step still runs if an earlier test fails but analysis
succeeded; its failure cannot be bypassed for publication. Both pin CfT
`156.0.8078.80`, verify its official version-specific metadata, verify the archive
SHA-256, and remove their unique extracted binary/archive directory. The checksum
was recorded from the official archive in Windows run `41587272125`; it is not
a separate vendor-published signature.

Pinned metadata: https://googlechromelabs.github.io/chrome-for-testing/156.0.8078.80.json

Pinned archive: https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.80/win64/chrome-win64.zip

Pinned archive SHA-256: `16edb57d6107bf1c48a7c149b8d78b155fe614410093796dd72441fd6640540f`

## Assertions

1. Fresh application state is paused. A registered main-agent browser tool is
   rejected before any CDP command; explicit Resume permits a real tool call.
2. Real authorized console/network activity is captured.
3. The real production recorder receives trusted Chrome input. One exact old
   binding event is held by the transport, and another input remains queued in
   its real debounce timer when takeover happens.
4. Global takeover completes within ten seconds, all required domain shutdowns
   receive actual Chrome acknowledgements, the recorder ends, queued input is
   discarded, and the real CDP session closes.
5. While still paused, the human path reattaches to the same target, obtains a
   real PNG and types into the page. The main-agent tool remains blocked.
6. After explicit Resume, a new recorder has a different generation and records
   new input. Releasing the old Chrome binding event does not backfill it.
   Console history emitted by `Runtime.enable` and network activity from the
   protected interval do not enter desktop records.
7. Same-conversation recovery cannot replace a live connection. Once the
   original native-protocol connection dies, a replacement still does not bind
   implicitly; explicit rebind and a separate Resume are required.
8. Unexpected real protocol errors are surfaced, including late errors.

## Limits that must accompany a result

A pass is **not** an extension/native-host end-to-end result. This fixture does
not load BaoCode's unchanged extension, test `chrome.debugger` attach/detach
notification timing, verify sharing/tab-group guards, register the Windows
native host, or operate a real account. It also does not render Flutter's browser
panel, test modal-dialog timing, multi-profile selection, restart the browser,
or test every optional debug domain (Fetch, Debugger, Tracing and CSS). Those
remain separate native integration/manual and synthetic test coverage.

Chrome protocol references:
- https://chromedevtools.github.io/devtools-protocol/tot/Runtime/
- https://chromedevtools.github.io/devtools-protocol/tot/Page/
- https://developer.chrome.com/docs/extensions/reference/api/debugger

## Browser panel click regression

`browser_mirror_real_chrome_test.dart` uses the same explicit opt-in and supplied
official CfT binary. Run it separately from the takeover test:

```powershell
flutter test test/browser/browser_mirror_real_chrome_test.dart --reporter expanded
```

This test mounts the production `BrowserMirror` widget. It finds an off-center
colored target in the **painted Flutter RepaintBoundary pixels**, clicks that
location with a Flutter mouse gesture, and checks the real page's trusted
`pointerdown`, `pointerup` and `wheel` target and `clientX`/`clientY`. It never
uses the production coordinate helpers to choose the click or fabricate CDP
mouse input. Wheel scaling is checked against the painted target width and its
independently measured DOM width.

The matrix covers actual Chrome browser zoom 100%, 125%, 150% and 200%; Flutter
view DPR 1, 1.25, 1.5 and 2; narrow and wide panel layouts; blank margins; explicitly reserved classic
scrollbars (verified against DOM viewport widths); pinch scale 1.5 plus page
scrolling and an off-center native touchpad pinch with required nonzero visual-viewport offsets; and screenshot fallback followed by stream
resumption. The fixture writes only its newly created disposable profile's
zoom preference. Each run must verify the requested real browser zoom through
`Page.getLayoutMetrics.cssVisualViewport.zoom` and `window.devicePixelRatio`.
A preference that no longer works fails the test instead of silently testing
100% zoom. Chrome's own device scale is 1.25 in the 200% browser-zoom case
and 1 in the others, independently checked through devicePixelRatio. This
controlled flag plus the Flutter DPR matrix is not proof of the user's native
Windows display-scaling settings.

For fallback, the adapter suppresses only actual screencast-event forwarding
and ACKs those real frames, so it does not stall Chrome's stream. The mirror
must obtain a real screenshot and resume real streaming afterward. The test
keeps bounded input/capture command evidence and checks late protocol errors.
Native touchpad pinch CDP is used only to set up the panned viewport; every asserted
click still goes through Flutter and the production mirror. The setup must
produce nonzero `visualViewport.offsetLeft` and `offsetTop`, or the test fails.
The extension/native-host installation limitations above still apply.

These new tests require execution with the repository's pinned Flutter SDK
and an authorized sandbox-capable runner. Merely adding them, or passing the
synthetic socket tests, is not evidence that this real rendering test passed.

### Wheel compatibility boundary

Chrome 156 and verified 157 source forward CDP wheel deltas as surface DIPs,
whereas mouse positions are CSS pixels. The upstream correction is present in
tagged 158.0.8111.0. The mirror reads only a parsed Chromium major through an
existing Runtime command and keeps it in memory for the capture generation.
It does not collect the full user agent, profile data or fullVersionList, use
the unavailable Browser domain, or send calibration input to a user page.
Recognized majors up to 157 use legacy DIP wheel mapping. Newer, malformed or
unavailable versions use the standard CSS contract. Synthetic tests exercise
both branches and read failure; the real DOM oracle remains independent.
This is a bounded compatibility heuristic, not a guarantee for early 158
builds, vendor backports, forks, or overridden user-agent values. Native Chrome
158+ has not been runtime-tested by this pinned 156 fixture.

Source correction: https://github.com/chromium/chromium/commit/b6291517908abb64a348cfdcc140dbd5ec16a867
