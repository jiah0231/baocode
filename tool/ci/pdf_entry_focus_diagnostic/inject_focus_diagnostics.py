"""Strict, diagnostic-only injection into three fixed BaoCode source revisions."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

SHAS = (
    "1e63028e029b5decc6e7dee915dc59679accab0c",
    "5d61828f0b794cddd5bd9ef12e66fd36fe1a854e",
    "1308fb3b70328aea8ca549ef4d1a287865d413da",
)
SOURCE = "windows/runner/translation_selection_action.cpp"
ORIGINAL = '  if (!has_focus) {\n    ACTION_STAGE("unfocusedInitialPane");\n    CONTROLTYPEID initial_type = 0;\n    wchar_t source_class[64] = {};\n    const bool known_type = ready() && SUCCEEDED(focused->get_CurrentControlType(&initial_type));\n    const bool chromium = GetClassNameW(source, source_class, 64) &&\n        _wcsicmp(source_class, L"Chrome_WidgetWin_1") == 0;\n    retryable = translation_retry::IsInitialChromiumPane(\n        previous_element != nullptr, GetForegroundWindow() == source,\n        static_cast<DWORD>(focused_pid) == pid, password == FALSE,\n        has_focus == FALSE, known_type && initial_type == UIA_PaneControlTypeId, chromium);\n    if (retryable) require_text_control = true;\n    return std::nullopt;\n  }\n'
DIAGNOSTIC = '  if (!has_focus) {\n    ACTION_STAGE("unfocusedInitialPane");\n    CONTROLTYPEID initial_type = 0;\n    wchar_t source_class[64] = {};\n    const bool type_ready = ready();\n    HRESULT type_hr = E_PENDING;\n    const bool known_type = type_ready &&\n        SUCCEEDED(type_hr = focused->get_CurrentControlType(&initial_type));\n    const bool chromium = GetClassNameW(source, source_class, 64) &&\n        _wcsicmp(source_class, L"Chrome_WidgetWin_1") == 0;\n    const bool same_foreground = GetForegroundWindow() == source;\n    const bool require_text_before = require_text_control;\n    retryable = translation_retry::IsInitialChromiumPane(\n        previous_element != nullptr, same_foreground,\n        static_cast<DWORD>(focused_pid) == pid, password == FALSE,\n        has_focus == FALSE, known_type && initial_type == UIA_PaneControlTypeId, chromium);\n    if (retryable) require_text_control = true;\n    ACTION_TRACE("ACTION_INITIAL_FOCUS|typeReady=%d|typeCalled=%d|typeHr=0x%08lx|type=%d|knownType=%d|sameForeground=%d|samePid=%d|chromium=%d|elementBound=%d|rangeBound=%d|requireTextBefore=%d|requireTextAfter=%d|hasFocus=%d|password=%d|retryable=%d|deadline=%llu|observedAt=%llu\\n",\n        type_ready ? 1 : 0, type_ready ? 1 : 0, static_cast<unsigned long>(type_hr),\n        initial_type, known_type ? 1 : 0, same_foreground ? 1 : 0,\n        static_cast<DWORD>(focused_pid) == pid ? 1 : 0, chromium ? 1 : 0,\n        previous_element ? 1 : 0, previous_range ? 1 : 0,\n        require_text_before ? 1 : 0, require_text_control ? 1 : 0,\n        has_focus ? 1 : 0, password ? 1 : 0, retryable ? 1 : 0,\n        deadline, GetTickCount64());\n    return std::nullopt;\n  }\n'
OPEN = "#ifdef BAOCODE_TRANSLATION_ACTION_DIAGNOSTICS\n"
MIDDLE = "#else\n"
CLOSE = "#endif\n"

def inject(source):
    if source.count(ORIGINAL) != 1 or "ACTION_INITIAL_FOCUS|" in source:
        raise ValueError("Expected exactly one unchanged original focus block")
    return source.replace(ORIGINAL, OPEN + DIAGNOSTIC + MIDDLE + ORIGINAL + CLOSE, 1)

def without_diagnostics(source):
    combined = OPEN + DIAGNOSTIC + MIDDLE + ORIGINAL + CLOSE
    if source.count(combined) != 1:
        raise ValueError("Diagnostic block altered")
    return source.replace(combined, ORIGINAL, 1)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--sha", required=True, choices=SHAS)
    args = parser.parse_args()
    actual = subprocess.check_output(["git", "-C", str(args.checkout), "rev-parse", "HEAD"], text=True).strip()
    if actual != args.sha:
        raise ValueError("Checkout SHA differs from the fixed baseline")
    path = args.checkout / SOURCE
    pristine = subprocess.check_output(["git", "-C", str(args.checkout), "show", actual + ":" + SOURCE])
    original = path.read_bytes()
    # Git checkout may use CRLF. Preserve its original newline representation.
    normalized = original.replace(b"\r\n", b"\n")
    if normalized != pristine.replace(b"\r\n", b"\n"):
        raise ValueError("Source already modified")
    patched = inject(normalized.decode("utf-8"))
    if without_diagnostics(patched).encode("utf-8") != normalized:
        raise ValueError("Non-diagnostic reconstruction differs from original source")
    newline = b"\r\n" if b"\r\n" in original else b"\n"
    output = patched.encode("utf-8").replace(b"\n", newline)
    path.write_bytes(output)
    print(json.dumps({"baseline": actual, "file": SOURCE,
        "originalSha256": hashlib.sha256(original).hexdigest(),
        "patchedSha256": hashlib.sha256(output).hexdigest(),
        "nonDiagnosticReconstructionEqual": True}))

if __name__ == "__main__":
    main()
