"""Narrow structural guard for passive selection discovery versus explicit read.

This complements runtime privacy tests; it is not a C++ semantic/security proof.
All selected-text reads must stay in the one reviewed click helper, called only
from the worker's explicit ClickJob branch. Discovery remains metadata-only.
"""
from pathlib import Path
import argparse
import re


def code_only(source: str) -> str:
    # Preserve offsets/braces outside comments and ordinary C++ literals.
    # Raw strings are not used by the reviewed implementation; fail closed if
    # introduced rather than attempting to parse arbitrary delimiter syntax.
    if re.search(r'\bR"', source):
        raise ValueError('Raw strings require an explicit guard/parser review')
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    return re.sub(pattern, lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), source)


def block_end(code: str, opening: int) -> int:
    if code[opening] != '{':
        raise ValueError('Expected an explicit braced scope')
    depth = 0
    for position in range(opening, len(code)):
        depth += (code[position] == '{') - (code[position] == '}')
        if depth == 0:
            return position + 1
    raise ValueError('Unbalanced scope')


def verify(source: str) -> None:
    code = code_only(source)
    forbidden = r'\b(?:GetDocumentRange|get_DocumentRange|GetCurrentPropertyValue|GetCurrentPropertyValueEx|GetClipboardData|SetClipboardData|EmptyClipboard|OpenClipboard|UIA_ValuePatternId|WH_KEYBOARD_LL|GetAsyncKeyState|GetKeyboardState|SendInput)\b'
    if re.search(forbidden, code):
        raise ValueError('Entry contains a prohibited document/value/clipboard/keyboard operation')
    definition = re.search(r'\btranslation_selection::Selection\s+CaptureBoundSelection\s*\(', code)
    if not definition:
        raise ValueError('Missing reviewed bound-click reader')
    opening = code.find('{', definition.end())
    end = block_end(code, opening)
    body = code[opening:end]
    reads = list(re.finditer(r'\bGetText\b', code))
    if len(reads) != 1 or not opening < reads[0].start() < end:
        raise ValueError('Only the bound explicit-click helper may contain one GetText')
    if not re.search(r'\bcurrent_range\s*->\s*GetText\s*\(\s*8001\s*,\s*&text\s*\)', body):
        raise ValueError('Click read must use the validated current range and 8001-unit overflow bound')
    # Exactly two metadata validations, one before and one after the read.
    validations = list(re.finditer(r'\bSelectionBounds\s*\(', code[opening:end]))
    read_offset = reads[0].start() - opening
    if len(validations) != 2 or not validations[0].start() < read_offset < validations[1].start():
        raise ValueError('Bound read must retain pre/post selection metadata validation')
    for validation in validations:
        call_end = body.find(')', validation.end())
        if not re.search(r'\bgesture\b', body[validation.end():call_end]):
            raise ValueError('Each bound-click metadata check must retain the original gesture')
    bounds_definition = re.search(r'\bstd::optional<RECT>\s+SelectionBounds\s*\(', code)
    bounds_open = code.find('{', bounds_definition.end())
    bounds_end = block_end(code, bounds_open)
    bounds_body = code[bounds_open:bounds_end]
    if not re.search(r'\bgesture_match\.Add\s*\(\s*\{clipped\.left,\s*clipped\.top,\s*clipped\.right,\s*clipped\.bottom\}', bounds_body):
        raise ValueError('Gesture check must inspect individual clipped selected lines')
    mismatch = re.search(r'if\s*\(result\s*&&\s*!gesture_match\.Matches\(\)\)\s*\{', bounds_body)
    if not mismatch:
        raise ValueError('Missing gesture/range mismatch rejection')
    mismatch_open = bounds_body.find('{', mismatch.start())
    mismatch_body = bounds_body[mismatch_open:block_end(bounds_body, mismatch_open)]
    if not re.search(r'return\s+std::nullopt\s*;', mismatch_body):
        raise ValueError('Geometry mismatch must fail before returning a readable range')
    branches = list(re.finditer(r'\bif\s*\(\s*worker\s*->\s*click\s*\)\s*\{', code))
    if len(branches) != 1:
        raise ValueError('Expected exactly one explicit ClickJob dispatch scope')
    click_open = code.find('{', branches[0].start())
    click_end = block_end(code, click_open)
    calls = list(re.finditer(r'\bCaptureBoundSelection\s*\(', code))
    if len(calls) != 2 or calls[0].start() < definition.start() or not click_open < calls[1].start() < click_end:
        raise ValueError('Bound reader may be invoked only once inside the explicit ClickJob branch')
    branch = code[click_open:click_end]
    for required in (r'previous_generation\s*==\s*job\.generation', r'job\.canceled\s*\(',
                     r'worker->active_generation\s*!=\s*job\.generation', r'job\.finish\s*\('):
        if not re.search(required, branch):
            raise ValueError('ClickJob lost a required generation/cancellation/completion guard')


def self_test(source: str) -> None:
    verify(source)
    verify('// GetText and OpenClipboard in documentation are not operations.\n' + source)
    mutations = {
        'discovery read': source.replace('  retryable = false;', '  range->GetText(10, &text);\n  retryable = false;', 1),
        'discovery bound-helper call': source.replace('  retryable = false;', '  CaptureBoundSelection(source);\n  retryable = false;', 1),
        'extra click read': source.replace('  BSTR text = nullptr;', '  current_range->GetText(10, &text);\n  BSTR text = nullptr;', 1),
        'unbounded read': source.replace('current_range->GetText(8001, &text)', 'current_range->GetText(-1, &text)', 1),
        'wrong range owner': source.replace('current_range->GetText(8001, &text)', 'expected_range->GetText(8001, &text)', 1),
        'non-click dispatch': source.replace('if (worker->click)', 'if (worker->pending)', 1),
        'missing generation gate': source.replace('previous_generation == job.generation', 'true', 1),
        'missing cancel gate': source.replace('job.canceled()', 'false', 1),
        'removed geometry rejection': source.replace('result && !gesture_match.Matches()', 'false', 1),
        'removed geometry accumulation': source.replace('gesture_match.Add(', 'OtherCheck(', 1),
        'replaced pre-read gesture': source.replace('deadline, gesture, &bounded', 'deadline, other_gesture, &bounded', 1),
        'replaced post-read gesture': source.replace('deadline, gesture) || stopped()', 'deadline, other_gesture) || stopped()', 1),
        'removed post validation': source.replace('!SelectionBounds(source, element, range, retryable, require_text,', '!OtherCheck(source, element, range, retryable, require_text,', 1),
    }
    for operation in ('GetDocumentRange()', 'get_DocumentRange()', 'GetCurrentPropertyValue()',
                      'OpenClipboard()', 'SetClipboardData()', 'UIA_ValuePatternId',
                      'WH_KEYBOARD_LL', 'GetAsyncKeyState()', 'SendInput()'):
        mutations[operation] = source + '\nvoid unexpected() { ' + operation + '; }\n'
    for label, mutation in mutations.items():
        if mutation == source:
            raise AssertionError(f'Mutation no longer targets reviewed code: {label}')
        try:
            verify(mutation)
        except ValueError:
            continue
        raise AssertionError(f'Privacy guard accepted mutation: {label}')
    print(f'Translation action privacy guard: {len(mutations)} prohibited mutations rejected')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('implementation', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    source = args.implementation.read_text(encoding='utf-8')
    if args.self_test:
        self_test(source)
    else:
        verify(source)
    print('Passive discovery is metadata-only; selected text is confined to explicit bound-click dispatch')
