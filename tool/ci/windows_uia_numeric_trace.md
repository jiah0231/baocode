# Disposable Windows UIA numeric timing diagnostic

This is not a product feature, capture fallback, or timeout fix. Production
`translation_selection::Capture` is unchanged. Default browser builds do not
compile or link the collector. Root and precreated-client experiments cannot be
combined with it (script and compile-time guards).

## Review and run in two stages

Use a disposable Windows Actions runner with the existing VS developer shell
and `BAOCODE_DISPOSABLE_UI_TEST=1`.

First run only:

    ./tool/ci/windows_translation_browser_smoke.ps1 -ScopedTimingTraceSelfTest

This compiles and runs portable negative tests, audits installed TDH schemas,
and verifies two intersecting ETW filters using a private fixed-ID provider with
zero payloads in two owned processes. It does not start Edge or enable the UIA
provider. A failed/unsupported audit or filter proof is terminal, never a reason
to collect broadly and filter afterward.

Only after code review and explicit approval of actual collection:

    ./tool/ci/windows_translation_browser_smoke.ps1 -ScopedTimingTrace -SkipPostFailureUiaDiagnostics

This repeats preflight before starting Edge. The fresh receipt is bound to the
specific capture-session GUID, exact executable SHA256, Windows build 26100 and
UIAutomationCore.dll version/SHA256. The capture process checks them again and
rechecks metadata. The loaded UIA DLL must resolve to that system DLL before any
numeric events are emitted. No UIA client, root or target is queried in advance.
There is no two-second wait. Audit/setup durations are explicitly reported.

The matched no-UIA-trace control is:

    ./tool/ci/windows_translation_browser_smoke.ps1 -ScopedTimingTraceControl -SkipPostFailureUiaDiagnostics

It uses the same compilation and private-probe/schema preflight before Edge
launch, then the original fixture/Capture with no UIA session or extra wait.
All three tracing switches are mutually exclusive with each other and every
root/client experiment. Tracing itself can change scheduling; a passing traced
capture does not demonstrate a fix.

## Closed data contract

Provider: `820A42D8-38C4-465D-B64E-D7D56EA1D612`.
Only version 0 IDs 521, 522, 544, 545, 546 and 547 are permitted. Fixed payload
sizes are 12, 12, 24, 12, 16 and 16 bytes. Every field is a reviewed 32-bit
Boolean/UInt32/HexInt32, with exact name/order/input/output type, no maps, structs,
arrays, custom flags, or additional fields. TDH's flags=0 scalar length=0
(implicit natural primitive width) or 4 describe the same fixed 32-bit scalar;
count must equal 1. Any explicit count/length flags are rejected.

One EnableTraceEx2 call supplies both collection-side PID and event-ID inclusion
filters. PIDs are only the harness and the already-verified Edge browser; no
executable-name wildcard or process-tree expansion is used. PowerShell holds the
freshly launched Edge process handle and passes its PID, creation FILETIME and
exact installed Edge path. The harness holds its own process handle and verifies
all three before manipulating the fixture. Trace and control perform the same
binding. CaptureTrace revalidates before enabling and at capture boundaries;
process exit, reuse, path mismatch or launch handoff fails closed. There is no
replacement-process, title-only or child-process fallback. The filter selftest
first establishes all four PID/event combinations, then requires only the
allowed intersection to reach the unfiltered callback. Extra callbacks are
failures, not silently discarded software-filtering successes. TraceLogging is
not used: Windows can ignore event-ID filters for TraceLogging providers.

Both private-probe phases explicitly flush their still-live session and await
callback delivery of the already-allowed parent-PID/event-1 zero-payload record.
Producer completion alone is not consumer readiness. Delivery must occur while
the consumer is active and without validation failure, within the original
five-second session limit (at most two seconds of event-driven waiting). This
is not a settling sleep, additional provider, or accepted ProcessTrace error.
The full four-combination/intersection counts and zero-loss/zero-error teardown
checks still run after Stop. No delivery, early consumer exit or timeout fails
closed. This handshake runs only in preflight, before Edge is launched.

Callbacks reject unknown versions/descriptors/lengths/extended data before
copying payload values. ETW cannot filter by version: unknown-version bytes may
briefly enter operating-system buffers, but they are not parsed, copied to the
numeric queue, printed or persisted. Standard ETW infrastructure headers are
counted without inspecting their payloads. No raw payload/ExtendedData dump,
ETL file, stack trace, SID capture or rundown is requested.

The queue has exactly 4096 fixed numeric entries. ETW requests two to four 64 KiB
buffers with no per-processor buffering. Overflow, ETW event/buffer loss, schema
mismatch or filter violation invalidates the trace and suppresses numeric output.
The collector is realtime-only; the only binary file it writes is its small
runtime/filter-verification receipt, which contains no event data.

Peer-bearing events must identify the exact local harness/Edge pair in opposite
endpoints. Cross-machine events are counted but not emitted. Server events
without an explicit cross-machine flag additionally need an opposite-endpoint
local client record in the capture window. Dispatch 521/522 records have no peer;
they are emitted only with a same-emitter/request-ID local peer record in that
window. Unassociated records are counted, not attributed to Edge.

RequestId is not globally unique. Even matching PID/peer/direction/request/window
is correlation, not a unique connection identity. Raw numeric timestamps are
reported without labeling an interval as pure IPC, Edge execution, or proof of a
retry. Multiple request IDs alone do not establish retries.

## Lifetime and cleanup

Only the first real Capture is traced. Its original 1500 ms deadline and exact
text, source, focus, pointer and clipboard assertions remain. Nonempty native
mouse capture before the call fails explicitly as an unfinished fixture gesture,
not as a UIA timeout; no extra UIA pre-read or settling wait is added.

Each session has an invocation-generated unique GUID and exact name. A separate
owned watchdog process stops that session after five seconds, on parent death,
or on validation failure. Parent Stop verifies absence and checks watchdog exit;
a failed stop never disables the watchdog's cleanup responsibility. Successful
consumer completion is joined; failure paths do not indefinitely join.

The PowerShell finally block runs cleanup for only the two GUIDs it generated
(private selftest and optional capture). Cleanup queries that exact name and
requires a matching session GUID before stopping it. It never enumerates trace
sessions, stops a prefix, or modifies another collector. Exceptions/timeouts are
failures; they never convert failed capture assertions to passes.
