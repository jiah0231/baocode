import copy
import unittest

from verify_multiwindow_release_gate import verified_run


SHA = "a" * 40


class MultiwindowReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.run = {
            "id": 10,
            "head_sha": SHA,
            "head_branch": "feat/global-translation-floating-window",
            "path": ".github/workflows/multiwindow-validation.yml",
            "status": "completed",
            "conclusion": "success",
        }

    def test_exact_full_success(self):
        self.assertEqual(verified_run({"workflow_runs": [self.run]}, SHA), 10)

    def test_missing_or_invalid(self):
        for payload in ({}, {"workflow_runs": []}, {"workflow_runs": None}):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                verified_run(payload, SHA)
        with self.assertRaises(ValueError):
            verified_run({"workflow_runs": [self.run]}, "main")

    def test_wrong_source_or_partial_workflow(self):
        for key, value in (
            ("head_sha", "b" * 40),
            ("head_branch", "feat/windows-new-window"),
            ("path", ".github/workflows/custom-update-release.yml"),
        ):
            wrong = dict(self.run, **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                verified_run({"workflow_runs": [wrong]}, SHA)

    def test_non_success_is_not_publishable(self):
        for status, conclusion in (
            ("in_progress", None), ("queued", None), ("completed", "failure"),
            ("completed", "cancelled"), ("completed", "skipped"),
        ):
            run = dict(self.run, status=status, conclusion=conclusion)
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ValueError):
                verified_run({"workflow_runs": [run]}, SHA)

    def test_stale_success_cannot_hide_newer_non_success(self):
        for status, conclusion in (
            ("queued", None), ("in_progress", None),
            ("completed", "failure"), ("completed", "cancelled"),
            ("completed", "skipped"), ("completed", "timed_out"),
        ):
            newer = dict(self.run, id=11, status=status, conclusion=conclusion)
            for runs in ([self.run, newer], [newer, self.run]):
                with self.subTest(status=status, conclusion=conclusion, runs=runs):
                    with self.assertRaises(ValueError):
                        verified_run({"workflow_runs": runs}, SHA)

    def test_new_success_supersedes_old_failure(self):
        older = dict(self.run, id=9, conclusion="failure")
        for runs in ([older, self.run], [self.run, older]):
            self.assertEqual(verified_run({"workflow_runs": runs}, SHA), 10)

    def test_translation_success_cannot_substitute_for_multiwindow(self):
        other = dict(self.run, path=".github/workflows/translation-validation.yml")
        with self.assertRaises(ValueError):
            verified_run({"workflow_runs": [other]}, SHA)

    def test_unrelated_run_does_not_change_exact_result(self):
        other = copy.deepcopy(self.run)
        other.update(id=20, head_sha="b" * 40, conclusion="failure")
        self.assertEqual(verified_run({"workflow_runs": [other, self.run]}, SHA), 10)


if __name__ == "__main__":
    unittest.main()
