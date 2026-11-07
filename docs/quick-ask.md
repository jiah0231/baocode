# Quick Ask: Chat and Agent

Select text in an editor, a draft or a conversation, then use **Ctrl+Alt+K**
(Windows/Linux) or **⌘⌥K** (macOS). The command remains `baocode.quickAsk`.
The 320 px popup follows the selected end and flips/clamps at the window edges.
It has one visible control: the **Chat / Agent** mode selector. No request is
made when opening it or changing modes.

- **Enter** or **Ctrl/⌘+Enter** sends; **Shift+Enter** inserts a new line.
  **Esc** cancels the popup request and closes it. An outside click dismisses it
  without pulling focus back from the clicked surface.
- Right-click the popup, or press **Shift+F10** / the menu key, for context review,
  selection/nearby-context inclusion, model choice, Stop, Copy and selection-edit
  preview actions. These are secondary commands, not a permanent toolbar.
- **Chat** streams a read-only answer in the popup. It uses Settings → Models →
  Quick Ask (following Auxiliary by default) and never receives file-reading,
  terminal or edit tools. It does not create a saved conversation.
- **Agent** sends the request to a fresh normal agent for the captured project,
  then opens that conversation. It retains the source agent's engine, model,
  approval and sandbox choices. It uses the ordinary project rules, tools,
  progress, permission prompts and change-review UI. It does not overwrite an
  existing draft, continue the source conversation or use the Quick Ask model.
  Agent is unavailable without an eligible project destination.

## What context is sent

The popup captures a snapshot before focus moves. It supplies a source label,
selected text (at most 8,000 UTF-16 code units) and a nearby excerpt (at most
4,000). The question is limited to 4,000. Surrogate pairs are not split.
Without a selection, supported editors capture the cursor neighborhood. An
empty conversation composer may supply up to two recent visible text messages,
within the same 4,000-unit budget. It does not silently attach the clipboard,
all open files, full conversation, repository, terminal, or another session.

**Review context** shows the excerpts before sending. Selection and nearby
context can each be excluded. A shortened selection is marked in the preview
and request. Context is encoded as quoted JSON data, separate from the request,
so source text containing role labels or commands is not an instruction.

Chat is a bounded, one-turn auxiliary request. Agent receives the same bounded
snapshot initially, but can subsequently read project files and use tools under
its normal permissions. Agent is explicitly told to read current source and
verify the target before editing; the snapshot is not a substitute for checking
a changed file. This is not repository indexing or automatic semantic retrieval.

## Selection-edit previews

In Chat's secondary menu, **Edit selection** requests replacement text rather
than executing tools. Review and adjust the proposed text, then choose
**Apply replacement** explicitly. Only the originally captured editable range
is replaced, as one undoable editor operation. Changed/closed sources, incomplete
streams and shortened selections cannot be applied. Normal save settings apply.
Sent conversation history and read-only previews can be copied, not rewritten.

## Cursor reference

This is a **Cursor-inspired inline UI**, not a claim to reproduce its internal
context system. Current [Cursor Agent documentation](https://cursor.com/help/ai-features/agent)
says Cmd/Ctrl+K or L sends selected lines into Agent and replaces its former inline
edit workflow. [Ask](https://cursor.com/help/ai-features/ask-mode) is read-only.
The [May 2025 changelog](https://cursor.com/changelog/0-50) documents the older
inline editor's selection-to-Agent path. BaoCode keeps the small anchored popup
requested here while using its own real agent and permissions for execution.

[Cursor's prompting guide](https://cursor.com/docs/agent/prompting) describes
explicit context attachments and tool-driven retrieval. BaoCode deliberately
keeps this popup's automatic snapshot bounded and reviewable; it does not claim
Cursor's retrieval, model limits or privacy guarantees.

## Verification

`test/quick_ask` covers bounded prompts, model routing, real-agent handoff,
streaming, cancellation, stale edits, focus, secondary menus, theme and layout.
`Quick Ask validation` runs these and related editor, history and composer
regressions without live provider calls. The signed Windows release workflow
must pass its broader regression/build gates before an update is published.
