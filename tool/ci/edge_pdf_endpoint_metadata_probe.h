#pragma once
#include "Accessible2_3.h"
#include "AccessibleTextSelectionContainer.h"

namespace edge_pdf_ia2 {
// These owners only clean up returned interface references. Rejected arrays are
// never inspected as candidates. Abnormal counts are not trusted for iteration;
// excess interface references then expire with this disposable diagnostic process.
struct EndpointRangesOwner {
  IA2Range* data = nullptr;
  long count = 0;
  ~EndpointRangesOwner() {
    if (data && (count < 0 || count > 64)) puts("IA2_ENDPOINT_CLEANUP|ranges_abnormal_count|references_not_iterated");
    if (data && count >= 0 && count <= 64) {
      for (long i = 0; i < count; ++i) {
        if (data[i].anchor) data[i].anchor->Release();
        if (data[i].active) data[i].active->Release();
      }
    }
    CoTaskMemFree(data);
  }
};
struct EndpointSelectionsOwner {
  IA2TextSelection* data = nullptr;
  long count = 0;
  ~EndpointSelectionsOwner() {
    if (data && (count < 0 || count > 64)) puts("IA2_ENDPOINT_CLEANUP|selections_abnormal_count|references_not_iterated");
    if (data && count >= 0 && count <= 64) {
      for (long i = 0; i < count; ++i) {
        if (data[i].startObj) data[i].startObj->Release();
        if (data[i].endObj) data[i].endObj->Release();
      }
    }
    CoTaskMemFree(data);
  }
};
struct EndpointMetadata {
  ComPtr<IUnknown> identity;
  long id = 0, role = 0, state = 0, semanticRole = 0;
  AccessibleStates extended = 0;
  HWND window = nullptr;
  DWORD pid = 0;
};
inline bool CaptureEndpointMetadata(IUnknown* endpoint, HWND source,
    IUnknown* paragraphIdentity, int snapshot, const char* label,
    EndpointMetadata* out) {
  if (!endpoint) return false;
  ComPtr<IAccessible2> core;
  ComPtr<IAccessible> accessible;
  ComPtr<IUnknown> coreIdentity, accessibleIdentity;
  if (endpoint->QueryInterface(IID_PPV_ARGS(&out->identity)) != S_OK || !out->identity ||
      endpoint->QueryInterface(IID_PPV_ARGS(&core)) != S_OK || !core ||
      endpoint->QueryInterface(IID_PPV_ARGS(&accessible)) != S_OK || !accessible ||
      core.As(&coreIdentity) != S_OK || !coreIdentity ||
      accessible.As(&accessibleIdentity) != S_OK || !accessibleIdentity ||
      out->identity.Get() != coreIdentity.Get() || out->identity.Get() != accessibleIdentity.Get()) {
    puts("IA2_ENDPOINT_REJECT|endpoint_interface_identity"); return false;
  }
  if (!SafeAccessible(accessible.Get(), source) ||
      !NativeMetadata(accessible.Get(), &out->role, &out->state) ||
      core->role(&out->semanticRole) != S_OK || core->get_states(&out->extended) != S_OK ||
      core->get_uniqueID(&out->id) != S_OK || out->id >= 0 ||
      core->get_windowHandle(&out->window) != S_OK || !out->window) return false;
  GetWindowThreadProcessId(out->window, &out->pid);
  DWORD sourcePid = 0;
  GetWindowThreadProcessId(source, &sourcePid);
  const bool isParagraph = out->identity.Get() == paragraphIdentity;
  printf("IA2_ENDPOINT_META|snapshot=%d|which=%s|canonical=%p|id=%ld|window=%p|pid=%lu|role=%ld|semanticRole=%ld|state=0x%08lX|extended=0x%llX|isBoundParagraph=%d\n",
      snapshot, label, static_cast<void*>(out->identity.Get()), out->id,
      static_cast<void*>(out->window), static_cast<unsigned long>(out->pid), out->role,
      out->semanticRole, static_cast<unsigned long>(out->state),
      static_cast<unsigned long long>(out->extended), isParagraph);
  // This is only metadata admission, never permission to read text. A generic
  // Grouping cannot pass; only the already-bound paragraph or readonly Text can.
  return sourcePid && out->pid == sourcePid && GetAncestor(out->window, GA_ROOT) == source &&
      (out->state & STATE_SYSTEM_READONLY) &&
      !(out->extended & (IA2_STATE_EDITABLE | IA2_STATE_DEFUNCT)) &&
      (out->role == ROLE_SYSTEM_TEXT || (isParagraph && out->role == ROLE_SYSTEM_GROUPING &&
          out->semanticRole == IA2_ROLE_PARAGRAPH)) && SafeAccessible(accessible.Get(), source);
}
inline bool SameEndpointMetadata(const EndpointMetadata& a, const EndpointMetadata& b) {
  return a.identity.Get() == b.identity.Get() && a.id == b.id && a.window == b.window &&
      a.pid == b.pid && a.role == b.role && a.semanticRole == b.semanticRole &&
      a.state == b.state && a.extended == b.extended;
}
struct EndpointSnapshot {
  EndpointMetadata anchor, active, start, end;
  long rawAnchorOffset = -1, rawActiveOffset = -1;
  long startOffset = -1, endOffset = -1;
  bool startIsActive = false;
};
inline bool CaptureEndpointSnapshot(const ChromiumServiceCandidate& paragraph,
    HWND source, const std::function<bool()>& validateParagraph,
    IAccessible2_3* rangesInterface, IAccessibleTextSelectionContainer* selectionsInterface,
    int number, EndpointSnapshot* out) {
  if (!validateParagraph()) return false;
  EndpointRangesOwner ranges;
  HRESULT hr = rangesInterface->get_selectionRanges(&ranges.data, &ranges.count);
  printf("IA2_ENDPOINT_RANGES|snapshot=%d|hr=0x%08lX|count=%ld\n",
      number, static_cast<unsigned long>(hr), ranges.count);
  if (hr != S_OK || ranges.count != 1 || !ranges.data ||
      !ranges.data[0].anchor || !ranges.data[0].active || !validateParagraph()) return false;
  out->rawAnchorOffset = ranges.data[0].anchorOffset;
  out->rawActiveOffset = ranges.data[0].activeOffset;
  if (out->rawAnchorOffset < 0 || out->rawActiveOffset < 0 ||
      !CaptureEndpointMetadata(ranges.data[0].anchor, source, paragraph.identity.Get(),
          number, "raw_anchor", &out->anchor) ||
      !CaptureEndpointMetadata(ranges.data[0].active, source, paragraph.identity.Get(),
          number, "raw_active", &out->active) || !validateParagraph()) return false;
  EndpointSelectionsOwner selections;
  hr = selectionsInterface->get_selections(&selections.data, &selections.count);
  printf("IA2_ENDPOINT_SELECTIONS|snapshot=%d|hr=0x%08lX|count=%ld\n",
      number, static_cast<unsigned long>(hr), selections.count);
  if (hr != S_OK || selections.count != 1 || !selections.data ||
      !selections.data[0].startObj || !selections.data[0].endObj || !validateParagraph()) return false;
  out->startOffset = selections.data[0].startOffset;
  out->endOffset = selections.data[0].endOffset;
  out->startIsActive = selections.data[0].startIsActive != 0;
  if (selections.data[0].startIsActive > 1 || out->startOffset < 0 || out->endOffset < 0 ||
      !CaptureEndpointMetadata(selections.data[0].startObj, source, paragraph.identity.Get(),
          number, "text_start", &out->start) ||
      !CaptureEndpointMetadata(selections.data[0].endObj, source, paragraph.identity.Get(),
          number, "text_end", &out->end) || !validateParagraph()) return false;
  const bool sameEndpoints = out->startIsActive ?
      (out->anchor.identity.Get() == out->end.identity.Get() && out->active.identity.Get() == out->start.identity.Get()) :
      (out->anchor.identity.Get() == out->start.identity.Get() && out->active.identity.Get() == out->end.identity.Get());
  const bool sameEndpointMetadata = out->startIsActive ?
      (SameEndpointMetadata(out->anchor, out->end) && SameEndpointMetadata(out->active, out->start)) :
      (SameEndpointMetadata(out->anchor, out->start) && SameEndpointMetadata(out->active, out->end));
  const bool oneEndpointObject = out->start.identity.Get() == out->end.identity.Get();
  const bool paragraphEndpoint = out->start.identity.Get() == paragraph.identity.Get() ||
      out->end.identity.Get() == paragraph.identity.Get();
  printf("IA2_ENDPOINT_OFFSETS|snapshot=%d|rawAnchor=%ld|rawActive=%ld|hyperStart=%ld|hyperEnd=%ld|startIsActive=%d|sameCrossApiEndpoints=%d|oneEndpointObject=%d|paragraphEndpoint=%d\n",
      number, out->rawAnchorOffset, out->rawActiveOffset, out->startOffset, out->endOffset,
      out->startIsActive, sameEndpoints, oneEndpointObject, paragraphEndpoint);
  // The raw offsets may be child indexes. Do not compare them to text offsets,
  // convert them, read their text, or traverse to explain a mismatch or clipping.
  return sameEndpoints && sameEndpointMetadata && oneEndpointObject && out->endOffset > out->startOffset &&
      out->endOffset - out->startOffset <= 4096 && validateParagraph();
}
inline void ProbeEndpointMetadata(const ChromiumServiceCandidate& paragraph, HWND source,
    const std::function<bool()>& validateParagraph) {
  puts("IA2_ENDPOINT_BEGIN|bound_paragraph_only|maximum_snapshots=2|endpoint_text_reads=0");
  if (!validateParagraph()) return;
  ComPtr<IAccessible2_3> ranges;
  ComPtr<IAccessibleTextSelectionContainer> selections;
  HRESULT hr = paragraph.core.As(&ranges);
  Hr("endpoint_paragraph_QI_IAccessible2_3", hr);
  if (hr != S_OK || !ranges) return;
  hr = paragraph.core.As(&selections);
  Hr("endpoint_paragraph_QI_selection_container", hr);
  if (hr != S_OK || !selections) return;
  ComPtr<IUnknown> rangesIdentity, selectionsIdentity;
  if (ranges.As(&rangesIdentity) != S_OK || !rangesIdentity ||
      selections.As(&selectionsIdentity) != S_OK || !selectionsIdentity ||
      rangesIdentity.Get() != paragraph.identity.Get() ||
      selectionsIdentity.Get() != paragraph.identity.Get() || !validateParagraph()) return;
  EndpointSnapshot first, second;
  if (!CaptureEndpointSnapshot(paragraph, source, validateParagraph, ranges.Get(), selections.Get(), 1, &first)) {
    puts("IA2_ENDPOINT_REJECT|first_snapshot"); return;
  }
  if (!CaptureEndpointSnapshot(paragraph, source, validateParagraph, ranges.Get(), selections.Get(), 2, &second)) {
    puts("IA2_ENDPOINT_REJECT|second_snapshot"); return;
  }
  const bool stable = SameEndpointMetadata(first.anchor, second.anchor) &&
      SameEndpointMetadata(first.active, second.active) && SameEndpointMetadata(first.start, second.start) &&
      SameEndpointMetadata(first.end, second.end) && first.rawAnchorOffset == second.rawAnchorOffset &&
      first.rawActiveOffset == second.rawActiveOffset && first.startOffset == second.startOffset &&
      first.endOffset == second.endOffset && first.startIsActive == second.startIsActive && validateParagraph();
  printf("IA2_ENDPOINT_RESULT|snapshots=2|stable=%d|endpoint_text_reads=0|not_text_correctness_evidence=1\n", stable);
}
}  // namespace edge_pdf_ia2
