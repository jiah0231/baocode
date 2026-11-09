#include "translation_selection_action.h"
#include <UIAutomation.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <thread>
#include <system_error>
#include <cstdint>
#include "translation_panel_geometry.h"
#include "translation_capture_retry.h"
#include "translation_action_budget.h"
#include "translation_console_binding.h"
#include "translation_selection_target.h"

#ifdef BAOCODE_TRANSLATION_ACTION_DIAGNOSTICS
#include <cstdio>
#define ACTION_TRACE(...) do { std::printf(__VA_ARGS__); std::fflush(stdout); } while (false)
#define ACTION_STAGE(value) bounds_trace.stage = value
#else
#define ACTION_TRACE(...) ((void)0)
#define ACTION_STAGE(value) ((void)0)
#endif

namespace {
#ifdef BAOCODE_TRANSLATION_ACTION_DIAGNOSTICS
struct BoundsTrace {
  HWND source;
  ULONGLONG began = GetTickCount64();
  const char* stage = "start";
  ~BoundsTrace() {
    ACTION_TRACE("ACTION_PROVIDER|source=%p|stage=%s|elapsedMs=%llu\n",
        static_cast<void*>(source), stage, GetTickCount64() - began);
  }
};
#endif
constexpr UINT kMouse = WM_APP + 0x391;
constexpr wchar_t kClass[] = L"BaoCodeTranslationSelectionAction";
TranslationSelectionAction* active = nullptr;
HWND hook_dispatcher = nullptr;
HWND hook_button = nullptr;
using Microsoft::WRL::ComPtr;

// Deliberately accepts only one noncollapsed selection. No GetText,
// ValuePattern, document range, clipboard, or keyboard monitoring is used.
std::optional<RECT> SelectionBounds(HWND source,
    ComPtr<IUIAutomationElement>& previous_element,
    ComPtr<IUIAutomationTextRange>& previous_range, bool& retryable,
    bool& require_text_control, translation_selection::SelectionTarget& selection_target,
    translation_selection::ConsoleBinding& console_binding,
    const std::function<bool()>& stopped, ULONGLONG deadline,
    ComPtr<IUIAutomation2>* transaction_control = nullptr,
    ComPtr<IUIAutomationTextRange>* validated_range = nullptr,
    std::optional<RECT>* selected_area = nullptr) {
  if (selected_area) selected_area->reset();
#ifdef BAOCODE_TRANSLATION_ACTION_DIAGNOSTICS
  BoundsTrace bounds_trace{source};
#endif
  retryable = false;
  DWORD pid = 0;
  GetWindowThreadProcessId(source, &pid);
  if (stopped() || !pid || pid == GetCurrentProcessId() || GetForegroundWindow() != source)
    return std::nullopt;
  ACTION_STAGE("createAutomation");
  ComPtr<IUIAutomation> automation;
  if (FAILED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&automation)))) return std::nullopt;
  const ULONGLONG now = GetTickCount64();
  if (stopped() || now >= deadline) return std::nullopt;
  const DWORD remaining = static_cast<DWORD>(std::min<ULONGLONG>(500, deadline - now));
  ComPtr<IUIAutomation2> bounded;
  if (FAILED(automation.As(&bounded)) || stopped() ||
      FAILED(bounded->put_ConnectionTimeout(std::min<DWORD>(previous_element ? 150 : 300, remaining))) ||
      stopped() || FAILED(bounded->put_TransactionTimeout(
          std::min<DWORD>(previous_element ? 200 : 500, remaining))) || stopped()) return std::nullopt;
  ACTION_STAGE("getFocusedElement");
  ComPtr<IUIAutomationElement> focused;
  const HRESULT focus_result = automation->GetFocusedElement(&focused);
  if (stopped()) return std::nullopt;
  if (FAILED(focus_result) || !focused) {
    // No element or text has been accepted yet. Only the exact lazy-tree
    // discovery timeout may retry; Tick supplies the shared attempt/deadline
    // budget. Once identity is bound, this never reacquires a different one.
    retryable = !previous_element && GetForegroundWindow() == source &&
        translation_retry::IsFocusTimeout(static_cast<uint32_t>(focus_result));
    return std::nullopt;
  }
  if (GetForegroundWindow() != source) return std::nullopt;
  const auto ready = [&] {
    ULONGLONG current = GetTickCount64();
    if (stopped() || current >= deadline || GetForegroundWindow() != source) return false;
    if (FAILED(bounded->put_ConnectionTimeout(static_cast<DWORD>(
            std::min<ULONGLONG>(150, deadline - current)))) || stopped()) return false;
    current = GetTickCount64();
    return current < deadline && SUCCEEDED(bounded->put_TransactionTimeout(static_cast<DWORD>(
        std::min<ULONGLONG>(200, deadline - current)))) && !stopped();
  };
  ACTION_STAGE("focusSecurityProperties");
  int focused_pid = 0;
  BOOL password = TRUE, has_focus = FALSE;
  if (!ready() || FAILED(focused->get_CurrentProcessId(&focused_pid)) ||
      (static_cast<DWORD>(focused_pid) != pid &&
       !console_binding.Verify(source, pid, static_cast<DWORD>(focused_pid), automation.Get(),
           focused.Get(), stopped, deadline)) ||
      !ready() || FAILED(focused->get_CurrentIsPassword(&password)) || password ||
      !ready() || FAILED(focused->get_CurrentHasKeyboardFocus(&has_focus)))
    return std::nullopt;
  if (!has_focus) {
    ACTION_STAGE("unfocusedInitialPane");
    CONTROLTYPEID initial_type = 0;
    wchar_t source_class[64] = {};
    const bool known_type = ready() && SUCCEEDED(focused->get_CurrentControlType(&initial_type));
    const bool chromium = GetClassNameW(source, source_class, 64) &&
        _wcsicmp(source_class, L"Chrome_WidgetWin_1") == 0;
    retryable = translation_retry::IsInitialChromiumPane(
        previous_element != nullptr, GetForegroundWindow() == source,
        static_cast<DWORD>(focused_pid) == pid, password == FALSE,
        has_focus == FALSE, known_type && initial_type == UIA_PaneControlTypeId, chromium);
    if (retryable) require_text_control = true;
    return std::nullopt;
  }
  ACTION_STAGE("resolveTarget");
  if (!selection_target.Resolve(automation.Get(), focused.Get(), source,
          static_cast<DWORD>(focused_pid), ready, !previous_range)) return std::nullopt;
  if (!previous_range) previous_element = focused;
  ComPtr<IUIAutomationElement> target = selection_target.Get();
  CONTROLTYPEID control_type = 0;
  const bool text_control = ready() && SUCCEEDED(target->get_CurrentControlType(&control_type)) &&
      (control_type == UIA_EditControlTypeId || control_type == UIA_DocumentControlTypeId);
  if (!ready() || (require_text_control && !text_control)) return std::nullopt;
  ACTION_STAGE("textPattern");
  ComPtr<IUIAutomationTextPattern> pattern;
  if (!ready()) return std::nullopt;
  const HRESULT pattern_result = target->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern));
  if (!ready()) return std::nullopt;
  if (FAILED(pattern_result) || !pattern) {
    retryable = text_control &&
        (pattern_result == UIA_E_NOTSUPPORTED || pattern_result == E_NOINTERFACE ||
         pattern_result == E_FAIL || (SUCCEEDED(pattern_result) && !pattern));
    return std::nullopt;
  }
  ACTION_STAGE("getSelection");
  ComPtr<IUIAutomationTextRangeArray> ranges;
  if (!ready()) return std::nullopt;
  const HRESULT selected = pattern->GetSelection(&ranges);
  if (!ready()) return std::nullopt;
  if (FAILED(selected) || !ranges) {
    retryable = text_control &&
        (selected == UIA_E_NOTSUPPORTED || selected == E_NOINTERFACE || selected == E_FAIL ||
         (SUCCEEDED(selected) && !ranges));
    return std::nullopt;
  }
  ComPtr<IUIAutomationTextRange> range;
  ACTION_STAGE("rangeCount");
  int count = 0, difference = 0;
  if (!ready() || FAILED(ranges->get_Length(&count))) return std::nullopt;
  ACTION_TRACE("ACTION_SELECTION|count=%d\n", count);
  if (count == 0) {
    retryable = !previous_range && selection_target.NoteEmpty(ready);
    return std::nullopt;
  }
  ACTION_STAGE("noncollapsedRange");
  if (count != 1 || !ready() ||
      FAILED(ranges->GetElement(0, &range)) || !range || !ready() ||
      FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_Start, range.Get(),
                                    TextPatternRangeEndpoint_End, &difference)) ||
      difference == 0) return std::nullopt;
  // Retain only provider endpoints/identity, never selected text. If selection
  // or the focused control changes, dismiss rather than tracking a new choice.
  ACTION_TRACE("ACTION_SELECTION|endpointDifference=%d\n", difference);
  ACTION_STAGE("pinnedIdentityAndEndpoints");
  if (previous_element && previous_range) {
    BOOL same = FALSE;
    int start = 0, end = 0;
    if (!ready() || FAILED(automation->CompareElements(previous_element.Get(), focused.Get(), &same)) || !same || !ready() ||
        FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_Start, previous_range.Get(),
                                       TextPatternRangeEndpoint_Start, &start)) || start != 0 || !ready() ||
        FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_End, previous_range.Get(),
                                       TextPatternRangeEndpoint_End, &end)) || end != 0)
      return std::nullopt;
  }
  previous_element = focused;
  if (!previous_range && (!ready() || FAILED(range->Clone(previous_range.ReleaseAndGetAddressOf())) || !ready()))
    return std::nullopt;
  ACTION_STAGE("boundingRectangles");
  SAFEARRAY* rectangles = nullptr;
  if (!ready()) return std::nullopt;
  const HRESULT hr = range->GetBoundingRectangles(&rectangles);
  std::optional<RECT> result;
  VARTYPE type = VT_EMPTY;
  LONG lo = 0, hi = -1;
  RECT window{};
  if (SUCCEEDED(hr) && rectangles && SafeArrayGetDim(rectangles) == 1 &&
      SUCCEEDED(SafeArrayGetVartype(rectangles, &type)) && type == VT_R8 &&
      SUCCEEDED(SafeArrayGetLBound(rectangles, 1, &lo)) &&
      SUCCEEDED(SafeArrayGetUBound(rectangles, 1, &hi)) && hi >= lo &&
      static_cast<int64_t>(hi) - lo < 256 &&
      (static_cast<int64_t>(hi) - lo + 1) % 4 == 0 && GetWindowRect(source, &window)) {
    double* data = nullptr;
    if (SUCCEEDED(SafeArrayAccessData(rectangles, reinterpret_cast<void**>(&data)))) {
      for (LONG i = 0; data && i < hi - lo + 1; i += 4) {
        auto checked = translation_panel::SelectionRect(data[i], data[i + 1], data[i + 2], data[i + 3]);
        if (!checked) continue;
        RECT rect{checked->left, checked->top, checked->right, checked->bottom}, clipped{};
        if (IntersectRect(&clipped, &rect, &window) && MonitorFromRect(&clipped, MONITOR_DEFAULTTONULL)) {
          result = clipped;  // Last visible selected line, not the mouse cursor.
          if (selected_area) {
            if (*selected_area) { RECT combined{}; UnionRect(&combined, &**selected_area, &clipped); *selected_area = combined; }
            else *selected_area = clipped;
          }
        }
      }
      SafeArrayUnaccessData(rectangles);
    }
  }
  if (rectangles) SafeArrayDestroy(rectangles);
  if (!result && (hr == E_FAIL || hr == UIA_E_NOTSUPPORTED)) retryable = text_control;
  ACTION_STAGE("finalFocus");
  ComPtr<IUIAutomationElement> final_focus;
  BOOL still_same = FALSE;
  if (!ready() || GetForegroundWindow() != source ||
      FAILED(automation->GetFocusedElement(&final_focus)) || !final_focus || !ready() ||
      FAILED(automation->CompareElements(focused.Get(), final_focus.Get(), &still_same)) || !still_same ||
      !selection_target.Resolve(automation.Get(), final_focus.Get(), source,
          static_cast<DWORD>(focused_pid), ready, false) ||
      (static_cast<DWORD>(focused_pid) != pid &&
       !console_binding.Verify(source, pid, static_cast<DWORD>(focused_pid), automation.Get(),
           final_focus.Get(), stopped, deadline))) {
    result.reset();
    retryable = false;
  }
  if (!ready()) result.reset();
  ACTION_STAGE(result ? "accepted" : "noBoundsOrFinalMismatch");
  if (result && transaction_control) *transaction_control = bounded;
  if (result && validated_range) *validated_range = range;
  return result;
}
translation_selection::Selection CaptureBoundSelection(HWND source,
    const ComPtr<IUIAutomationElement>& expected_element,
    const ComPtr<IUIAutomationTextRange>& expected_range,
    translation_selection::SelectionTarget& target,
    translation_selection::ConsoleBinding& console,
    const std::function<bool()>& stopped, ULONGLONG deadline) {
  translation_selection::Selection result;
  result.status = "focusChanged";
  if (!expected_element || !expected_range || stopped()) return result;
  // Keep the accepted metadata clone immutable. A normal probe may validate
  // it, but cannot replace it with another selection on this generation.
  auto element = expected_element;
  auto range = expected_range;
  bool retryable = false, require_text = false;
  ComPtr<IUIAutomation2> bounded;
  ComPtr<IUIAutomationTextRange> current_range;
  const auto bounds = SelectionBounds(source, element, range, retryable, require_text,
      target, console, stopped, deadline, &bounded, &current_range, &result.area);
  if (!bounds || stopped() || !bounded || !current_range) return result;
  const auto ready = [&] {
    ULONGLONG now = GetTickCount64();
    if (stopped() || now >= deadline || GetForegroundWindow() != source) return false;
    if (FAILED(bounded->put_ConnectionTimeout(static_cast<DWORD>(
            std::min<ULONGLONG>(150, deadline - now)))) || stopped()) return false;
    now = GetTickCount64();
    return now < deadline && SUCCEEDED(bounded->put_TransactionTimeout(static_cast<DWORD>(
        std::min<ULONGLONG>(200, deadline - now)))) && !stopped();
  };
  if (!ready()) return result;
  BSTR text = nullptr;
  // This current range was compared against the retained expected clone
  // before return; use its own UIA client/timeout owner for the text request.
  const HRESULT read = current_range->GetText(8001, &text);
  if (SUCCEEDED(read) && text && !stopped()) {
    const UINT count = SysStringLen(text);
    if (count > 8000) result.status = "tooLong";
    else if (count) {
      result.text.assign(text, count);
      result.status = "ok";
      result.bounds = bounds;
      translation_selection::RejectEmbeddedNull(result);
    } else result.status = "noSelection";
  }
  SysFreeString(text);
  if (result.status != "ok") { result.text.clear(); result.bounds.reset(); return result; }
  // Re-read ONLY selection metadata after GetText. Any mutation/cancel/focus
  // change discards the local text before it can reach a completion callback.
  if (!ready() || !SelectionBounds(source, element, range, retryable, require_text,
          target, console, stopped, deadline) || stopped()) {
    result = translation_selection::Selection{};
    result.status = "focusChanged";
  }
  return result;
}
}

struct TranslationSelectionAction::Worker {
  struct ClickJob {
    HWND source = nullptr;
    unsigned generation = 0;
    ULONGLONG deadline = 0;
    std::function<bool()> canceled;
    std::function<void(translation_selection::Selection)> finish;
  };
  std::optional<ClickJob> click;
  std::mutex mutex;
  std::condition_variable wake;
  bool stop = false, busy = false, pending = false, ready = false;
  bool retryable = false;
  HWND source = nullptr;
  unsigned generation = 0, active_generation = 0;
  ULONGLONG deadline = 0;
  std::optional<RECT> result;
};

TranslationSelectionAction::TranslationSelectionAction(HWND dispatcher,
    std::function<void(HWND)> on_click)
    : dispatcher_(dispatcher), on_click_(std::move(on_click)), worker_(std::make_shared<Worker>()) {
  // One worker for this object's entire lifetime, including disable/re-enable.
  // A stuck provider never causes replacement threads or blocks UI/destruction.
  const auto worker = worker_;
  try {
    std::thread([worker] {
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ComPtr<IUIAutomationElement> previous_element;
    ComPtr<IUIAutomationTextRange> previous_range;
    unsigned previous_generation = 0;
    DWORD previous_source_pid = 0, previous_source_thread = 0;
    HANDLE previous_source_process = nullptr;
    translation_selection::SelectionTarget selection_target;
    auto console_binding = std::make_unique<translation_selection::ConsoleBinding>();
    bool require_text_control = false;
    std::unique_lock<std::mutex> lock(worker->mutex);
    while (true) {
      worker->wake.wait(lock, [&] { return worker->stop || worker->pending || worker->click.has_value(); });
      if (worker->stop) break;
      if (worker->click) {
        auto job = std::move(*worker->click);
        worker->click.reset();
        lock.unlock();
        const auto stopped = [&] {
          DWORD current_pid = 0;
          const DWORD current_thread = GetWindowThreadProcessId(job.source, &current_pid);
          if (GetTickCount64() >= job.deadline || job.canceled() ||
              GetForegroundWindow() != job.source || current_pid != previous_source_pid ||
              current_thread != previous_source_thread || !previous_source_process ||
              WaitForSingleObject(previous_source_process, 0) != WAIT_TIMEOUT) return true;
          std::lock_guard<std::mutex> guard(worker->mutex);
          return worker->stop || worker->active_generation != job.generation;
        };
        translation_selection::Selection selected;
        selected.status = "focusChanged";
        if (SUCCEEDED(initialized) && !stopped() && previous_generation == job.generation &&
            previous_element && previous_range && selection_target.Get()) {
          selected = CaptureBoundSelection(job.source, previous_element, previous_range,
              selection_target, *console_binding, stopped, job.deadline);
        }
        if (stopped()) {
          selected = translation_selection::Selection{};
          selected.status = "focusChanged";
        }
        // Completion owns only request data, never this action/channel/UI.
        job.finish(std::move(selected));
        lock.lock();
        continue;
      }
      const HWND source = worker->source;
      const unsigned generation = worker->generation;
      const ULONGLONG deadline = worker->deadline;
      worker->pending = false;
      lock.unlock();
      if (generation != previous_generation) {
        previous_element.Reset(); previous_range.Reset();
        if (previous_source_process) CloseHandle(previous_source_process);
        previous_source_pid = 0;
        previous_source_thread = GetWindowThreadProcessId(source, &previous_source_pid);
        previous_source_process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                                             FALSE, previous_source_pid);
        require_text_control = false;
        selection_target.Reset();
        console_binding = std::make_unique<translation_selection::ConsoleBinding>();
        previous_generation = generation;
      }
      const auto stopped = [&] {
        if (GetTickCount64() >= deadline) return true;
        std::lock_guard<std::mutex> guard(worker->mutex);
        return worker->stop || worker->active_generation != generation;
      };
      bool retryable = false;
      auto result = SUCCEEDED(initialized)
          ? SelectionBounds(source, previous_element, previous_range, retryable, require_text_control,
                            selection_target, *console_binding, stopped, deadline) : std::nullopt;
      lock.lock();
      worker->result = result;
      worker->retryable = retryable;
      worker->ready = true;
      worker->busy = false;
    }
    lock.unlock();
    previous_element.Reset(); previous_range.Reset();
    if (previous_source_process) CloseHandle(previous_source_process);
    selection_target.Reset();
    console_binding.reset();
    if (SUCCEEDED(initialized)) CoUninitialize();
    }).detach();
  } catch (const std::system_error&) {
    worker_available_ = false;
  }
}

TranslationSelectionAction::~TranslationSelectionAction() {
  Configure(false, dark_);
  { std::lock_guard<std::mutex> lock(worker_->mutex); worker_->stop = true; }
  worker_->wake.notify_one();
  if (button_) DestroyWindow(button_);
}

bool TranslationSelectionAction::Configure(bool enabled, bool dark) {
  dark_ = dark;
  if (button_) InvalidateRect(button_, nullptr, TRUE);
  if (enabled_ == enabled) return enabled_;
  enabled_ = enabled;
  if (!enabled) {
    if (hook_) UnhookWindowsHookEx(hook_);
    hook_ = nullptr;
    if (active == this) { active = nullptr; hook_dispatcher = nullptr; hook_button = nullptr; }
    if (timer_) KillTimer(dispatcher_, timer_);
    timer_ = 0;
    down_ = false;
    Hide();
    return false;
  }
  if (!worker_available_) { enabled_ = false; return false; }
  if (active && active != this) { enabled_ = false; return false; }
  active = this;
  hook_dispatcher = dispatcher_;
  hook_button = button_;
  hook_ = SetWindowsHookExW(WH_MOUSE_LL, MouseHook, GetModuleHandle(nullptr), 0);
  timer_ = SetTimer(dispatcher_, reinterpret_cast<UINT_PTR>(this), 50, nullptr);
  if (!hook_ || !timer_) Configure(false, dark);
  return enabled_;
}

LRESULT CALLBACK TranslationSelectionAction::MouseHook(int code, WPARAM wparam, LPARAM lparam) {
  // Constant-time event bookkeeping only. No UIA, focus mutation, or text reads.
  if (code == HC_ACTION && hook_dispatcher &&
      (wparam == WM_LBUTTONDOWN || wparam == WM_LBUTTONUP ||
       wparam == WM_RBUTTONDOWN || wparam == WM_MBUTTONDOWN ||
       wparam == WM_XBUTTONDOWN || wparam == WM_MOUSEWHEEL || wparam == WM_MOUSEHWHEEL)) {
    const auto* mouse = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
    RECT rect{};
    if (!((wparam == WM_LBUTTONDOWN || wparam == WM_LBUTTONUP) &&
          hook_button && IsWindowVisible(hook_button) &&
          GetWindowRect(hook_button, &rect) && PtInRect(&rect, mouse->pt))) {
      // Coordinates remain signed on monitors left/above the primary display.
      static_assert(sizeof(LPARAM) >= sizeof(uint64_t), "Selection action requires Win64");
      const uint64_t packed = static_cast<uint32_t>(mouse->pt.x) |
          (static_cast<uint64_t>(static_cast<uint32_t>(mouse->pt.y)) << 32);
      PostMessage(hook_dispatcher, kMouse, wparam, static_cast<LPARAM>(packed));
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

bool TranslationSelectionAction::CaptureClickedSelection(HWND source, ULONGLONG deadline,
    std::function<bool()> canceled,
    std::function<void(translation_selection::Selection)> finish,
    std::function<void()> invalidate, unsigned* accepted_generation) {
  if (!accepting_click_ || click_queued_ || !enabled_ || !worker_available_ ||
      !source || source != source_ || GetForegroundWindow() != source ||
      GetTickCount64() >= deadline || !canceled || !finish || !invalidate || canceled()) return false;
  std::lock_guard<std::mutex> lock(worker_->mutex);
  if (worker_->stop || worker_->click || worker_->active_generation != generation_) return false;
  worker_->click = Worker::ClickJob{source, generation_, deadline, std::move(canceled), std::move(finish)};
  invalidate_click_ = std::move(invalidate);
  click_queued_ = true;
  if (accepted_generation) *accepted_generation = generation_;
  worker_->wake.notify_one();
  return true;
}

void TranslationSelectionAction::ReleaseClickedSelection(unsigned accepted_generation) {
  // Only the UI-thread consumer of this exact generation can detach its token.
  // A late completion must not clear a newer click's cancellation link.
  if (accepted_generation && accepted_generation == generation_ && click_queued_) {
    invalidate_click_ = {};
    click_queued_ = false;
  }
}

void TranslationSelectionAction::Hide() {
  // Keep the request cancellation link until invalidation, including the gap
  // after worker completion but before the channel's next Poll/delivery.
  if (invalidate_click_) { invalidate_click_(); invalidate_click_ = {}; }
  ++generation_;
  ACTION_TRACE("ACTION_HIDE|generation=%u|wasShown=%d\n", generation_, shown_ ? 1 : 0);
  { std::lock_guard<std::mutex> lock(worker_->mutex); worker_->active_generation = generation_; }
  candidate_ = false;
  discovery_attempts_ = 0;
  discovery_started_ = 0;
  shown_ = false;
  source_ = nullptr;
  if (button_) ShowWindow(button_, SW_HIDE);
}

bool TranslationSelectionAction::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result) {
  if (message == WM_TIMER && timer_ && wparam == timer_) { Tick(); *result = 0; return true; }
  if (message != kMouse) return false;
  *result = 0;
  if (!enabled_) return true;
  const uint64_t packed = static_cast<uint64_t>(lparam);
  const POINT point{static_cast<LONG>(static_cast<int32_t>(packed & 0xffffffffu)),
                    static_cast<LONG>(static_cast<int32_t>(packed >> 32))};
  if (wparam == WM_LBUTTONDOWN) { Hide(); down_ = true; down_point_ = point; }
  else if (wparam == WM_LBUTTONUP) {
    const DWORD now = GetTickCount();
    const bool dragged = std::abs(point.x - down_point_.x) >= GetSystemMetrics(SM_CXDRAG) ||
                         std::abs(point.y - down_point_.y) >= GetSystemMetrics(SM_CYDRAG);
    const bool doubled = last_up_ && now - last_up_ <= GetDoubleClickTime() &&
                         std::abs(point.x - last_up_point_.x) <= GetSystemMetrics(SM_CXDOUBLECLK) &&
                         std::abs(point.y - last_up_point_.y) <= GetSystemMetrics(SM_CYDOUBLECLK);
    ACTION_TRACE("ACTION_GESTURE|generation=%u|down=%d|dragged=%d|doubled=%d|from=%ld,%ld|to=%ld,%ld|foreground=%p\n",
        generation_, down_ ? 1 : 0, dragged ? 1 : 0, doubled ? 1 : 0,
        down_point_.x, down_point_.y, point.x, point.y, static_cast<void*>(GetForegroundWindow()));
    if (down_ && (dragged || doubled)) {
      source_ = GetForegroundWindow();
      candidate_ = true;
      discovery_started_ = GetTickCount64();
      discovery_attempts_ = 0;
      due_ = discovery_started_ + 120;
      expires_ = due_ + 5000;
    }
    down_ = false;
    last_up_ = now;
    last_up_point_ = point;
  } else { down_ = false; Hide(); }
  return true;
}

void TranslationSelectionAction::Request() {
  std::lock_guard<std::mutex> lock(worker_->mutex);
  if (worker_->busy) return;
  ACTION_TRACE("ACTION_REQUEST|generation=%u|attempt=%u|source=%p|shown=%d\n",
      generation_, discovery_attempts_ + 1, static_cast<void*>(source_), shown_ ? 1 : 0);
  worker_->source = source_;
  worker_->generation = generation_;
  worker_->active_generation = generation_;
  worker_->busy = true;
  worker_->pending = true;
  worker_->ready = false;
  started_ = GetTickCount64();
  worker_->deadline = translation_action_budget::RequestDeadline(shown_, discovery_started_, started_);
  if (!shown_) ++discovery_attempts_;
  worker_->wake.notify_one();
}

void TranslationSelectionAction::Tick() {
  const ULONGLONG now = GetTickCount64();
  if (!candidate_) return;
  if (!shown_ && translation_action_budget::Expired(now,
          translation_action_budget::DiscoveryDeadline(discovery_started_))) { Hide(); return; }
  if (GetForegroundWindow() != source_ || now >= expires_) { Hide(); return; }
  std::optional<RECT> bounds;
  bool ready = false, busy = false, retryable = false;
  {
    std::lock_guard<std::mutex> lock(worker_->mutex);
    busy = worker_->busy;
    if (worker_->ready) {
      ready = worker_->generation == generation_;
      if (ready) { bounds = worker_->result; retryable = worker_->retryable; }
      worker_->ready = false;
    }
  }
  const ULONGLONG deadline = translation_action_budget::RequestDeadline(shown_, discovery_started_, started_);
  if (ready) {
    ACTION_TRACE("ACTION_RESULT|generation=%u|bounds=%d|retryable=%d|elapsedMs=%llu\n",
        generation_, bounds ? 1 : 0, retryable ? 1 : 0, now - started_);
    if (translation_action_budget::Expired(now, deadline)) { Hide(); return; }
    if (!bounds) {
      // Only incomplete first discovery retries. Once visible, a changed or
      // vanished selection dismisses immediately. Never read selected text.
      if (!shown_ && translation_retry::CanRetry(retryable, discovery_attempts_,
                                                 now, translation_action_budget::DiscoveryDeadline(discovery_started_))) {
        due_ = now + translation_retry::Delay(discovery_attempts_);
        return;
      }
      Hide(); return;
    }
    if (shown_ && !EqualRect(&shown_bounds_, &*bounds)) { Hide(); return; }
    shown_bounds_ = *bounds;
    shown_ = true;
    Show(*bounds);
    due_ = now + 250;
  } else if (busy && translation_action_budget::Expired(now, deadline)) { Hide(); return; }
  if (!busy && now >= due_) Request();
}

void TranslationSelectionAction::Show(const RECT& bounds) {
  if (!button_) {
    WNDCLASSW cls{};
    cls.hInstance = GetModuleHandle(nullptr);
    cls.lpfnWndProc = WindowProc;
    cls.lpszClassName = kClass;
    cls.hCursor = LoadCursor(nullptr, IDC_HAND);
    RegisterClassW(&cls);
    button_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
        kClass, L"翻译选中文字", WS_POPUP, 0, 0, 32, 32, nullptr, nullptr, cls.hInstance, this);
    hook_button = button_;
  }
  if (!button_) return;
  MONITORINFO monitor{sizeof(monitor)};
  if (!GetMonitorInfo(MonitorFromRect(&bounds, MONITOR_DEFAULTTONEAREST), &monitor)) return;
  const int size = MulDiv(32, static_cast<int>(GetDpiForWindow(source_)), 96);
  const RECT& work = monitor.rcWork;
  const int x = std::clamp(static_cast<int>(bounds.right + 6), static_cast<int>(work.left),
                         std::max(static_cast<int>(work.left), static_cast<int>(work.right) - size));
  const int y = std::clamp(static_cast<int>(bounds.bottom + 5), static_cast<int>(work.top),
                         std::max(static_cast<int>(work.top), static_cast<int>(work.bottom) - size));
  SetWindowPos(button_, HWND_TOPMOST, x, y, size, size, SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

LRESULT CALLBACK TranslationSelectionAction::WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<TranslationSelectionAction*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<TranslationSelectionAction*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(hwnd, message, wparam, lparam);
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (message == WM_LBUTTONUP) {
    const HWND source = self->source_;
    const bool valid = self->candidate_ && self->shown_ && source &&
                       source == GetForegroundWindow() && GetTickCount64() < self->expires_;
    if (valid && self->on_click_) {
      // Consume the visible affordance, but preserve THIS generation until its
      // synchronous callback has queued a bound job and allocated requestId.
      self->candidate_ = false;
      self->shown_ = false;
      ShowWindow(hwnd, SW_HIDE);
      self->accepting_click_ = true;
      self->click_queued_ = false;
      self->on_click_(source);
      self->accepting_click_ = false;
      if (!self->click_queued_) self->Hide();
    } else {
      self->Hide();
    }
    return 0;
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    const HDC dc = BeginPaint(hwnd, &paint);
    RECT rect{}; GetClientRect(hwnd, &rect);
    const HBRUSH brush = CreateSolidBrush(self->dark_ ? RGB(48, 49, 55) : RGB(250, 250, 252));
    FillRect(dc, &rect, brush); DeleteObject(brush);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, self->dark_ ? RGB(242, 242, 248) : RGB(40, 40, 48));
    DrawTextW(dc, L"译", 1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    EndPaint(hwnd, &paint);
    return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
