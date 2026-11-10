#ifndef RUNNER_TRANSLATION_MOUSE_HOOK_H_
#define RUNNER_TRANSLATION_MOUSE_HOOK_H_
#include <windows.h>
#include <condition_variable>
#include <thread>
#include <system_error>
#include <vector>
#include "translation_action_visual.h"
#include "translation_mouse_mailbox.h"

namespace translation_mouse {
// Owns its hook AND its message pump on a dedicated thread. WH_MOUSE_LL is
// delivered synchronously to the installing thread, even for WM_MOUSEMOVE
// which we ignore. Installing on Flutter's UI thread stalls the system cursor
// whenever that UI thread is busy, regardless of callback complexity.
class Hook {
 public:
  struct Event { WPARAM message = 0; POINT point{}; DWORD time = 0; HWND source = nullptr; };
  struct Button {
    RECT bounds{};
    int size = 0;
    std::vector<uint32_t> pixels;
    bool Hit(POINT point) const {
      return translation_action_visual::PixelHit(pixels, size,
          point.x - bounds.left, point.y - bounds.top);
    }
  };
  using Inbox = Mailbox<Event, Button>;
  Hook(HWND dispatcher, UINT message) : dispatcher_(dispatcher), message_(message) {}
  ~Hook() {
    if (stop_) SetEvent(stop_);
    if (thread_.joinable()) thread_.join();
    if (stop_) CloseHandle(stop_);
  }
  bool Start() {
    if (thread_.joinable()) return installed_;
    stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!stop_) return false;
    try {
      thread_ = std::thread([this] { Run(); });
    } catch (const std::system_error&) {
      CloseHandle(stop_);
      stop_ = nullptr;
      return false;
    }
    std::unique_lock<std::mutex> lock(start_mutex_);
    started_.wait(lock, [this] { return ready_; });
    return installed_;
  }
  void Publish(Button button) { inbox_.Publish(std::move(button)); }
  Inbox::Batch Take() { return inbox_.Take(); }
  Hook(const Hook&) = delete;
  Hook& operator=(const Hook&) = delete;
 private:
  static LRESULT CALLBACK Callback(int code, WPARAM wparam, LPARAM lparam) {
    auto* self = current_;
    if (code == HC_ACTION && self &&
        (wparam == WM_LBUTTONDOWN || wparam == WM_LBUTTONUP ||
         wparam == WM_RBUTTONDOWN || wparam == WM_MBUTTONDOWN ||
         wparam == WM_XBUTTONDOWN || wparam == WM_MOUSEWHEEL || wparam == WM_MOUSEHWHEEL)) {
      const auto& mouse = *reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
      // Only immutable value snapshots: no action, HWND queries on the pill,
      // UIA, channel, text access or synchronous UI calls on this thread.
      if (self->inbox_.Push({wparam, mouse.pt, mouse.time, GetForegroundWindow()},
          [&](const Button& button) {
            return (wparam == WM_LBUTTONDOWN || wparam == WM_LBUTTONUP) && button.Hit(mouse.pt);
          }) && !PostMessageW(self->dispatcher_, self->message_, 0, 0)) {
        self->inbox_.PostFailed();
      }
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  void Run() {
    current_ = this;
    MSG message{};
    PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE);
    const HHOOK hook = SetWindowsHookExW(WH_MOUSE_LL, Callback, GetModuleHandleW(nullptr), 0);
    { std::lock_guard<std::mutex> lock(start_mutex_); installed_ = hook != nullptr; ready_ = true; }
    started_.notify_one();
    if (hook) {
      while (MsgWaitForMultipleObjects(1, &stop_, FALSE, INFINITE, QS_ALLINPUT) == WAIT_OBJECT_0 + 1) {
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
          if (WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0) break;
          TranslateMessage(&message);
          DispatchMessageW(&message);
        }
      }
      UnhookWindowsHookEx(hook);
    }
    current_ = nullptr;
  }
  inline static thread_local Hook* current_ = nullptr;
  const HWND dispatcher_;
  const UINT message_;
  Inbox inbox_;
  HANDLE stop_ = nullptr;
  std::thread thread_;
  std::mutex start_mutex_;
  std::condition_variable started_;
  bool ready_ = false, installed_ = false;
};
}  // namespace translation_mouse
#endif
