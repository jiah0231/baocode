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
`156.0.8078.80`, verify its official version-specific metadata, log the archive
SHA-256, and remove their unique extracted binary/archive directory.

Pinned metadata: https://googlechromelabs.github.io/chrome-for-testing/156.0.8078.80.json

Pinned archive: https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.80/win64/chrome-win64.zip

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
