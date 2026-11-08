import copy
import unittest

from verify_translation_release_gate import verified_run


SHA = "a" * 40


class TranslationReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.run = {
            "id": 10,
            "head_sha": SHA,
            "head_branch": "feat/global-translation-floating-window",
            "path": ".github/workflows/translation-validation.yml",
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
            ("head_branch", "feat/global-translation-native-tests"),
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

    def test_new_failure_cannot_use_old_success(self):
        newer = dict(self.run, id=11, conclusion="failure")
        with self.assertRaises(ValueError):
            verified_run({"workflow_runs": [self.run, newer]}, SHA)

    def test_unrelated_run_does_not_change_exact_result(self):
        other = copy.deepcopy(self.run)
        other.update(id=20, head_sha="b" * 40, conclusion="failure")
        self.assertEqual(verified_run({"workflow_runs": [other, self.run]}, SHA), 10)


if __name__ == "__main__":
    unittest.main()
