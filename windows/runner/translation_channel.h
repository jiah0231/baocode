#ifndef RUNNER_TRANSLATION_CHANNEL_H_
#define RUNNER_TRANSLATION_CHANNEL_H_
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

class TranslationPanelWindow;
class TranslationSelectionAction;
class TranslationChannel {
 public:
  static constexpr UINT_PTR kTimer = 0x4254;
  TranslationChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~TranslationChannel();
  bool HandleHotkey(WPARAM id);
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result);
  void Poll();
 private:
  struct Pending;
  bool Register(const std::string& spec);
  void Capture(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
               const char* origin = "manual");
  std::optional<int64_t> CreatePanel(int64_t engine_id);
  bool ShowPanel(std::optional<int64_t> request_id);
  void HidePanel(bool restore_focus, bool invalidate = true, bool notify = true);
  void BeginRequest(HWND foreground);
  flutter::BinaryMessenger* messenger_;
  HWND window_;
  HWND foreground_ = nullptr;
  DWORD foreground_process_ = 0;
  POINT pointer_ = {};
  std::optional<RECT> anchor_;
  int64_t request_id_ = 0;
  ULONGLONG request_started_ = 0;
  int64_t panel_request_id_ = 0;
  bool panel_shown_ = false;
  bool registered_ = false;
  bool clipboard_fallback_ = false;
  bool selection_action_enabled_ = false;
  bool delivered_ = false;
  ULONGLONG started_ = 0;
  std::shared_ptr<Pending> pending_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result_;
  std::unique_ptr<TranslationPanelWindow> panel_;
  std::unique_ptr<TranslationSelectionAction> selection_action_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
