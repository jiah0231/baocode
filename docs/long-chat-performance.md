# Long-running conversation performance

This change is an independent, non-publishing candidate based on
`5c4583efe6466cacd1330fd29746ffa7b2f4ca0a` (the +53 candidate plus selection
geometry protection). It does not change the release gates or publish an update.

## Two separate paths

- Windows delivers `WH_MOUSE_LL` callbacks synchronously to the installing
  thread. The previous installer was the Flutter UI thread. A constant-time
  callback still makes system input wait when that thread is busy. The new
  hook owns an independent message pump and sends bounded, coalesced metadata
  notifications to the UI. It never reads selection text in the hook.
- Every displayed text delta rebuilt folds and walked the minimap across the
  complete conversation. The transcript now identifies structural changes and
  accumulates text-only row changes. Folds refresh only those text rows; the
  minimap refreshes the affected suffix. Unknown feeds still use the conservative
  full path. Prepend, removal, replacement and turn transitions invalidate the
  structure. Merged thoughts invalidate their displayed first row.

## Reproducible synthetic checks

`flutter test test/chat/history_stream_work_test.dart` drives the real
`ChatSession` and `Transcript` with a local synthetic kernel. It loads 20 or
2,000 completed turns, keeps the minimap enabled, and delivers eight displayed
text deltas. It then stops the same agent and pumps eight more frames. Both
semantics-disabled and semantics-enabled runs are covered. No saved session,
real model or user data is read.

The test counts `itemAt` calls, rather than making a wall-clock/FPS assertion
from a debug test. On the original files, the new bounded-work assertion fails:

| Completed turns | Original running | Patched running | Stopped, both |
| --- | ---: | ---: | ---: |
| 20 | 9,976 | 8,312 | 0 |
| 2,000 | 168,376 | 8,312 | 0 |

These counts are the same with semantics enabled. The long-history fixture
removes about 95% of these reads. This is not a claim of a 95% frame-rate or
end-to-end mouse-latency improvement. Initial history construction remains
linear in history size; growing individual Markdown messages still requires
processing their changed text.

`tool/ci/windows_translation_mouse_hook_smoke.ps1` runs only on an explicitly
enabled disposable Windows Actions desktop. It first demonstrates that a hook
installed on a blocked UI thread waits, then measures marked real `SendInput`
events through the production dedicated hook while the UI thread does not pump
messages. It also checks a bounded flood, single pending wake, and repeated
installation/destruction. It does not inject input on the user's desktop.

The full conversation directory passes 735 tests on Linux. On Windows, the
broader initial run exposed 27 failures in seven path/side-panel suites. The
workflow runs the affected history/minimap regressions, then reruns those seven
suites against both the patched and pinned baseline Dart source in the same
workspace. Its comparison fails for introduced failures, missing tests or
unclassified/compile failures and retains the exact shared-failure report.
A green comparison does not mean the full Windows suite is green.

The workflow then builds the real app in profile mode for synthetic
`chat.long_history` and `a11y.long_history` scenarios. Their JSON, logs and report
are CI artifacts.
Profile results require a visible desktop and must not be compared across
unlike machines. Existing release checks remain independently required.

### Recorded Windows profile

Run [42861390402](https://github.com/jiah0231/baocode/actions/runs/42861390402)
at `7b56aac44fb7c1a0b2ef902e75bf5cc797cf5742` passed native checks, 97
affected conversation tests, analyze/format, profile compilation and both
profile scenarios. Its overall result remained red at the baseline comparison
parser, which mistook a widget-finder assertion for an infrastructure failure.
The two completed raw test runs and all four profile runs were retained.
Reparsing those unchanged raw test streams with the corrected parser found
94 matching cases across seven suites, 27 identical failures, no introduced
failures and no changed failure signatures. The signatures include the actual
Flutter assertion/exception text, not just its generic "Test failed" wrapper.
This offline classification does not change the original CI run's red status.

The profile fixture uses 40 synthetic turns, not the 2,000-turn work-count
fixture above. On Windows Server 2025 with four cores, Skia profile, 64 Hz,
1008 x 712 at 1x, medians of two runs were:

| Phase | Frames/s | Build p90 ms | Build p99 ms | Delta-to-frame p90 ms |
| --- | ---: | ---: | ---: | ---: |
| Stream | 63 | 7.26 | 9.91 | 16.1 |
| Stream, semantics enabled | 63 | 7.71 | 10.70 | 17.4 |
| Initial load | 39 | 25.8 | 64.74 | 56.6 |
| Initial load, semantics enabled | 38 | 26.2 | 36.74 | 52.7 |

All four raw profile runs were complete and had no `disturbed` flags.
Initial loading still exceeds frame budgets. These are patched-only results,
not a before/after FPS comparison or proof about a particular user's session.
The [raw artifact](https://github.com/jiah0231/baocode/actions/runs/42861390402/artifacts/13787426715)
is retained until 2026-11-17.

## Existing unrelated test discrepancy

`test/transcript_test.dart`, test `a turn done is timed on its message; a stopped
one is not`, already fails on the unchanged baseline: the implementation retains
the supplied duration for a stopped turn while this assertion expects null.
The same failure was rerun with original source files. This patch does not
change that behavior or silently redefine the assertion.
