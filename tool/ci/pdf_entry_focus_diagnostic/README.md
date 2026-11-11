# Fixed-baseline PDF initial-focus diagnosis

This is a diagnostic-only workflow. No production retry, focus acceptance, identity, geometry, text, clipboard, or test assertion is changed. There are no publication steps.

## Source layout

- Copy `inject_focus_diagnostics.py` and `test_inject_focus_diagnostics.py` to `tool/ci/pdf_entry_focus_diagnostic/` in a dedicated diagnostic branch.
- Copy `pdf-entry-focus-diagnostic.yml` to `.github/workflows/` in that branch.
- The workflow checks out three fixed source SHAs independently. It verifies exact HEAD and pristine source before injection.
- The original desktop smoke script remains untouched. Its existing diagnostic compiler macro activates the new trace. Its compiler, process/profile creation, single positive drag, later negative phase, sleeps, deadlines, clipboard/source/identity assertions, and exit behavior remain unchanged.

## Interpretation

`unfocusedInitialPane` alone proves only `HasKeyboardFocus=false` reached the classification branch. It does not prove that the object is a Pane, Document, or Group. `ACTION_INITIAL_FOCUS` records the existing ControlType call result and its values. `typeCalled=0` means E_PENDING is a local sentinel, not a provider return. The single `typeReady` value is the result of the original `ready()` call, not another probe.

The original foreground query is captured once and reused; original PID and keyboard/password values are reused. `requireTextBefore/After`, bound element/range state, and the original absolute deadline are reported. `observedAt` is the only extra local time call. No extra UIA calls, `ready()`, `stopped()`, focus queries, descendants, selection reads, or input are introduced.

The diagnostic macro's #else contains the original block unchanged. Portable tests reconstruct the entire non-diagnostic source byte-for-byte (normalized checkout line endings) for all three fixed source commits. This is a text-branch equivalence check, not a full Windows compiler preprocessor comparison. Injection preserves checkout newline style and reports original/patched SHA256 hashes. Six portable tests pass locally, including the three actual source revisions. Windows compilation and execution are not performed locally.

## Bias and boundaries

The fixed orders are ABC, BCA, CAB, sequentially on one Windows 2025 runner. Each invocation of the unchanged script creates new test processes and a unique Edge profile. Existing test cleanup is retained. There is no retry conditional on outcome, no warming, and no second positive drag. The original subsequent warm stale-selection negative phase is still required after a successful positive phase.

Logging and one local clock call may perturb timing. Shared OS/browser binary caches and elapsed runner time remain possible confounders even with rotated orders. This is nine observations, not proof of absence of intermittent failures. The workflow does not update Edge or system settings. The unchanged coverage artifacts record each actual Edge version and source identity.

Each original script runs in a child pwsh process. Its exit code and all output/artifacts are retained; a failed original gate does not stop the remaining planned cases, but causes the comparison step and overall workflow to fail at the end. Infrastructure/setup failures may prevent remaining cases; they are not passes. Artifacts upload on failure. There is no release action, auto-merge, or updater change.

This experiment does not resolve the separate public-PDF visually-selected-text versus UIA-range mismatch. Any production remedy requires a new evidence-based review after results.

The workflow emits FOCUS_CASE_BEGIN/END boundaries around each captured case log, with case/SHA and pending/original exit code. Injection verifies `git diff --name-only` contains exactly the target C++ file and saves that list. Each comparison record extracts Edge version only from that case's original coverage result; missing/invalid/versionless coverage remains explicit with a null version and never replaces the original exit code.
