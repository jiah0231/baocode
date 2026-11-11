#!/usr/bin/env python3
"""Structural checks only; not runtime identity, privacy, race or security tests."""
from pathlib import Path
import argparse
import re
from verify_edge_pdf_ia2_probe import compact


def check(source, harness, script):
    src=compact(source); h=compact(harness); failures=[]
    def require(value,label):
        if not value: failures.append(label)
    def has(token,label): require(compact(token) in src,label)
    require(src.count('ReadSelected(')==1,'exactly one shared selected-read call')
    has('ReadSelected(bound.text, validateCandidate, 200, &consumed)','bound text is sole selected-read source')
    has('bool consumed = false;', 'one local read allowance')
    require(src.count('boolconsumed=false;')==1, 'exactly one read allowance initialization')
    has('if (!validateCandidate()) { puts("IA2_BOUND_REJECT|pre_selection_identity"); return; }', 'full admission before selection API')
    for token,label in [
        ('Same(uia, focus.Get(), now.Get()) && SafeElement(now.Get(), focusPid, true)', 'bound exact safe UIA focus'),
        ('InSource(uia, walker.Get(), root.Get(), now.Get()) && validateFocusPath()', 'full source ancestry and safe focus path'),
        ('type != UIA_GroupControlTypeId && type != UIA_DocumentControlTypeId', 'safe bounded group/document ancestry'),
        ('type != focusTypes[index]', 'full focus path types stable'),
        ('terminalRole != ROLE_SYSTEM_PANE || !(terminalState & STATE_SYSTEM_FOCUSED) || !(terminalState & STATE_SYSTEM_READONLY)', 'fixed public readonly focused Pane only'),
        ('out->identity.Get() == coreIdentity.Get() && out->identity.Get() == accessibleIdentity.Get()', 'service core text accessible canonical identities match'),
        ('out->identity &&', 'nonnull canonical service identity'),
        ('coreIdentity &&', 'nonnull core canonical identity'),
        ('accessibleIdentity &&', 'nonnull accessible canonical identity'),
        ('const GUID propertyGuid = {0xcc7eeb32, 0x4b62, 0x4f4c, {0xaf, 0xf6, 0x1c, 0x2e, 0x57, 0x52, 0xad, 0x8e}}', 'exact official Chromium property GUID'),
        ('return same && validateFocus() && SafeAccessible(terminal, source) && SafeAccessible(out->accessible.Get(), source)', 'native and own service source safety'),
        ('serviceRole != terminalRole || serviceState != terminalState', 'own service matches safe terminal role/state'),
        ('bound.core->get_uniqueID(&boundId) != S_OK || boundId >= 0', 'captured Chromium ID is negative and valid'),
        ('boundWindowPid != boundSourcePid || GetAncestor(boundWindow, GA_ROOT) != source', 'captured exact source root and PID'),
        ('UIAutomationPropertyInfo propertyInfo = {propertyGuid, L"UniqueId", UIAutomationType_String}', 'official property name/type'),
        ('if (hr != S_OK || propertyId <= 0) return;', 'property registration succeeds'),
        ('SnapshotNativeFocus(source, validateFocus, &freshChain)', 'fresh native focus reacquired for every validation'),
        ('freshChain.objects.size() != originalChain.objects.size()', 'native focus chain length stable'),
        ('freshChain.roles != originalChain.roles || freshChain.states != originalChain.states', 'native focus chain role/state stable'),
        ('QueryChromiumService(freshChain.objects.back().Get(), source, validateFocus, &fresh)', 'unwrap fresh focused terminal, not retained wrapper'),
        ('fresh.identity.Get() == bound.identity.Get()', 'fresh canonical service equals retained identity'),
        ('if (!sameCanonicalService) return false;', 'stop on canonical identity mismatch'),
        ('freshRole != serviceRole || retainedRole != serviceRole || freshState != serviceState || retainedState != serviceState', 'both own accessible role/state remain safe and unchanged'),
        ('!SafeAccessible(fresh.accessible.Get(), source) || !SafeAccessible(bound.accessible.Get(), source)', 'fresh and retained service safety'),
        ('freshId != boundId', 'fresh unique ID equals captured'),
        ('retainedId != boundId', 'retained unique ID equals captured'),
        ('freshWindow != boundWindow', 'fresh containing window equals captured'),
        ('retainedWindow != boundWindow', 'retained containing window equals captured'),
        ('nowWindowPid != boundWindowPid || nowSourcePid != boundSourcePid', 'original window owner PIDs retained'),
        ('focus->GetCurrentPropertyValueEx(propertyId, TRUE, &value)', 'property read only from exact bound focus'),
        ('valueHr == S_OK && value.vt == VT_BSTR && value.bstrVal && SysStringLen(value.bstrVal) > 0 && SysStringLen(value.bstrVal) <= 11', 'bounded strict BSTR unique ID'),
        ('std::wstring(value.bstrVal, SysStringLen(value.bstrVal)) == std::to_wstring(boundId)', 'complete exact signed ID equality'),
        ('VariantClear(&value)', 'property result freed'),
        ('return sameExactNode && sourceStillValid;', 'exact node and safety required after metadata calls'),
    ]: has(token,label)
    for token in ('->get_text(', '->get_nSelections(', '->get_selection(', '->get_characterExtents(',
                  'Run(', 'QueryText(', 'ReadOffsets(', 'get_accName', 'get_accValue', 'get_CurrentName',
                  'get_CurrentValue', 'get_DocumentRange', 'get_nCharacters', 'FindAll(', 'FindFirst(',
                  'FindItemByProperty(', 'GetRuntimeId(', 'OpenClipboard(', 'GetClipboardData(',
                  'SendInput(', 'SetFocus(', 'SetForegroundWindow(', 'CoRegisterPSClsid(',
                  'RegSetValue', 'RegCreateKey', 'RegisterTypeLib(', 'DllRegisterServer('):
        require(token not in src,'no alternate read or forbidden API: '+token)
    exclusive='''#if defined(BAOCODE_CHROMIUM_BOUND_IA2_DIAGNOSTIC)
    edge_pdf_ia2::RunChromiumBoundSelection(uia.Get(), browser, [] { Scoped(); });
#else
    edge_pdf_ia2::Run(uia.Get(), browser, [] { Scoped(); });
#endif'''
    require(compact(exclusive) in h, 'old/new experiments are mutually exclusive')
    require(h.count('RunChromiumBoundSelection(')==1,'new mode invoked once')
    require('if ($ChromiumBoundIA2 -and !$IA2)' in script, 'new mode explicitly requires IA2')
    require("if ($ChromiumBoundIA2) { $extraCompile += '/DBAOCODE_CHROMIUM_BOUND_IA2_DIAGNOSTIC' }" in script,'new mode opt-in compiler flag')
    return failures


def self_test(s,h,p):
    mutations=[
        ('wrong_guid','0xcc7eeb32','0xcc7eeb33'),
        ('null_core','&& coreIdentity &&','&& true &&'),
        ('null_accessible','&& accessibleIdentity &&','&& true &&'),
        ('allowance_reset','bool consumed = false;','bool consumed = false; bool consumed = false;'),
        ('fresh_native', 'SnapshotNativeFocus(source, validateFocus, &freshChain)', 'true'),
        ('fresh_service', 'freshChain.objects.back().Get()', 'originalChain.objects.back().Get()'),
        ('canonical', 'fresh.identity.Get() == bound.identity.Get()', 'true'),
        ('canonical_gate', 'if (!sameCanonicalService) return false;', ''),
        ('own_state', 'freshState != serviceState', 'false'),
        ('retained_state', 'retainedState != serviceState', 'false'),
        ('fresh_id', 'freshId != boundId', 'false'),
        ('retained_id', 'retainedId != boundId', 'false'),
        ('fresh_window', 'freshWindow != boundWindow', 'false'),
        ('retained_window', 'retainedWindow != boundWindow', 'false'),
        ('source_pid', 'nowSourcePid != boundSourcePid', 'false'),
        ('wrong_focus', 'focus->GetCurrentPropertyValueEx', 'root->GetCurrentPropertyValueEx'),
        ('wide_bstr', 'SysStringLen(value.bstrVal) <= 11', 'true'),
        ('wrong_variant', 'value.vt == VT_BSTR', 'true'),
        ('no_admission', 'if (!validateCandidate())', 'if (false)'),
        ('second_read', 'ReadSelected(bound.text, validateCandidate, 200, &consumed);', 'ReadSelected(bound.text, validateCandidate, 200, &consumed); ReadSelected();'),
        ('raw_text', 'printf("IA2_BOUND_DONE', 'bound.text->get_text(0,-1,nullptr); printf("IA2_BOUND_DONE'),
        ('role_loosen', 'terminalRole != ROLE_SYSTEM_PANE', 'false'),
        ('editable', '!(terminalState & STATE_SYSTEM_READONLY)', 'false'),
        ('fresh_source_safety', '!SafeAccessible(fresh.accessible.Get(), source)', 'false'),
        ('id_only_admission', 'return sameExactNode && sourceStillValid;', 'return sourceStillValid;'),
    ]
    for name,old,new in mutations:
        if old not in s: raise AssertionError('Missing mutation anchor: '+name)
        if not check(s.replace(old,new,1),h,p): raise AssertionError('Mutation survived: '+name)
    if not check(s,h.replace('#else\n    edge_pdf_ia2::Run', '#endif\n    edge_pdf_ia2::Run'),p): raise AssertionError('Both modes admitted')
    return len(mutations)+1


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--self-test',action='store_true');args=parser.parse_args()
    root=Path(__file__).parent
    s=(root/'edge_pdf_chromium_selection_probe.h').read_text();h=(root/'edge_pdf_probe.cpp').read_text();p=(root/'run_edge_pdf_probe.ps1').read_text()
    failures=check(s,h,p)
    if failures: raise AssertionError('; '.join(failures))
    if args.self_test: print('CHROMIUM_BOUND_STRUCTURAL_SELF_TEST|negative_mutations_rejected='+str(self_test(s,h,p)))
    print('CHROMIUM_BOUND_STRUCTURAL_PASS|not_runtime_safety_testing')

if __name__=='__main__': main()
