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

namespace {
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
    ComPtr<IUIAutomationTextRange>& previous_range) {
  DWORD pid = 0;
  GetWindowThreadProcessId(source, &pid);
  if (!pid || pid == GetCurrentProcessId() || GetForegroundWindow() != source)
    return std::nullopt;
  ComPtr<IUIAutomation> automation;
  if (FAILED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&automation)))) return std::nullopt;
  ComPtr<IUIAutomation2> bounded;
  if (FAILED(automation.As(&bounded)) ||
      FAILED(bounded->put_ConnectionTimeout(150)) ||
      FAILED(bounded->put_TransactionTimeout(200))) return std::nullopt;
  ComPtr<IUIAutomationElement> focused;
  if (FAILED(automation->GetFocusedElement(&focused)) || !focused) return std::nullopt;
  int focused_pid = 0;
  BOOL password = TRUE, has_focus = FALSE;
  if (FAILED(focused->get_CurrentProcessId(&focused_pid)) ||
      static_cast<DWORD>(focused_pid) != pid ||
      FAILED(focused->get_CurrentIsPassword(&password)) || password ||
      FAILED(focused->get_CurrentHasKeyboardFocus(&has_focus)) || !has_focus)
    return std::nullopt;
  ComPtr<IUIAutomationTextPattern> pattern;
  ComPtr<IUIAutomationTextRangeArray> ranges;
  ComPtr<IUIAutomationTextRange> range;
  int count = 0, difference = 0;
  if (FAILED(focused->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern))) ||
      !pattern || FAILED(pattern->GetSelection(&ranges)) || !ranges ||
      FAILED(ranges->get_Length(&count)) || count != 1 ||
      FAILED(ranges->GetElement(0, &range)) || !range ||
      FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_Start, range.Get(),
                                    TextPatternRangeEndpoint_End, &difference)) ||
      difference == 0) return std::nullopt;
  // Retain only provider endpoints/identity, never selected text. If selection
  // or the focused control changes, dismiss rather than tracking a new choice.
  if (previous_element && previous_range) {
    BOOL same = FALSE;
    int start = 0, end = 0;
    if (FAILED(automation->CompareElements(previous_element.Get(), focused.Get(), &same)) || !same ||
        FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_Start, previous_range.Get(),
                                       TextPatternRangeEndpoint_Start, &start)) || start != 0 ||
        FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_End, previous_range.Get(),
                                       TextPatternRangeEndpoint_End, &end)) || end != 0)
      return std::nullopt;
  }
  previous_element = focused;
  if (FAILED(range->Clone(previous_range.ReleaseAndGetAddressOf()))) return std::nullopt;
  SAFEARRAY* rectangles = nullptr;
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
        if (IntersectRect(&clipped, &rect, &window) && MonitorFromRect(&clipped, MONITOR_DEFAULTTONULL))
          result = clipped;  // Last visible selected line, not the mouse cursor.
      }
      SafeArrayUnaccessData(rectangles);
    }
  }
  if (rectangles) SafeArrayDestroy(rectangles);
  if (GetForegroundWindow() != source) result.reset();
  return result;
}
}

struct TranslationSelectionAction::Worker {
  std::mutex mutex;
  std::condition_variable wake;
  bool stop = false, busy = false, pending = false, ready = false;
  HWND source = nullptr;
  unsigned generation = 0;
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
    std::unique_lock<std::mutex> lock(worker->mutex);
    while (true) {
      worker->wake.wait(lock, [&] { return worker->stop || worker->pending; });
      if (worker->stop) break;
      const HWND source = worker->source;
      const unsigned generation = worker->generation;
      worker->pending = false;
      lock.unlock();
      if (generation != previous_generation) {
        previous_element.Reset(); previous_range.Reset();
        previous_generation = generation;
      }
      auto result = SUCCEEDED(initialized)
          ? SelectionBounds(source, previous_element, previous_range) : std::nullopt;
      lock.lock();
      worker->result = result;
      worker->ready = true;
      worker->busy = false;
    }
    lock.unlock();
    previous_element.Reset(); previous_range.Reset();
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

void TranslationSelectionAction::Hide() {
  ++generation_;
  candidate_ = false;
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
    if (down_ && (dragged || doubled)) {
      source_ = GetForegroundWindow();
      candidate_ = true;
      due_ = GetTickCount64() + 120;
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
  worker_->source = source_;
  worker_->generation = generation_;
  worker_->busy = true;
  worker_->pending = true;
  worker_->ready = false;
  started_ = GetTickCount64();
  worker_->wake.notify_one();
}

void TranslationSelectionAction::Tick() {
  const ULONGLONG now = GetTickCount64();
  if (!candidate_) return;
  if (GetForegroundWindow() != source_ || now >= expires_) { Hide(); return; }
  std::optional<RECT> bounds;
  bool ready = false, busy = false;
  {
    std::lock_guard<std::mutex> lock(worker_->mutex);
    busy = worker_->busy;
    if (worker_->ready) {
      ready = worker_->generation == generation_;
      if (ready) bounds = worker_->result;
      worker_->ready = false;
    }
  }
  if (ready) {
    if (!bounds || now - started_ > 700) { Hide(); return; }
    if (shown_ && !EqualRect(&shown_bounds_, &*bounds)) { Hide(); return; }
    shown_bounds_ = *bounds;
    shown_ = true;
    Show(*bounds);
    due_ = now + 250;
  } else if (busy && now - started_ > 700) { Hide(); return; }
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
    const bool valid = self->candidate_ && source && source == GetForegroundWindow() &&
                       GetTickCount64() < self->expires_;
    self->Hide();
    if (valid && self->on_click_) self->on_click_(source);
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
