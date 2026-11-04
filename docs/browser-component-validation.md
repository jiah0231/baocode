# Browser component evidence without Chrome

The `Browser components only (no Chrome)` workflow is a separate regression
check. It does not replace the existing complete Windows or signed-release
workflows, and it cannot establish real Chrome/extension end-to-end success.

## Execution boundary

- Run only from a `component-check/chrome-click-offset-*` branch. Pushing the
  candidate to the normal fix branch would start its unchanged complete CI,
  including Chrome, so that is not the execution path for this check.
- Before creating a branch, check that no custom-update release is running or
  pending. The existing release workflow receives branch-create events; its
  jobs reject this branch prefix, but its global concurrency group can still
  affect a pending run.
- Verify the base commit's create-event guards and the remote default branch's
  workflow-run listeners before uploading. For the first run, create the
  isolated branch at the verified base, then advance it once to the reviewed
  candidate with an expected-old-SHA check. That push triggers this workflow;
  do not rely on manual dispatch before the file exists on the default branch.
- Keep the complete Windows and release workflows unchanged. Do not create a
  release-request branch or tag, publish an installer, or change updater data.
- This workflow uses the existing pinned Flutter and Rust setup on Windows.
  It explicitly selects three component test files, never a broad test glob.
  It does not download or launch Chrome, change ACLs/sandbox settings, or use
  a personal browser profile. `BAOCODE_REAL_CHROME_SMOKE` is set to `0`.

## What is checked

The baseline covers frame geometry, the production mirror widget, and toolbar
interactions. Synthetic native-protocol responses and deterministic PNGs let
the widget exercise its actual decoding, layout, pointer handling and outgoing
CDP coordinates without a browser process.

Landmark tests locate targets in the final painted Flutter raster and compare
the resulting CDP positions with independently declared CSS target positions.
They do not use the production coordinate helpers to select their clicks.
The six scenes cover both screenshot and stream captures, four asymmetric
landmarks per capture, separate browser/Flutter pixel ratios, zoom and pinch,
and blank margins. A seventh case checks a decoded-but-not-yet-painted frame.

The mutation harness then introduces one known old defect at a time in the
ephemeral CI checkout. Each narrowly selected regression must fail with a test
assertion. Compilation errors, transport errors, missing/ignored tests and
timeouts are not successful mutation detection. The original source bytes are
restored between mutations and after errors, then the baseline is repeated.
The workflow also independently checks that production files are unchanged.

Expected evidence is the exact commit, original/restored source hashes, test
events, a passing baseline, an assertion failure for each intentional defect,
and a passing restored baseline. Only these component logs are retained.
If process cleanup is uncertain after a timeout, the harness fails and does
not start another test process. The disposable CI job must finish teardown;
that outcome is not successful mutation validation.

## Remaining limits

This verifies Flutter paint-to-input behavior under supplied protocol data.
Synthetic responses cannot establish Chrome's actual metadata, native input
dispatch, version-specific wheel behavior, extension authorization, or Windows
native-host integration. It also does not establish the user's actual display
scaling or browser state. A green component check must not be presented as a
replacement for the still-required, safely configured real-browser gate.
