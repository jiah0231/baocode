#include "translation_channel.h"
#include <flutter/standard_method_codec.h>
#include <mutex>
#include <thread>
#include <system_error>
#include "stash_channel.h"
#include "translation_selection.h"
#include "utils.h"

namespace {
constexpr int kHotkey = 0x4254;
flutter::EncodableValue Encode(const translation_selection::Selection& selection) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("text"), flutter::EncodableValue(Utf8FromUtf16(selection.text.c_str()))},
      {flutter::EncodableValue("status"), flutter::EncodableValue(selection.status)},
      {flutter::EncodableValue("self"), flutter::EncodableValue(selection.self)}});
}
}
struct TranslationChannel::Pending {
  std::mutex mutex;
  bool done = false;
  translation_selection::Selection selection;
};
TranslationChannel::TranslationChannel(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "baocode/translation", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "setHotkey") {
      const auto* spec = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      result->Success(flutter::EncodableValue(spec && Register(*spec)));
    } else if (call.method_name() == "captureSelection") {
      Capture(std::move(result));
    } else {
      result->NotImplemented();
    }
  });
}
TranslationChannel::~TranslationChannel() {
  channel_->SetMethodCallHandler(nullptr);
  if (registered_) UnregisterHotKey(window_, kHotkey);
  KillTimer(window_, kTimer);
  // A late/hung provider owns only Pending, never this or Flutter objects.
  pending_.reset();
  result_.reset();
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
bool TranslationChannel::HandleHotkey(WPARAM id) {
  if (id != kHotkey) return false;
  Capture(nullptr);
  return true;
}
void TranslationChannel::Capture(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const HWND foreground = GetForegroundWindow();
  DWORD process = 0;
  GetWindowThreadProcessId(foreground, &process);
  if (foreground && process == GetCurrentProcessId()) {
    // Dart already knows the focused view and its selection. Do not change
    // focus from a secondary IDE/agent window to the main window.
    const auto own = Encode({L"", "noSelection", true});
    if (result) result->Success(own);
    else channel_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(own));
    return;
  }
  if (pending_) {
    if (result) {
      result->Success(Encode({L"", "busy", false}));
    } else if (delivered_) {
      // A provider that never returns cannot spawn more workers. A later
      // explicit shortcut can still open a manual-entry panel.
      ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(window_);
      channel_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(
          Encode({L"", "busy", false})));
    }
    return;
  }
  foreground_ = foreground;
  pending_ = std::make_shared<Pending>();
  result_ = std::move(result);
  delivered_ = false;
  started_ = GetTickCount64();
  if (!SetTimer(window_, kTimer, 25, nullptr)) {
    if (result_) result_->Success(Encode({L"", "unsupported", false}));
    result_.reset();
    pending_.reset();
    return;
  }
  const auto pending = pending_;
  try {
    std::thread([pending, foreground]() {
      auto selection = translation_selection::Capture(foreground);
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
  if (!delivered_ && (done || GetTickCount64() - started_ >= 1500)) {
    if (!done) {
      selection.text.clear();
      selection.status = "timeout";
      SetTimer(window_, kTimer, 1000, nullptr);
    }
    delivered_ = true;
    const bool changed = !foreground_ || GetForegroundWindow() != foreground_;
    if (changed) {
      selection.text.clear();
      selection.status = "focusChanged";
    }
    if (result_) {
      result_->Success(Encode(selection));
      result_.reset();
    } else if (!changed && selection.status != "focusChanged") {
      // Only a global shortcut requests activation; captureSelection does not.
      ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(window_);
      channel_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(Encode(selection)));
    }
  }
  if (done) {
    pending_.reset();
    KillTimer(window_, kTimer);
  }
}
