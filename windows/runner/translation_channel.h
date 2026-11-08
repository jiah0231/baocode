#ifndef RUNNER_TRANSLATION_CHANNEL_H_
#define RUNNER_TRANSLATION_CHANNEL_H_
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>
#include <string>

class TranslationChannel {
 public:
  static constexpr UINT_PTR kTimer = 0x4254;
  TranslationChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~TranslationChannel();
  bool HandleHotkey(WPARAM id);
  void Poll();
 private:
  struct Pending;
  bool Register(const std::string& spec);
  void Capture(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  HWND window_;
  HWND foreground_ = nullptr;
  bool registered_ = false;
  bool delivered_ = false;
  ULONGLONG started_ = 0;
  std::shared_ptr<Pending> pending_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
