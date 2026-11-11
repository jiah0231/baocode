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
        self.assertEqual(after['if'], before['if'] + 1)
        for allowed in ('if', 'ACTION_TRACE', 'static_cast', 'GetTickCount64'):
            before.pop(allowed, None); after.pop(allowed, None)
        self.assertEqual(before, after)
        self.assertEqual(d.DIAGNOSTIC.count('GetTickCount64()'), 0)
        for forbidden in ('GetText(', 'SetFocus(', 'GetSelection(', 'GetFocusedElement(', 'Sleep('):
            self.assertNotIn(forbidden, d.DIAGNOSTIC)
    def test_only_terminal_rejection_logs(self):
        self.assertEqual(d.DIAGNOSTIC.count('ACTION_TRACE('), 1)
        self.assertIn('if (!retryable) ACTION_TRACE("ACTION_INITIAL_FOCUS_REJECT|', d.DIAGNOSTIC)
        self.assertLess(d.DIAGNOSTIC.index('if (retryable) require_text_control = true;'),
                        d.DIAGNOSTIC.index('if (!retryable) ACTION_TRACE('))
        # Reconstruct the original branch by removing only instrumentation,
        # proving the predicate, short-circuit behavior, and return are intact.
        stripped = d.DIAGNOSTIC[:d.DIAGNOSTIC.index('    if (!retryable) ACTION_TRACE(')] + '    return std::nullopt;\n  }\n'
        stripped = stripped.replace('    const bool type_ready = ready();\n    HRESULT type_hr = E_PENDING;\n    const bool known_type = type_ready &&\n        SUCCEEDED(type_hr = focused->get_CurrentControlType(&initial_type));',
            '    const bool known_type = ready() && SUCCEEDED(focused->get_CurrentControlType(&initial_type));')
        stripped = stripped.replace('    const bool same_foreground = GetForegroundWindow() == source;\n    const bool require_text_before = require_text_control;\n', '')
        stripped = stripped.replace('previous_element != nullptr, same_foreground,',
            'previous_element != nullptr, GetForegroundWindow() == source,')
        self.assertEqual(stripped, d.ORIGINAL)
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
