#!/usr/bin/env python3
"""Prove three browser regression tests reject old bugs, without Chrome.

Run only in a disposable checkout with an already provisioned Flutter 3.47.5 SDK
and dependencies. This tool never installs Flutter, runs pub, edits assertions,
launches Chrome, stages files, or commits. It temporarily edits ONE production
file, restores its exact bytes in finally, and runs the final baseline even when
a mutant survives or a test process fails, unless process cleanup is uncertain
(then the gate fails closed without another process). No concurrent source writers.

  python tool/ci/browser_component_mutations.py \
    --flutter /existing/flutter/bin/flutter --output-dir build/component-evidence

On Windows pass (Get-Command flutter).Source for --flutter. A .bat command is
passed as an argument array, not interpolated into a caller-provided shell line.
Only the fixed commands and exact tests below can be selected. All subprocesses
have a wall-clock bound; a timeout/compile/runtime/protocol failure is NEVER a
killed mutation. Ctrl-C/SIGTERM restore source; no program can recover from
SIGKILL, power loss, or forced termination of the Python interpreter.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from typing import Callable


FLUTTER_VERSION = "3.47.5"
SOURCE = Path("lib/browser/browser_mirror.dart")
TEST_FILE = Path("test/browser/browser_mirror_test.dart")
PROTECTED = (Path("lib/browser/browser_frame_flow.dart"), TEST_FILE,
             Path("pubspec.lock"))
LANDMARK_TEST = "painted landmarks independently map screenshot and stream input: browser zoom only"
PAINTED_TEST = "pending decode and pre-build completion keep input on painted pixels"
SCROLLBAR_TEST = "scrollbar-excluding CSS clients do not squeeze full captured surfaces"
TEST_NAMES = (LANDMARK_TEST, PAINTED_TEST, SCROLLBAR_TEST)
ASSERTION_MARKERS = {
    LANDMARK_TEST: "stream_css_position_oracle",
    PAINTED_TEST: "painted_frame_pairing_oracle",
    SCROLLBAR_TEST: "full_surface_css_position_oracle",
}


@dataclass(frozen=True)
class Mutation:
    name: str
    test_name: str
    before: bytes
    after: bytes

    def apply(self, source: bytes) -> bytes:
        before, after = self.before, self.after
        if b"\r\n" in source:
            if b"\n" in source.replace(b"\r\n", b""):
                raise GateError(f"{self.name}: mixed source line endings")
            before, after = before.replace(b"\n", b"\r\n"), after.replace(b"\n", b"\r\n")
        count = source.count(before)
        if count != 1:
            raise GateError(f"{self.name}: source anchor occurs {count} times, expected exactly 1")
        if self.before == self.after:
            raise GateError(f"{self.name}: mutation must change source")
        return source.replace(before, after, 1)


MUTATIONS = (
    Mutation("stream_without_css_scale", LANDMARK_TEST,
             b"            final factor = viewport.zoom * pending.payload.pageScale;\n"
             b"            inputSize = pending.payload.pageSize / factor;",
             b"            inputSize = pending.payload.pageSize;"),
    Mutation("client_instead_of_full_surface", SCROLLBAR_TEST,
             b"          final Size inputSize;\n"
             b"          if (pending.payload.viewport != null) {\n"
             b"            final factor = viewport.pixelRatio * viewport.scale;\n"
             b"            inputSize = Size(decoded.width / factor, decoded.height / factor);\n"
             b"          } else {\n"
             b"            final factor = viewport.zoom * pending.payload.pageScale;\n"
             b"            inputSize = pending.payload.pageSize / factor;\n"
             b"          }",
             b"          final inputSize = viewport.size;"),
    Mutation("decoded_instead_of_painted_frame", PAINTED_TEST,
             b"  Offset? _pagePoint(Offset local, {bool clamp = false}) {\n"
             b"    final frame = _paintedFrame;",
             b"  Offset? _pagePoint(Offset local, {bool clamp = false}) {\n"
             b"    final frame = _frame;"),
)


class GateError(Exception):
    pass


class UncertainCleanup(GateError):
    pass


@dataclass
class ProcessResult:
    returncode: int | None
    stdout: str = ""
    stderr: str = ""
    timed_out: bool = False
    launch_error: str | None = None
    cleanup_confirmed: bool = True


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def test_command(flutter: Path, names: tuple[str, ...], machine_report: Path) -> list[str]:
    if not names or any(name not in TEST_NAMES for name in names):
        raise GateError("Only the built-in component test names are permitted")
    pattern = "^(?:" + "|".join(re.escape(name) for name in names) + ")$"
    return [str(flutter), "--no-version-check", "test", "--no-pub", "--machine",
            "--concurrency=1", "--timeout=2m", str(TEST_FILE), "--name", pattern,
            "--file-reporter", "json:" + str(machine_report)]


def child_environment(environment: dict[str, str]) -> dict[str, str]:
    if environment.get("BAOCODE_REAL_CHROME_SMOKE", "0") != "0":
        raise GateError("BAOCODE_REAL_CHROME_SMOKE must be unset or exactly 0")
    # Do not pass tokens, browser overrides, account data, or unrelated CI secrets.
    # Native Windows build-tool discovery needs the standard installation roots.
    allowed = {"PATH", "HOME", "USERPROFILE", "SYSTEMROOT", "WINDIR", "COMSPEC",
               "SYSTEMDRIVE", "PATHEXT", "TEMP", "TMP", "TMPDIR", "APPDATA",
               "LOCALAPPDATA", "PROGRAMDATA", "PROGRAMFILES", "PROGRAMFILES(X86)",
               "PROGRAMW6432", "PUB_CACHE", "LANG", "LC_ALL"}
    result = {key: value for key, value in environment.items() if key.upper() in allowed}
    result.update(BAOCODE_REAL_CHROME_SMOKE="0", CI="true",
                  FLUTTER_SUPPRESS_ANALYTICS="true", DART_SUPPRESS_ANALYTICS="true")
    return result


class _WindowsJob:
    """Bound assigned descendants, without taskkill; assignment has a launch race."""

    def __init__(self) -> None:
        from ctypes import wintypes
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = (ctypes.c_void_p, wintypes.LPCWSTR)
        self.kernel.CreateJobObjectW.restype = wintypes.HANDLE
        self.kernel.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
        self.kernel.AssignProcessToJobObject.restype = wintypes.BOOL
        self.kernel.TerminateJobObject.argtypes = (wintypes.HANDLE, wintypes.UINT)
        self.kernel.TerminateJobObject.restype = wintypes.BOOL
        self.kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        self.kernel.CloseHandle.restype = wintypes.BOOL
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise OSError(ctypes.get_last_error(), "CreateJobObject failed")

    def assign(self, process: subprocess.Popen[str]) -> None:
        # Popen owns this Windows process handle for its entire lifetime.
        if not self.kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise OSError(ctypes.get_last_error(), "AssignProcessToJobObject failed")

    def stop(self) -> bool:
        if self.handle:
            return bool(self.kernel.TerminateJobObject(self.handle, 1))
        return True

    def close(self) -> bool:
        if self.handle:
            closed = bool(self.kernel.CloseHandle(self.handle))
            self.handle = None
            return closed
        return True


def run_process(command: list[str], root: Path, environment: dict[str, str],
                timeout: int) -> ProcessResult:
    """Launch only Flutter; bounded cleanup, with uncertain Windows cleanup failed closed."""
    job = None
    process = None
    outcome = ProcessResult(None)
    cleanup_ok = True
    interrupted = False

    def stop() -> None:
        nonlocal cleanup_ok
        if process is None:
            return
        if job is not None:
            try:
                cleanup_ok = job.stop() and cleanup_ok
            except OSError:
                cleanup_ok = False
        elif os.name != "nt":
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_ok = False
        if process.poll() is None:
            try:
                process.kill()
            except OSError:
                cleanup_ok = False

    try:
        if os.name == "nt":
            job = _WindowsJob()
        process = subprocess.Popen(
            command, cwd=root, env=environment, shell=False, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            encoding="utf-8", errors="replace", start_new_session=os.name != "nt",
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
        if job is not None:
            job.assign(process)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            outcome = ProcessResult(process.returncode, stdout, stderr)
            return outcome
        except subprocess.TimeoutExpired:
            stop()
            stdout, stderr = process.communicate(timeout=10)
            outcome = ProcessResult(process.returncode, stdout, stderr, timed_out=True)
            return outcome
    except OSError as error:
        stop()
        if process is not None:
            process.communicate(timeout=10)
        outcome = ProcessResult(None, launch_error=f"{type(error).__name__}: {error}")
        return outcome
    except BaseException:
        interrupted = True
        raise
    finally:
        # This also runs for Ctrl-C/SIGTERM and exceptions raised by communicate.
        stop()
        if job is not None:
            try:
                cleanup_ok = job.close() and cleanup_ok
            except OSError:
                cleanup_ok = False
        if process is not None and process.poll() is None:
            try:
                process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                cleanup_ok = False
        # A .bat descendant might start before AssignProcessToJobObject. Normal
        # test completion is usable evidence; after a Windows abnormal exit we
        # cannot prove every descendant stopped. Do not start another baseline.
        outcome.cleanup_confirmed = cleanup_ok and not (os.name == "nt" and process is not None and
            (outcome.timed_out or outcome.launch_error or interrupted or outcome.returncode not in (0, 1)))
        if interrupted and not outcome.cleanup_confirmed:
            raise UncertainCleanup("Flutter process cleanup is uncertain; no further test process is safe")


# Be conservative: false rejection is a failed gate, never false proof of a kill.
# A matching phrase in benign test output can intentionally fail this gate too.
INFRASTRUCTURE = re.compile(
    r"Compilation failed|Failed to load|Error when reading|Compiler (?:failed|crashed)|"
    r"Error: (?:Not found|Couldn't resolve)|TimeoutException|Test timed out|"
    r"SocketException|FileSystemException|ProcessException|Bad state:|"
    r"Null check operator|NoSuchMethodError|TypeError|Lost connection to device|"
    r"test (?:process|shell).*?(?:crash|terminated|exit)|Unhandled exception|"
    r"synthetic browser handshake or frame timed out|Multiple exceptions",
    re.IGNORECASE)


def validate_machine(result: ProcessResult, names: tuple[str, ...], root: Path,
                     *, mutant: bool, machine_output: str | None = None) -> dict:
    """Validate the Dart JSON reporter protocol and positive assertion evidence.

    Protocol: github.com/dart-lang/test/blob/master/pkgs/test/doc/json_reporter.md
    Flutter may wrap a framework-reported TestFailure with a generic error event;
    in that case the assertion must be in a print event for the SAME test ID.
    """
    def fail(reason: str) -> dict:
        return {"outcome": "gate_failure", "reason": reason}

    if not result.cleanup_confirmed:
        return fail("Flutter process cleanup is uncertain")
    if result.launch_error or result.timed_out:
        return fail(result.launch_error or "subprocess wall-clock timeout")
    if result.returncode not in (0, 1):
        return fail(f"unexpected Flutter exit code: {result.returncode}")
    stream = result.stdout if machine_output is None else machine_output
    if INFRASTRUCTURE.search(stream + "\n" + result.stdout + "\n" + result.stderr):
        return fail("compile, timeout, process, or runtime error in Flutter output")
    try:
        events = [json.loads(line) for line in stream.splitlines() if line.strip()]
    except (ValueError, TypeError):
        return fail("malformed/non-JSON Flutter machine output")
    if (not events or any(not isinstance(event, dict) or not isinstance(event.get("type"), str)
                          for event in events)):
        return fail("missing or malformed machine events")
    if (events[0]["type"] != "start" or events[-1]["type"] != "done" or
            sum(event["type"] == "start" for event in events) != 1 or
            sum(event["type"] == "done" for event in events) != 1 or
            not isinstance(events[-1].get("success"), bool)):
        return fail("missing, duplicate, incomplete, or misplaced start/done event")
    tests: dict[int, dict] = {}
    suites: dict[int, dict] = {}
    completions: dict[int, dict] = {}
    errors: list[dict] = []
    messages: dict[int, list[str]] = {}
    starts_at: dict[int, int] = {}
    completions_at: dict[int, int] = {}
    errors_at: list[int] = []
    prints: list[tuple[int, dict]] = []
    try:
        for position, event in enumerate(events):
            kind = event["type"]
            if kind == "suite":
                suite = event["suite"]
                if suite["id"] in suites or suite.get("platform") not in (None, "vm"):
                    return fail("duplicate suite or non-VM platform")
                if suite.get("path") is not None and (root / suite["path"]).resolve() != (root / TEST_FILE).resolve():
                    return fail("unexpected test suite path")
                suites[suite["id"]] = suite
            elif kind == "testStart":
                test = event["test"]
                if test["id"] in tests or not isinstance(test["name"], str):
                    return fail("duplicate or malformed test start")
                tests[test["id"]] = test
                starts_at[test["id"]] = position
            elif kind == "testDone":
                test_id = event["testID"]
                if test_id not in tests or test_id in completions:
                    return fail("missing test start or duplicate test completion")
                if event.get("skipped") is not False or event.get("retried", False) is not False:
                    return fail("skipped or retried test is not mutation evidence")
                if not isinstance(event.get("hidden"), bool):
                    return fail("test completion lacks hidden flag")
                completions[test_id] = event
                completions_at[test_id] = position
            elif kind == "error":
                if (event["testID"] not in tests or not isinstance(event["error"], str) or
                        not isinstance(event["stackTrace"], str) or
                        not isinstance(event["isFailure"], bool)):
                    return fail("malformed or unassociated test error")
                errors.append(event)
                errors_at.append(position)
            elif kind == "print":
                if event["testID"] not in tests or not isinstance(event["message"], str):
                    return fail("malformed or unassociated test message")
                if event.get("messageType") == "skip":
                    return fail("skip message is not mutation evidence")
                messages.setdefault(event["testID"], []).append(event["message"])
                prints.append((position, event))
            elif kind not in {"start", "done", "allSuites", "group", "debug"}:
                return fail(f"unsupported machine event: {kind}")
        if set(tests) != set(completions):
            return fail("test started without a completion")
        selected: dict[str, int] = {}
        for test_id, test in tests.items():
            completion = completions[test_id]
            if test["name"] not in names:
                if completion["hidden"] is not True or completion.get("result") != "success":
                    return fail("unexpected visible test or failed setup/loading/teardown")
                continue
            if test["name"] in selected or completion["hidden"]:
                return fail("duplicate or hidden selected test")
            suite = suites.get(test["suiteID"])
            if not suite or suite.get("path") is None or suite.get("platform") != "vm":
                return fail("selected test lacks the expected VM suite")
            selected[test["name"]] = test_id
        if set(selected) != set(names):
            return fail("one or more exact selected tests never started")
        all_pass = all(event.get("result") == "success" for event in completions.values())
        if all_pass and not errors and events[-1]["success"] is True and result.returncode == 0:
            return {"outcome": "mutant_survived" if mutant else "baseline_pass",
                    "tests": list(names)}
        if not mutant:
            return fail("baseline did not pass every selected test without errors")
        if len(names) != 1 or result.returncode != 1 or events[-1]["success"] is not False:
            return fail("mutation lacks the expected failing exit code/done event")
        test_id = selected[names[0]]
        if len(errors) != 1 or errors[0]["testID"] != test_id:
            return fail("expected exactly one assertion error from the selected test, with no extra late errors")
        if not starts_at[test_id] < errors_at[0] < completions_at[test_id]:
            return fail("selected assertion error is outside its started/completed test interval")
        error = errors[0]
        marker = ASSERTION_MARKERS.get(names[0])
        assertion_format = "direct_test_failure"
        if error["isFailure"] is True and completions[test_id].get("result") == "failure":
            assertion_text = error["error"] + "\n" + error["stackTrace"]
            assertion_text += "\n" + "\n".join(messages.get(test_id, []))
        elif error["isFailure"] is False and completions[test_id].get("result") == "error":
            # Flutter 3.47.5's framework can print the actual TestFailure and
            # throw this exact generic wrapper as a non-TestFailure. Accept ONLY
            # that captured protocol shape, never an arbitrary runtime error.
            expected_wrapper = ("Test failed. See exception logs above.\n"
                                "The test description was: " + names[0])
            if error["error"] != expected_wrapper or error["stackTrace"] != "" or len(prints) != 1:
                return fail("non-TestFailure error is not the single exact Flutter framework wrapper")
            print_at, printed = prints[0]
            if (printed["testID"] != test_id or printed.get("messageType") != "print" or
                    not starts_at[test_id] < print_at < errors_at[0]):
                return fail("Flutter assertion print has the wrong test identity, type, or ordering")
            assertion_text = printed["message"]
            description = list(re.finditer(r"(?m)^The test description was:\n  " + re.escape(names[0]) + r"\n", assertion_text))
            source = list(re.finditer(r"(?m)^This was caught by the test expectation on the following line:\n"
                                     r"[ \t]+[^\n]*test/browser/browser_mirror_test\.dart line [1-9][0-9]*$", assertion_text))
            expected = list(re.finditer(r"(?m)^Expected:", assertion_text))
            actual = list(re.finditer(r"(?m)^  Actual:", assertion_text))
            markers = list(re.finditer(r"(?m)^" + re.escape(marker) + r":", assertion_text)) if marker else []
            header = "The following TestFailure was thrown running a test:\n"
            stack = "When the exception was thrown, this was the stack:\n"
            if (not assertion_text.startswith("══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞") or
                    assertion_text.count(header) != 1 or assertion_text.count(stack) != 1 or
                    assertion_text.count("The test description was:\n") != 1 or
                    any(len(matches) != 1 for matches in (description, source, expected, actual, markers))):
                return fail("Flutter wrapper lacks its exact printed TestFailure, description, assertion source, or marker")
            if not (assertion_text.index(header) < expected[0].start() < actual[0].start() <
                    markers[0].start() < assertion_text.index(stack) < source[0].start() < description[0].start()):
                return fail("Flutter printed assertion sections are out of order")
            assertion_format = "flutter_framework_wrapper"
        else:
            return fail("expected named test did not report a supported TestFailure shape")
        if not (marker and marker in assertion_text and "Expected:" in assertion_text and
                "Actual:" in assertion_text and TEST_FILE.name in assertion_text):
            return fail("missing regression-specific assertion marker, Expected/Actual, or test-source evidence")
        # Runtime exceptions may be wrapped by Flutter in a generic TestFailure.
        headers = re.findall(r"The following (.*?) was thrown", assertion_text)
        if len(headers) > 1 or any(header != "TestFailure" for header in headers):
            return fail("Flutter reported a non-TestFailure exception")
        return {"outcome": "killed", "tests": list(names), "assertion_test_id": test_id,
                "assertion_marker": marker, "assertion_format": assertion_format}
    except (KeyError, TypeError, ValueError, AttributeError):
        return fail("malformed machine event fields")


def preflight(root: Path, flutter: Path, environment: dict[str, str]) -> dict[str, str]:
    child = child_environment(environment)
    if flutter.name.lower() not in {"flutter", "flutter.bat"} or flutter.parent.name != "bin":
        raise GateError("--flutter must name an existing Flutter SDK bin/flutter[.bat]")
    sdk = flutter.parent.parent
    host = {"win32": "windows-x64", "linux": "linux-x64", "darwin": "darwin-x64"}.get(sys.platform)
    if host is None:
        raise GateError("unsupported Flutter test host")
    suffix = ".exe" if os.name == "nt" else ""
    cache = sdk / "bin/cache"
    required = [flutter, cache / "flutter_tools.snapshot", cache / "dart-sdk/bin" / f"dart{suffix}",
                root / ".dart_tool/package_config.json", root / SOURCE, *[root / p for p in PROTECTED]]
    tester = cache / "artifacts/engine" / host / f"flutter_tester{suffix}"
    if sys.platform == "darwin" and not tester.is_file():
        tester = cache / "artifacts/engine/darwin-arm64/flutter_tester"
    required.append(tester)
    if any(not path.is_file() for path in required):
        raise GateError("existing SDK engine/tools or resolved dependencies missing; provision them separately")
    return child


def run_gate(root: Path, flutter: Path, output: Path, timeout: int,
             *, runner: Callable = run_process, environment: dict[str, str] | None = None) -> dict:
    report: dict = {"schema_version": 1, "flutter_version_expected": FLUTTER_VERSION,
                    "status": "failed", "stages": [], "failures": []}
    original = None
    protected: dict[Path, bytes] = {}
    ready = False
    cleanup_confirmed = True

    def verify(expected: bytes) -> None:
        if (root / SOURCE).read_bytes() != expected:
            raise GateError("production source changed unexpectedly during the gate")
        if any((root / path).read_bytes() != data for path, data in protected.items()):
            raise GateError("protected component/test/lock source changed during the gate")

    def stage(name: str, names: tuple[str, ...], *, mutant: bool = False,
              source: bytes | None = None) -> dict:
        nonlocal cleanup_confirmed
        directory = output / name
        directory.mkdir()
        machine_report = directory / "machine.jsonl"
        cleanup_confirmed = False
        try:
            result = runner(test_command(flutter, names, machine_report), root, child, timeout)
        except (Exception, KeyboardInterrupt) as error:
            record(name, ProcessResult(None, launch_error=f"{type(error).__name__}: {error}", cleanup_confirmed=False),
                   {"outcome": "gate_failure", "expected_tests": list(names),
                    "reason": "runner aborted without a confirmed process result"})
            raise UncertainCleanup("runner aborted without confirmed cleanup") from error
        cleanup_confirmed = result.cleanup_confirmed
        if not machine_report.is_file():
            verdict = {"outcome": "gate_failure", "reason": "Flutter JSON file reporter produced no evidence"}
        else:
            verdict = validate_machine(result, names, root, mutant=mutant,
                                       machine_output=machine_report.read_text(encoding="utf-8"))
        verdict["expected_tests"] = list(names)
        verdict["source_sha256"] = digest(source if source is not None else original)
        return record(name, result, verdict)

    def record(name: str, result: ProcessResult, verdict: dict) -> dict:
        directory = output / name
        directory.mkdir(exist_ok=True)
        (directory / "stdout.log").write_text(result.stdout, encoding="utf-8")
        (directory / "stderr.log").write_text(result.stderr, encoding="utf-8")
        details = {"stage": name, "returncode": result.returncode, "timed_out": result.timed_out,
                   "launch_error": result.launch_error, "cleanup_confirmed": result.cleanup_confirmed, **verdict}
        (directory / "result.json").write_text(json.dumps(details, indent=2) + "\n", encoding="utf-8")
        report["stages"].append(details)
        return details

    try:
        child = preflight(root, flutter, os.environ if environment is None else environment)
        original = (root / SOURCE).read_bytes()
        protected = {path: (root / path).read_bytes() for path in PROTECTED}
        report["source_sha256_before"] = {str(SOURCE): digest(original),
                                          **{str(path): digest(data) for path, data in protected.items()}}
        mutants = [(mutation, mutation.apply(original)) for mutation in MUTATIONS]
        cleanup_confirmed = False
        result = runner([str(flutter), "--no-version-check", "--version", "--machine"],
                        root, child, min(timeout, 60))
        cleanup_confirmed = result.cleanup_confirmed
        try:
            version = json.loads(result.stdout)
            version_ok = isinstance(version, dict) and version.get("frameworkVersion") == FLUTTER_VERSION
        except ValueError:
            version_ok = False
        version_ok = (version_ok and result.returncode == 0 and not result.timed_out
                      and not result.launch_error and result.cleanup_confirmed)
        record("00_flutter_version", result, {"outcome": "version_pass" if version_ok else "gate_failure"})
        if not version_ok:
            raise GateError("existing Flutter does not report pinned version " + FLUTTER_VERSION)
        verify(original)
        ready = True
        initial = stage("01_baseline", TEST_NAMES)
        verify(original)
        if initial["outcome"] != "baseline_pass":
            raise GateError("initial baseline failed; no mutations attempted")
        for index, (mutation, data) in enumerate(mutants, 2):
            verify(original)
            try:
                (root / SOURCE).write_bytes(data)
                result = stage(f"{index:02}_{mutation.name}", (mutation.test_name,), mutant=True, source=data)
                verify(data)
                if result["outcome"] != "killed":
                    raise GateError(mutation.name + ": " + result["outcome"])
            finally:
                (root / SOURCE).write_bytes(original)
                verify(original)
    except (Exception, KeyboardInterrupt) as error:
        if isinstance(error, UncertainCleanup):
            cleanup_confirmed = False
        report["failures"].append(f"{type(error).__name__}: {error}")
    finally:
        if original is not None:
            try:
                (root / SOURCE).write_bytes(original)
                verify(original)
                report["source_sha256_after"] = {str(SOURCE): digest((root / SOURCE).read_bytes()),
                                                  **{str(path): digest((root / path).read_bytes()) for path in protected}}
                report["source_restored"] = True
            except Exception as error:
                report["source_restored"] = False
                report["failures"].append(f"restoration: {type(error).__name__}: {error}")
        if ready and report.get("source_restored") and cleanup_confirmed:
            try:
                final = stage("05_final_baseline", TEST_NAMES)
                verify(original)
                if final["outcome"] != "baseline_pass":
                    raise GateError("final baseline did not pass")
            except (Exception, KeyboardInterrupt) as error:
                report["failures"].append(f"final baseline: {type(error).__name__}: {error}")
            finally:
                try:
                    (root / SOURCE).write_bytes(original)
                    verify(original)
                    report["source_sha256_after"] = {str(SOURCE): digest((root / SOURCE).read_bytes()),
                                                      **{str(path): digest((root / path).read_bytes()) for path in protected}}
                except Exception as error:
                    report["source_restored"] = False
                    report["failures"].append(f"final restoration: {type(error).__name__}: {error}")
        elif ready and not cleanup_confirmed:
            report["stages"].append({"stage": "05_final_baseline", "outcome": "not_run",
                                     "reason": "prior Flutter process cleanup is uncertain"})
        report["process_cleanup_confirmed"] = cleanup_confirmed
        if (not report["failures"] and report.get("source_restored") and
                sum(stage["outcome"] == "killed" for stage in report["stages"]) == len(MUTATIONS)):
            report["status"] = "passed"
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--flutter", type=Path, required=True, help="existing pinned SDK executable path, not a shell command")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output-dir", type=Path, required=True, help="new or empty evidence directory")
    parser.add_argument("--timeout-seconds", type=int, default=240, choices=range(30, 601), metavar="30..600")
    args = parser.parse_args(argv)
    root = args.repo_root.resolve()
    flutter = args.flutter.resolve()
    output = args.output_dir.resolve()
    if output == root or any(directory == output or directory in output.parents
                             for directory in (root / "lib", root / "test", root / ".git", root / "tool")):
        parser.error("output directory must not overwrite source/test/tool/git directories")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("output directory must be new or empty")
    output.mkdir(parents=True, exist_ok=True)

    def interrupted(signum: int, _frame: object) -> None:
        raise GateError(f"interrupted by signal {signum}")

    previous = signal.signal(signal.SIGTERM, interrupted)
    started = time.monotonic()
    try:
        report = run_gate(root, flutter, output, args.timeout_seconds)
    finally:
        signal.signal(signal.SIGTERM, previous)
    print(json.dumps({"status": report["status"], "report": str(output / "report.json"),
                      "elapsed_seconds": round(time.monotonic() - started, 2)}))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
