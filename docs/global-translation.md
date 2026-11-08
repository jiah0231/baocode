# Selection translation

BaoCode custom 1.9.1+49 opens a dedicated lightweight Windows translation window using the existing Flutter engine. It does not install a second app, browser, webview, model or background service.

## Use

- Windows: select text in another application, then press **Ctrl+Alt+Y** while BaoCode is running. A floating translation window opens near the selected text (or the pointer when bounds are unavailable), without opening, restoring or focusing the BaoCode workbench. Review the source and click **Translate**.
- The workbench can be minimized or hidden in the system tray. Keep **Notifications → System tray** enabled if you want closing the last workbench window to keep BaoCode running. Explicit Quit or a disabled tray ending the last window stops global shortcuts. This feature does not change your startup/tray preferences or install a background service.
- Close the floating window with **Escape**, **Alt+F4**, its close button, or the same shortcut while it is focused. Clicking another app hides it without stealing focus back. Closing cancels the current translation and clears the source/result; reopening starts a fresh session.
- Within BaoCode: use the **Translate Selection** command, **Ctrl+Alt+Y** (**Cmd+Option+Y** on macOS), or the translation entry in editor/chat selection context menus.
- Configure the Windows global shortcut or disable it in **Settings → Region & Language** or **Keyboard Shortcuts**. A registration failure is shown if another app owns the keys.
- Translation follows **Models → Quick Ask**, displays the resolved provider and model, and uses the existing text-only model transport. Configure that model before translating. Standard provider charges can apply.
- Source detection plus Chinese, English, Japanese, Korean, French, German and Spanish are available. Edit/paste text, swap explicitly selected languages, retry, cancel or copy the result.

## Privacy and limits

Only clicking Translate submits the text visible in the panel. Selecting text, opening the panel, changing language and setting a shortcut do not contact a model. No tools, project files or conversation history are attached, and BaoCode does not keep translation history. The selected provider's data policy still applies.

The existing Usage page can still record token counts. If you explicitly enabled Usage debug tracing (off by default), model request and response bodies may be stored in its local diagnostic logs. The panel warns while that setting is enabled; turn it off in Usage settings if you do not want such logs.

Windows capture reads only UI Automation's selected text ranges of the foreground focused control. It refuses password controls and invalid focus, bounds input to 8,000 UTF-16 units, and uses a background worker with a response deadline. It never monitors or injects keys, reads the clipboard, or replaces its contents. Only the explicit **Copy translation** button writes the clipboard.

Some applications, elevated windows, custom-rendered controls and browser accessibility configurations do not expose selected text through UI Automation. In that case, copy the selection yourself and paste into the panel. This release does not implement OCR, automatic mouse-up popups, or macOS/Linux system-wide selection capture. In-app translation works on those platforms.

## Design references

The compact source/result workflow, global shortcut and explicit selection action were informed by [STranslate](https://github.com/STranslate/STranslate) (MIT). Its [input-trigger flow](https://github.com/STranslate/STranslate/blob/main/src/docs/flow-input-trigger.md) directly shows its lightweight translation window from the background and supports hiding on deactivation. BaoCode separates that translation surface from its much larger workbench rather than opening the workbench first. This feature is an independent implementation using BaoCode's existing components and Windows APIs; no STranslate code or assets are bundled. A separate Electron/WPF app or model runtime is deliberately not embedded.

## Verification

`tool/ci/windows_translation_smoke.ps1` compiles a Windows SDK fixture in a separate process. It exercises the real selection capture code with selected text, a caret, a password field, an unsupported control, oversize text and changed foreground, and verifies the clipboard sequence is unchanged. Dart tests cover exact model input, routing, safe errors, cancellation, repeated opening, theme layouts and hotkey lifecycle. `tool/ci/windows_translation_window_smoke.ps1` additionally exercises the compiled application on a disposable Windows runner, using only synthetic text and an isolated data directory. It checks the real global shortcut with the workbench hidden/minimized, independent tool-window visibility, focus/close/reopen behavior and clipboard protection, and captures theme screenshots. The isolated translation workflow makes no live model requests or releases. The signed custom release workflow repeats feature checks before publishing.
