#ifndef RUNNER_TRANSLATION_SELECTION_ACTION_H_
#define RUNNER_TRANSLATION_SELECTION_ACTION_H_
#include <windows.h>
#include <functional>
#include <memory>

// A metadata-only mouse selection affordance. Text capture is exclusively the
// caller's explicit-click callback. All public methods run on the UI thread.
class TranslationSelectionAction {
 public:
  TranslationSelectionAction(HWND dispatcher, std::function<void(HWND)> on_click);
  ~TranslationSelectionAction();
  bool Configure(bool enabled, bool dark);
  void Hide();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result);
  TranslationSelectionAction(const TranslationSelectionAction&) = delete;
  TranslationSelectionAction& operator=(const TranslationSelectionAction&) = delete;
 private:
  struct Worker;
  static LRESULT CALLBACK MouseHook(int code, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  void Tick();
  void Request();
  void Show(const RECT& bounds);
  HWND dispatcher_ = nullptr;
  HWND button_ = nullptr;
  HWND source_ = nullptr;
  HHOOK hook_ = nullptr;
  UINT_PTR timer_ = 0;
  bool worker_available_ = true;
  bool enabled_ = false, dark_ = false, down_ = false, candidate_ = false;
  RECT shown_bounds_{};
  bool shown_ = false;
  POINT down_point_{};
  DWORD last_up_ = 0;
  POINT last_up_point_{};
  ULONGLONG due_ = 0, expires_ = 0, started_ = 0;
  unsigned generation_ = 0;
  std::function<void(HWND)> on_click_;
  std::shared_ptr<Worker> worker_;
};
#endif
