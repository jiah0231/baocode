"""Stdlib-only harness tests. No Flutter, Chrome, or other child process runs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import browser_component_mutations as gate


def machine_events(names, *, failure=False, wrapped=False):
    events = [
        {"type": "start", "protocolVersion": "0.1.1"},
        {"type": "suite", "suite": {"id": 0, "platform": "vm", "path": str(gate.TEST_FILE)}},
        {"type": "testStart", "test": {"id": 0, "suiteID": 0, "name": "loading component test"}},
        {"type": "testDone", "testID": 0, "result": "success", "skipped": False, "hidden": True},
    ]
    for test_id, name in enumerate(names, 1):
        events.append({"type": "testStart", "test": {"id": test_id, "suiteID": 0, "name": name}})
        if failure:
            assertion = "Expected: a value close to 100\n  Actual: <200>\n" + gate.ASSERTION_MARKERS.get(name, "") + "\n"
            stack = "package:matcher/expect.dart 149\ntest/browser/browser_mirror_test.dart 271"
            if wrapped:
                events.append({"type": "print", "testID": test_id, "messageType": "print",
                               "message": "The following TestFailure was thrown running a test:\n" + assertion + stack})
            events.append({"type": "error", "testID": test_id, "isFailure": True,
                           "error": "Test failed. See exception logs above." if wrapped else assertion,
                           "stackTrace": stack})
        events.append({"type": "testDone", "testID": test_id,
                       "result": "failure" if failure else "success", "hidden": False,
                       "skipped": False, "retried": False})
    events.append({"type": "done", "success": not failure})
    return events


def process(events, returncode=0, **kwargs):
    return gate.ProcessResult(returncode, "\n".join(json.dumps(event) for event in events) + "\n", **kwargs)


class MachineProtocolTests(unittest.TestCase):
    def verdict(self, events, *, failure=True, returncode=None, **kwargs):
        result = process(events, (1 if failure else 0) if returncode is None else returncode, **kwargs)
        return gate.validate_machine(result, (gate.LANDMARK_TEST,), Path.cwd(), mutant=failure)["outcome"]

    def test_baseline_pass(self):
        self.assertEqual(self.verdict(machine_events((gate.LANDMARK_TEST,)), failure=False), "baseline_pass")

    def test_exact_assertion_kills_mutant(self):
        self.assertEqual(self.verdict(machine_events((gate.LANDMARK_TEST,), failure=True)), "killed")

    def test_flutter_wrapped_assertion_kills_mutant(self):
        self.assertEqual(self.verdict(machine_events((gate.LANDMARK_TEST,), failure=True, wrapped=True)), "killed")

    def test_unexpected_mutant_pass_is_not_killed(self):
        self.assertEqual(self.verdict(machine_events((gate.LANDMARK_TEST,)), returncode=0), "mutant_survived")

    def test_runtime_exception_even_when_flutter_wrapped_is_not_killed(self):
        events = machine_events((gate.LANDMARK_TEST,), failure=True, wrapped=True)
        message = next(event for event in events if event["type"] == "print")
        message["message"] = message["message"].replace("TestFailure", "StateError")
        self.assertEqual(self.verdict(events), "gate_failure")

    def test_infrastructure_errors_are_not_killed(self):
        for reason in ("Compilation failed", "Test timed out after 2 minutes", "Bad state: No element",
                       "SocketException", "The test process crashed"):
            with self.subTest(reason=reason):
                events = machine_events((gate.LANDMARK_TEST,), failure=True)
                events.insert(-1, {"type": "print", "testID": 1, "messageType": "print", "message": reason})
                self.assertEqual(self.verdict(events), "gate_failure")

    def test_late_infrastructure_error_after_test_done_is_rejected(self):
        events = machine_events((gate.LANDMARK_TEST,), failure=True)
        events.insert(-1, {"type": "error", "testID": 1, "error": "unrelated async runtime failure",
                           "stackTrace": "frame", "isFailure": False})
        self.assertEqual(self.verdict(events), "gate_failure")

    def test_late_baseline_error_is_rejected(self):
        events = machine_events((gate.LANDMARK_TEST,))
        events.insert(-1, {"type": "error", "testID": 1, "error": "late error", "stackTrace": "", "isFailure": False})
        self.assertEqual(self.verdict(events, failure=False), "gate_failure")

    def test_selected_test_helper_assertion_is_not_a_regression_kill(self):
        events = machine_events((gate.LANDMARK_TEST,), failure=True, wrapped=True)
        message = next(event for event in events if event["type"] == "print")
        message["message"] = message["message"].replace(gate.ASSERTION_MARKERS[gate.LANDMARK_TEST],
                                                     "synthetic browser handshake or frame timed out")
        self.assertEqual(self.verdict(events), "gate_failure")

    def test_marker_assertion_plus_extra_helper_assertion_is_rejected(self):
        events = machine_events((gate.LANDMARK_TEST,), failure=True, wrapped=True)
        events.insert(-1, {"type": "error", "testID": 1, "isFailure": True,
                           "error": "Expected: true\nActual: false\nhelper failed",
                           "stackTrace": "test/browser/browser_mirror_test.dart 999"})
        self.assertEqual(self.verdict(events), "gate_failure")

    def test_assertion_with_wrong_regression_marker_is_rejected(self):
        events = machine_events((gate.LANDMARK_TEST,), failure=True)
        error = next(event for event in events if event["type"] == "error")
        error["error"] = error["error"].replace(gate.ASSERTION_MARKERS[gate.LANDMARK_TEST],
                                               gate.ASSERTION_MARKERS[gate.PAINTED_TEST])
        self.assertEqual(self.verdict(events), "gate_failure")

    def test_missing_assertion_evidence_is_rejected(self):
        events = machine_events((gate.LANDMARK_TEST,), failure=True)
        next(event for event in events if event["type"] == "error")["error"] = "Test failed."
        self.assertEqual(self.verdict(events), "gate_failure")

    def test_failure_from_other_test_is_rejected(self):
        events = machine_events((gate.LANDMARK_TEST,), failure=True)
        next(event for event in events if event["type"] == "error")["testID"] = 0
        self.assertEqual(self.verdict(events), "gate_failure")

    def test_malformed_protocol_missing_target_skip_retry_and_exit_are_rejected(self):
        for defect in ("missing_target", "skip", "retry", "missing_done", "duplicate_done", "unexpected_test",
                       "chrome", "other_file", "missing_start", "error_result", "wrong_exit"):
            with self.subTest(defect=defect):
                events = machine_events((gate.LANDMARK_TEST,), failure=True)
                target_start = next(event for event in events if event["type"] == "testStart" and event["test"]["id"] == 1)
                target_done = next(event for event in events if event["type"] == "testDone" and event["testID"] == 1)
                code = 1
                if defect == "missing_target":
                    target_start["test"]["name"] = "different test"
                elif defect == "skip":
                    target_done["skipped"] = True
                elif defect == "retry":
                    target_done["retried"] = True
                elif defect == "missing_done":
                    events.pop()
                elif defect == "duplicate_done":
                    events.append(events[-1])
                elif defect == "unexpected_test":
                    events[3]["hidden"] = False
                elif defect == "chrome":
                    events[1]["suite"]["platform"] = "chrome"
                elif defect == "other_file":
                    events[1]["suite"]["path"] = "test/browser/browser_mirror_real_chrome_test.dart"
                elif defect == "missing_start":
                    events.pop(0)
                elif defect == "error_result":
                    target_done["result"] = "error"
                elif defect == "wrong_exit":
                    code = 255
                self.assertEqual(self.verdict(events, returncode=code), "gate_failure")

    def test_bad_json_and_timeout_are_rejected(self):
        for result in (gate.ProcessResult(1, "not JSON"), gate.ProcessResult(1, "{}"),
                       gate.ProcessResult(1, "[]"), gate.ProcessResult(1, "", timed_out=True),
                       gate.ProcessResult(None, launch_error="launch failed")):
            with self.subTest(result=result):
                self.assertEqual(gate.validate_machine(result, (gate.LANDMARK_TEST,), Path.cwd(), mutant=True)["outcome"],
                                 "gate_failure")

    def test_reporter_file_handles_native_hook_stdout_but_not_malformed_reporter(self):
        raw = gate.ProcessResult(1, "Running build hooks...\n")
        reporter = process(machine_events((gate.LANDMARK_TEST,), failure=True), 1).stdout
        verdict = gate.validate_machine(raw, (gate.LANDMARK_TEST,), Path.cwd(), mutant=True, machine_output=reporter)
        self.assertEqual(verdict["outcome"], "killed")
        verdict = gate.validate_machine(raw, (gate.LANDMARK_TEST,), Path.cwd(), mutant=True, machine_output=reporter + "bad line")
        self.assertEqual(verdict["outcome"], "gate_failure")


class GateLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "evidence"
        self.output.mkdir()
        self.original = b"// prefix\n" + gate.MUTATIONS[1].before + b"\n" + gate.MUTATIONS[2].before + b"\n// suffix\n"
        for path, data in [(gate.SOURCE, self.original), *[(path, b"unchanged fixture\n") for path in gate.PROTECTED]]:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_bytes(data)
        self.flutter = self.root / "sdk/bin/flutter"
        self.calls = []
        self.mode = None

    def fake_runner(self, command, root, environment, timeout):
        self.calls.append(command)
        self.assertEqual(environment["BAOCODE_REAL_CHROME_SMOKE"], "0")
        if "--version" in command:
            version = "0.0.0" if self.mode == "wrong_version" else gate.FLUTTER_VERSION
            return gate.ProcessResult(0, json.dumps({"frameworkVersion": version}))
        self.assertIn("--machine", command)
        self.assertIn("--no-pub", command)
        self.assertIn(str(gate.TEST_FILE), command)
        self.assertFalse(any("real_chrome" in arg or "--platform" in arg for arg in command))
        source = (root / gate.SOURCE).read_bytes()
        names = gate.TEST_NAMES
        failure = False
        if source != self.original:
            matches = [mutation for mutation in gate.MUTATIONS if mutation.apply(self.original) == source]
            self.assertEqual(len(matches), 1, "each stage contains exactly one known mutation")
            names = (matches[0].test_name,)
            failure = self.mode != "survivor"
            if self.mode == "raise":
                raise RuntimeError("mock execution failure")
            if self.mode == "interrupt":
                raise KeyboardInterrupt()
        events = machine_events(names, failure=failure, wrapped=True)
        result = process(events, int(failure))
        if source != self.original and self.mode == "timeout":
            result.timed_out = True
        if source != self.original and self.mode == "uncertain_cleanup":
            result.timed_out = True
            result.cleanup_confirmed = False
        if source != self.original and self.mode == "compile":
            result.stderr = "Compilation failed"
        if source != self.original and self.mode == "malformed":
            result.stdout += "not JSON\n"
        if self.mode == "initial_baseline_fail" and len(self.calls) == 2:
            result = process(machine_events(names, failure=True), 1)
        if self.mode != "missing_report":
            Path(command[command.index("--file-reporter") + 1].removeprefix("json:")).write_text(result.stdout, encoding="utf-8")
        return result

    def run_gate(self):
        with patch.object(gate, "preflight", side_effect=lambda root, flutter, environment: gate.child_environment(environment)):
            return gate.run_gate(self.root, self.flutter, self.output, 30,
                                 runner=self.fake_runner, environment={"BAOCODE_REAL_CHROME_SMOKE": "0"})

    def test_success_restores_bytes_and_records_separate_hashes_and_final_baseline(self):
        report = self.run_gate()
        self.assertEqual(report["status"], "passed")
        self.assertEqual(len(self.calls), 6)
        self.assertEqual((self.root / gate.SOURCE).read_bytes(), self.original)
        self.assertEqual(report["source_sha256_before"], report["source_sha256_after"])
        self.assertEqual(report["stages"][-1]["stage"], "05_final_baseline")
        for mutation in gate.MUTATIONS:
            stage = next(stage for stage in report["stages"] if stage["stage"].endswith(mutation.name))
            disk = json.loads((self.output / stage["stage"] / "result.json").read_text())
            self.assertEqual(disk["source_sha256"], gate.digest(mutation.apply(self.original)))
            self.assertEqual(disk["outcome"], "killed")
        for path in gate.PROTECTED:
            self.assertEqual((self.root / path).read_bytes(), b"unchanged fixture\n")

    def test_restoration_and_final_baseline_after_each_failure_kind(self):
        for mode in ("survivor", "timeout", "compile", "malformed", "raise", "interrupt", "uncertain_cleanup"):
            with self.subTest(mode=mode):
                self.mode = mode
                self.calls = []
                self.output = self.root / mode
                self.output.mkdir()
                report = self.run_gate()
                self.assertEqual(report["status"], "failed")
                self.assertEqual((self.root / gate.SOURCE).read_bytes(), self.original)
                self.assertTrue(report["source_restored"])
                self.assertEqual(report["stages"][-1]["stage"], "05_final_baseline")
                if mode in ("raise", "interrupt", "uncertain_cleanup"):
                    self.assertEqual(report["stages"][-1]["outcome"], "not_run")
                    self.assertFalse(report["process_cleanup_confirmed"])
                    self.assertEqual(len(self.calls), 3)
                else:
                    self.assertEqual(report["stages"][-1]["outcome"], "baseline_pass")
                    self.assertEqual(len(self.calls), 4)

    def test_missing_file_reporter_fails_closed(self):
        self.mode = "missing_report"
        report = self.run_gate()
        self.assertEqual(report["status"], "failed")
        self.assertFalse(any(stage["outcome"] == "killed" for stage in report["stages"]))

    def test_initial_baseline_failure_never_mutates(self):
        self.mode = "initial_baseline_fail"
        report = self.run_gate()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(report["stages"][-1]["outcome"], "baseline_pass")
        self.assertEqual((self.root / gate.SOURCE).read_bytes(), self.original)

    def test_wrong_flutter_version_never_runs_tests(self):
        self.mode = "wrong_version"
        report = self.run_gate()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.root / gate.SOURCE).read_bytes(), self.original)

    def test_anchor_drift_fails_before_process_or_mutation(self):
        self.original = self.original.replace(b"_paintedFrame", b"_otherFrame")
        (self.root / gate.SOURCE).write_bytes(self.original)
        report = self.run_gate()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(self.calls, [])
        self.assertEqual((self.root / gate.SOURCE).read_bytes(), self.original)
        self.assertIn("anchor occurs 0 times", report["failures"][0])


class InputAndProcessTests(unittest.TestCase):
    def test_exact_anchor_rejects_zero_and_multiple_occurrences(self):
        mutation = gate.MUTATIONS[0]
        for source in (b"no anchor", mutation.before + mutation.before):
            with self.assertRaises(gate.GateError):
                mutation.apply(source)

    def test_crlf_preserved_and_mixed_endings_rejected(self):
        mutation = gate.MUTATIONS[0]
        original = b"prefix\r\n" + mutation.before.replace(b"\n", b"\r\n") + b"\r\nsuffix\r\n"
        expected = b"prefix\r\n" + mutation.after.replace(b"\n", b"\r\n") + b"\r\nsuffix\r\n"
        self.assertEqual(mutation.apply(original), expected)
        with self.assertRaises(gate.GateError):
            mutation.apply(original + b"mixed\n")

    def test_no_smoke_opt_in_secrets_or_arbitrary_test_command(self):
        for value in ("1", "true", ""):
            with self.assertRaises(gate.GateError):
                gate.child_environment({"BAOCODE_REAL_CHROME_SMOKE": value})
        environment = gate.child_environment({"PATH": "tools", "GITHUB_TOKEN": "not-a-real-secret",
                                               "BAOCODE_CHROME_FOR_TESTING": "browser"})
        self.assertEqual(environment["PATH"], "tools")
        self.assertNotIn("GITHUB_TOKEN", environment)
        self.assertNotIn("BAOCODE_CHROME_FOR_TESTING", environment)
        with self.assertRaises(gate.GateError):
            gate.test_command(Path("flutter"), ("test/browser/real_chrome",), Path("report"))

    def test_windows_installation_roots_preserve_casing_without_secrets_or_smoke_override(self):
        roots = {"ProgramFiles": r"C:\Program Files",
                 "ProgramFiles(x86)": r"C:\Program Files (x86)",
                 "ProgramW6432": r"C:\Program Files"}
        environment = {**roots, "GITHUB_TOKEN": "not-a-real-token",
                       "ACTIONS_RUNTIME_TOKEN": "not-a-real-token",
                       "BAOCODE_CHROME_FOR_TESTING": "browser",
                       "BAOCODE_CFT_VERSION": "browser-version", "CHROME_EXECUTABLE": "browser",
                       "BAOCODE_REAL_CHROME_SMOKE": "0"}
        self.assertEqual(gate.child_environment(environment), {
            **roots, "BAOCODE_REAL_CHROME_SMOKE": "0", "CI": "true",
            "FLUTTER_SUPPRESS_ANALYTICS": "true", "DART_SUPPRESS_ANALYTICS": "true"})
        with self.assertRaises(gate.GateError):
            gate.child_environment({**environment, "BAOCODE_REAL_CHROME_SMOKE": "1"})

    def test_missing_existing_sdk_does_not_launch_or_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(gate.subprocess, "Popen") as popen:
                with self.assertRaises(gate.GateError):
                    gate.preflight(root, root / "sdk/bin/flutter", {})
                popen.assert_not_called()

    def test_windows_batch_uses_argument_array_and_uncertain_cleanup_fails_closed(self):
        root = Path.cwd()
        command = ["C:/existing Flutter/bin/flutter.bat", "--version", "--machine"]
        for defect in ("timeout", "terminate_failed", "close_failed", "assign_failed"):
            with self.subTest(defect=defect):
                fake = Mock(pid=1234, returncode=0)
                fake.poll.return_value = 0
                fake.communicate.return_value = ("stdout", "stderr")
                if defect == "timeout":
                    fake.returncode = -9
                    fake.communicate.side_effect = [subprocess.TimeoutExpired(command, 30), ("partial", "stderr")]
                job = Mock()
                job.stop.return_value = defect != "terminate_failed"
                job.close.return_value = defect != "close_failed"
                if defect == "assign_failed":
                    job.assign.side_effect = OSError("mock job assignment denied")
                with patch.object(gate.os, "name", "nt"), patch.object(gate, "_WindowsJob", return_value=job), \
                        patch.object(gate.subprocess, "Popen", return_value=fake) as popen, \
                        patch.object(gate.subprocess, "CREATE_NEW_PROCESS_GROUP", 512, create=True):
                    result = gate.run_process(command, root, {}, 30)
                self.assertFalse(result.cleanup_confirmed)
                self.assertEqual(popen.call_args.args[0], command)
                self.assertFalse(popen.call_args.kwargs["shell"])
                self.assertEqual(popen.call_args.kwargs["creationflags"], 512)
                self.assertTrue(job.close.called)

    @unittest.skipIf(os.name == "nt", "POSIX process-group mock; Windows job runs in provisioned CI")
    def test_subprocess_timeout_is_bounded_and_kills_own_process_group(self):
        fake = Mock(pid=1234, returncode=-9)
        fake.communicate.side_effect = [subprocess.TimeoutExpired(["flutter"], 30), ("partial", "stderr")]
        fake.poll.return_value = -9
        with patch.object(gate.subprocess, "Popen", return_value=fake) as popen, patch.object(gate.os, "killpg") as kill:
            result = gate.run_process(["flutter"], Path.cwd(), {}, 30)
        self.assertTrue(result.timed_out)
        self.assertEqual(result.stdout, "partial")
        self.assertEqual(fake.communicate.call_args_list[0].kwargs["timeout"], 30)
        self.assertEqual(fake.communicate.call_args_list[1].kwargs["timeout"], 10)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertFalse(popen.call_args.kwargs["shell"])
        kill.assert_called_with(1234, gate.signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
