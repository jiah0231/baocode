#pragma once
#include "AccessibleHypertext.h"
#if defined(BAOCODE_SELECTED_PARAGRAPH_IA2_DIAGNOSTIC)
#include "AccessibleRole.h"
#endif
#if defined(BAOCODE_SELECTED_ENDPOINT_METADATA_IA2_DIAGNOSTIC)
#include "edge_pdf_endpoint_metadata_probe.h"
#endif

namespace edge_pdf_ia2 {
// At most one read in each stage, at most two text calls in this entire mode.
// Shared selection helpers still reject multiple/collapsed/unbounded selections.
inline bool ReadEmbeddedStage(ComPtr<IAccessibleText> text,
    const std::function<bool()>& validateCandidate, long maximumCharacters,
    bool* consumed, int* totalReads, long* selectedStart, long* selectedEnd,
    std::wstring* result) {
  if (*consumed || *totalReads >= 2 || !validateCandidate()) return false;
  long start = -1, end = -1;
  if (!ReadOffsets(text.Get(), &start, &end, "embedded_stage_before") ||
      end - start > maximumCharacters) return false;
  long checkStart = -1, checkEnd = -1;
  if (!validateCandidate() || !ReadOffsets(text.Get(), &checkStart, &checkEnd,
      "embedded_stage_immediately_before") || checkStart != start || checkEnd != end) return false;
  *consumed = true;
  ++*totalReads;
  BSTR value = nullptr;
  const HRESULT hr = text->get_text(start, end, &value);
  Hr("embedded_stage_get_text_explicit_selection", hr, *totalReads);
  long afterStart = -1, afterEnd = -1;
  const bool accepted = hr == S_OK && value &&
      SysStringLen(value) <= static_cast<UINT>(maximumCharacters) &&
      validateCandidate() && ReadOffsets(text.Get(), &afterStart, &afterEnd,
          "embedded_stage_after") && afterStart == start && afterEnd == end && validateCandidate();
  if (accepted) {
    result->assign(value, SysStringLen(value));
    *selectedStart = start; *selectedEnd = end;
  }
  SysFreeString(value);
  printf("IA2_EMBEDDED_STAGE|totalReads=%d|accepted=%d\n", *totalReads, accepted);
  return accepted;
}

inline bool SafeEmbeddedText(const ChromiumServiceCandidate& child, HWND source,
    long* role, long* state, AccessibleStates* extended, long* semanticRole) {
  if (!SafeAccessible(child.accessible.Get(), source) ||
      !NativeMetadata(child.accessible.Get(), role, state)) return false;
  const HRESULT hr = child.core->get_states(extended);
  Hr("embedded_child_IA2_states", hr);
  printf("IA2_EMBEDDED_CHILD_ROLE|role=%ld|state=0x%08lX|extended=0x%llX\n",
      *role, static_cast<unsigned long>(*state), static_cast<unsigned long long>(*extended));
#if defined(BAOCODE_SELECTED_PARAGRAPH_IA2_DIAGNOSTIC)
  const HRESULT roleHr = child.core->role(semanticRole);
  Hr("embedded_child_IA2_semantic_role", roleHr);
  printf("IA2_EMBEDDED_SEMANTIC_ROLE|roleHr=0x%08lX|semanticRole=%ld|isParagraph=%d\n",
      static_cast<unsigned long>(roleHr), *semanticRole, *semanticRole == IA2_ROLE_PARAGRAPH);
  return roleHr == S_OK && *role == ROLE_SYSTEM_GROUPING &&
      *semanticRole == IA2_ROLE_PARAGRAPH && (*state & STATE_SYSTEM_READONLY) &&
      hr == S_OK && !(*extended & (IA2_STATE_EDITABLE | IA2_STATE_DEFUNCT));
#else
  *semanticRole = *role;
  return *role == ROLE_SYSTEM_TEXT && (*state & STATE_SYSTEM_READONLY) &&
      hr == S_OK && !(*extended & (IA2_STATE_EDITABLE | IA2_STATE_DEFUNCT));
#endif
}

inline void ReadSelectedEmbedded(const ChromiumServiceCandidate& bound, HWND source,
    const std::function<bool()>& validateRootCandidate) {
  puts("IA2_SELECTED_EMBEDDED_BEGIN|one_selected_object|one_level|maximum_text_calls=2");
  bool parentConsumed = false, childConsumed = false;
  int totalReads = 0;
  long parentStart = -1, parentEnd = -1;
  std::wstring parentText;
  if (!ReadEmbeddedStage(bound.text, validateRootCandidate, 1, &parentConsumed,
      &totalReads, &parentStart, &parentEnd, &parentText) ||
      parentEnd - parentStart != 1 || parentText != L"\xFFFC") {
    puts("IA2_EMBEDDED_REJECT|parent_not_current_single_placeholder"); return;
  }
  ComPtr<IAccessibleHypertext> hypertext;
  ComPtr<IUnknown> hypertextIdentity;
  if (bound.text.As(&hypertext) != S_OK || !hypertext ||
      hypertext.As(&hypertextIdentity) != S_OK || !hypertextIdentity ||
      hypertextIdentity.Get() != bound.identity.Get()) {
    puts("IA2_EMBEDDED_REJECT|parent_hypertext_identity"); return;
  }
  auto resolveCurrentSelectedChild = [&](ChromiumServiceCandidate* child, long* index) {
    if (!validateRootCandidate()) return false;
    long nowStart = -1, nowEnd = -1;
    if (!ReadOffsets(bound.text.Get(), &nowStart, &nowEnd, "embedded_parent_relation") ||
        nowStart != parentStart || nowEnd != parentEnd) return false;
    HRESULT hr = hypertext->get_hyperlinkIndex(parentStart, index);
    Hr("embedded_selected_offset_hyperlinkIndex", hr);
    if (hr != S_OK || *index < 0) return false;
    ComPtr<IAccessibleHyperlink> link;
    hr = hypertext->get_hyperlink(*index, &link);
    Hr("embedded_selected_index_hyperlink", hr);
    if (hr != S_OK || !link) return false;
    long linkStart = -1, linkEnd = -1;
    if (link->get_startIndex(&linkStart) != S_OK || linkStart != parentStart ||
        link->get_endIndex(&linkEnd) != S_OK || linkEnd != parentEnd) return false;
    if (link.As(&child->text) != S_OK || !child->text ||
        link.As(&child->core) != S_OK || !child->core ||
        link.As(&child->accessible) != S_OK || !child->accessible) return false;
    ComPtr<IUnknown> textIdentity, coreIdentity, accessibleIdentity;
    const bool same = link.As(&child->identity) == S_OK && child->identity &&
        child->text.As(&textIdentity) == S_OK && textIdentity &&
        child->core.As(&coreIdentity) == S_OK && coreIdentity &&
        child->accessible.As(&accessibleIdentity) == S_OK && accessibleIdentity &&
        child->identity.Get() == textIdentity.Get() && child->identity.Get() == coreIdentity.Get() &&
        child->identity.Get() == accessibleIdentity.Get() && child->identity.Get() != bound.identity.Get();
    printf("IA2_EMBEDDED_RELATION|sameChildInterfaces=%d|index=%ld|selectedOffset=%ld\n",
        same, *index, parentStart);
    return same && validateRootCandidate();
  };
  ChromiumServiceCandidate child;
  long boundIndex = -1;
  if (!resolveCurrentSelectedChild(&child, &boundIndex)) {
    puts("IA2_EMBEDDED_REJECT|selected_object_relation"); return;
  }
  long childRole = 0, childState = 0, childSemanticRole = 0;
  AccessibleStates childExtended = 0;
  if (!SafeEmbeddedText(child, source, &childRole, &childState, &childExtended, &childSemanticRole)) {
    puts("IA2_EMBEDDED_REJECT|child_role_or_state_unsafe"); return;
  }
  long childId = 0; HWND childWindow = nullptr;
  if (child.core->get_uniqueID(&childId) != S_OK || childId >= 0 ||
      child.core->get_windowHandle(&childWindow) != S_OK || !childWindow) return;
  DWORD childPid = 0, sourcePid = 0;
  GetWindowThreadProcessId(childWindow, &childPid);
  GetWindowThreadProcessId(source, &sourcePid);
  if (!sourcePid || childPid != sourcePid || GetAncestor(childWindow, GA_ROOT) != source) return;
  int childValidations = 0;
  auto validateChild = [&]() {
    ++childValidations;
    ChromiumServiceCandidate fresh;
    long nowIndex = -1;
    if (!resolveCurrentSelectedChild(&fresh, &nowIndex) || nowIndex != boundIndex ||
        fresh.identity.Get() != child.identity.Get()) return false;
    long role = 0, state = 0, retainedRole = 0, retainedState = 0;
    long semanticRole = 0, retainedSemanticRole = 0;
    AccessibleStates extended = 0, retainedExtended = 0;
    if (!SafeEmbeddedText(fresh, source, &role, &state, &extended, &semanticRole) ||
        !SafeEmbeddedText(child, source, &retainedRole, &retainedState, &retainedExtended, &retainedSemanticRole) ||
        role != childRole || retainedRole != childRole || state != childState || retainedState != childState ||
        extended != childExtended || retainedExtended != childExtended ||
        semanticRole != childSemanticRole || retainedSemanticRole != childSemanticRole) return false;
    long freshId = 0, retainedId = 0; HWND freshWindow = nullptr, retainedWindow = nullptr;
    if (fresh.core->get_uniqueID(&freshId) != S_OK || freshId != childId ||
        child.core->get_uniqueID(&retainedId) != S_OK || retainedId != childId ||
        fresh.core->get_windowHandle(&freshWindow) != S_OK || freshWindow != childWindow ||
        child.core->get_windowHandle(&retainedWindow) != S_OK || retainedWindow != childWindow) return false;
    DWORD nowChildPid = 0, nowSourcePid = 0;
    GetWindowThreadProcessId(childWindow, &nowChildPid);
    GetWindowThreadProcessId(source, &nowSourcePid);
    if (nowChildPid != childPid || nowSourcePid != sourcePid || GetAncestor(childWindow, GA_ROOT) != source) return false;
    const bool valid = validateRootCandidate() && SafeAccessible(child.accessible.Get(), source) &&
        SafeAccessible(fresh.accessible.Get(), source);
    printf("IA2_EMBEDDED_CHILD_VALIDATION|number=%d|accepted=%d\n", childValidations, valid);
    return valid;
  };
#if defined(BAOCODE_SELECTED_ENDPOINT_METADATA_IA2_DIAGNOSTIC)
  static_cast<void>(childConsumed);
  ProbeEndpointMetadata(child, source, validateChild);
  printf("IA2_ENDPOINT_MODE_DONE|parentTextReads=%d|endpointTextReads=0|paragraphTextReads=0\n", totalReads);
  return;
#else
  long childStart = -1, childEnd = -1;
  std::wstring selected;
  if (!ReadEmbeddedStage(child.text, validateChild, 4096, &childConsumed,
      &totalReads, &childStart, &childEnd, &selected)) {
    puts("IA2_EMBEDDED_REJECT|child_current_selection"); return;
  }
  if (!validateChild()) { puts("IA2_EMBEDDED_REJECT|final_relation_changed"); return; }
  printf("IA2_EMBEDDED_SELECTED_UTF16|");
  for (wchar_t c : selected) printf("\\u%04X", static_cast<unsigned>(c));
  puts("");
  printf("IA2_EMBEDDED_RESULT|VAD_method=%d|anotherPlaceholder=%d|totalReads=%d|childValidations=%d|one_level_only=1\n",
      selected == L"VAD method", selected == L"\xFFFC", totalReads, childValidations);
#endif
}
}  // namespace edge_pdf_ia2
