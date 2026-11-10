#!/usr/bin/env python3
"""Portable parser and exception-safe source restoration tests; no Flutter needed."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import compare_long_chat_windows_baseline as gate


def stream(failed=()):
    events = [{"type": "start", "protocolVersion": "0.1.1"},
              {"type": "allSuites", "count": len(gate.SUITES)}]
    for sid, suite in enumerate(gate.SUITES):
        tid = sid * 2
        events += [
            {"type": "suite", "suite": {"id": sid, "path": suite}},
            {"type": "testStart", "test": {"id": tid, "suiteID": sid,
             "name": "loading " + suite, "metadata": {"skip": False}}},
            {"type": "testDone", "testID": tid, "result": "success",
             "skipped": False, "hidden": True},
            {"type": "group", "group": {"id": sid, "suiteID": sid,
             "parentID": None, "testCount": 1, "metadata": {"skip": False}}},
            {"type": "testStart", "test": {"id": tid + 1, "suiteID": sid,
             "name": "case", "metadata": {"skip": False}}},
        ]
        if sid in failed:
            events.append({"type": "error", "testID": tid + 1,
                           "error": "Expected: 1\n Actual: 2", "isFailure": True})
        events.append({"type": "testDone", "testID": tid + 1,
                       "result": "failure" if sid in failed else "success",
                       "skipped": False, "hidden": False})
    events.append({"type": "done", "success": not failed})
    return events


class ParserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def parse(self, events, code=0, stderr="", extra=""):
        log, err = self.root / "run.jsonl", self.root / "stderr.log"
        log.write_text("\n".join(json.dumps(e) for e in events) + extra, encoding="utf-8")
        err.write_text(stderr, encoding="utf-8")
        return gate.parse_run(log, err, code, self.root)

    def test_valid_pass_with_warning(self):
        run = self.parse(stream(), stderr="Warning: unused import\n")
        self.assertEqual(run.summary()["case_count"], 7)
        self.assertFalse(run.failures)

    def test_shared_failures_are_explicit(self):
        report = gate.compare(self.parse(stream((0,)), 1), self.parse(stream((0,)), 1))
        self.assertTrue(report["passed_comparison"])
        self.assertEqual(report["shared_failures"][0]["suite"], gate.SUITES[0])
        self.assertEqual(report["shared_failures"][0]["errors"][0]["kind"], "assertion")

    def test_introduced_failure_fails_comparison(self):
        report = gate.compare(self.parse(stream((0,)), 1), self.parse(stream()))
        self.assertFalse(report["passed_comparison"])
        self.assertEqual(len(report["introduced_failures"]), 1)

    def test_malformed_missing_done_and_trailing_events(self):
        for events, extra in [(stream(), "\nnot JSON"), (stream()[:-1], ""),
                              (stream() + [{"type": "print", "message": "late"}], "")]:
            with self.subTest(extra=extra), self.assertRaises(gate.InvalidRun):
                self.parse(events, extra=extra)

    def test_canceled_run(self):
        events = stream()
        del events[-2]  # One started test never completed, even though done exists.
        with self.assertRaises(gate.InvalidRun):
            self.parse(events)
        with self.assertRaises(gate.InvalidRun):
            self.parse(stream(), 130)

    def test_compile_and_load_errors(self):
        events = stream((0,))
        for event in events:
            if event["type"] == "error":
                event["error"] = "Failed to load test: compilation failed"
        with self.assertRaises(gate.InvalidRun):
            self.parse(events, 1)
        events = stream()
        events[4]["result"] = "failure"  # Hidden loader cannot be a baseline failure.
        with self.assertRaises(gate.InvalidRun):
            self.parse(events, 1)

    def test_matching_visible_runtime_errors_are_reported(self):
        events = stream((0,))
        error = next(e for e in events if e["type"] == "error")
        error.update(isFailure=False, error="Bad state: No element")
        next(e for e in events if e["type"] == "testDone" and e["testID"] == 1)["result"] = "error"
        run = self.parse(events, 1)
        report = gate.compare(run, self.parse(events, 1))
        self.assertTrue(report["passed_comparison"])
        self.assertEqual(report["shared_failures"][0]["errors"][0]["kind"], "runtime")
        error["error"] = "Bad state: a new error"
        self.assertFalse(gate.compare(self.parse(events, 1), run)["passed_comparison"])
        error["error"] = "Bad state: No element"
        error["isFailure"] = True
        self.assertFalse(gate.compare(self.parse(events, 1), run)["passed_comparison"])

    def test_stderr_errors_and_exit_mismatch(self):
        with self.assertRaises(gate.InvalidRun):
            self.parse(stream(), stderr="Error: compiler broke")
        with self.assertRaises(gate.InvalidRun):
            self.parse(stream((0,)), 0)

    def test_skipped_test_and_group(self):
        for kind in ("testDone", "testStart", "group"):
            events = stream()
            target = next(e for e in events if e["type"] == kind)
            if kind == "testDone":
                target["skipped"] = True
            else:
                target["test" if kind == "testStart" else "group"]["metadata"]["skip"] = True
            with self.subTest(kind=kind), self.assertRaises(gate.InvalidRun):
                self.parse(events)

    def test_missing_suite_and_count_mismatch(self):
        events = stream()
        next(e for e in events if e["type"] == "allSuites")["count"] = 6
        with self.assertRaises(gate.InvalidRun):
            self.parse(events)
        events = stream()
        next(e for e in events if e["type"] == "group")["group"]["testCount"] = 2
        with self.assertRaises(gate.InvalidRun):
            self.parse(events)
        patched, baseline = self.parse(stream()), self.parse(stream())
        patched.cases[(gate.SUITES[0], "extra")] = 1
        with self.assertRaises(gate.InvalidRun):
            gate.compare(patched, baseline)

    def test_windows_and_file_url_paths(self):
        root = self.root
        prefix = str(root.resolve()).replace("/", "\\")
        raw = prefix + "\\" + gate.SUITES[0].replace("/", "\\")
        self.assertEqual(gate.canonical_suite(raw, root), gate.SUITES[0])
        self.assertEqual(gate.canonical_suite((root / gate.SUITES[0]).as_uri(), root), gate.SUITES[0])
        with self.assertRaises(gate.InvalidRun):
            gate.canonical_suite("/different/repo/" + gate.SUITES[0], root)

    @unittest.skipUnless(os.name == "nt", "Windows .bat integration test")
    def test_real_windows_batch_path_with_spaces(self):
        sdk = self.root / "fake flutter sdk"
        sdk.mkdir()
        batch = sdk / "flutter.bat"
        batch.write_text(
            '@echo off\necho {"marker":"executed"}\necho retained warning 1>&2\nexit /b 1\n',
            encoding="ascii",
        )
        code = gate.run_tests(self.root, self.root, "fixture", str(batch))
        self.assertEqual(code, 1)
        self.assertEqual(json.loads((self.root / "fixture.jsonl").read_text()),
                         {"marker": "executed"})
        self.assertIn("retained warning", (self.root / "fixture.stderr.log").read_text())

    def test_production_and_test_helper_guard(self):
        changes = [gate.SOURCES[0], gate.RETAINED_NATIVE[0], gate.NEW_REGRESSION_TESTS[0]]
        def fake_git(root, *args):
            if args[0] == "diff":
                return "\n".join(changes).encode()
            if args[0] == "show":
                return b"baseline source"
            return b""
        with patch.object(gate, "git", fake_git):
            blobs, paths = gate.baseline_blobs(self.root)
            self.assertEqual(set(blobs), set(gate.SOURCES))
            self.assertEqual(paths, changes)
            for forbidden in ("test/flutter_test_config.dart", "lib/other.dart", "pubspec.lock"):
                changes.append(forbidden)
                with self.subTest(path=forbidden), self.assertRaises(gate.InvalidRun):
                    gate.baseline_blobs(self.root)
                changes.pop()

    def test_restore_on_exception_including_binary_bytes(self):
        original = {"a.dart": b"patched\r\n\xff", "b.dart": b"other\n"}
        for name, data in original.items():
            (self.root / name).write_bytes(data)
        with self.assertRaisesRegex(RuntimeError, "test crashed"):
            with gate.replaced_sources(self.root, {name: b"baseline" for name in original}):
                self.assertEqual((self.root / "a.dart").read_bytes(), b"baseline")
                raise RuntimeError("test crashed")
        for name, data in original.items():
            self.assertEqual((self.root / name).read_bytes(), data)

    def test_restore_after_partial_replacement(self):
        for name in ("a.dart", "b.dart"):
            (self.root / name).write_bytes(b"patched")
        real_write = Path.write_bytes
        calls = 0
        def fail_second(path, data):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("partial write")
            return real_write(path, data)
        with patch.object(Path, "write_bytes", fail_second), self.assertRaises(OSError):
            with gate.replaced_sources(self.root, {"a.dart": b"base", "b.dart": b"base"}):
                self.fail("Must not reach test run")
        for name in ("a.dart", "b.dart"):
            self.assertEqual((self.root / name).read_bytes(), b"patched")


if __name__ == "__main__":
    unittest.main()
