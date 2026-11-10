#!/usr/bin/env python3
"""Compare seven Windows suites with only the six long-chat sources reverted.

This is not a full-suite pass. Both executions use the same checkout, SDK,
packages, test files, and command. JSONL, stderr, and a comparison report remain
under build/perf/long-chat-ci/windows-baseline even when validation fails.
"""
from __future__ import annotations

from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlparse

BASE = "5c4583efe6466cacd1330fd29746ffa7b2f4ca0a"
SOURCES = (
    "lib/kernel/transcript.dart", "lib/chat/chat_feed.dart",
    "lib/chat/chat_session.dart", "lib/chat/step_folds.dart",
    "lib/chat/chat_history_view.dart", "lib/chat/widgets/chat_minimap.dart",
)
SUITES = (
    "test/chat/code_citation_test.dart", "test/chat/composer_files_test.dart",
    "test/chat/content_image_test.dart", "test/chat/file_tags_test.dart",
    "test/chat/side_panel/file_open_test.dart",
    "test/chat/side_panel/side_panel_search_test.dart",
    "test/chat/side_panel/side_panel_workspace_test.dart",
)
# Native runner-only changes are not linked into flutter test's widget host.
RETAINED_NATIVE = (
    "windows/runner/translation_mouse_hook.h",
    "windows/runner/translation_mouse_mailbox.h",
    "windows/runner/translation_selection_action.cpp",
    "windows/runner/translation_selection_action.h",
)
NEW_REGRESSION_TESTS = (
    "test/chat/history_stream_work_test.dart",
    "test/chat/stream_change_tracking_test.dart",
    "test/chat/chat_minimap_incremental_test.dart",
)
RECONSTRUCTED_FONT = "assets/fonts/maple/MapleMonoNormal-NF-CN-Regular.ttf"
FONT_VERIFIER = "tool/ci/reassemble_maple_font.py"
ARTIFACTS = Path("build/perf/long-chat-ci/windows-baseline")
# Infrastructure failures are not evidence of a completed testcase baseline.
INFRASTRUCTURE = re.compile(
    r"failed to load|compilation failed|compiler (?:crash|error)|"
    r"error when reading|could not (?:load|resolve|find)|"
    r"timed out|timeoutexception|"
    r"test (?:was )?cancel(?:ed|led)|connection (?:closed|reset)|"
    r"lost connection|shell subprocess|exited unexpectedly|"
    r"(?:^|\n).*\.dart:\d+:\d+: error:", re.IGNORECASE,
)


class InvalidRun(ValueError):
    """Incomplete, ambiguous, or infrastructure-failed test execution."""


@dataclass
class Run:
    cases: Counter
    failures: frozenset[tuple[str, str]]
    signatures: dict[tuple[str, str], tuple[tuple[str, str], ...]]

    def summary(self):
        return {
            "case_count": sum(self.cases.values()),
            "suite_counts": dict(sorted(Counter(
                suite for (suite, _), count in self.cases.items()
                for _ in range(count)
            ).items())),
            "failures": [dict(suite=suite, test=name)
                         for suite, name in sorted(self.failures)],
        }


def canonical_suite(raw: str, root: Path) -> str:
    """Accept file URLs, Windows paths, or repository-relative suite paths."""
    value = unquote(urlparse(raw).path) if raw.startswith("file:") else raw
    value = value.replace("\\", "/")
    # File URLs can prefix Windows drive paths with a slash.
    if re.match(r"^/[A-Za-z]:/", value):
        value = value[1:]
    # Windows temporary directories can use 8.3 aliases (RUNNER~1). Resolve
    # both absolute paths before applying the strict repository boundary.
    if Path(value).is_absolute():
        value = str(Path(value).resolve()).replace("\\", "/")
    prefix = str(root.resolve()).replace("\\", "/").rstrip("/") + "/"
    if value.casefold().startswith(prefix.casefold()):
        value = value[len(prefix):]
    if value.startswith("./"):
        value = value[2:]
    if value not in SUITES:
        raise InvalidRun(f"Unexpected suite path: {raw!r}")
    return value


def parse_run(path: Path, stderr: Path, returncode: int, root: Path) -> Run:
    suites, tests, ended, errors, expected_counts = {}, {}, {}, {}, {}
    suite_count = None
    started = done = None
    for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except (ValueError, TypeError) as exc:
            raise InvalidRun(f"Malformed JSON at line {number}") from exc
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise InvalidRun(f"Invalid JSON event at line {number}")
        kind = event["type"]
        if done is not None:
            raise InvalidRun("Events after done")
        if kind == "start":
            if started is not None:
                raise InvalidRun("Duplicate start")
            started = event
        elif kind == "suite":
            suite = event.get("suite", {})
            sid = suite.get("id")
            if sid is None or sid in suites:
                raise InvalidRun("Invalid/duplicate suite ID")
            suites[sid] = canonical_suite(suite.get("path", ""), root)
        elif kind == "allSuites":
            if suite_count is not None or event.get("count") != len(SUITES):
                raise InvalidRun("Unexpected/duplicate allSuites count")
            suite_count = event["count"]
        elif kind == "group":
            group = event.get("group", {})
            if group.get("metadata", {}).get("skip", False):
                raise InvalidRun("Skipped test group")
            if group.get("parentID") is None:
                sid = group.get("suiteID")
                count = group.get("testCount")
                if sid not in suites or sid in expected_counts or type(count) is not int or count < 1:
                    raise InvalidRun("Invalid root-group test count")
                expected_counts[sid] = count
        elif kind == "testStart":
            test = event.get("test", {})
            tid = test.get("id")
            if tid is None or tid in tests or test.get("suiteID") not in suites:
                raise InvalidRun("Invalid test ID or unknown suite")
            if not isinstance(test.get("name"), str) or not test["name"]:
                raise InvalidRun("Missing test name")
            if test.get("metadata", {}).get("skip", False):
                raise InvalidRun(f"Skipped test: {test['name']}")
            tests[tid] = test
        elif kind == "testDone":
            tid = event.get("testID")
            if tid not in tests or tid in ended:
                raise InvalidRun("Unknown/duplicate completed test")
            if event.get("skipped") is not False:
                raise InvalidRun("Skipped test or missing skipped flag")
            if event.get("result") not in ("success", "failure", "error"):
                raise InvalidRun("Unknown test result")
            ended[tid] = event
        elif kind == "error":
            tid = event.get("testID")
            if tid not in tests or not isinstance(event.get("error"), str):
                raise InvalidRun("Unattributed error")
            errors.setdefault(tid, []).append(event)
        elif kind == "done":
            done = event
        elif kind not in ("allSuites", "group", "print", "debug"):
            raise InvalidRun(f"Unknown event type: {kind}")
        if kind in ("error", "print"):
            message = event.get("error", event.get("message", ""))
            if INFRASTRUCTURE.search(message):
                raise InvalidRun(f"Infrastructure error: {message[:300]}")
    if started is None or done is None or not isinstance(done.get("success"), bool):
        raise InvalidRun("Missing start/done or invalid done.success")
    if suite_count != len(SUITES) or set(suites.values()) != set(SUITES) or len(suites) != len(SUITES):
        raise InvalidRun("Not all seven requested suites executed exactly once")
    if not tests or set(tests) != set(ended):
        raise InvalidRun("Canceled/incomplete test run")
    cases, failures, signatures = Counter(), set(), {}
    for tid, test in tests.items():
        result = ended[tid]
        name = test["name"]
        # package:test's synthetic loader and setUpAll/tearDownAll events are
        # hidden. They must succeed but are not test cases.
        hidden = result.get("hidden", False)
        if not isinstance(hidden, bool):
            raise InvalidRun("Invalid hidden flag")
        if hidden or name.startswith("loading ") or name.endswith(("(setUpAll)", "(tearDownAll)")):
            if result["result"] != "success" or errors.get(tid):
                raise InvalidRun(f"Suite loading/setup failed: {name}")
            continue
        key = (suites[test["suiteID"]], name)
        cases[key] += 1
        if result["result"] in ("failure", "error"):
            if not errors.get(tid) or any(type(e.get("isFailure")) is not bool for e in errors[tid]):
                raise InvalidRun(f"Unconfirmed test failure: {key}")
            signatures[key] = tuple(sorted(
                ("assertion" if e["isFailure"] else "runtime",
                 normalize_message(e["error"], root)) for e in errors[tid]
            ))
            failures.add(key)
        elif errors.get(tid):
            raise InvalidRun(f"Error reported for successful test: {key}")
    if {suite for suite, _ in cases} != set(SUITES):
        raise InvalidRun("A requested suite executed no test cases")
    actual_counts = Counter(suite for suite, _ in cases.elements())
    if {suites[sid]: count for sid, count in expected_counts.items()} != dict(actual_counts):
        raise InvalidRun("Executed test counts differ from declared suite counts")
    if any(count != 1 for count in cases.values()):
        raise InvalidRun("Duplicate canonical test names prevent unambiguous comparison")
    expected_code = 1 if failures else 0
    if returncode != expected_code or done["success"] != (not failures):
        raise InvalidRun(f"Exit/done mismatch: code={returncode}, failures={len(failures)}")
    stderr_text = stderr.read_text(encoding="utf-8", errors="replace")
    if INFRASTRUCTURE.search(stderr_text) or re.search(
        r"(?im)^\s*(?:error|fatal|exception)\b", stderr_text
    ):
        raise InvalidRun("Infrastructure error on stderr (see retained artifact)")
    return Run(cases, frozenset(failures), signatures)


def normalize_message(message: str, root: Path) -> str:
    message = message.replace("\r\n", "\n")
    for prefix in (str(root.resolve()), str(root.resolve()).replace("\\", "/")):
        message = message.replace(prefix, "<repo>")
    return message


def failure_detail(run: Run, key: tuple[str, str]) -> dict:
    return {"suite": key[0], "test": key[1],
            "errors": [{"kind": kind, "message": message}
                       for kind, message in run.signatures[key]]}


def compare(patched: Run, baseline: Run) -> dict:
    if patched.cases != baseline.cases:
        raise InvalidRun("Baseline and patch test identities/counts differ")
    introduced = patched.failures - baseline.failures
    changed = {key for key in patched.failures & baseline.failures
               if patched.signatures[key] != baseline.signatures[key]}
    shared = (patched.failures & baseline.failures) - changed
    report = {
        "baseline_commit": BASE,
        "scope": "Seven selected Windows suites, not the full chat suite",
        "patched": patched.summary(), "baseline": baseline.summary(),
        "shared_failures": [failure_detail(patched, key) for key in sorted(shared)],
        "changed_failure_signatures": [
            {"patched": failure_detail(patched, key), "baseline": failure_detail(baseline, key)}
            for key in sorted(changed)],
        "introduced_failures": [dict(suite=s, test=n) for s, n in sorted(introduced)],
        "resolved_failures": [dict(suite=s, test=n) for s, n in sorted(baseline.failures - patched.failures)],
        "passed_comparison": not (introduced or changed),
    }
    return report


@contextmanager
def replaced_sources(root: Path, blobs: dict[str, bytes]):
    """Restore every original byte even on partial writes or test exceptions."""
    originals = {name: (root / name).read_bytes() for name in blobs}
    try:
        for name, data in blobs.items():
            (root / name).write_bytes(data)
        yield
    finally:
        failures = []
        for name, data in originals.items():
            try:
                (root / name).write_bytes(data)
                if (root / name).read_bytes() != data:
                    raise OSError("restoration verification failed")
            except OSError as exc:
                failures.append(f"{name}: {exc}")
        if failures:
            raise RuntimeError("SOURCE RESTORATION FAILED: " + "; ".join(failures))


def git(root: Path, *args: str) -> bytes:
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True).stdout


def baseline_blobs(root: Path) -> tuple[dict[str, bytes], list[str]]:
    try:
        git(root, "cat-file", "-e", BASE + "^{commit}")
    except subprocess.CalledProcessError as exc:
        raise InvalidRun(f"Pinned baseline {BASE} unavailable; use checkout fetch-depth >=10") from exc
    changes = git(root, "diff", "--name-only", BASE, "--").decode().splitlines()
    # Allow CI/docs/performance harness changes, but no other production or
    # dependency changes. Tests themselves stay identical in both executions.
    guarded = ("lib/", "packages/", "windows/", "linux/", "macos/", "android/", "ios/", "web/", "assets/", "test/")
    allowed = SOURCES + RETAINED_NATIVE + NEW_REGRESSION_TESTS
    unexpected = [name for name in changes if name not in allowed and (
        name.startswith(guarded) or name in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml")
        or name in SUITES or name == FONT_VERIFIER
    )]
    untracked = git(root, "ls-files", "--others", "--exclude-standard").decode().splitlines()
    if RECONSTRUCTED_FONT in untracked:
        verifier = root / FONT_VERIFIER
        baseline_verifier = git(root, "show", f"{BASE}:{FONT_VERIFIER}")
        if verifier.read_bytes().replace(b"\r\n", b"\n") != baseline_verifier.replace(b"\r\n", b"\n"):
            raise InvalidRun("Font verifier differs from pinned baseline")
        from reassemble_maple_font import verify_font
        verify_font(root)
    unexpected += [name for name in untracked if name.startswith(guarded)
                   and name not in NEW_REGRESSION_TESTS and name != RECONSTRUCTED_FONT]
    if unexpected:
        raise InvalidRun(f"Other production/dependency/selected-test changes from baseline: {unexpected}")
    for name in NEW_REGRESSION_TESTS:
        if git(root, "ls-tree", "--name-only", BASE, "--", name):
            raise InvalidRun(f"Expected new regression test already exists at baseline: {name}")
    blobs = {name: git(root, "show", f"{BASE}:{name}") for name in SOURCES}
    if not all(blobs.values()):
        raise InvalidRun("Missing/empty baseline source blob")
    return blobs, changes


def run_tests(root: Path, artifact_dir: Path, label: str, flutter: str) -> int:
    args = [flutter, "test", "--no-pub", "--reporter", "json", "--timeout", "2m", *SUITES]
    # Python's Windows shell=True quoting handles .bat paths with spaces.
    # Arguments are fixed here, never shell text supplied by a caller.
    with (artifact_dir / f"{label}.jsonl").open("wb") as out, (artifact_dir / f"{label}.stderr.log").open("wb") as err:
        return subprocess.run(args, shell=True, cwd=root, stdout=out, stderr=err, check=False).returncode


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    artifacts = root / ARTIFACTS
    artifacts.mkdir(parents=True, exist_ok=True)
    report = {"baseline_commit": BASE, "passed_comparison": False}
    try:
        if os.name != "nt":
            raise InvalidRun("Actual baseline comparison must run on Windows")
        flutter = shutil.which("flutter.bat")
        if not flutter:
            raise InvalidRun("flutter.bat not found on PATH")
        blobs, changes = baseline_blobs(root)
        report["changed_paths_from_baseline"] = changes
        report["replaced_sources"] = list(SOURCES)
        report["retained_native_paths"] = [name for name in RETAINED_NATIVE if name in changes]
        # Run both even when the first test process exits nonzero. Restoration
        # happens before parsing either stream, including when parsing fails.
        patched_code = run_tests(root, artifacts, "patched", flutter)
        with replaced_sources(root, blobs):
            baseline_code = run_tests(root, artifacts, "baseline", flutter)
        report["exit_codes"] = {"patched": patched_code, "baseline": baseline_code}
        patched = parse_run(artifacts / "patched.jsonl", artifacts / "patched.stderr.log", patched_code, root)
        baseline = parse_run(artifacts / "baseline.jsonl", artifacts / "baseline.stderr.log", baseline_code, root)
        report.update(compare(patched, baseline))
    except (ValueError, TypeError, KeyError, AttributeError, OSError, subprocess.SubprocessError, RuntimeError) as exc:
        report["error"] = str(exc)
    (artifacts / "comparison.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["passed_comparison"] else 1


if __name__ == "__main__":
    sys.exit(main())
