from pathlib import Path
import sys
import unittest

from make_compile_variant import COMPILE, MODES, native_project, variant

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).parent.parent / "baocode-perf-integration-20261111"
sys.argv[1:] = []

class CompileVariantTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "tool/ci/windows_translation_desktop_entry_smoke.ps1").read_text(encoding="utf-8")
        cls.cmake = (ROOT / "windows/CMakeLists.txt").read_text(encoding="utf-8")
        cls.harness = (ROOT / "tool/ci/windows_translation_desktop_entry_smoke.cpp").read_text(encoding="utf-8")

    def test_four_fixed_modes_only(self):
        self.assertEqual(len(MODES), 4)
        with self.assertRaises(ValueError): variant(self.source, "retry", self.cmake)

    def test_exact_reconstruction_for_every_mode(self):
        for mode in MODES:
            with self.subTest(mode=mode):
                output, replacement = variant(self.source, mode, self.cmake)
                self.assertEqual(output.replace(replacement, COMPILE, 1), self.source)

    def test_legacy_control_is_original_bytes(self):
        self.assertEqual(variant(self.source, MODES[0], self.cmake)[0], self.source)

    def test_quiet_changes_only_diagnostic_define(self):
        self.assertEqual(variant(self.source, "legacy-quiet", self.cmake)[0],
                         self.source.replace(" /DBAOCODE_TRANSLATION_ACTION_DIAGNOSTICS", ""))

    def test_actual_runner_settings_are_preserved(self):
        for diag in (True, False):
            output = native_project(self.cmake, diag)
            for value in ('"_HAS_EXCEPTIONS=0"', '"_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR"', '/EHsc', '/utf-8', 'cxx_std_17'):
                self.assertIn(value, output)
            self.assertEqual('PRIVATE "BAOCODE_TRANSLATION_ACTION_DIAGNOSTICS"' in output, diag)

    def test_no_assert_checks_disabled_by_release(self):
        import re
        self.assertIsNone(re.search(r'\bassert\s*\(', self.harness))
        self.assertIn('void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }', self.harness)

    def test_reject_altered_or_duplicate_invocation(self):
        for source in (self.source.replace(COMPILE, ""), self.source + COMPILE):
            with self.assertRaises(ValueError): variant(source, MODES[0], self.cmake)

    def test_reject_missing_actual_runner_settings(self):
        for cmake in ("", self.cmake.replace('"_HAS_EXCEPTIONS=0"', '"OTHER"')):
            with self.assertRaises(ValueError): native_project(cmake, False)

if __name__ == "__main__": unittest.main()
