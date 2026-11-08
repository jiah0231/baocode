# Selection translation

BaoCode custom 1.9.1+49 opens a dedicated lightweight Windows translation window using the existing Flutter engine. It does not install a second app, browser, webview, model or background service.

## Use

- Windows: drag-select or double-click text in another application. When the control exposes a selection, a small **译** entry appears nearby; click it to load the source into the translation window. You can instead press **Ctrl+Alt+Y** while BaoCode is running. A floating translation window opens near the selected text (or the pointer when bounds are unavailable), without opening, restoring or focusing the BaoCode workbench. Review the source and click **Translate**.
- The workbench can be minimized or hidden in the system tray. Keep **Notifications → System tray** enabled if you want closing the last workbench window to keep BaoCode running. Explicit Quit or a disabled tray ending the last window stops global shortcuts. This feature does not change your startup/tray preferences or install a background service.
- Close the floating window with **Escape**, **Alt+F4**, **Ctrl+W**, **Ctrl+Shift+W**, its close button, or the same shortcut while it is focused. Clicking another app hides it without stealing focus back. Closing cancels the current translation and clears the source/result; reopening starts a fresh session.
- Within BaoCode: use the **Translate Selection** command, **Ctrl+Alt+Y** (**Cmd+Option+Y** on macOS), or the translation entry in editor/chat selection context menus.
- Configure the Windows global shortcut or disable it in **Settings → Region & Language** or **Keyboard Shortcuts**. The Region & Language translation card also lets you disable the selection entry or automatic selection-copy fallback independently. Defaults are enabled without rewriting existing preferences. A registration failure is shown if another app owns the keys or the selection entry could not start.
- Translation follows **Models → Quick Ask**, displays the resolved provider and model, and uses the existing text-only model transport. Configure that model before translating. Standard provider charges can apply.
- Source detection plus Chinese, English, Japanese, Korean, French, German and Spanish are available. Edit/paste text, swap explicitly selected languages, retry, cancel or copy the result.

## Privacy and limits

Only clicking Translate submits the text visible in the panel. Selecting text, opening the panel, changing language and setting a shortcut do not contact a model. No tools, project files or conversation history are attached, and BaoCode does not keep translation history. The selected provider's data policy still applies.

The existing Usage page can still record token counts. If you explicitly enabled Usage debug tracing (off by default), model request and response bodies may be stored in its local diagnostic logs. The panel warns while that setting is enabled; turn it off in Usage settings if you do not want such logs.

The mouse-selection entry uses a mouse hook and UI Automation metadata to detect a nonempty selection in the current foreground control. It does not read selected text, field values or the clipboard while waiting for clicks. The entry does not take focus and disappears on selection/focus changes or after a short timeout. Only clicking the entry or pressing the shortcut requests source capture. Keyboard-only selection can use the shortcut.

Explicit capture first reads only UI Automation's selected ranges. It refuses password controls and invalid focus, bounds input to 8,000 UTF-16 units, and uses a background worker with a response deadline. If selection text is unsupported, the optional copy fallback is limited to verified non-password native Edit/RichEdit controls at ordinary privilege. It waits for shortcut keys to be released, sends Ctrl+C once, and accepts only newly changed clipboard data from the same focused target. It attempts to restore supported original clipboard formats only while the captured clipboard sequence still belongs to that operation. It aborts on unrelated writes, changed focus or user input, unsafe/unsupported clipboard formats, a collapsed selection, cancellation or timeout. It does not read a previous clipboard value as source, monitor clipboard changes in the background, or copy translation results automatically.

Clipboard copying is not transactional: clipboard managers or cloud sync may observe the temporary text even after restoration, and delayed target writes or simultaneous same-target user copying cannot always be distinguished perfectly by Windows. Disable the fallback if this matters to you. A detected restoration failure produces a warning, including when the capture has already been canceled; it never reopens an old window to display the warning. Only the explicit **Copy translation** button copies translated output.

Some applications, elevated windows, custom-rendered controls and browser accessibility configurations do not expose a usable selected range. The copy fallback deliberately does not inject Ctrl+C into terminals or general browser documents, where it can have another meaning. If capture is unavailable, copy the selection yourself and paste into the panel. This release does not implement OCR or macOS/Linux system-wide selection capture. In-app translation works on those platforms.

## Design references

The compact source/result workflow, global shortcut and explicit selection action were informed by [STranslate](https://github.com/STranslate/STranslate) (MIT). Its [input-trigger flow](https://github.com/STranslate/STranslate/blob/main/src/docs/flow-input-trigger.md) directly shows its lightweight translation window from the background and supports hiding on deactivation. BaoCode separates that translation surface from its much larger workbench rather than opening the workbench first. This feature is an independent implementation using BaoCode's existing components and Windows APIs; no STranslate code or assets are bundled. A separate Electron/WPF app or model runtime is deliberately not embedded.

## Verification

`tool/ci/windows_translation_smoke.ps1` compiles a Windows SDK fixture in a separate process. It exercises the real selection capture code with selected text, a caret, a password field, an unsupported control, oversize text and changed foreground, and verifies the clipboard sequence is unchanged. `tool/ci/windows_translation_clipboard_smoke.ps1` tests actual keyboard injection and restoration against a separate-process fixture, including concurrent clipboard writers, slow/late copying, password controls and focus changes. `tool/ci/windows_translation_action_smoke.ps1` checks the nonactivating mouse-selection entry without reading source text, including non-text drags. `tool/ci/windows_translation_browser_smoke.ps1` checks cold and repeated selection in default Edge without prewarming accessibility, enabling special browser flags, injecting page scripts or copying through the clipboard. Dart tests cover exact model input, routing, safe errors, cancellation, repeated opening, theme layouts, tool-view keyboard isolation and hotkey lifecycle. `tool/ci/windows_translation_window_smoke.ps1` additionally exercises the compiled application on a disposable Windows runner, using only synthetic text and an isolated data directory. It checks the real global shortcut with the workbench hidden/minimized, independent tool-window visibility, focus/close/reopen behavior and clipboard protection, and captures theme screenshots. The isolated translation workflow makes no live model requests or releases. The signed custom release workflow repeats feature checks before publishing.


Real installed desktop application observations are recorded separately by
`tool/ci/windows_translation_desktop_smoke.ps1`. See
[the desktop coverage contract](windows-translation-desktop-coverage.md) and the
exact commit's CI artifacts for Notepad, local PDF, Console Host and installation
inventory results. A generic native control does not prove Office support, and a
successful browser page test does not establish PDF or terminal support.
