#pragma once
// Explicit second-interface-only metadata experiment. The first-interface
// experiment and all selected-text branches are excluded by the caller.
namespace edge_pdf_ia2 {
struct ContainerMetadataSnapshot {
  EndpointMetadata start, end;
  long startOffset = -1, endOffset = -1;
  bool startIsActive = false;
};
inline bool CaptureContainerMetadataSnapshot(const ChromiumServiceCandidate& paragraph,
    HWND source, const std::function<bool()>& validateParagraph,
    IAccessibleTextSelectionContainer* container, int number,
    ContainerMetadataSnapshot* out) {
  if (!validateParagraph()) return false;
  EndpointSelectionsOwner selections;
  const HRESULT hr = container->get_selections(&selections.data, &selections.count);
  printf("IA2_CONTAINER_SNAPSHOT|number=%d|hr=0x%08lX|count=%ld\n",
      number, static_cast<unsigned long>(hr), selections.count);
  if (hr != S_OK || selections.count != 1 || !selections.data ||
      !selections.data[0].startObj || !selections.data[0].endObj || !validateParagraph()) return false;
  out->startOffset = selections.data[0].startOffset;
  out->endOffset = selections.data[0].endOffset;
  out->startIsActive = selections.data[0].startIsActive != 0;
  if (selections.data[0].startIsActive > 1 || out->startOffset < 0 || out->endOffset < 0 ||
      !CaptureEndpointMetadata(selections.data[0].startObj, source, paragraph.identity.Get(),
          number, "container_start", &out->start) ||
      !CaptureEndpointMetadata(selections.data[0].endObj, source, paragraph.identity.Get(),
          number, "container_end", &out->end) || !validateParagraph()) return false;
  const bool sameEndpoint = SameEndpointMetadata(out->start, out->end);
  const bool boundParagraphEndpoint = out->start.identity.Get() == paragraph.identity.Get() ||
      out->end.identity.Get() == paragraph.identity.Get();
  printf("IA2_CONTAINER_OFFSETS|number=%d|hyperStart=%ld|hyperEnd=%ld|startIsActive=%d|sameEndpoint=%d|boundParagraphEndpoint=%d|croppingUnverified=1\n",
      number, out->startOffset, out->endOffset, out->startIsActive, sameEndpoint, boundParagraphEndpoint);
  // No other endpoint API, tree traversal or content read is used to explain
  // clipping. Metadata consistency never establishes the actual physical text.
  return sameEndpoint && out->endOffset > out->startOffset &&
      out->endOffset - out->startOffset <= 4096 && validateParagraph();
}
inline void ProbeContainerOnlyMetadata(const ChromiumServiceCandidate& paragraph, HWND source,
    const std::function<bool()>& validateParagraph) {
  puts("IA2_CONTAINER_BEGIN|same_bound_paragraph_only|maximum_snapshots=2|endpoint_text_reads=0|first_interface_not_attempted=1");
  if (!validateParagraph()) return;
  ComPtr<IAccessibleTextSelectionContainer> container;
  const HRESULT hr = paragraph.core.As(&container);
  Hr("container_only_paragraph_QI_selection_container", hr);
  if (hr != S_OK || !container) return;
  ComPtr<IUnknown> identity;
  if (container.As(&identity) != S_OK || !identity ||
      identity.Get() != paragraph.identity.Get() || !validateParagraph()) return;
  ContainerMetadataSnapshot first, second;
  if (!CaptureContainerMetadataSnapshot(paragraph, source, validateParagraph, container.Get(), 1, &first)) {
    puts("IA2_CONTAINER_REJECT|first_snapshot"); return;
  }
  if (!CaptureContainerMetadataSnapshot(paragraph, source, validateParagraph, container.Get(), 2, &second)) {
    puts("IA2_CONTAINER_REJECT|second_snapshot"); return;
  }
  const bool stable = SameEndpointMetadata(first.start, second.start) &&
      SameEndpointMetadata(first.end, second.end) && first.startOffset == second.startOffset &&
      first.endOffset == second.endOffset && first.startIsActive == second.startIsActive && validateParagraph();
  printf("IA2_CONTAINER_RESULT|snapshots=2|stable=%d|endpoint_text_reads=0|croppingUnverified=1|not_text_correctness_evidence=1\n", stable);
}
}  // namespace edge_pdf_ia2
