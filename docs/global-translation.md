# Selection translation

BaoCode custom 1.9.1+48 adds a lightweight translation panel to the existing Flutter application. It does not install a second app, browser, webview, model or background service.

## Use

- Windows: select text in another application, then press **Ctrl+Alt+Y** while BaoCode is running. BaoCode opens a translation panel with the captured source. Review it and click **Translate**.
- Within BaoCode: use the **Translate Selection** command, **Ctrl+Alt+Y** (**Cmd+Option+Y** on macOS), or the translation entry in editor/chat selection context menus.
- Configure the Windows global shortcut or disable it in **Settings → Region & Language** or **Keyboard Shortcuts**. A registration failure is shown if another app owns the keys.
- Translation follows **Models → Quick Ask**, displays the resolved provider and model, and uses the existing text-only model transport. Configure that model before translating. Standard provider charges can apply.
- Source detection plus Chinese, English, Japanese, Korean, French, German and Spanish are available. Edit/paste text, swap explicitly selected languages, retry, cancel or copy the result.

## Privacy and limits

Only clicking Translate submits the text visible in the panel. Selecting text, opening the panel, changing language and setting a shortcut do not contact a model. No tools, project files or conversation history are attached, and BaoCode does not keep translation history. The selected provider's data policy still applies.

Windows capture reads only UI Automation's selected text ranges of the foreground focused control. It refuses password controls and invalid focus, bounds input to 8,000 UTF-16 units, and uses a background worker with a response deadline. It never monitors or injects keys, reads the clipboard, or replaces its contents. Only the explicit **Copy translation** button writes the clipboard.

Some applications, elevated windows, custom-rendered controls and browser accessibility configurations do not expose selected text through UI Automation. In that case, copy the selection yourself and paste into the panel. This release does not implement OCR, automatic mouse-up popups, or macOS/Linux system-wide selection capture. In-app translation works on those platforms.

## Design references

The compact source/result workflow, global shortcut and explicit selection action were informed by [STranslate](https://github.com/STranslate/STranslate) (MIT). This feature is an independent implementation using BaoCode's existing components and Windows APIs; no STranslate code or assets are bundled. A separate Electron/WPF app or model runtime is deliberately not embedded.

## Verification

`tool/ci/windows_translation_smoke.ps1` compiles a Windows SDK fixture in a separate process. It exercises the real selection capture code with selected text, a caret, a password field, an unsupported control, oversize text and changed foreground, and verifies the clipboard sequence is unchanged. Dart tests cover exact model input, routing, safe errors, cancellation, repeated opening, theme layouts and hotkey lifecycle. The isolated translation workflow makes no live model requests or releases. The signed custom release workflow repeats feature checks before publishing.
