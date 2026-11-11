#!/usr/bin/env python3
"""Bounded second-interface source-shape checks, not runtime safety proof."""
from pathlib import Path
import argparse
from verify_edge_pdf_ia2_probe import compact
from verify_edge_pdf_endpoint_metadata_probe import FORBIDDEN

REQUIRED = [
    'if (!validateParagraph()) return false; EndpointSelectionsOwner selections;',
    'const HRESULT hr = container->get_selections(&selections.data, &selections.count);',
    'hr != S_OK || selections.count != 1 || !selections.data || !selections.data[0].startObj || !selections.data[0].endObj || !validateParagraph()',
    'selections.data[0].startIsActive > 1 || out->startOffset < 0 || out->endOffset < 0',
    'CaptureEndpointMetadata(selections.data[0].startObj, source, paragraph.identity.Get(), number, "container_start", &out->start)',
    'CaptureEndpointMetadata(selections.data[0].endObj, source, paragraph.identity.Get(), number, "container_end", &out->end) || !validateParagraph()',
    'const bool sameEndpoint = SameEndpointMetadata(out->start, out->end);',
    'return sameEndpoint && out->endOffset > out->startOffset && out->endOffset - out->startOffset <= 4096 && validateParagraph();',
    'if (!validateParagraph()) return; ComPtr<IAccessibleTextSelectionContainer> container;',
    'const HRESULT hr = paragraph.core.As(&container);',
    'if (hr != S_OK || !container) return;',
    'container.As(&identity) != S_OK || !identity || identity.Get() != paragraph.identity.Get() || !validateParagraph()',
    'if (!CaptureContainerMetadataSnapshot(paragraph, source, validateParagraph, container.Get(), 1, &first))',
    'if (!CaptureContainerMetadataSnapshot(paragraph, source, validateParagraph, container.Get(), 2, &second))',
    'SameEndpointMetadata(first.start, second.start) && SameEndpointMetadata(first.end, second.end)',
    'first.startOffset == second.startOffset && first.endOffset == second.endOffset && first.startIsActive == second.startIsActive && validateParagraph()',
]

def check(source,parent,script):
    s,p=compact(source),compact(parent)
    failures=[x for x in REQUIRED if compact(x) not in s]
    for token in FORBIDDEN+['get_selectionRanges(', 'IAccessible2_3', 'ProbeEndpointMetadata(', 'for(', 'while(']:
        if token in s: failures.append('forbidden '+token)
    for token,count in [('CaptureContainerMetadataSnapshot(',3),('->get_selections(',1),('ProbeContainerOnlyMetadata(',1),('croppingUnverified=1',2)]:
        if s.count(token)!=count:failures.append('bounded calls/disclaimer '+token)
    route='''#if defined(BAOCODE_SELECTION_CONTAINER_ONLY_METADATA_IA2_DIAGNOSTIC)
  ProbeContainerOnlyMetadata(child, source, validateChild);
#else
  ProbeEndpointMetadata(child, source, validateChild);
#endif'''
    if compact(route) not in p:failures.append('first interface compile-time excluded')
    if p.count('ProbeContainerOnlyMetadata(')!=1:failures.append('exactly one container-only invocation')
    if 'if ($SelectionContainerOnlyMetadataIA2 -and !$SelectedEndpointMetadataIA2)' not in script:
        failures.append('explicit previous metadata prerequisite')
    if "if ($SelectionContainerOnlyMetadataIA2) { $extraCompile += '/DBAOCODE_SELECTION_CONTAINER_ONLY_METADATA_IA2_DIAGNOSTIC' }" not in script:
        failures.append('explicit second-interface opt in')
    return failures

def self_test(source,parent,script):
    for i,token in enumerate(REQUIRED):
        s=compact(source);token=compact(token)
        if token not in s:raise AssertionError('Missing mutation '+str(i))
        if not check(s.replace(token,'true',1),parent,script):raise AssertionError('Mutation survived '+str(i))
    forbidden=FORBIDDEN+['get_selectionRanges(', 'IAccessible2_3', 'ProbeEndpointMetadata(', 'for(', 'while(']
    for token in forbidden:
        if not check(source+'\n'+token,parent,script):raise AssertionError('Forbidden survived '+token)
    if not check(source,parent.replace('#else\n  ProbeEndpointMetadata','#endif\n  ProbeEndpointMetadata'),script):
        raise AssertionError('Both endpoint API paths survived')
    if not check(source.replace('croppingUnverified=1','croppingVerified=1',1),parent,script):
        raise AssertionError('Unsupported clipping conclusion survived')
    return len(REQUIRED)+len(forbidden)+2

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--self-test',action='store_true');args=ap.parse_args();root=Path(__file__).parent
    s=(root/'edge_pdf_container_metadata_probe.h').read_text();p=(root/'edge_pdf_selected_embedded_probe.h').read_text();script=(root/'run_edge_pdf_probe.ps1').read_text()
    failures=check(s,p,script)
    if failures:raise AssertionError('; '.join(failures))
    if args.self_test:print('CONTAINER_METADATA_SELF_TEST|negative_mutations_rejected='+str(self_test(s,p,script)))
    print('CONTAINER_METADATA_STRUCTURAL_PASS|source_shape_only|not_runtime_safety_testing')

if __name__=='__main__':main()
