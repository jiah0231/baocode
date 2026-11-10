#!/usr/bin/env python3
"""Test-only structural guard. Not runtime security, COM, or race validation."""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


def compact(source: str) -> str:
    # Strip comments so a comment cannot satisfy a source invariant.
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    return re.sub(r'\s+', '', source)


def check(header: str, script: str | None = None) -> list[str]:
    src = compact(header)
    failures: list[str] = []

    def require(condition: bool, label: str) -> None:
        if not condition:
            failures.append(label)

    def has(token: str, label: str) -> None:
        require(compact(token) in src, label)

    calls = re.findall(r'->get_text\s*\(', header)
    require(len(calls) == 1, 'exactly one IA2 selected-text read site')
    has('text->get_text(start, end, &selected)', 'text read uses explicit captured selection endpoints')
    require(len(re.findall(r'->get_nSelections\s*\(', header)) == 1,
            'exactly one nSelections call site in shared offset validator')
    for token, label in [
        ('hr != S_OK || count != 1', 'selection count must succeed and equal one'),
        ('hr == S_OK && *start >= 0 && *end > *start && *end <= 10000000 && *end - *start <= 4096',
         'successful noncollapsed nonnegative bounded selection offsets'),
        ('text->get_selection(0, start, end)', 'selection zero only'),
        ('FAILED(hr) || childId != CHILDID_SELF', 'initial Legacy child must be self'),
        ('currentChild == CHILDID_SELF', 'revalidated Legacy child must be self'),
        ('SUCCEEDED(element->get_CurrentIsPassword(&password)) && !password',
         'UIA password read must succeed and reject passwords'),
        ('SUCCEEDED(element->get_CurrentIsOffscreen(&offscreen)) && !offscreen',
         'UIA offscreen read must succeed and reject offscreen'),
        ('SUCCEEDED(element->get_CurrentProcessId(&pid)) && pid > 0 && pid == expectedPid',
         'UIA process identity is bound'),
        ('SUCCEEDED(element->get_CurrentHasKeyboardFocus(&focused)) && focused',
         'actual focus metadata must succeed'),
        ('SUCCEEDED(hr) && state.vt == VT_I4 && !(state.lVal & (STATE_SYSTEM_PROTECTED | STATE_SYSTEM_INVISIBLE | STATE_SYSTEM_OFFSCREEN | STATE_SYSTEM_UNAVAILABLE))',
         'MSAA state succeeds, has known type, and rejects unsafe states'),
        ('GetAncestor(native, GA_ROOT) != source', 'MSAA native root is exact source'),
        ('nativePid != sourcePid', 'native window process binding'),
        ('Same(uia, focus.Get(), now.Get()) && SafeElement(now.Get(), focusPid, true)',
         'current focus identity and safe state revalidated'),
        ('!validateFocus() || !SafeElement(candidate.Get(), candidatePid, depth == 0)',
         'candidate validation includes focus and safe candidate identity'),
        ('!InSource(uia, walker.Get(), root.Get(), candidate.Get())',
         'candidate remains inside exact source ancestry'),
        ('!SafeAccessible(accessible.Get(), source)', 'candidate MSAA safety revalidated'),
        ('SameAccessible(accessible.Get(), currentAccessible.Get())',
         'Legacy accessible COM identity revalidated'),
        ('ReadOffsets(text.Get(), &start, &end, "before")', 'initial explicit selection read'),
        ('!validateCandidate() || !ReadOffsets(text.Get(), &beforeStart, &beforeEnd, "immediately_before_text") || beforeStart != start || beforeEnd != end',
         'selection and identity revalidated immediately before text'),
        ('readHr == S_OK && selected && SysStringLen(selected) <= 4096 && validateCandidate() && ReadOffsets(text.Get(), &afterStart, &afterEnd, "after") && afterStart == start && afterEnd == end && validateCandidate()',
         'successful bounded result, focus, and same selection revalidated after text'),
        ('if (valid) { printf("IA2_SELECTED_UTF16|")',
         'text logging is gated by full post-read validation'),
        ('candidate && depth <= 4', 'bounded focus-parent candidate walk'),
        ('node && depth < 24', 'bounded source ancestry verification'),
        ('k == 0 ? start : end - 1', 'extents restricted to selection boundary characters'),
    ]:
        has(token, label)

    for token, label in [
        ('if (*consumed) return true', 'one shared read across bridge paths'),
        ('*consumed = true; const HRESULT readHr = text->get_text(start, end, &selected)', 'read allowance consumed before call'),
        ('AccessibleObjectFromWindow(source, static_cast<DWORD>(OBJID_CLIENT), IID_IAccessible', 'native bridge restricted to exact source client'),
        ('depth < 8', 'bounded native focus-only walk'),
        ('next.vt == VT_I4 && next.lVal == CHILDID_SELF', 'native terminal must be self'),
        ('next.vt != VT_DISPATCH || !next.pdispVal', 'native nonself child IDs rejected'),
        ('return (state & STATE_SYSTEM_FOCUSED) && (role == ROLE_SYSTEM_DOCUMENT || (role == ROLE_SYSTEM_TEXT && (state & STATE_SYSTEM_READONLY)))', 'native Document/Text role helper requires focused/read-only state'),
        ('if (!(state & STATE_SYSTEM_FOCUSED))', 'native final chain object must be focused'),
        ('role == ROLE_SYSTEM_TEXT && (state & STATE_SYSTEM_READONLY)', 'native text role must be readonly'),
        ('before.roles != after.roles', 'native chain roles stable'),
        ('before.states != after.states', 'native chain state values stable'),
        ('SameAccessible(before.objects[index].Get(), after.objects[index].Get())', 'all native focus chain COM identities stable'),
        ('SameNativeFocusChain(originalChain, currentChain)', 'native chain revalidated before and after selected read'),
        ('accessibleIdentity.Get() == textIdentity.Get()', 'queried IA2 interface has same COM identity'),
        ('type != UIA_GroupControlTypeId && type != UIA_DocumentControlTypeId', 'group focus path excludes unsafe controls'),
        ('SafeElement(parent.Get(), focusPid, false)', 'group document path uses fixed source PID and safety'),
        ('type != focusTypes[index]', 'group document path control types stable'),
        ('validateFocusPath()', 'full focused UIA path remains stable'),
        ('role != ROLE_SYSTEM_PANE || !(state & STATE_SYSTEM_FOCUSED) || !(state & STATE_SYSTEM_READONLY)', 'Pane exception requires focused readonly state'),
        ('uia->ElementFromIAccessible(accessible.Get(), CHILDID_SELF, &mapped)', 'Pane mapped from exact terminal self'),
        ('uia->CompareElements(mapped.Get(), focus.Get(), &equalsBoundFocus)', 'Pane requires exact bound focused UIA element'),
        ('mappingHr == S_OK && mapped && compareHr == S_OK && equalsBoundFocus && SafeElement(mapped.Get(), focusPid, true) && validateFocus()', 'Pane mapping succeeds and focus/password/PID revalidated'),
        ('SafeAccessible(accessible.Get(), source) && validateMappedNativeRole()', 'every native candidate validation remaps Pane'),
        ('if (!validateNativeCandidate()) { puts("IA2_NATIVE_METADATA_ONLY|selection_reads=0|role_mapping_or_identity_rejected"); return; }', 'rejected mapping cannot enter selection getter'),
        ('SameNativeFocusChain(originalChain, beforeQuery)', 'interface metadata requires stable native chain'),
    ]:
        has(token, label)

    branch_start = src.find('if(!SnapshotNativeFocus(source,validateFocus,&beforeQuery)||!SameNativeFocusChain(originalChain,beforeQuery)){')
    branch_end = src.find('ComPtr<IAccessibleText>nativeText=QueryText(accessible,100);', branch_start)
    failure_branch = src[branch_start:branch_end] if branch_start >= 0 and branch_end > branch_start else ''
    require(bool(failure_branch), 'locate unstable-chain metadata-only branch')
    require('if(validateFocus()&&SafeAccessible(accessible.Get(),source)){' in failure_branch,
            'unstable-chain metadata revalidates focus and original terminal')
    require('LogNativeChainEquality(originalChain,beforeQuery);' in failure_branch,
            'unstable-chain per-node equality is logged')
    require('QueryText(accessible,101);' in failure_branch,
            'unstable-chain query remains metadata-only')
    require('uia->CompareElements(metadataMapped.Get(),focus.Get(),&metadataEqualsBoundFocus)' in failure_branch,
            'unstable-chain mapping compares exact original focus')
    require(failure_branch.endswith('puts("IA2_NATIVE_UNSTABLE_CHAIN_METADATA_ONLY|selection_reads=0|unconditional_return");return;}'),
            'unstable-chain branch returns unconditionally before any read admission')
    for forbidden_read in ('ReadSelected(', 'ReadOffsets(', 'get_nSelections(', 'get_selection(',
                           'get_text(', 'get_characterExtents(', 'validateMappedNativeRole(', 'validateNativeCandidate('):
        require(forbidden_read not in failure_branch,
                'unstable-chain metadata branch forbids: ' + forbidden_read)

    read = src.find('text->get_text(start,end,&selected)')
    pre = src.find('beforeStart!=start||beforeEnd!=end')
    post = src.find('afterStart==start&&afterEnd==end')
    output = src.find('if(valid){printf("IA2_SELECTED_UTF16|")')
    require(-1 not in (read, pre, post, output) and pre < read < post < output,
            'read is between pre-validation and post-validation-gated output')

    forbidden = (
        'get_accName', 'get_accValue', 'get_CurrentName', 'get_CurrentValue',
        'get_DocumentRange', 'get_nCharacters', 'get_textAtOffset',
        'get_textBeforeOffset', 'get_textAfterOffset', 'get_newText', 'get_oldText',
        'FindAll(', 'FindFirst(', 'TreeScope_Descendants', 'TreeScope_Subtree',
        'get_accChild(', 'get_accChildCount(', 'AccessibleChildren(',
        'setSelection(', 'addSelection(', 'removeSelection(', 'setCaretOffset(',
        'scrollSubstringTo', 'SetFocus(', 'SetForegroundWindow(',
        'OpenClipboard(', 'GetClipboardData(', 'SendInput(',
        'CoRegisterClassObject(', 'CoRegisterPSClsid(', 'RegisterTypeLib(',
        'RegSetValue', 'RegCreateKey', 'DllRegisterServer(',
    )
    for token in forbidden:
        require(token not in src, 'forbidden API: ' + token)
    if script is not None:
        executable = re.sub(r'(?m)^\s*#.*$', '', script).lower()
        for token in ('regsvr32', 'registertypelib', 'dllregisterserver',
                      'new-itemproperty', 'set-itemproperty', 'reg.exe add',
                      'coregisterpsclsid', 'coregisterclassobject'):
            require(token not in executable, 'persistent/proxy registration: ' + token)
    return failures


def self_test(header: str, script: str | None) -> int:
    baseline = check(header, script)
    if baseline:
        raise AssertionError('Baseline failed: ' + '; '.join(baseline))
    mutations = {
        'unstable_chain_fallthrough': ('puts("IA2_NATIVE_UNSTABLE_CHAIN_METADATA_ONLY|selection_reads=0|unconditional_return");\n    return;', 'puts("IA2_NATIVE_UNSTABLE_CHAIN_METADATA_ONLY|selection_reads=0|unconditional_return");'),
        'unstable_chain_selection_read': ('QueryText(accessible, 101);', 'QueryText(accessible, 101); ReadOffsets();'),
        'unstable_chain_character_read': ('QueryText(accessible, 101);', 'QueryText(accessible, 101); get_characterExtents();'),
        'unstable_chain_reuse_admission': ('QueryText(accessible, 101);', 'QueryText(accessible, 101); validateMappedNativeRole();'),
        'unstable_chain_skip_scope': ('if (validateFocus() && SafeAccessible(accessible.Get(), source)) {', 'if (true) {'),
        'pane_unfocused': ('role != ROLE_SYSTEM_PANE || !(state & STATE_SYSTEM_FOCUSED) ||', 'role != ROLE_SYSTEM_PANE || false ||'),
        'pane_not_readonly': ('!(state & STATE_SYSTEM_READONLY)', 'false'),
        'pane_wrong_mapping_target': ('uia->CompareElements(mapped.Get(), focus.Get(), &equalsBoundFocus)', 'uia->CompareElements(mapped.Get(), root.Get(), &equalsBoundFocus)'),
        'pane_ignore_mapping_failure': ('mappingHr == S_OK && mapped && compareHr == S_OK && equalsBoundFocus', 'true'),
        'pane_ignore_mapped_password': ('SafeElement(mapped.Get(), focusPid, true) && validateFocus()', 'validateFocus()'),
        'pane_skip_remapping': ('SafeAccessible(accessible.Get(), source) && validateMappedNativeRole()', 'SafeAccessible(accessible.Get(), source)'),
        'pane_ignore_read_gate': ('if (!validateNativeCandidate()) {', 'if (false) {'),
        'reuse_read_allowance': ('if (*consumed) return true', 'if (false) return true'),
        'native_nonself_terminal': ('next.lVal == CHILDID_SELF', 'next.lVal >= 0'),
        'native_unfocused_terminal': ('state & STATE_SYSTEM_FOCUSED', 'true'),
        'native_editable_text': ('state & STATE_SYSTEM_READONLY', 'true'),
        'native_chain_state': ('before.states != after.states', 'false'),
        'native_chain_identity': ('SameNativeFocusChain(originalChain, currentChain)', 'true'),
        'service_other_object': ('accessibleIdentity.Get() == textIdentity.Get()', 'true'),
        'group_path_changed_type': ('type != focusTypes[index]', 'false'),
        'full_document_sentinel': ('text->get_text(start, end, &selected)', 'text->get_text(0, -1, &selected)'),
        'duplicate_text_read': ('const HRESULT readHr = text->get_text(start, end, &selected);',
                                'text->get_text(start, end, &selected); const HRESULT readHr = text->get_text(start, end, &selected);'),
        'multiple_selections': ('count != 1', 'count < 1'),
        'collapsed_selection': ('*end > *start', '*end >= *start'),
        'negative_offsets': ('*start >= 0', '*start >= -2'),
        'unbounded_span': ('*end - *start <= 4096', '*end - *start <= 10000000'),
        'nonself_child': ('childId != CHILDID_SELF', 'childId < 0'),
        'nonself_revalidation': ('currentChild == CHILDID_SELF', 'currentChild >= 0'),
        'ignore_password': ('&& !password', '&& true'),
        'ignore_offscreen': ('&& !offscreen', '&& true'),
        'ignore_protected': ('STATE_SYSTEM_PROTECTED |', ''),
        'unknown_state_type': ('SUCCEEDED(hr) && state.vt == VT_I4', 'SUCCEEDED(hr) && true'),
        'lose_pid_binding': ('pid == expectedPid', 'pid > 0'),
        'lose_native_root': ('GetAncestor(native, GA_ROOT) != source', 'false'),
        'lose_focus_identity': ('Same(uia, focus.Get(), now.Get())', 'true'),
        'lose_com_identity': ('SameAccessible(accessible.Get(), currentAccessible.Get())', 'true'),
        'lose_pre_offsets': ('beforeStart != start || beforeEnd != end', 'false'),
        'lose_post_offsets': ('afterStart == start && afterEnd == end', 'true'),
        'unconditional_log': ('if (valid) {', 'if (true) {'),
        'unbounded_parents': ('candidate && depth <= 4', 'candidate'),
        'forbidden_name_read': ('puts("IA2_DIAGNOSTIC_BEGIN', 'accessible->get_accName(); puts("IA2_DIAGNOSTIC_BEGIN'),
        'forbidden_proxy_registration': ('puts("IA2_DIAGNOSTIC_BEGIN', 'CoRegisterPSClsid(); puts("IA2_DIAGNOSTIC_BEGIN'),
    }
    for name, (old, new) in mutations.items():
        if old not in header:
            raise AssertionError('Mutation anchor missing: ' + name)
        if not check(header.replace(old, new, 1), script):
            raise AssertionError('Unsafe mutation survived: ' + name)
    if script is not None and not check(header, script + '\nregsvr32.exe /s proxy.dll\n'):
        raise AssertionError('Persistent registration mutation survived')
    return len(mutations) + (script is not None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('header', nargs='?', type=pathlib.Path,
                        default=pathlib.Path(__file__).with_name('edge_pdf_ia2_probe.h'))
    parser.add_argument('--script', type=pathlib.Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    header = args.header.read_text(encoding='utf-8')
    script = args.script.read_text(encoding='utf-8') if args.script else None
    failures = check(header, script)
    if failures:
        for failure in failures:
            print('IA2_STRUCTURAL_FAIL|' + failure, file=sys.stderr)
        return 1
    if args.self_test:
        count = self_test(header, script)
        print(f'IA2_STRUCTURAL_SELF_TEST|negative_mutations_rejected={count}')
    print('IA2_STRUCTURAL_PASS|source_shape_only|not_runtime_negative_testing')
    return 0


if __name__ == '__main__':
    sys.exit(main())
