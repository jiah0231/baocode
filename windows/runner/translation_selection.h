#ifndef RUNNER_TRANSLATION_SELECTION_H_
#define RUNNER_TRANSLATION_SELECTION_H_
#include <windows.h>
#include <UIAutomation.h>
#include <wrl/client.h>
#include <string>
#include <optional>
#include <cstdint>
#include "translation_panel_geometry.h"
#include "translation_capture_retry.h"
#include "translation_clipboard_capture.h"
#include "translation_console_binding.h"
#include "translation_selection_target.h"
#if defined(BAOCODE_CAPTURE_FOREGROUND_TIMEOUT_CONTINUATION) && \
    !defined(BAOCODE_CAPTURE_FOREGROUND_CONNECTION_EXPERIMENT)
#error Timeout continuation requires the foreground connection diagnostic experiment.
#endif

#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY) && \
    !defined(BAOCODE_CAPTURE_FOREGROUND_TIMEOUT_CONTINUATION)
#error Shared discovery requires the timeout continuation diagnostic experiment.
#endif
#if defined(BAOCODE_CAPTURE_FOREGROUND_METADATA_BUDGET) && \
    !defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
#error Metadata root budget requires shared discovery accounting.
#endif

namespace translation_selection {
// Optional test diagnostics contain only operation names/HRESULTs, never text.
struct FocusAttemptDiagnostics {
  ULONGLONG started_ms = 0, elapsed_ms = 0, remaining_ms = 0;
  ULONGLONG starting_remaining_ms = 0;
  DWORD connection_ms = 0, transaction_ms = 0;
  HRESULT result = S_OK;
  bool completed = false;
};
struct CaptureDiagnostics {
  const char* last_failure_stage = "none";
  HRESULT last_failure = S_OK;
  unsigned attempts = 0;
  unsigned final_attempts = 0;
  unsigned initial_discovery_calls = 0;
  FocusAttemptDiagnostics com_initialize, automation_create, foreground_connection;
  bool foreground_connection_timeout_continued = false;
  FocusAttemptDiagnostics focus_attempts[translation_retry::kMaxAttempts];
  FocusAttemptDiagnostics final_focus_attempts[3];
  DWORD console_host_integrity = 0, console_client_integrity = 0;
  SelectionTargetDiagnostics target;
  const char* bounds_stage = "notRequested";
  HRESULT bounds_result = S_OK;
  unsigned bounds_rectangles = 0, bounds_dimensions = 0;
  VARTYPE bounds_vartype = VT_EMPTY;
  LONG bounds_lower = 0, bounds_upper = -1;
  double bounds_first[4]{};
  RECT bounds_source{};
};
struct Selection {
  std::wstring text;
  std::string status = "unsupported";
  bool self = false;
  std::optional<RECT> bounds;
  std::optional<translation_clipboard::Proof> copy_proof;
  std::optional<RECT> area;  // Visible selection union, used only to avoid covering it.
};
// Bounding rectangles are optional. A broken geometry provider must neither
// expose arbitrary data nor invalidate otherwise valid selected text.
inline std::optional<RECT> ReadBounds(IUIAutomationTextRange* range,
                                      HWND foreground, CaptureDiagnostics* diagnostics = nullptr,
                                      std::optional<RECT>* area = nullptr) {
  if (area) area->reset();
  SAFEARRAY* values = nullptr;
  const HRESULT read = range->GetBoundingRectangles(&values);
  if (diagnostics) {
    diagnostics->bounds_stage = FAILED(read) ? "GetBoundingRectangles.failed" : "invalidOrEmptyArray";
    diagnostics->bounds_result = read;
    diagnostics->bounds_rectangles = 0;
    diagnostics->bounds_dimensions = values ? SafeArrayGetDim(values) : 0;
    diagnostics->bounds_vartype = VT_EMPTY;
    diagnostics->bounds_lower = 0;
    diagnostics->bounds_upper = -1;
    diagnostics->bounds_source = RECT{};
    for (double& value : diagnostics->bounds_first) value = 0;
  }
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
        if (diagnostics) {
          diagnostics->bounds_stage = "noValidSourceIntersection";
          diagnostics->bounds_rectangles = static_cast<unsigned>(count / 4);
          diagnostics->bounds_source = source;
          for (int i = 0; i < 4; ++i) diagnostics->bounds_first[i] = data[i];
        }
        for (int i = 0; i < count; i += 4) {
          const auto checked = translation_panel::SelectionRect(
              data[i], data[i + 1], data[i + 2], data[i + 3]);
          if (!checked) continue;
          const RECT rect{checked->left, checked->top, checked->right, checked->bottom};
          RECT clipped = {};
          if (IntersectRect(&clipped, &rect, &source) &&
              MonitorFromRect(&clipped, MONITOR_DEFAULTTONULL)) {
            result = clipped;
            if (area) {
              if (*area) { RECT combined{}; UnionRect(&combined, &**area, &clipped); *area = combined; }
              else *area = clipped;
            }
          }
        }
      }
      SafeArrayUnaccessData(values);
    }
  }
  if (diagnostics) {
    diagnostics->bounds_vartype = type;
    diagnostics->bounds_lower = lower;
    diagnostics->bounds_upper = upper;
  }
  if (values) SafeArrayDestroy(values);
  if (result && diagnostics) diagnostics->bounds_stage = "accepted";
  return result;
}
// BSTRs are length-delimited, but downstream native string conversion is not.
// Never return a prefix of a selection containing an embedded null.
inline void RejectEmbeddedNull(Selection& selection) {
  if (selection.text.find(L'\0') != std::wstring::npos) {
    selection.text.clear();
    selection.status = "unsupported";
    selection.bounds.reset();
    selection.area.reset();
  }
}
// Call only on an MTA worker after an explicit user action. Never reads the
// clipboard, ValuePattern, document range, or arbitrary window captions.
inline Selection Capture(HWND foreground, bool explicit_shortcut = false,
                         const std::atomic<bool>* canceled = nullptr,
                         ULONGLONG deadline = 0,
                         CaptureDiagnostics* diagnostics = nullptr) {
  if (diagnostics) *diagnostics = CaptureDiagnostics{};
  const ULONGLONG diagnostic_started = diagnostics ? GetTickCount64() : 0;
  DWORD diagnostic_connection_ms = 0, diagnostic_transaction_ms = 0;
  const auto start_diagnostic = [&](FocusAttemptDiagnostics* record) {
    if (!record) return;
    const ULONGLONG now = GetTickCount64();
    record->started_ms = now - diagnostic_started;
    record->starting_remaining_ms = now < deadline ? deadline - now : 0;
    record->connection_ms = diagnostic_connection_ms;
    record->transaction_ms = diagnostic_transaction_ms;
  };
  const auto finish_diagnostic = [&](FocusAttemptDiagnostics* record, HRESULT hr) {
    if (!record) return;
    const ULONGLONG now = GetTickCount64();
    record->elapsed_ms = now - diagnostic_started - record->started_ms;
    record->remaining_ms = now < deadline ? deadline - now : 0;
    record->result = hr;
    record->completed = true;
  };
  const auto observe = [&](const char* stage, HRESULT hr) {
    if (diagnostics && FAILED(hr)) {
      diagnostics->last_failure_stage = stage;
      diagnostics->last_failure = hr;
    }
    return hr;
  };
  if (!deadline) deadline = GetTickCount64() + 1500;
  const auto stopped = [&] {
    return (canceled && canceled->load()) || GetTickCount64() >= deadline;
  };
  Selection out;
  DWORD process = 0;
  GetWindowThreadProcessId(foreground, &process);
  out.self = process == GetCurrentProcessId();
  if (!foreground) return out;
  if (stopped()) {
    out.status = canceled && canceled->load() ? "canceled" : "timeout";
    return out;
  }
  if (GetForegroundWindow() != foreground) { out.status = "focusChanged"; return out; }
  auto* initialize_record = diagnostics ? &diagnostics->com_initialize : nullptr;
  start_diagnostic(initialize_record);
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  finish_diagnostic(initialize_record, initialized);
  if (FAILED(initialized)) return out;
  {
    using Microsoft::WRL::ComPtr;
    ComPtr<IUIAutomation> automation;
    auto* create_record = diagnostics ? &diagnostics->automation_create : nullptr;
    start_diagnostic(create_record);
    const HRESULT created = CoCreateInstance(CLSID_CUIAutomation8, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation));
    finish_diagnostic(create_record, created);
    if (SUCCEEDED(created)) {
      ComPtr<IUIAutomation2> bounded;
      const auto set_connection_timeout = [&](DWORD timeout) {
        const HRESULT hr = bounded->put_ConnectionTimeout(timeout);
        if (diagnostics && SUCCEEDED(hr)) diagnostic_connection_ms = timeout;
        return hr;
      };
      const auto set_transaction_timeout = [&](DWORD timeout) {
        const HRESULT hr = bounded->put_TransactionTimeout(timeout);
        if (diagnostics && SUCCEEDED(hr)) diagnostic_transaction_ms = timeout;
        return hr;
      };
      if (SUCCEEDED(automation.As(&bounded))) {
        set_connection_timeout(300);
        set_transaction_timeout(500);
      }
      ComPtr<IUIAutomationElement> original_element;
      bool require_text_control = false;
      ConsoleBinding console_binding;
      SelectionTarget selection_target;
      const auto source_process_matches = [&](DWORD provider, IUIAutomationElement* element) {
        if (provider == process) return true;
        ConsoleBindingDiagnostics host_diagnostics;
        const bool verified = console_binding.Verify(foreground, process, provider,
            automation.Get(), element, stopped, deadline, &host_diagnostics);
        if (diagnostics) {
          diagnostics->console_host_integrity = host_diagnostics.host_integrity;
          diagnostics->console_client_integrity = host_diagnostics.client_integrity;
          if (!verified) {
            diagnostics->last_failure_stage = host_diagnostics.stage;
            diagnostics->last_failure = E_ACCESSDENIED;
          }
        }
        return verified;
      };
#if defined(BAOCODE_CAPTURE_FOREGROUND_CONNECTION_EXPERIMENT)
      DWORD connection_source_pid = 0;
      const DWORD foreground_connection_source_thread =
          GetWindowThreadProcessId(foreground, &connection_source_pid);
      const auto source_current = [&] {
        DWORD current_pid = 0;
        const DWORD current_thread = GetWindowThreadProcessId(foreground, &current_pid);
        return foreground_connection_source_thread &&
            current_thread == foreground_connection_source_thread &&
            connection_source_pid == process && current_pid == process &&
            GetForegroundWindow() == foreground &&
            GetAncestor(foreground, GA_ROOT) == foreground;
      };
#endif
      const auto ready = [&] {
        const ULONGLONG now = GetTickCount64();
        if (stopped() || now >= deadline || GetForegroundWindow() != foreground) return false;
        if (!bounded) return false;
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
        if (!source_current()) return false;
#endif
        const DWORD remaining = static_cast<DWORD>(std::min<ULONGLONG>(200, deadline - now));
        return SUCCEEDED(set_connection_timeout(std::min<DWORD>(150, remaining))) &&
            !stopped() && SUCCEEDED(set_transaction_timeout(remaining)) && !stopped();
      };
#if defined(BAOCODE_CAPTURE_FOREGROUND_CONNECTION_EXPERIMENT)
#if !defined(BAOCODE_DISPOSABLE_UI_TEST_BUILD)
#error Foreground connection experiment requires a disposable native test build.
#endif
      // Diagnostic experiment, never a pre-request provider warm-up. Connect
      // only to the verified foreground HWND inside this request's deadline.
      // The root is retained as a connection, NEVER as a selection target.
      // No root properties, patterns, text, children or descendants are read.
      ComPtr<IUIAutomationElement> foreground_connection;
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
      bool foreground_connection_called = false;
#endif
#if defined(BAOCODE_CAPTURE_FOREGROUND_TIMEOUT_CONTINUATION)
      bool foreground_connection_timeout_continued = false;
#endif
      const bool foreground_connection_permitted = [&] {
        if (stopped()) return false;
        if (!source_current()) { out.status = "focusChanged"; return false; }
        wchar_t source_class[64] = {};
        if (!GetClassNameW(foreground, source_class, 64) ||
            _wcsicmp(source_class, L"Chrome_WidgetWin_1") != 0) return true;
        if (!bounded) return false;
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) return false;
        const DWORD remaining = static_cast<DWORD>(deadline - now);
#if defined(BAOCODE_CAPTURE_FOREGROUND_METADATA_BUDGET)
        constexpr DWORD root_connection_ms = 150, root_transaction_ms = 200;
#else
        constexpr DWORD root_connection_ms = 300, root_transaction_ms = 500;
#endif
        if (FAILED(set_connection_timeout(std::min(root_connection_ms, remaining))) ||
            stopped() || !source_current() ||
            FAILED(set_transaction_timeout(std::min(root_transaction_ms, remaining))) ||
            stopped() || !source_current()) return false;
        auto* connection_record = diagnostics ? &diagnostics->foreground_connection : nullptr;
        start_diagnostic(connection_record);
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
        foreground_connection_called = true;
#endif
        if (diagnostics) ++diagnostics->initial_discovery_calls;
        const HRESULT connected = observe("ForegroundConnection.ElementFromHandle",
            automation->ElementFromHandle(foreground, &foreground_connection));
        finish_diagnostic(connection_record, connected);
        if (stopped()) return false;
        if (!source_current()) { out.status = "focusChanged"; return false; }
        if (SUCCEEDED(connected)) return foreground_connection != nullptr;
#if defined(BAOCODE_CAPTURE_FOREGROUND_TIMEOUT_CONTINUATION)
        // Only an exact transient timeout can continue to the original focus
        // query. No root identity/text was accepted. Access denial, unsupported,
        // empty successful results and all other failures still stop above/below.
        foreground_connection_timeout_continued =
            translation_retry::CanContinueAfterForegroundConnection(
                static_cast<uint32_t>(connected), original_element != nullptr,
                source_current(), foreground_connection_timeout_continued,
                GetTickCount64(), deadline, canceled && canceled->load());
        if (diagnostics) diagnostics->foreground_connection_timeout_continued =
            foreground_connection_timeout_continued;
        return foreground_connection_timeout_continued;
#else
        return false;
#endif
      }();
#endif
      // Chromium may expose a focused Document before its accessibility text
      // pattern is ready, or time out before returning any element. Reacquire
      // only that initial timeout; once bound, retry the same security-checked
      // identity. Never scan descendants or change focus.
      for (unsigned attempt = 0; attempt < translation_retry::kMaxAttempts && !stopped()
#if defined(BAOCODE_CAPTURE_FOREGROUND_CONNECTION_EXPERIMENT)
          && foreground_connection_permitted
#endif
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
          && attempt < translation_retry::FocusDiscoveryLimit(foreground_connection_called)
#elif defined(BAOCODE_CAPTURE_FOREGROUND_TIMEOUT_CONTINUATION)
          && (!foreground_connection_timeout_continued || attempt == 0)
#endif
          ; ++attempt) {
        if (diagnostics) diagnostics->attempts = attempt + 1;
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
        const unsigned completed_attempts = translation_retry::DiscoveryCompleted(
            attempt + 1, foreground_connection_called);
#else
        const unsigned completed_attempts = attempt + 1;
#endif
        bool retryable = false;
        out = Selection{};
        out.self = process == GetCurrentProcessId();
        if (GetForegroundWindow() != foreground) { out.status = "focusChanged"; break; }
        if (bounded) {
          const ULONGLONG now = GetTickCount64();
          if (now >= deadline) break;
          const DWORD remaining = static_cast<DWORD>(deadline - now);
          // The first accessibility connection can wake Chromium's lazy tree.
          // Give discovery the original 500ms transaction budget, but never
          // exceed this request's remaining lifetime. Bound later transactions.
          const DWORD connection = original_element ? 150 : 300;
          const DWORD transaction = original_element ? 200 : 500;
          if (FAILED(set_connection_timeout(std::min(connection, remaining))) ||
              FAILED(set_transaction_timeout(std::min(transaction, remaining)))) break;
        }
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
        if (stopped()) break;
        if (!source_current()) { out.status = "focusChanged"; break; }
#elif defined(BAOCODE_CAPTURE_FOREGROUND_TIMEOUT_CONTINUATION)
        if (foreground_connection_timeout_continued) {
          if (stopped()) break;
          if (!source_current()) { out.status = "focusChanged"; break; }
        }
#endif
        ComPtr<IUIAutomationElement> focused;
        auto* focus_record = diagnostics ? &diagnostics->focus_attempts[attempt] : nullptr;
        start_diagnostic(focus_record);
        if (diagnostics) ++diagnostics->initial_discovery_calls;
        const HRESULT focus_result = observe("GetFocusedElement", automation->GetFocusedElement(&focused));
        finish_diagnostic(focus_record, focus_result);
        if (stopped()) break;
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
        if (!source_current()) { out.status = "focusChanged"; break; }
#endif
        if (GetForegroundWindow() != foreground) { out.status = "focusChanged"; break; }
        retryable = translation_retry::CanRetryInitialFocus(
            static_cast<uint32_t>(focus_result), original_element != nullptr,
            GetForegroundWindow() == foreground, completed_attempts, GetTickCount64(), deadline,
            canceled && canceled->load());
        if (SUCCEEDED(focus_result) && focused) {
          // The longer budget is solely for initial focus discovery, not for
          // later security properties or reading selection text.
          if (bounded) {
            const ULONGLONG now = GetTickCount64();
            if (now >= deadline) break;
            const DWORD remaining = static_cast<DWORD>(deadline - now);
            if (FAILED(set_connection_timeout(std::min<DWORD>(150, remaining))) ||
                FAILED(set_transaction_timeout(std::min<DWORD>(200, remaining)))) break;
          }
          int focused_process = 0;
          BOOL password = TRUE;
          BOOL has_focus = FALSE;
          // Fail closed if the provider cannot affirm this is not a password.
          if (!stopped() && SUCCEEDED(observe("ProcessId", focused->get_CurrentProcessId(&focused_process))) &&
              source_process_matches(static_cast<DWORD>(focused_process), focused.Get()) &&
              !stopped() && SUCCEEDED(observe("HasKeyboardFocus", focused->get_CurrentHasKeyboardFocus(&has_focus))) &&
              !stopped() && SUCCEEDED(observe("IsPassword", focused->get_CurrentIsPassword(&password)))) {
            if (password) {
              out.status = "password";
            } else if (!has_focus) {
              CONTROLTYPEID initial_type = 0;
              wchar_t source_class[64] = {};
              const bool known_type = !stopped() &&
                  SUCCEEDED(observe("InitialPane.ControlType", focused->get_CurrentControlType(&initial_type)));
              const bool chromium = GetClassNameW(foreground, source_class, 64) &&
                  _wcsicmp(source_class, L"Chrome_WidgetWin_1") == 0;
              retryable = translation_retry::IsInitialChromiumPane(
                  original_element != nullptr, GetForegroundWindow() == foreground,
                  static_cast<DWORD>(focused_process) == process, password == FALSE,
                  has_focus == FALSE, known_type && initial_type == UIA_PaneControlTypeId, chromium);
              if (retryable) {
                require_text_control = true;
                if (diagnostics) {
                  diagnostics->last_failure_stage = "InitialPane.notReady";
                  diagnostics->last_failure = S_FALSE;
                }
              }
            } else {
              if (!selection_target.Resolve(automation.Get(), focused.Get(), foreground,
                      static_cast<DWORD>(focused_process), ready, true,
                      diagnostics ? &diagnostics->target : nullptr)) {
                if (diagnostics) {
                  diagnostics->last_failure_stage = diagnostics->target.stage;
                  diagnostics->last_failure = diagnostics->target.result;
                }
                out.status = "focusChanged";
                break;
              }
              original_element = selection_target.Get();
              ComPtr<IUIAutomationElement> target = original_element;
              if (stopped()) break;
              CONTROLTYPEID control_type = 0;
              const bool text_control = SUCCEEDED(target->get_CurrentControlType(&control_type)) &&
                  (control_type == UIA_EditControlTypeId || control_type == UIA_DocumentControlTypeId);
              if (stopped() || (require_text_control && !text_control)) break;
              ComPtr<IUIAutomationTextPattern> pattern;
              const HRESULT pattern_result = observe("TextPattern", target->GetCurrentPatternAs(
                  UIA_TextPatternId, IID_PPV_ARGS(&pattern)));
              if (SUCCEEDED(pattern_result) && !pattern) observe("TextPattern.null", E_NOINTERFACE);
              retryable = text_control &&
                  (pattern_result == UIA_E_NOTSUPPORTED || pattern_result == E_NOINTERFACE ||
                   pattern_result == E_FAIL || (SUCCEEDED(pattern_result) && !pattern));
              // Only an explicitly unsupported pattern can qualify for copying.
              // Provider failures, timeouts and collapsed selections never do.
              if (explicit_shortcut &&
                  (pattern_result == UIA_E_NOTSUPPORTED || pattern_result == E_NOINTERFACE ||
                   (SUCCEEDED(pattern_result) && !pattern))) {
                CONTROLTYPEID type = 0;
                UIA_HWND native = {};
                DWORD source_process = 0, focus_process = 0;
                const DWORD thread = GetWindowThreadProcessId(foreground, &source_process);
                GUITHREADINFO info = {};
                info.cbSize = sizeof(info);
                if (SUCCEEDED(focused->get_CurrentControlType(&type)) &&
                    type == UIA_EditControlTypeId &&
                    SUCCEEDED(focused->get_CurrentNativeWindowHandle(&native)) && native &&
                    GetGUIThreadInfo(thread, &info) &&
                    info.hwndFocus == reinterpret_cast<HWND>(native) &&
                    GetWindowThreadProcessId(info.hwndFocus, &focus_process) == thread &&
                    source_process == process && focus_process == process &&
                    GetAncestor(info.hwndFocus, GA_ROOT) == foreground &&
                    GetForegroundWindow() == foreground) {
                  out.copy_proof = translation_clipboard::Proof{
                      foreground, info.hwndFocus, process, thread, true, true, true};
                }
              }
              if (SUCCEEDED(pattern_result) && pattern) {
                ComPtr<IUIAutomationTextRangeArray> ranges;
                if (stopped()) break;
                const HRESULT selected = observe("GetSelection", pattern->GetSelection(&ranges));
                if (SUCCEEDED(selected) && !ranges) observe("GetSelection.null", E_NOINTERFACE);
                retryable = text_control &&
                    (selected == UIA_E_NOTSUPPORTED || selected == E_NOINTERFACE ||
                     selected == E_FAIL || (SUCCEEDED(selected) && !ranges));
                if (SUCCEEDED(selected) && ranges) {
                  if (stopped()) break;
                  int length = 0;
                  if (SUCCEEDED(observe("Selection.Length", ranges->get_Length(&length)))) {
                    out.status = length > 16 ? "tooLong" : "noSelection";
                    retryable = length == 0 && selection_target.NoteEmpty(ready);
                    // Request one extra UTF-16 unit to detect overflow, never
                    // accept a truncated source or a partial multi-range result.
                    bool failed = length < 0;
                    for (int i = 0; i < length && length <= 16; ++i) {
                      if (stopped()) { failed = true; break; }
                      ComPtr<IUIAutomationTextRange> range;
                      if (FAILED(observe("Selection.GetElement", ranges->GetElement(i, &range))) || !range) {
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
                      if (stopped()) { failed = true; break; }
                      BSTR text = nullptr;
                      const HRESULT read = observe("Selection.GetText", range->GetText(
                          static_cast<int>(8001 - out.text.size()), &text));
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
                      if (!stopped()) {
                        std::optional<RECT> range_area;
                        const auto bounds = ReadBounds(range.Get(), foreground, diagnostics, &range_area);
                        if (bounds) out.bounds = bounds;
                        if (range_area) {
                          if (out.area) { RECT combined{}; UnionRect(&combined, &*out.area, &*range_area); out.area = combined; }
                          else out.area = range_area;
                        }
                      }
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
#if defined(BAOCODE_CAPTURE_FOREGROUND_TIMEOUT_CONTINUATION) && \
    !defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
        // One original discovery attempt after a root timeout, not a fresh
        // four-attempt allowance. Preserve final validation of successful text.
        if (foreground_connection_timeout_continued) break;
#endif
        if ((out.status != "unsupported" && out.status != "noSelection") ||
            !translation_retry::CanRetry(retryable, completed_attempts, GetTickCount64(), deadline,
                                         canceled && canceled->load())) break;
        // Small interruptible backoff, no replacement workers or provider retry
        // after cancellation. Empty selection/password/unknown controls stop above.
        const ULONGLONG wake = std::min<ULONGLONG>(deadline, GetTickCount64() + translation_retry::Delay(completed_attempts));
        while (GetTickCount64() < wake && !stopped() && GetForegroundWindow() == foreground) Sleep(5);
      }
      // A source can switch controls without changing its foreground HWND.
      // Chromium may also briefly return its unfocused root Pane again while
      // its accessibility tree initializes. Only requery metadata for that
      // narrow case or the exact UIA timeout, within the ORIGINAL deadline.
      // Keep original_element pinned: never read more text or bind another
      // element here. A genuinely different focused control rejects at once.
      if (original_element && !stopped() && (out.status == "ok" || out.copy_proof)) {
        bool verified = false;
        for (unsigned check = 0; check < 3 && !stopped(); ++check) {
          if (diagnostics) diagnostics->final_attempts = check + 1;
          if (GetForegroundWindow() != foreground) break;
          if (bounded) {
            const ULONGLONG now = GetTickCount64();
            if (now >= deadline) break;
            const DWORD remaining = static_cast<DWORD>(deadline - now);
            if (FAILED(set_connection_timeout(std::min<DWORD>(150, remaining))) ||
                FAILED(set_transaction_timeout(std::min<DWORD>(200, remaining)))) break;
          }
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
          if (stopped() || !source_current()) break;
#endif
          ComPtr<IUIAutomationElement> final_focus;
          auto* final_record = diagnostics ? &diagnostics->final_focus_attempts[check] : nullptr;
          start_diagnostic(final_record);
          const HRESULT final_result = observe("FinalFocus.GetFocusedElement",
              automation->GetFocusedElement(&final_focus));
          finish_diagnostic(final_record, final_result);
          if (stopped() || GetForegroundWindow() != foreground) break;
#if defined(BAOCODE_CAPTURE_FOREGROUND_SHARED_DISCOVERY)
          if (!source_current()) break;
#endif
          bool transient_pane = false;
          if (SUCCEEDED(final_result) && final_focus) {
            int final_process = 0;
            BOOL final_password = TRUE, final_has_focus = FALSE;
            if (FAILED(observe("FinalFocus.ProcessId", final_focus->get_CurrentProcessId(&final_process))) ||
                !source_process_matches(static_cast<DWORD>(final_process), final_focus.Get()) || stopped() ||
                FAILED(observe("FinalFocus.IsPassword", final_focus->get_CurrentIsPassword(&final_password))) ||
                final_password || stopped() ||
                FAILED(observe("FinalFocus.HasKeyboardFocus", final_focus->get_CurrentHasKeyboardFocus(&final_has_focus))) ||
                stopped()) break;
            if (final_has_focus) {
              verified = selection_target.Resolve(automation.Get(), final_focus.Get(), foreground,
                  static_cast<DWORD>(final_process), ready, false,
                  diagnostics ? &diagnostics->target : nullptr);
              if (!verified && diagnostics) {
                diagnostics->last_failure_stage = "FinalFocus.DifferentElement";
                diagnostics->last_failure = S_FALSE;
              }
              break;
            }
            CONTROLTYPEID final_type = 0;
            wchar_t source_class[64] = {};
            const bool pane = !stopped() &&
                SUCCEEDED(observe("FinalFocus.ControlType", final_focus->get_CurrentControlType(&final_type))) &&
                final_type == UIA_PaneControlTypeId;
            const bool chromium = GetClassNameW(foreground, source_class, 64) &&
                _wcsicmp(source_class, L"Chrome_WidgetWin_1") == 0;
            // This checks only the transient Pane's metadata. It does not
            // replace original_element or authorize reading the Pane itself.
            transient_pane = pane && chromium && final_password == FALSE &&
                final_has_focus == FALSE && GetForegroundWindow() == foreground;
            if (transient_pane && diagnostics) {
              diagnostics->last_failure_stage = "FinalFocus.TransientPane";
              diagnostics->last_failure = S_FALSE;
            }
          }
          const bool exact_timeout = translation_retry::IsFocusTimeout(
              static_cast<uint32_t>(final_result));
          if (!translation_retry::CanRetryFinalFocus(true, GetForegroundWindow() == foreground,
                  exact_timeout, transient_pane, check + 1, GetTickCount64(), deadline,
                  canceled && canceled->load())) break;
          const ULONGLONG wake = std::min<ULONGLONG>(deadline,
              GetTickCount64() + translation_retry::Delay(check + 1));
          while (GetTickCount64() < wake && !stopped() &&
                 GetForegroundWindow() == foreground) Sleep(5);
        }
        if (!verified) {
          out = Selection{};
          out.status = "focusChanged";
        }
      }
    }
  }
  CoUninitialize();
  if (stopped()) {
    out = Selection{};
    out.status = canceled && canceled->load() ? "canceled" : "timeout";
  }
  RejectEmbeddedNull(out);
  // Do not deliver text from an app the user switched away from meanwhile.
  if (GetForegroundWindow() != foreground) {
    out.text.clear();
    out.status = "focusChanged";
  }
  if (out.status != "ok") { out.bounds.reset(); out.area.reset(); }
  if (out.status != "unsupported") out.copy_proof.reset();
  return out;
}
}  // namespace translation_selection
#endif
