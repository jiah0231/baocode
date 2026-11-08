#ifndef RUNNER_TRANSLATION_SELECTION_H_
#define RUNNER_TRANSLATION_SELECTION_H_
#include <windows.h>
#include <UIAutomation.h>
#include <wrl/client.h>
#include <string>

namespace translation_selection {
struct Selection {
  std::wstring text;
  std::string status = "unsupported";
  bool self = false;
};
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
                    BSTR text = nullptr;
                    const HRESULT read = range->GetText(
                        static_cast<int>(8001 - out.text.size()), &text);
                    if (SUCCEEDED(read) && text) out.text.append(text, SysStringLen(text));
                    const bool has_text = text != nullptr;
                    SysFreeString(text);
                    if (FAILED(read) || !has_text) { failed = true; break; }
                    if (out.text.size() > 8000) { out.status = "tooLong"; break; }
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
  // Do not deliver text from an app the user switched away from meanwhile.
  if (GetForegroundWindow() != foreground) {
    out.text.clear();
    out.status = "focusChanged";
  }
  return out;
}
}  // namespace translation_selection
#endif
