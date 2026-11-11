#!/usr/bin/env python3
"""One-level public-fixture structural guard; not runtime security verification."""
from pathlib import Path
import argparse
from verify_edge_pdf_ia2_probe import compact


def check(source,parent,script):
    s=compact(source);p=compact(parent);failures=[]
    def require(v,n):
        if not v:failures.append(n)
    for token,label in [
        ('if (*consumed || *totalReads >= 2 || !validateCandidate()) return false;', 'per-stage and global read budget with full identity'),
        ('end - start > maximumCharacters', 'stage range length bound'),
        ('checkStart != start || checkEnd != end', 'pre-read current selection stable'),
        ('*consumed = true; ++*totalReads; BSTR value = nullptr; const HRESULT hr = text->get_text(start, end, &value);', 'consume both budgets before selected text call'),
        ('hr == S_OK && value && SysStringLen(value) <= static_cast<UINT>(maximumCharacters) && validateCandidate()', 'bounded result and post-read identity'),
        ('afterStart == start && afterEnd == end && validateCandidate()', 'post-read selection stable and final identity'),
        ('if (accepted) { result->assign(value, SysStringLen(value));', 'return result only after full acceptance'),
        ('SysFreeString(value)', 'release selected BSTR'),
        ('bool parentConsumed = false, childConsumed = false; int totalReads = 0;', 'two explicit stage budgets and global counter'),
        ('ReadEmbeddedStage(bound.text, validateRootCandidate, 1, &parentConsumed, &totalReads, &parentStart, &parentEnd, &parentText)', 'parent only one currently selected character'),
        ('parentEnd - parentStart != 1 || parentText != L"\\xFFFC"', 'freshly confirm selected placeholder'),
        ('hypertextIdentity.Get() != bound.identity.Get()', 'parent hypertext canonical identity bound'),
        ('nowStart != parentStart || nowEnd != parentEnd', 'parent offsets remain selected during every relation check'),
        ('hypertext->get_hyperlinkIndex(parentStart, index)', 'resolve only currently selected offset'),
        ('hr != S_OK || *index < 0', 'selected hyperlink index succeeds'),
        ('hypertext->get_hyperlink(*index, &link)', 'one exact selected hyperlink index'),
        ('link->get_startIndex(&linkStart) != S_OK || linkStart != parentStart', 'link begins at selected offset'),
        ('link->get_endIndex(&linkEnd) != S_OK || linkEnd != parentEnd', 'link ends exactly at selected end'),
        ('child->identity.Get() == textIdentity.Get() && child->identity.Get() == coreIdentity.Get() && child->identity.Get() == accessibleIdentity.Get() && child->identity.Get() != bound.identity.Get()', 'four child interfaces identity-equal and not parent'),
        ('*role == ROLE_SYSTEM_TEXT && (*state & STATE_SYSTEM_READONLY) && hr == S_OK && !(*extended & (IA2_STATE_EDITABLE | IA2_STATE_DEFUNCT))', 'safe explicit readonly native child and noneditable IA2 state'),
        ('if (!SafeEmbeddedText(child, source, &childRole, &childState, &childExtended, &childSemanticRole))', 'child safety before any child selection'),
        ('childPid != sourcePid || GetAncestor(childWindow, GA_ROOT) != source', 'child window PID/root bound'),
        ('resolveCurrentSelectedChild(&fresh, &nowIndex) || nowIndex != boundIndex || fresh.identity.Get() != child.identity.Get()', 'fresh selected link index and canonical child identity'),
        ('!SafeEmbeddedText(fresh, source, &role, &state, &extended, &semanticRole) || !SafeEmbeddedText(child, source, &retainedRole, &retainedState, &retainedExtended, &retainedSemanticRole)', 'fresh and retained child safety'),
        ('role != childRole || retainedRole != childRole || state != childState || retainedState != childState || extended != childExtended || retainedExtended != childExtended', 'own child role/all states unchanged'),
        ('freshId != childId', 'fresh child ID stable'),
        ('retainedId != childId', 'retained child ID stable'),
        ('freshWindow != childWindow', 'fresh child window stable'),
        ('retainedWindow != childWindow', 'retained child window stable'),
        ('nowChildPid != childPid || nowSourcePid != sourcePid', 'child/source owning processes stable'),
        ('ReadEmbeddedStage(child.text, validateChild, 4096, &childConsumed, &totalReads, &childStart, &childEnd, &selected)', 'child only bounded explicit current selection'),
        ('if (!validateChild()) { puts("IA2_EMBEDDED_REJECT|final_relation_changed"); return; }', 'final current selected relation before logging'),
    ]: require(compact(token) in s,label)
    require(s.count('->get_text(')==1,'one shared text-read site')
    require(s.count('ReadEmbeddedStage(')==3,'one declaration and exactly two read-stage callsites')
    require(s.count('inttotalReads=0;')==1,'global budget never reset')
    require(s.count('ReadSelectedEmbedded(')==1,'one-level function is never recursive')
    for token in ('get_nHyperlinks(', 'get_accChild(', 'get_accChildCount(', 'AccessibleChildren(',
                  'FindAll(', 'FindFirst(', 'FindItemByProperty(', 'get_anchor(', 'get_anchorTarget(',
                  'get_valid(', 'doAction(', 'get_nCharacters(', 'get_DocumentRange(', 'get_accName(',
                  'get_accValue(', 'OpenClipboard(', 'GetClipboardData(', 'SendInput(', 'SetFocus(',
                  'ReadSelected(', 'CoRegisterPSClsid(', 'RegSetValue', 'RegCreateKey'):
        require(token not in s,'forbidden enumeration/content/action API: '+token)
    exclusive='''#if defined(BAOCODE_SELECTED_EMBEDDED_IA2_DIAGNOSTIC)
  ReadSelectedEmbedded(bound, source, validateCandidate);
#else
  bool consumed = false;
  ReadSelected'''
    require(compact(exclusive) in p,'embedded and single-read modes mutually exclusive')
    require(p.count('ReadSelectedEmbedded(')==2,'one declaration and one exclusive embedded invocation')
    require('if ($SelectedEmbeddedIA2 -and !$ChromiumBoundIA2)' in script,'embedded mode explicitly requires identity mode')
    require('if ($SelectedParagraphIA2 -and !$SelectedEmbeddedIA2)' in script,'paragraph mode explicitly requires selected-object mode')
    paragraph_start=s.find('constHRESULTroleHr=child.core->role(semanticRole);')
    paragraph_end=s.find('#else', paragraph_start)
    paragraph=s[paragraph_start:paragraph_end] if paragraph_start>=0 and paragraph_end>paragraph_start else ''
    require(bool(paragraph),'locate separately gated semantic paragraph mode')
    require('#ifdefined(BAOCODE_SELECTED_PARAGRAPH_IA2_DIAGNOSTIC)constHRESULTroleHr=' in s and '#else*semanticRole=*role;return*role==ROLE_SYSTEM_TEXT' in s,'paragraph predicate is opt in with separate Text default')
    require('returnroleHr==S_OK&&*role==ROLE_SYSTEM_GROUPING&&*semanticRole==IA2_ROLE_PARAGRAPH&&(*state&STATE_SYSTEM_READONLY)&&hr==S_OK&&!(*extended&(IA2_STATE_EDITABLE|IA2_STATE_DEFUNCT));' in paragraph,'only exact readonly semantic paragraph admitted')
    require('semanticRole!=childSemanticRole||retainedSemanticRole!=childSemanticRole' in s,'fresh and retained semantic role unchanged')
    require("if ($SelectedParagraphIA2) { $extraCompile += '/DBAOCODE_SELECTED_PARAGRAPH_IA2_DIAGNOSTIC' }" in script,'semantic mode explicitly opt in')
    return failures


def self_test(s,p,script):
    mutations=[
        ('paragraph_opt_in_removed','#if defined(BAOCODE_SELECTED_PARAGRAPH_IA2_DIAGNOSTIC)\n  const HRESULT roleHr', '  const HRESULT roleHr'),
        ('paragraph_sfalse','roleHr == S_OK','SUCCEEDED(roleHr)'),
        ('paragraph_role_failure','roleHr == S_OK','true'),
        ('paragraph_generic_group','*semanticRole == IA2_ROLE_PARAGRAPH &&','true &&'),
        ('paragraph_native_role','*role == ROLE_SYSTEM_GROUPING &&','true &&'),
        ('paragraph_fresh_role','semanticRole != childSemanticRole','false'),
        ('paragraph_retained_role','retainedSemanticRole != childSemanticRole','false'),
        ('paragraph_wrong_enum','*semanticRole == IA2_ROLE_PARAGRAPH &&','*semanticRole == IA2_ROLE_SECTION &&'),
        ('budget_decrement','++*totalReads;','--*totalReads;'),
        ('budget_reset','int totalReads = 0;','int totalReads = 0; int totalReads = 0;'),
        ('defunct_child',' | IA2_STATE_DEFUNCT',''),
        ('text_failed_hr','hr == S_OK && value &&','true && value &&'),
        ('budget','*totalReads >= 2','*totalReads >= 20'),
        ('stage_reuse','*consumed ||','false ||'),
        ('parent_fulltext','validateRootCandidate, 1, &parentConsumed','validateRootCandidate, 4096, &parentConsumed'),
        ('parent_not_placeholder','parentText != L"\\xFFFC"','false'),
        ('wrong_offset','get_hyperlinkIndex(parentStart, index)','get_hyperlinkIndex(0, index)'),
        ('wrong_index','get_hyperlink(*index, &link)','get_hyperlink(0, &link)'),
        ('wrong_start','linkStart != parentStart','false'),
        ('wrong_end','linkEnd != parentEnd','false'),
        ('child_cycle','child->identity.Get() != bound.identity.Get()','true'),
        ('fresh_identity','fresh.identity.Get() != child.identity.Get()','false'),
        ('fresh_index','nowIndex != boundIndex','false'),
        ('editable_child','IA2_STATE_EDITABLE |',''),
        ('no_readonly','(*state & STATE_SYSTEM_READONLY)','true'),
        ('unsafe_role','*role == ROLE_SYSTEM_TEXT','true'),
        ('unknown_states','hr == S_OK && !(*extended','true && !(*extended'),
        ('fresh_id','freshId != childId','false'),
        ('retained_id','retainedId != childId','false'),
        ('fresh_window','freshWindow != childWindow','false'),
        ('retained_window','retainedWindow != childWindow','false'),
        ('parent_selection_changed','nowEnd != parentEnd','false'),
        ('post_offsets','afterStart == start && afterEnd == end','true'),
        ('unconditional_result','if (accepted) {','if (true) {'),
        ('second_text','text->get_text(start, end, &value)','text->get_text(0, -1, &value); text->get_text(start, end, &value)'),
        ('child_read_unbounded','validateChild, 4096, &childConsumed','validateChild, 10000000, &childConsumed'),
        ('no_final_validation','if (!validateChild())','if (false)'),
    ]
    for name,a,b in mutations:
        if a not in s:raise AssertionError('Missing mutation: '+name)
        if not check(s.replace(a,b,1),p,script):raise AssertionError('Mutation survived: '+name)
    if not check(s,p.replace('#else\n  bool consumed', '#endif\n  bool consumed'),script):raise AssertionError('Dual read paths survived')
    return len(mutations)+1


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--self-test',action='store_true');args=parser.parse_args();root=Path(__file__).parent
    s=(root/'edge_pdf_selected_embedded_probe.h').read_text();p=(root/'edge_pdf_chromium_selection_probe.h').read_text();script=(root/'run_edge_pdf_probe.ps1').read_text()
    failures=check(s,p,script)
    if failures:raise AssertionError('; '.join(failures))
    if args.self_test:print('SELECTED_OBJECT_STRUCTURAL_SELF_TEST|negative_mutations_rejected='+str(self_test(s,p,script)))
    print('SELECTED_OBJECT_STRUCTURAL_PASS|source_shape_only|not_runtime_safety_tests')

if __name__=='__main__':main()
