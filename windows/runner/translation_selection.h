#ifndef RUNNER_TRANSLATION_SELECTION_H_
#define RUNNER_TRANSLATION_SELECTION_H_
#include <windows.h>
#include <UIAutomation.h>
#include <wrl/client.h>
#include <string>
#include <optional>
#include <cstdint>
#include "translation_panel_geometry.h"

namespace translation_selection {
struct Selection {
  std::wstring text;
  std::string status = "unsupported";
  bool self = false;
  std::optional<RECT> bounds;
};
// Bounding rectangles are optional. A broken geometry provider must neither
// expose arbitrary data nor invalidate otherwise valid selected text.
inline std::optional<RECT> ReadBounds(IUIAutomationTextRange* range,
                                      HWND foreground) {
  SAFEARRAY* values = nullptr;
  const HRESULT read = range->GetBoundingRectangles(&values);
  std::optional<RECT> result;
  VARTYPE type = VT_EMPTY;
  LONG lower = 0, upper = -1;
  if (SUCCEEDED(read) && values && SafeArrayGetDim(values) == 1 &&
      SUCCEEDED(SafeArrayGetVartype(values, &type)) && type == VT_R8 &&
      SUCCEEDED(SafeArrayGetLBound(values, 1, &lower)) &&
      SUCCEEDED(SafeArrayGetUBound(values, 1, &upper)) &&
      upper >= lower && static_cast<int64_t>(upper) - lower < 256 &&
      (static_cast<int64_t>(upper) - lower + 1) % 4 == 0) {
    double* data = nullptr;
    if (SUCCEEDED(SafeArrayAccessData(values, reinterpret_cast<void**>(&data)))) {
      RECT source = {};
      if (data && GetWindowRect(foreground, &source)) {
        const int count = static_cast<int>(static_cast<int64_t>(upper) - lower + 1);
        for (int i = 0; i < count && !result; i += 4) {
          const auto checked = translation_panel::SelectionRect(
              data[i], data[i + 1], data[i + 2], data[i + 3]);
          if (!checked) continue;
          const RECT rect{checked->left, checked->top, checked->right, checked->bottom};
          RECT clipped = {};
          if (IntersectRect(&clipped, &rect, &source) &&
              MonitorFromRect(&clipped, MONITOR_DEFAULTTONULL)) result = clipped;
        }
      }
      SafeArrayUnaccessData(values);
    }
  }
  if (values) SafeArrayDestroy(values);
  return result;
}
// BSTRs are length-delimited, but downstream native string conversion is not.
// Never return a prefix of a selection containing an embedded null.
inline void RejectEmbeddedNull(Selection& selection) {
  if (selection.text.find(L'\0') != std::wstring::npos) {
    selection.text.clear();
    selection.status = "unsupported";
    selection.bounds.reset();
  }
}
// Call only on an MTA worker after an explicit user action. Never reads the
// clipboard, ValuePattern, document range, or arbitrary window captions.
inline Selection Capture(HWND foreground) {
  Selection out;
  DWORD process = 0;
  GetWindowThreadProcessId(foreground, &process);
  out.self = process == GetCurrentProcessId();
  if (!foreground) return out;
  if (GetForegroundWindow() != foreground) { out.status = "focusChanged"; return out; }
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return out;
  {
    using Microsoft::WRL::ComPtr;
    ComPtr<IUIAutomation> automation;
    if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&automation)))) {
      ComPtr<IUIAutomation2> bounded;
      if (SUCCEEDED(automation.As(&bounded))) {
        bounded->put_ConnectionTimeout(300);
        bounded->put_TransactionTimeout(500);
      }
      ComPtr<IUIAutomationElement> focused;
      if (SUCCEEDED(automation->GetFocusedElement(&focused)) && focused) {
        int focused_process = 0;
        BOOL password = TRUE;
        BOOL has_focus = FALSE;
        // Fail closed if the provider cannot affirm this is not a password.
        if (SUCCEEDED(focused->get_CurrentProcessId(&focused_process)) &&
            static_cast<DWORD>(focused_process) == process &&
            SUCCEEDED(focused->get_CurrentHasKeyboardFocus(&has_focus)) &&
            has_focus &&
            SUCCEEDED(focused->get_CurrentIsPassword(&password))) {
          if (password) {
            out.status = "password";
          } else {
            ComPtr<IUIAutomationTextPattern> pattern;
            if (SUCCEEDED(focused->GetCurrentPatternAs(UIA_TextPatternId,
                                                       IID_PPV_ARGS(&pattern))) && pattern) {
              ComPtr<IUIAutomationTextRangeArray> ranges;
              if (SUCCEEDED(pattern->GetSelection(&ranges)) && ranges) {
                int length = 0;
                if (SUCCEEDED(ranges->get_Length(&length))) {
                  out.status = length > 16 ? "tooLong" : "noSelection";
                  // Request one extra UTF-16 unit to detect overflow, never
                  // accept a truncated source or a partial multi-range result.
                  bool failed = length < 0;
                  for (int i = 0; i < length && length <= 16; ++i) {
                    ComPtr<IUIAutomationTextRange> range;
                    if (FAILED(ranges->GetElement(i, &range)) || !range) {
                      failed = true; break;
                    }
                    int difference = 0;
                    if (FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_Start,
                        range.Get(), TextPatternRangeEndpoint_End, &difference))) {
                      failed = true; break;
                    }
                    if (difference == 0) continue;
                    if (!out.text.empty()) out.text += L"\n";
                    if (out.text.size() > 8000) { out.status = "tooLong"; break; }
                    BSTR text = nullptr;
                    const HRESULT read = range->GetText(
                        static_cast<int>(8001 - out.text.size()), &text);
                    if (SUCCEEDED(read) && text) {
                      const UINT units = SysStringLen(text);
                      // Do not trust a provider to honor GetText's maximum.
                      if (units > 8000 - out.text.size()) out.status = "tooLong";
                      else out.text.append(text, units);
                    }
                    const bool has_text = text != nullptr;
                    SysFreeString(text);
                    if (FAILED(read) || !has_text) { failed = true; break; }
                    if (out.status == "tooLong") break;
                    if (!out.bounds) out.bounds = ReadBounds(range.Get(), foreground);
                  }
                  if (failed || out.status == "tooLong") {
                    out.text.clear();
                    if (failed) out.status = "unsupported";
                  } else if (!out.text.empty()) {
                    out.status = "ok";
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  CoUninitialize();
  RejectEmbeddedNull(out);
  // Do not deliver text from an app the user switched away from meanwhile.
  if (GetForegroundWindow() != foreground) {
    out.text.clear();
    out.status = "focusChanged";
  }
  if (out.status != "ok") out.bounds.reset();
  return out;
}
}  // namespace translation_selection
#endif
