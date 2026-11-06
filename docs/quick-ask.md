# Quick Ask / Edit

Open the compact question window from the code editor or an agent conversation
with **Ctrl+Alt+K** (Windows/Linux) or **⌘⌥K** (macOS). The command is
`baocode.quickAsk`, available in the command catalog and keyboard settings.

- Select code, a draft, or text in an agent conversation first. Without a
  selection, supported editors provide a small neighborhood around the cursor.
- Ask a question, or choose **Edit selection** and describe the desired change.
- **Settings → Models → Quick Ask** chooses its model independently of normal
  conversations and AI actions. The popup also offers the same picker. Its
  default follows the auxiliary model.
- **Review context** shows the selected excerpt and the nearby text. Nearby
  context can be switched off before sending. No request occurs just by opening
  the window.
- Selection is capped at 8,000 UTF-16 code units, nearby context at 4,000, and the
  question at 4,000. A clipped selection can be asked about, but cannot be edited.
  It does not send the whole repository or whole conversation, attach files,
  create a saved agent conversation, or grant tool access.
- An edit is a preview first. Review and adjust it, then explicitly choose
  **Apply replacement**. Only the original editable selection is replaced, as
  one undoable edit. A changed/closed source refuses stale application. Normal
  editor auto-save settings still apply.
- Sent conversation history is not rewritten. An edited excerpt from it can be
  copied. Read-only code previews also offer copying rather than application.
- **Ctrl/⌘+Enter** sends. **Stop** cancels a request; **Esc** or the close button
  cancels and closes. Reopening starts a fresh question.

The frame, inputs, buttons, previews and errors use the active workbench theme,
including changes while the window is open. UI text is available in English and
Chinese. Requests use the existing configured provider infrastructure; a model
must be available and authenticated as for other auxiliary AI actions.

## Verification

Focused tests are in `test/quick_ask`, with catalog, provider and settings
regressions in their existing suites. `Quick Ask validation` runs these and the
related history-selection/composer regressions on a separate feature branch,
without publishing a release or invoking live providers.
