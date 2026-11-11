import re
import os
import unittest
import subprocess
from pathlib import Path
import inject_focus_diagnostics as d

class InjectionTests(unittest.TestCase):
    def test_round_trip(self):
        source = 'prefix\n' + d.ORIGINAL + 'suffix\n'
        self.assertEqual(d.without_diagnostics(d.inject(source)), source)
    def test_reject_missing_duplicate_mutated(self):
        for source in ('', d.ORIGINAL * 2, d.ORIGINAL.replace('!has_focus', 'has_focus')):
            with self.assertRaises(ValueError): d.inject(source)
    def test_reject_double_injection(self):
        with self.assertRaises(ValueError): d.inject(d.inject(d.ORIGINAL))
    def test_call_counts_unchanged(self):
        # Count every original call, not just UIA: ready/stopped/foreground
        # calls must not be added or removed by diagnostics.
        calls = lambda s: re.findall(r'\b([A-Za-z_]\w*)\s*\(', s)
        from collections import Counter
        before, after = Counter(calls(d.ORIGINAL)), Counter(calls(d.DIAGNOSTIC))
        self.assertEqual(before['ready'], 1)
        self.assertEqual(before['get_CurrentControlType'], 1)
        self.assertEqual(before['GetForegroundWindow'], 1)
        self.assertEqual(before['GetClassNameW'], 1)
        self.assertEqual(before['IsInitialChromiumPane'], 1)
        for allowed in ('ACTION_TRACE', 'static_cast', 'GetTickCount64'):
            before.pop(allowed, None); after.pop(allowed, None)
        self.assertEqual(before, after)
        self.assertEqual(d.DIAGNOSTIC.count('GetTickCount64()'), 1)
        for forbidden in ('GetText(', 'SetFocus(', 'GetSelection(', 'GetFocusedElement(', 'Sleep('):
            self.assertNotIn(forbidden, d.DIAGNOSTIC)
    def test_no_predicate_changes(self):
        self.assertIn('previous_element != nullptr, same_foreground,', d.DIAGNOSTIC)
        self.assertIn('known_type && initial_type == UIA_PaneControlTypeId, chromium)', d.DIAGNOSTIC)
        self.assertIn('if (retryable) require_text_control = true;', d.DIAGNOSTIC)
    def test_three_real_sources(self):
        local = Path(__file__).parent.parent / 'baocode-perf-integration-20261111'
        workspace = Path(os.environ.get('GITHUB_WORKSPACE', '.'))
        for key, sha in zip('abc', d.SHAS):
            repo = local if (local / '.git').exists() else workspace / ('baseline-' + key)
            if not (repo / '.git').exists():
                self.fail('Required baseline checkout unavailable: ' + str(repo))
            source = subprocess.check_output(['git', '-C', str(repo), 'show', sha + ':' + d.SOURCE], text=True)
            self.assertEqual(d.without_diagnostics(d.inject(source)), source)

if __name__ == '__main__': unittest.main()
