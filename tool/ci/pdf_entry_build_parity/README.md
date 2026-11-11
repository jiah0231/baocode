# Cold PDF entry compiler comparison

This is a single, predeclared two-by-two experiment on exact candidate
1308fb3b70328aea8ca549ef4d1a287865d413da. Each of four independent Windows
2025 runners executes the unchanged original PDF-and-console cold-entry
harness once, with its original assertions, focus/identity guards, wait limits,
gesture, privacy checks, and later stale-target negative check. There are no
outcome-conditioned retries, warmups, provider reads, or additional gestures.

The factors are the diagnostic macro on/off and the legacy direct compiler
versus native Release configuration. The legacy diagnostic cell is the original
script byte-for-byte. Legacy quiet removes only the diagnostic definition.
Release cells use CMake Release and verbatim APPLY_STANDARD_SETTINGS from the
candidate's windows/CMakeLists.txt, including its exception-library and mutex
definitions, with the runner's Unicode, NOMINMAX, and UTF-8 options. Release
diagnostic adds only the existing diagnostic macro to that configuration.
The generated vcxproj is retained to disclose the actual compiler configuration.

This is the production native selection source inside the existing synthetic
harness, not the whole shipped Flutter executable. No code or test assertion is
altered. The compiler-only transformation is reversible and tested under normal
and optimized Python. The harness uses explicit throwing checks rather than
assert, so Release/NDEBUG does not compile away its acceptance checks.

The original signed-release and full-translation workflows are untouched.
Passing this experiment cannot substitute for a failed required gate, erase
the original failure, prove a root cause, or authorize publication. If all four
cells pass, the timing hypothesis remains unresolved. If only one cell fails,
retain it as an observation, not statistical proof: fresh hosts and scheduler
variation remain confounders with one sample per configuration.

No signer, update publication, real model, user desktop, credentials, or user
files are used. Retain every original exit code, logs, source/diff evidence,
actual Edge version, and runner image version.
