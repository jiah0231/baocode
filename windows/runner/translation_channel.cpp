#include "translation_channel.h"
#include <flutter/standard_method_codec.h>
#include <functional>
#include <atomic>
#include <mutex>
#include <thread>
#include <system_error>
#include <utility>
#include "app_windows.h"
#include "stash_channel.h"
#include "translation_selection.h"
#include "translation_selection_action.h"
#include "utils.h"

// This engine export is omitted from the distributed public Flutter header.
// Keep its ABI identical to app_windows.cpp's existing multi-view declaration.
extern "C" FLUTTER_EXPORT FlutterDesktopEngineRef
FlutterDesktopEngineForId(int64_t engine_id);

namespace {
constexpr int kHotkey = 0x4254;
flutter::EncodableValue Encode(const translation_selection::Selection& selection,
                               int64_t request_id) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("text"), flutter::EncodableValue(Utf8FromUtf16(selection.text.c_str()))},
      {flutter::EncodableValue("status"), flutter::EncodableValue(selection.status)},
      {flutter::EncodableValue("self"), flutter::EncodableValue(selection.self)},
      {flutter::EncodableValue("requestId"), flutter::EncodableValue(request_id)}});
}
bool BoolArgument(const flutter::EncodableValue* arguments, const char* key) {
  const auto* map = arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  if (!map) return false;
  const auto found = map->find(flutter::EncodableValue(key));
  if (found == map->end()) return false;
  const auto* value = std::get_if<bool>(&found->second);
  return value && *value;
}
std::optional<int64_t> Argument(const flutter::EncodableValue* arguments,
                               const char* key) {
  const auto* map = arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  if (!map) return std::nullopt;
  const auto found = map->find(flutter::EncodableValue(key));
  if (found == map->end()) return std::nullopt;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  return std::nullopt;
}
}

// This view shares the running engine, but is deliberately NOT an AppWindows
// workspace entry. Closing it never opens, restores, or closes the main window.
class TranslationPanelWindow : public IdeWindow {
 public:
  TranslationPanelWindow(FlutterDesktopEngineRef engine,
                         flutter::BinaryMessenger* messenger,
                         std::function<void(bool)> hide)
      : IdeWindow(engine, messenger), hide_(std::move(hide)) {}
  void Detach() { hide_ = nullptr; }
 protected:
  LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override {
    if (message == WM_CLOSE) {
      if (hide_) hide_(true);
      return 0;
    }
    if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
      if (hide_) hide_(false);
    }
    return IdeWindow::MessageHandler(window, message, wparam, lparam);
  }
 private:
  std::function<void(bool)> hide_;
};
struct TranslationChannel::Pending {
  std::mutex mutex;
  bool done = false;
  std::atomic<bool> canceled{false};
  int64_t request_id = 0;
  HWND foreground = nullptr;
  translation_selection::Selection selection;
};
TranslationChannel::TranslationChannel(flutter::BinaryMessenger* messenger, HWND window)
    : messenger_(messenger), window_(window),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "baocode/translation", &flutter::StandardMethodCodec::GetInstance())) {
  selection_action_ = std::make_unique<TranslationSelectionAction>(window_,
      [this](HWND source) {
        if (source && GetForegroundWindow() == source) Capture(nullptr);
      });
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "configure") {
      const bool fallback = BoolArgument(call.arguments(), "clipboardFallback");
      const bool action = BoolArgument(call.arguments(), "selectionAction");
      if (((clipboard_fallback_ && !fallback) ||
           (selection_action_enabled_ && !action)) && pending_) {
        pending_->canceled.store(true);
      }
      clipboard_fallback_ = fallback;
      selection_action_enabled_ = action;
      const bool installed = selection_action_->Configure(
          action, BoolArgument(call.arguments(), "dark"));
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("selectionAction"), flutter::EncodableValue(installed)}}));
    } else if (call.method_name() == "setHotkey") {
      const auto* spec = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      result->Success(flutter::EncodableValue(spec && Register(*spec)));
    } else if (call.method_name() == "captureSelection") {
      Capture(std::move(result));
    } else if (call.method_name() == "createPanel") {
      const auto engine = Argument(call.arguments(), "engineId");
      const auto view = engine ? CreatePanel(*engine) : std::nullopt;
      result->Success(view ? flutter::EncodableValue(*view) : flutter::EncodableValue());
    } else if (call.method_name() == "showPanel") {
      result->Success(flutter::EncodableValue(ShowPanel(Argument(call.arguments(), "requestId"))));
    } else if (call.method_name() == "hidePanel") {
      // Dart owns clearing its state. No echo event that could erase a newer
      // request; also allow hiding the old panel before showing that request.
      HidePanel(true, false, false);
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}
TranslationChannel::~TranslationChannel() {
  if (pending_) pending_->canceled.store(true);
  selection_action_.reset();
  channel_->SetMethodCallHandler(nullptr);
  if (registered_) UnregisterHotKey(window_, kHotkey);
  KillTimer(window_, kTimer);
  // View destruction is outside a platform callback, before engine teardown.
  if (panel_) panel_->Detach();
  panel_.reset();
  // A late/hung provider owns only Pending, never this or Flutter objects.
  pending_.reset();
  result_.reset();
}
std::optional<int64_t> TranslationChannel::CreatePanel(int64_t engine_id) {
  if (panel_) return panel_->view_id();
  const auto engine = FlutterDesktopEngineForId(engine_id);
  if (!engine) return std::nullopt;
  auto panel = std::make_unique<TranslationPanelWindow>(engine, messenger_,
      [this](bool restore) { if (panel_shown_) HidePanel(restore); });
  if (!panel->Create(L"BaoCode Translate", Win32Window::Point(10, 10),
                      Win32Window::Size(480, 560))) return std::nullopt;
  panel->SetMinimumSize(Win32Window::Size(280, 240));
  const HWND handle = panel->GetHandle();
  SetWindowLongPtrW(handle, GWL_STYLE,
      GetWindowLongPtrW(handle, GWL_STYLE) & ~(WS_MINIMIZEBOX | WS_MAXIMIZEBOX));
  SetWindowLongPtrW(handle, GWL_EXSTYLE,
      (GetWindowLongPtrW(handle, GWL_EXSTYLE) | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
  SetWindowPos(handle, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  const auto view_id = panel->view_id();
  panel_ = std::move(panel);
  return view_id;
}
void TranslationChannel::BeginRequest(HWND foreground) {
  if (pending_) pending_->canceled.store(true);
  ++request_id_;
  request_started_ = GetTickCount64();
  foreground_ = foreground;
  foreground_process_ = 0;
  if (foreground) GetWindowThreadProcessId(foreground, &foreground_process_);
  GetCursorPos(&pointer_);
  anchor_.reset();
}
bool TranslationChannel::ShowPanel(std::optional<int64_t> request_id) {
  if (!panel_) return false;
  const HWND panel = panel_->GetHandle();
  if (!request_id) {
    // Context menu / toolbar translation has no external capture. Do not use
    // an earlier external selection's position or return-focus target.
    const HWND front = GetForegroundWindow();
    DWORD process = 0;
    if (front) GetWindowThreadProcessId(front, &process);
    // An in-app request delayed by first-view creation must not steal focus
    // from a different application the user has switched to meanwhile.
    if (!front || process != GetCurrentProcessId()) return false;
    if (front != panel) BeginRequest(front);
  } else if (*request_id != request_id_ ||
             GetTickCount64() - request_started_ > 5000) {
    return false;
  }
  const HWND front = GetForegroundWindow();
  if (!foreground_ || (front != foreground_ && front != panel)) return false;
  DWORD process = 0;
  GetWindowThreadProcessId(foreground_, &process);
  if (process != foreground_process_) return false;
  const RECT anchor = anchor_.value_or(RECT{pointer_.x, pointer_.y, pointer_.x, pointer_.y});
  const HMONITOR monitor = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return false;
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const auto& work = info.rcWork;
  const auto placed = translation_panel::Place(
      {anchor.left, anchor.top, anchor.right, anchor.bottom},
      {work.left, work.top, work.right, work.bottom},
      static_cast<int>(480 * scale), static_cast<int>(560 * scale),
      static_cast<int>(10 * scale));
  // A small display must remain usable even if its physical work area is
  // smaller than the normal minimum logical panel size.
  panel_->SetMinimumSize(Win32Window::Size(1, 1));
  SetWindowPos(panel, HWND_TOP, placed.left, placed.top,
      placed.right - placed.left, placed.bottom - placed.top, SWP_NOACTIVATE);
  panel_->SetMinimumSize(Win32Window::Size(
      static_cast<unsigned int>(std::clamp(
          static_cast<int>((work.right - work.left) / scale) - 24, 1, 280)),
      static_cast<unsigned int>(std::clamp(
          static_cast<int>((work.bottom - work.top) / scale) - 24, 1, 240))));
  if (GetForegroundWindow() != front) return false;
  panel_request_id_ = request_id_;
  panel_shown_ = true;
  ShowWindow(panel, SW_SHOWNOACTIVATE);
  SetForegroundWindow(panel);
  if (GetForegroundWindow() != panel) {
    HidePanel(false);
    return false;
  }
  return panel_shown_;
}
void TranslationChannel::HidePanel(bool restore_focus, bool invalidate, bool notify) {
  if (pending_) pending_->canceled.store(true);
  const bool shown = std::exchange(panel_shown_, false);
  const HWND panel = panel_ ? panel_->GetHandle() : nullptr;
  const bool was_front = panel && GetForegroundWindow() == panel;
  const HWND source = foreground_;
  const DWORD source_process = foreground_process_;
  if (invalidate) ++request_id_;
  DWORD process = 0;
  if (source) GetWindowThreadProcessId(source, &process);
  // Never steal focus back after the user clicks / Alt-Tabs to another app.
  // Never restore a hidden/minimized main or source window. Activate the
  // verified source BEFORE hiding an active popup: SW_HIDE otherwise chooses
  // another window to activate, potentially restoring the minimized main in
  // the interval before focus is returned to the source. panel_shown_ is
  // already false, so this deactivation cannot recursively hide/notify.
  if (restore_focus && was_front && source && IsWindowVisible(source) &&
      !IsIconic(source) && process == source_process &&
      GetForegroundWindow() == panel) SetForegroundWindow(source);
  if (panel) ShowWindow(panel, SW_HIDE);
  if (shown && notify) {
    channel_->InvokeMethod("panelHidden", std::make_unique<flutter::EncodableValue>(
        flutter::EncodableMap{{flutter::EncodableValue("requestId"),
                               flutter::EncodableValue(panel_request_id_)}}));
  }
}
bool TranslationChannel::Register(const std::string& spec) {
  if (registered_) UnregisterHotKey(window_, kHotkey);
  registered_ = false;
  if (spec.empty()) return true;
  const auto parsed = StashChannel::Parse(spec);
  if (!parsed) return false;
  registered_ = RegisterHotKey(window_, kHotkey, parsed->first | MOD_NOREPEAT,
                               parsed->second) != FALSE;
  return registered_;
}
bool TranslationChannel::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                        LRESULT* result) {
  return selection_action_ && selection_action_->HandleMessage(message, wparam, lparam, result);
}
bool TranslationChannel::HandleHotkey(WPARAM id) {
  if (id != static_cast<WPARAM>(kHotkey)) return false;
  if (panel_shown_) HidePanel(true);
  else Capture(nullptr);
  return true;
}
void TranslationChannel::Capture(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  selection_action_->Hide();
  const bool explicit_shortcut = result == nullptr;
  const HWND foreground = GetForegroundWindow();
  BeginRequest(foreground);
  if (result_) {
    result_->Success(Encode({L"", "focusChanged", false, std::nullopt},
                            pending_ ? pending_->request_id : request_id_));
    result_.reset();
  }
  if (foreground && foreground_process_ == GetCurrentProcessId()) {
    // Dart knows the focused view and its selection. No main activation.
    const auto own = Encode({L"", "noSelection", true, std::nullopt}, request_id_);
    if (result) result->Success(own);
    else channel_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(own));
    return;
  }
  if (pending_) {
    // One bounded worker at a time even if a broken UIA provider never
    // returns. New shortcuts get a fresh, empty manual-entry request.
    delivered_ = true;
    const auto busy = Encode({L"", "busy", false, std::nullopt}, request_id_);
    if (result) result->Success(busy);
    else channel_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(busy));
    return;
  }
  pending_ = std::make_shared<Pending>();
  pending_->request_id = request_id_;
  pending_->foreground = foreground;
  result_ = std::move(result);
  delivered_ = false;
  started_ = GetTickCount64();
  if (!SetTimer(window_, kTimer, 25, nullptr)) {
    const auto failed = Encode({L"", "unsupported", false, std::nullopt}, request_id_);
    if (result_) result_->Success(failed);
    else channel_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(failed));
    result_.reset();
    pending_.reset();
    return;
  }
  const auto pending = pending_;
  const bool allow_copy = explicit_shortcut && clipboard_fallback_;
  const HWND owner = window_;
  const ULONGLONG deadline = started_ + 1500;
  try {
    std::thread([pending, foreground, allow_copy, owner, deadline]() {
      auto selection = translation_selection::Capture(
          foreground, allow_copy, &pending->canceled, deadline);
      if (allow_copy && selection.status == "unsupported" && selection.copy_proof &&
          !pending->canceled.load() && GetTickCount64() < deadline) {
        auto copied = translation_clipboard::CopySelection(
            owner, *selection.copy_proof, &pending->canceled, deadline);
        selection.text = std::move(copied.text);
        selection.status = std::move(copied.status);
      }
      selection.copy_proof.reset();
      std::lock_guard<std::mutex> lock(pending->mutex);
      pending->selection = std::move(selection);
      pending->done = true;
    }).detach();
  } catch (const std::system_error&) {
    // Resource exhaustion must not escape the native window procedure.
    pending->selection.status = "unsupported";
    pending->done = true;
  }
}
void TranslationChannel::Poll() {
  if (!pending_) return;
  translation_selection::Selection selection;
  bool done;
  {
    std::lock_guard<std::mutex> lock(pending_->mutex);
    done = pending_->done;
    selection = pending_->selection;
  }
  // Restoration is a separate user-visible outcome, even if the source
  // request was canceled/timed out. Never reopen or deliver its stale text.
  if (done && selection.status == "clipboardRestoreFailed" &&
      (delivered_ || pending_->canceled.load() ||
       pending_->request_id != request_id_ ||
       GetForegroundWindow() != pending_->foreground)) {
    channel_->InvokeMethod("captureWarning", std::make_unique<flutter::EncodableValue>(
        flutter::EncodableMap{{flutter::EncodableValue("status"),
                               flutter::EncodableValue("clipboardRestoreFailed")}}));
  }
  if (!delivered_ && (done || GetTickCount64() - started_ >= 1500)) {
    const bool canceled = pending_->canceled.load();
    if (!done) {
      pending_->canceled.store(true);
      selection.text.clear();
      selection.bounds.reset();
      selection.status = "timeout";
      SetTimer(window_, kTimer, 1000, nullptr);
    }
    delivered_ = true;
    const bool changed = canceled || pending_->request_id != request_id_ ||
        !pending_->foreground || GetForegroundWindow() != pending_->foreground;
    if (changed) {
      selection.text.clear();
      selection.bounds.reset();
      selection.status = "focusChanged";
    }
    if (!changed) anchor_ = selection.bounds;
    if (result_) {
      result_->Success(Encode(selection, pending_->request_id));
      result_.reset();
    } else if (!changed && selection.status != "focusChanged") {
      channel_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(
          Encode(selection, pending_->request_id)));
    }
  }
  if (done) {
    pending_.reset();
    KillTimer(window_, kTimer);
  }
}
