#pragma once
#include "edge_pdf_ia2_probe.h"

namespace edge_pdf_ia2 {
struct ChromiumServiceCandidate {
  ComPtr<IAccessibleText> text;
  ComPtr<IAccessible2> core;
  ComPtr<IAccessible> accessible;
  ComPtr<IUnknown> identity;
};
inline bool QueryChromiumService(IAccessible* terminal, HWND source,
    const std::function<bool()>& validateFocus, ChromiumServiceCandidate* out) {
  if (!terminal || !validateFocus() || !SafeAccessible(terminal, source)) return false;
  ComPtr<IServiceProvider> provider;
  HRESULT hr = terminal->QueryInterface(IID_PPV_ARGS(&provider));
  Hr("bound_service_provider", hr);
  if (hr != S_OK || !provider) return false;
  hr = provider->QueryService(__uuidof(IAccessible), __uuidof(IAccessibleText),
      reinterpret_cast<void**>(out->text.GetAddressOf()));
  Hr("bound_service_text", hr);
  if (hr != S_OK || !out->text) return false;
  if (out->text.As(&out->core) != S_OK || !out->core ||
      out->text.As(&out->accessible) != S_OK || !out->accessible) return false;
  ComPtr<IUnknown> coreIdentity, accessibleIdentity;
  const bool same = SUCCEEDED(out->text.As(&out->identity)) && out->identity &&
      SUCCEEDED(out->core.As(&coreIdentity)) && coreIdentity &&
      SUCCEEDED(out->accessible.As(&accessibleIdentity)) && accessibleIdentity &&
      out->identity.Get() == coreIdentity.Get() &&
      out->identity.Get() == accessibleIdentity.Get();
  printf("IA2_BOUND_SERVICE_IDENTITIES|same=%d\n", same);
  return same && validateFocus() && SafeAccessible(terminal, source) &&
      SafeAccessible(out->accessible.Get(), source);
}

inline void RunChromiumBoundSelection(IUIAutomation* uia, HWND source,
                const std::function<void()>& validateNativeIdentity) {
  puts("IA2_CHROMIUM_BOUND_BEGIN|separate_identity_strategy|public_fixture_only|not_product_fallback");
  validateNativeIdentity();
  CLSID proxy{};
  HRESULT proxyHr = CoGetPSClsid(__uuidof(IAccessibleText), &proxy);
  Hr("CoGetPSClsid_IAccessibleText_read_only", proxyHr);
  wchar_t proxyString[64]{};
  if (SUCCEEDED(proxyHr) && StringFromGUID2(proxy, proxyString, 64))
    printf("IA2_REGISTERED_PROXY|clsid=%ls|registration_performed=0\n", proxyString);
  ComPtr<IUIAutomationElement> root, focus;
  ComPtr<IUIAutomationTreeWalker> walker;
  HRESULT hr = uia->ElementFromHandle(source, &root); Hr("source_root", hr);
  if (FAILED(hr) || !root) return;
  hr = uia->get_ControlViewWalker(&walker); Hr("control_walker", hr);
  if (FAILED(hr) || !walker) return;
  hr = uia->GetFocusedElement(&focus); Hr("focused_element", hr);
  if (FAILED(hr) || !focus || !InSource(uia, walker.Get(), root.Get(), focus.Get())) {
    puts("IA2_REJECT|focus_not_proven_in_exact_source"); return;
  }
  int focusPid = 0;
  if (FAILED(focus->get_CurrentProcessId(&focusPid)) ||
      !SafeElement(focus.Get(), focusPid, true)) {
    puts("IA2_REJECT|focus_metadata_unsafe_or_unknown"); return;
  }
  CONTROLTYPEID focusType = 0;
  hr = focus->get_CurrentControlType(&focusType); Hr("focused_control_type", hr);
  printf("IA2_FOCUSED_CONTROL|type=%d\n", focusType);
  if (FAILED(hr)) return;
  std::vector<ComPtr<IUIAutomationElement>> focusPath{focus};
  std::vector<CONTROLTYPEID> focusTypes{focusType};
  if (focusType == UIA_GroupControlTypeId) {
    // This fixed PDF reports Group focus and a Document parent. Only that
    // metadata-proven Group/Document path is permitted, never toolbar controls.
    bool reachedDocument = false;
    for (int depth = 0; depth < 4; ++depth) {
      ComPtr<IUIAutomationElement> parent;
      CONTROLTYPEID type = 0;
      if (FAILED(walker->GetParentElement(focusPath.back().Get(), &parent)) || !parent ||
          !SafeElement(parent.Get(), focusPid, false) ||
          !InSource(uia, walker.Get(), root.Get(), parent.Get()) ||
          FAILED(parent->get_CurrentControlType(&type)) ||
          (type != UIA_GroupControlTypeId && type != UIA_DocumentControlTypeId)) {
        puts("IA2_REJECT|group_focus_path_not_safe_group_document"); return;
      }
      focusPath.push_back(parent); focusTypes.push_back(type);
      if (type == UIA_DocumentControlTypeId) { reachedDocument = true; break; }
    }
    if (!reachedDocument) { puts("IA2_REJECT|group_focus_document_not_reached"); return; }
  } else if (focusType != UIA_DocumentControlTypeId && focusType != UIA_TextControlTypeId) {
    puts("IA2_REJECT|focused_control_not_public_document_text_group"); return;
  }
  auto validateFocusPath = [&]() {
    ComPtr<IUIAutomationElement> node = focus;
    for (size_t index = 0; index < focusPath.size(); ++index) {
      CONTROLTYPEID type = 0;
      if (!Same(uia, node.Get(), focusPath[index].Get()) ||
          !SafeElement(node.Get(), focusPid, index == 0) ||
          FAILED(node->get_CurrentControlType(&type)) || type != focusTypes[index]) return false;
      if (index + 1 < focusPath.size()) {
        ComPtr<IUIAutomationElement> parent;
        if (FAILED(walker->GetParentElement(node.Get(), &parent))) return false;
        node = parent;
      }
    }
    return true;
  };
  auto validateFocus = [&]() {
    validateNativeIdentity();
    ComPtr<IUIAutomationElement> now;
    CONTROLTYPEID nowType = 0;
    return SUCCEEDED(uia->GetFocusedElement(&now)) && now &&
        SUCCEEDED(now->get_CurrentControlType(&nowType)) && nowType == focusType &&
        Same(uia, focus.Get(), now.Get()) && SafeElement(now.Get(), focusPid, true) &&
        InSource(uia, walker.Get(), root.Get(), now.Get()) && validateFocusPath();
  };
  NativeFocusChain originalChain;
  if (!SnapshotNativeFocus(source, validateFocus, &originalChain)) {
    puts("IA2_BOUND_REJECT|initial_native_focus"); return;
  }
  const long terminalRole = originalChain.roles.back();
  const long terminalState = originalChain.states.back();
  // This experiment is restricted to the already observed readonly PDF Pane.
  if (terminalRole != ROLE_SYSTEM_PANE || !(terminalState & STATE_SYSTEM_FOCUSED) ||
      !(terminalState & STATE_SYSTEM_READONLY)) {
    puts("IA2_BOUND_REJECT|unexpected_terminal_role_state"); return;
  }
  ChromiumServiceCandidate bound;
  if (!QueryChromiumService(originalChain.objects.back().Get(), source, validateFocus, &bound)) {
    puts("IA2_BOUND_REJECT|initial_service_identity"); return;
  }
  long serviceRole = 0, serviceState = 0;
  if (!NativeMetadata(bound.accessible.Get(), &serviceRole, &serviceState) ||
      serviceRole != terminalRole || serviceState != terminalState) {
    puts("IA2_BOUND_REJECT|service_role_state"); return;
  }
  long boundId = 0; HWND boundWindow = nullptr;
  if (bound.core->get_uniqueID(&boundId) != S_OK || boundId >= 0 ||
      bound.core->get_windowHandle(&boundWindow) != S_OK || !boundWindow) {
    puts("IA2_BOUND_REJECT|initial_uniqueid_window"); return;
  }
  DWORD boundWindowPid = 0, boundSourcePid = 0;
  GetWindowThreadProcessId(boundWindow, &boundWindowPid);
  GetWindowThreadProcessId(source, &boundSourcePid);
  if (!boundSourcePid || boundWindowPid != boundSourcePid ||
      GetAncestor(boundWindow, GA_ROOT) != source || !validateFocus()) {
    puts("IA2_BOUND_REJECT|initial_window_binding"); return;
  }
  const GUID propertyGuid = {0xcc7eeb32, 0x4b62, 0x4f4c,
      {0xaf, 0xf6, 0x1c, 0x2e, 0x57, 0x52, 0xad, 0x8e}};
  ComPtr<IUIAutomationRegistrar> registrar;
  hr = CoCreateInstance(CLSID_CUIAutomationRegistrar, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&registrar));
  if (hr != S_OK || !registrar) return;
  UIAutomationPropertyInfo propertyInfo = {propertyGuid, L"UniqueId", UIAutomationType_String};
  PROPERTYID propertyId = 0;
  hr = registrar->RegisterProperty(&propertyInfo, &propertyId);
  Hr("bound_RegisterProperty_process_lifetime_only", hr);
  if (hr != S_OK || propertyId <= 0) return;
  int validationCount = 0;
  auto validateCandidate = [&]() {
    ++validationCount;
    if (!validateFocus() || !SafeAccessible(bound.accessible.Get(), source)) return false;
    NativeFocusChain freshChain;
    if (!SnapshotNativeFocus(source, validateFocus, &freshChain) ||
        freshChain.objects.size() != originalChain.objects.size() ||
        freshChain.roles != originalChain.roles || freshChain.states != originalChain.states) {
      puts("IA2_BOUND_REJECT|fresh_native_focus_structure"); return false;
    }
    ChromiumServiceCandidate fresh;
    if (!QueryChromiumService(freshChain.objects.back().Get(), source, validateFocus, &fresh)) return false;
    const bool sameCanonicalService = fresh.identity.Get() == bound.identity.Get();
    printf("IA2_BOUND_FRESH_SERVICE|validation=%d|sameCanonicalService=%d\n",
        validationCount, sameCanonicalService);
    if (!sameCanonicalService) return false;
    long freshRole = 0, freshState = 0, retainedRole = 0, retainedState = 0;
    if (!NativeMetadata(fresh.accessible.Get(), &freshRole, &freshState) ||
        !NativeMetadata(bound.accessible.Get(), &retainedRole, &retainedState) ||
        freshRole != serviceRole || retainedRole != serviceRole ||
        freshState != serviceState || retainedState != serviceState ||
        !SafeAccessible(fresh.accessible.Get(), source) ||
        !SafeAccessible(bound.accessible.Get(), source)) return false;
    long freshId = 0, retainedId = 0; HWND freshWindow = nullptr, retainedWindow = nullptr;
    if (fresh.core->get_uniqueID(&freshId) != S_OK || freshId != boundId ||
        bound.core->get_uniqueID(&retainedId) != S_OK || retainedId != boundId ||
        fresh.core->get_windowHandle(&freshWindow) != S_OK || freshWindow != boundWindow ||
        bound.core->get_windowHandle(&retainedWindow) != S_OK || retainedWindow != boundWindow) return false;
    DWORD nowWindowPid = 0, nowSourcePid = 0;
    GetWindowThreadProcessId(boundWindow, &nowWindowPid);
    GetWindowThreadProcessId(source, &nowSourcePid);
    if (nowWindowPid != boundWindowPid || nowSourcePid != boundSourcePid ||
        GetAncestor(boundWindow, GA_ROOT) != source || !validateFocus()) return false;
    VARIANT value{};
    const HRESULT valueHr = focus->GetCurrentPropertyValueEx(propertyId, TRUE, &value);
    const bool supported = valueHr == S_OK && value.vt == VT_BSTR && value.bstrVal &&
        SysStringLen(value.bstrVal) > 0 && SysStringLen(value.bstrVal) <= 11;
    const bool sameExactNode = supported &&
        std::wstring(value.bstrVal, SysStringLen(value.bstrVal)) == std::to_wstring(boundId);
    VariantClear(&value);
    const bool sourceStillValid = validateFocus() &&
        SafeAccessible(bound.accessible.Get(), source) && SafeAccessible(fresh.accessible.Get(), source);
    printf("IA2_BOUND_EXACT_NODE|validation=%d|sameExactNode=%d|sourceStillValid=%d\n",
        validationCount, sameExactNode, sourceStillValid);
    return sameExactNode && sourceStillValid;
  };
  // Independent admission: fresh service canonical identity AND Chromium's
  // documented shared node ID. Never admit using MSAA wrapper similarity.
  if (!validateCandidate()) { puts("IA2_BOUND_REJECT|pre_selection_identity"); return; }
  bool consumed = false;
  ReadSelected(bound.text, validateCandidate, 200, &consumed);
  printf("IA2_BOUND_DONE|selected_text_read_consumed=%d|validationCount=%d|diagnostic_only=1\n",
      consumed, validationCount);
}
}  // namespace edge_pdf_ia2
