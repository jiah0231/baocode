# Inline learning and local work trace (preview)

These are two different surfaces, not two copies of an agent log:

- **Learn / 边看边学** in the conversation controls enables short teaching bubbles
  attached to the **exact completed operation** in the conversation. On a wide
  conversation, a bubble sits beside its command or code diff. In a narrow view
  it sits immediately below that same operation. It scrolls with the operation;
  there is no separate lesson feed or follow-latest mode. Expand a bubble for
  the possible rationale, useful concept, example, tradeoff and observed evidence.
- **Work trace / 工作轨迹** in the existing right panel is a model-written
  natural-language account of the current work: important actions, changes and
  what their observed results do (or do not) establish. It is **not** a locally
  templated list of tool calls. Short stages can explain how the observed work
  progresses, with optional expansion for supporting facts and exact source
  navigation. When no model result exists, the panel says so; it does not present
  local fallback text as generated prose. Local factual records are available
  only behind **Show raw evidence / 查看原始依据**. The rail remains resizable
  (360 px initially), independently of file/diff width, with the existing
  narrow-window overlay.

## Independent model and consent

Generated teaching and the work-process narrative are **off by default**. Configure a chat model from the existing
Settings → Models providers, then explicitly agree to the displayed provider,
model, contextual sharing and possible extra usage costs. The explanation model
is independent of the working agent. Consent is bound to the project and provider
configuration; changes require confirmation again.

Each **inline bubble** request contains evidence for **one operation only**, not
neighboring operations. A **work-process narrative** request instead uses a small
current-turn snapshot of at most 12 representative observable facts (the early settled steps
and recent progress) and bounded confirmed
operation excerpts. It can organize these facts into stages, but cannot invent
intent, results or evidence references. Neither request sends a whole conversation.
Depending on the observed operation, selected code evidence can be
bounded changed/context diff lines, allowlisted before/after edit fields, a patch
excerpt, or a completed command and bounded output excerpt with its observed
status. When only confirmed file counts are available, the evidence explicitly
says code and intent are unavailable. Paths used for local navigation come from
host-observed events, not generated output.

Completed Claude and Codex operations use the common event pipeline. Exact item
IDs bind each explanation to its source; filenames are not used to guess which
operation a lesson belongs to. A staged diff preview is not proof of an edit.
Failed or declined edit content, denied operation context, historical transcripts, streamed
text/thoughts, whole files and environment snapshots are not forwarded. Failed
completed commands may be explained as failures, not relabelled as successes.
Common secret forms and sensitive paths/commands are filtered, but automatic
redaction is not a confidentiality guarantee: enable only for content you may
share with the selected provider.

The explanation model has no tools, filesystem access or ability to modify code.
Its response must pass structured validation and is rendered as plain text. It
must reference only the supplied evidence, acknowledge insufficient context, and
qualify possible rationale rather than claim access to the working agent's private
thoughts. Generated links, commands and source locations are not executable UI.

## Pacing and lifecycle

Calm (24 seconds) and balanced (12 seconds) pacing space out requests. Inline
bubbles remain strictly one-operation explanations. Narrative requests coalesce
meaningful changes into a latest bounded snapshot, not a request per token.
Both surfaces share the same single-flight scheduler and session request budget;
the narrative is not a second unrestricted model loop. Limits include one in-flight request,
12 queued operations, 6,000 serialized evidence characters per request, 24 requests,
40 retained inline explanations, and bounded structured output (700/1,100 tokens
for brief/deeper inline explanations; 1,100 for narratives). Bubbles stop before
the final two request slots, and the last slot is reserved for an ended-turn
narrative. Requests alternate fairly when both kinds are pending.
Requests time out after 45 seconds with no automatic retry.

Pause keeps existing bubbles but stops new context sharing. Explicit off clears
explanations. Hidden/offstage conversations stop generation and cancel pending sharing;
local bounded operation facts can still be recorded without a model request; a still-visible split conversation stays active. Switching between right
panel sections does not turn teaching on or off. Stale results are discarded on
pause, loss of visibility, disable, configuration change or session invalidation.
Explanations are memory-only and do not block the working agent.

The local evidence collector retains at most 80 entries for the current turn and resets
for a new turn or replacement kernel. Repeated status updates coalesce. It does
not infer that tests passed from a command exit, or that an unfinished operation
was cancelled just because a turn ended: an unconfirmed result stays explicitly
unconfirmed. File counts are observed changes, not a claim that a build or
deployment succeeded. Source-less facts remain non-clickable rather than linking
to another same-named file operation. Narrative source IDs are validated against
locally supplied evidence; removal, revision, reversal, turn changes and kernel
replacement invalidate stale context. Reads can contribute only a bounded safe
basename/status fact, not file contents; searches contribute no query or output.
Sensitive environment/credential operations and denied context are excluded from
model snapshots. A command completing is not evidence that tests passed or a
deployment worked. If results are unavailable, the narrative must say they remain
unconfirmed rather than manufacture a useful-sounding conclusion.

## Verification

`flutter test test/learning --dart-define=BAOCODE_LEARNING_VISUALS=true` uses fake
transport and synthetic fixtures only. The focused tests cover consent, bounds,
redaction, cancellation, exact operation provenance, failed-edit protection,
structured response validation, inline bubbles, narrative provenance, bounded local
evidence, narrow layout and
source navigation. Rendered fixtures are synthetic; never use private project
content or credentials in screenshots.

The artifact-only Windows workflow also runs analysis, existing regression
suites, the no-model Codex smoke, packaging and executable startup checks. These
are verification gates, not a claim that they have already passed for a given
snapshot. No real model requests belong in development or CI. Live explanation
quality and real-device smoothness require separate testing.
