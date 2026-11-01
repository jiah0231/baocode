# Learning sidebar (opt-in preview)

Open **Learn / 学习** in the existing conversation side panel. It uses the native
resizable right rail (360 px initially), with an independent width from files and
diffs. Narrow windows use the existing dismissible overlay.

The feature is **off by default**. Configure a chat model from the existing
Settings → Models providers, then explicitly agree to the displayed provider,
model, scoped contextual sharing and possible extra usage costs. This choice is
independent of the working agent's model. Consent is bound to the project and
provider configuration; changing these requires confirmation again.

Completed Claude and Codex operations share the same event pipeline. Only
bounded diff lines, allowlisted edit fields, or completed command excerpts are
considered. Completed failed commands are explicitly labelled as failures, not successes. Historical transcripts, streamed text/thoughts, denied operations,
whole files and environment snapshots are not forwarded. Common secret forms
and sensitive paths/commands are filtered, but automatic redaction is not a
confidentiality guarantee: enable only for project content you may share.

The explanation model has no tools, no filesystem access and cannot modify code.
Its reply must be a validated plain-text card with evidence IDs from the supplied
operations. Rationale is presented as possible, not the agent's private thought;
missing evidence must be acknowledged. File links are host-observed paths and
open the current file read-only, not a fabricated historical source.

Cards begin with a short takeaway; expand for why, concept, example, tradeoff and
observed evidence. A local three-takeaway recap costs no model request. Reading
older cards or expanding them stops automatic following; use Follow latest when
ready. Pause retains cards. Leaving the learning page cancels pending work and
stops new collection; returning preserves the session's cards. Turning off clears
them. Cards are memory-only and are not saved to disk.

Calm (24 seconds) and balanced (12 seconds) pacing group at most three operations.
Limits per session: one in-flight request, 12 queued operations, 6,000 context
characters per batch, 24 requests, 40 retained cards, and 700/1,100 output tokens
for brief/deeper mode. Requests time out after 45 seconds with no automatic retry.
Stale results are discarded on pause, closure, disable, configuration change or
session invalidation. The learning path never blocks the working agent.

## Verification

`flutter test test/learning --dart-define=BAOCODE_LEARNING_VISUALS=true` uses fake
transport and synthetic fixtures only. It covers consent, bounds, redaction,
cancellation, card validation, native layout, interaction and dark/light rendered
PNG fixtures in `build/learning-visuals`. The artifact-only Windows workflow also
runs analysis, existing regression suites, the no-model Codex smoke, packaging
and executable startup checks. No real model requests are part of development or
CI. Live explanation quality and real-device smoothness require separate testing.
