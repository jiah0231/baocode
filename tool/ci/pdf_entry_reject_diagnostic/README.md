# Terminal initial-focus rejection diagnostic

## Scope and execution contract

This package adds one diagnostic line only after the original `IsInitialChromiumPane` predicate returned false and the existing `require_text_control` statement finished. Retryable initial Panes generate no new output. The original `ACTION_PROVIDER` stage and all other existing logging remain unchanged.

Use a dedicated branch `diagnostic/pdf-entry-reject-20261111`. Place the two Python files under `tool/ci/pdf_entry_reject_diagnostic/` and the workflow under `.github/workflows/`. The workflow creates three matrix jobs on distinct fresh Windows 2025 runners, one job per fixed SHA. Each runs the unchanged original smoke script exactly once. No outcome-conditioned retry, additional drag, warm-up, assertion change, or production behavior fix is included. Three source checkouts per runner support the actual three-source tests; only that job's selected baseline launches applications.

A failure remains that job's original exit code. Fail-fast is disabled so one failure does not cancel the other preplanned independent observations. Every job saves original artifacts, injection hashes, exact changed-file list/diff, case markers, and an exit-code/actual Edge version summary. Missing coverage/version is explicit, never fabricated. No workflow release or updater steps exist.

## Captured evidence and perturbation

The injector captures only results already evaluated by the original branch: its one ready() result, conditional ControlType HRESULT/value, original foreground comparison, Chromium-class result, existing PID/password/focus values, identity/range binding state, require-text flag before/after, and original deadline. There is no new clock, UIA, ready(), stopped(), foreground, focus, text, clipboard, input, sleep, lock, or thread call.

`typeCalled=0` and E_PENDING mean the original ready() short circuit prevented a ControlType query. E_PENDING in this case is a diagnostic sentinel, not a provider result.

Unlike the earlier every-Pane trace, a normal retryable Pane performs no added synchronous I/O. A nonretryable classification is already final before the new fprintf/flush runs; its predicate cannot be changed retroactively by this line. This is still not literally zero perturbation: local assignment/conditional instructions remain, and rejected attempts incur output latency before worker completion/timer consumption. Existing baseline logs also remain synchronous. Do not claim instrumentation is timing-free or a pass proves absence of intermittent failures.

The original `unfocusedInitialPane` stage applies to any false HasKeyboardFocus result reaching that branch. Do not assign Document/Group/Panes to an old failure without its actual type evidence.

## Verification

Seven local portable tests pass under normal Python and `python -O`. Tests cover all three real sources, exact non-diagnostic full-source reconstruction, refusal of modified/duplicate injection targets, nonempty original-call counts, unchanged call counts except the one conditional logging statement, logging only after false classification, and reconstruction of the original branch after removing diagnostic assignments/logging. Injection's integrity check uses explicit if/raise, not assert. CI tests use the real baseline-a/b/c checkouts and fail rather than skip if a source is absent.

Local portable checks do not establish Windows compilation or PowerShell execution; inspect the corresponding workflow results separately. Source inspection of focus/retry/action lifecycle found no evidence-backed independent production fix for the original failure. Geometry was never reached in that failure; loosening keyboard focus, retry types, deadlines, or identity guards is not justified. The separate public-PDF range/text mismatch remains unresolved.
