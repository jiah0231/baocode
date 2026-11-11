#!/usr/bin/env python3
"""Source-shape and mutation checks, not runtime privacy or correctness proof."""
from pathlib import Path
import argparse
from verify_edge_pdf_ia2_probe import compact

REQUIRED = [
    'if (!endpoint) return false;',
    'out->identity.Get() != coreIdentity.Get() || out->identity.Get() != accessibleIdentity.Get()',
    'core->role(&out->semanticRole) != S_OK || core->get_states(&out->extended) != S_OK',
    'core->get_uniqueID(&out->id) != S_OK || out->id >= 0',
    'sourcePid && out->pid == sourcePid && GetAncestor(out->window, GA_ROOT) == source',
    '(out->state & STATE_SYSTEM_READONLY)',
    '!(out->extended & (IA2_STATE_EDITABLE | IA2_STATE_DEFUNCT))',
    '(out->role == ROLE_SYSTEM_TEXT || (isParagraph && out->role == ROLE_SYSTEM_GROUPING && out->semanticRole == IA2_ROLE_PARAGRAPH))',
    'if (!validateParagraph()) return false; EndpointRangesOwner ranges;',
    'hr != S_OK || ranges.count != 1 || !ranges.data || !ranges.data[0].anchor || !ranges.data[0].active || !validateParagraph()',
    'out->rawAnchorOffset < 0 || out->rawActiveOffset < 0',
    'hr != S_OK || selections.count != 1 || !selections.data || !selections.data[0].startObj || !selections.data[0].endObj || !validateParagraph()',
    'selections.data[0].startIsActive > 1 || out->startOffset < 0 || out->endOffset < 0',
    'SameEndpointMetadata(out->anchor, out->end) && SameEndpointMetadata(out->active, out->start)',
    'SameEndpointMetadata(out->anchor, out->start) && SameEndpointMetadata(out->active, out->end)',
    'out->start.identity.Get() == out->end.identity.Get()',
    'return sameEndpoints && sameEndpointMetadata && oneEndpointObject && out->endOffset > out->startOffset && out->endOffset - out->startOffset <= 4096 && validateParagraph();',
    'a.identity.Get() == b.identity.Get() && a.id == b.id && a.window == b.window && a.pid == b.pid && a.role == b.role && a.semanticRole == b.semanticRole && a.state == b.state && a.extended == b.extended',
    'paragraph.core.As(&ranges)',
    'if (hr != S_OK || !ranges) return;',
    'paragraph.core.As(&selections)',
    'if (hr != S_OK || !selections) return;',
    'rangesIdentity.Get() != paragraph.identity.Get() || selectionsIdentity.Get() != paragraph.identity.Get() || !validateParagraph()',
    'if (!CaptureEndpointSnapshot(paragraph, source, validateParagraph, ranges.Get(), selections.Get(), 1, &first))',
    'if (!CaptureEndpointSnapshot(paragraph, source, validateParagraph, ranges.Get(), selections.Get(), 2, &second))',
    'SameEndpointMetadata(first.anchor, second.anchor) && SameEndpointMetadata(first.active, second.active) && SameEndpointMetadata(first.start, second.start) && SameEndpointMetadata(first.end, second.end)',
    'first.rawAnchorOffset == second.rawAnchorOffset && first.rawActiveOffset == second.rawActiveOffset && first.startOffset == second.startOffset && first.endOffset == second.endOffset && first.startIsActive == second.startIsActive && validateParagraph()',
    'count >= 0 && count <= 64',
    'data[i].anchor->Release()', 'data[i].active->Release()',
    'data[i].startObj->Release()', 'data[i].endObj->Release()',
]
FORBIDDEN = [
    'get_text(', 'GetText(', 'ReadEmbeddedStage(', 'ReadOffsets(', 'get_selection(',
    'get_nCharacters(', 'get_accName(', 'get_accValue(', 'get_accChild(',
    'get_accChildCount(', 'get_accParent(', 'AccessibleChildren(', 'FindAll(',
    'FindFirst(', 'get_hyperlink(', 'get_hyperlinkIndex(', 'get_anchor(',
    'get_anchorTarget(', 'get_attributes(', 'get_DocumentRange(', 'get_relations(',
    'get_relationTargetsOfType(', 'get_accessibleWithCaret(', 'get_characterExtents(',
    'OpenClipboard(', 'GetClipboardData(', 'SendInput(', 'SetFocus(',
    'setSelectionRanges(', 'setSelections(', 'CoRegisterPSClsid(', 'RegSetValue',
]

def check(source, parent, script):
    s, p = compact(source), compact(parent)
    failures = [token for token in REQUIRED if compact(token) not in s]
    failures += ['forbidden '+token for token in FORBIDDEN if token in s]
    for token, count in [('CaptureEndpointSnapshot(',3), ('->get_selectionRanges(',1),
                         ('->get_selections(',1), ('CoTaskMemFree(data)',2),
                         ('for(',2), ('count>=0&&count<=64',2), ('ProbeEndpointMetadata(',1)]:
        if s.count(token) != count: failures.append('bounded calls: '+token)
    route = '''#if defined(BAOCODE_SELECTED_ENDPOINT_METADATA_IA2_DIAGNOSTIC)
  static_cast<void>(childConsumed);
#if defined(BAOCODE_SELECTION_CONTAINER_ONLY_METADATA_IA2_DIAGNOSTIC)
  ProbeContainerOnlyMetadata(child, source, validateChild);
#else
  ProbeEndpointMetadata(child, source, validateChild);
#endif
  printf("IA2_ENDPOINT_MODE_DONE|parentTextReads=%d|endpointTextReads=0|paragraphTextReads=0\\n", totalReads);
  return;
#else
  long childStart = -1, childEnd = -1;'''
    if compact(route) not in p: failures.append('exclusive metadata route, no paragraph read')
    if p.count('ProbeEndpointMetadata(') != 1: failures.append('one metadata invocation')
    if 'if ($SelectedEndpointMetadataIA2 -and !$SelectedParagraphIA2)' not in script:
        failures.append('requires prior explicit paragraph mode')
    if "if ($SelectedEndpointMetadataIA2) { $extraCompile += '/DBAOCODE_SELECTED_ENDPOINT_METADATA_IA2_DIAGNOSTIC' }" not in script:
        failures.append('explicit metadata compiler opt in')
    return failures

def self_test(source, parent, script):
    mutations = [(str(i),token, 'true') for i,token in enumerate(REQUIRED)]
    for name, token, changed in mutations:
        s=compact(source)
        token=compact(token)
        if token not in s: raise AssertionError('Missing mutation '+name)
        if not check(s.replace(token,changed,1),parent,script):
            raise AssertionError('Mutation survived '+name)
    for token in FORBIDDEN:
        if not check(source+'\n'+token,parent,script):
            raise AssertionError('Forbidden API survived '+token)
    for changed in [parent.replace('  return;\n#else\n  long childStart','\n#else\n  long childStart'),
                    parent.replace('#else\n  long childStart','#endif\n  long childStart')]:
        if not check(source,changed,script):raise AssertionError('Dual content path survived')
    return len(mutations)+len(FORBIDDEN)+2

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--self-test',action='store_true');args=ap.parse_args()
    root=Path(__file__).parent
    s=(root/'edge_pdf_endpoint_metadata_probe.h').read_text()
    p=(root/'edge_pdf_selected_embedded_probe.h').read_text()
    script=(root/'run_edge_pdf_probe.ps1').read_text()
    failures=check(s,p,script)
    if failures:raise AssertionError('; '.join(failures))
    if args.self_test:print('ENDPOINT_METADATA_SELF_TEST|negative_mutations_rejected='+str(self_test(s,p,script)))
    print('ENDPOINT_METADATA_STRUCTURAL_PASS|source_shape_only|not_runtime_safety_testing')

if __name__=='__main__':main()
