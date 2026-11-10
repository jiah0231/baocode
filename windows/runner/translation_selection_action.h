#ifndef RUNNER_TRANSLATION_SELECTION_ACTION_H_
#define RUNNER_TRANSLATION_SELECTION_ACTION_H_
#include <windows.h>
#include <functional>
#include <memory>
#include <cstdint>
#include <vector>
#include "translation_selection.h"
#include "translation_gesture_geometry.h"

// A metadata-only mouse selection affordance. Text capture is exclusively the
// caller's explicit-click callback. All public methods run on the UI thread.
class TranslationSelectionAction {
 public:
  TranslationSelectionAction(HWND dispatcher, std::function<void(HWND)> on_click);
  ~TranslationSelectionAction();
  bool Configure(bool enabled, bool dark);
  void Hide();
  // Physical point from the click message, valid only inside on_click. Cursor
  // movement while the native message or UIA work is queued cannot replace it.
  std::optional<POINT> ClickPoint() const { return click_point_; }
  // Valid only synchronously inside on_click. Completion runs on the existing
  // MTA worker and must not access UI/channel objects. No fresh/unbound capture.
  bool CaptureClickedSelection(HWND source, ULONGLONG deadline,
      std::function<bool()> canceled,
      std::function<void(translation_selection::Selection)> finish,
      std::function<void()> invalidate, unsigned* accepted_generation = nullptr);
  void ReleaseClickedSelection(unsigned accepted_generation);
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
  void PaintButton();
  bool ButtonHit(POINT screen) const;
  bool hovered_ = false, pressed_ = false;
  int visual_size_ = 0;
  int painted_size_ = 0;
  std::vector<uint32_t> painted_pixels_;
  HWND dispatcher_ = nullptr;
  HWND button_ = nullptr;
  HWND source_ = nullptr;
  HHOOK hook_ = nullptr;
  UINT_PTR timer_ = 0;
  bool worker_available_ = true;
  bool enabled_ = false, dark_ = false, down_ = false, candidate_ = false;
  RECT shown_bounds_{};
  bool shown_ = false;
  bool accepting_click_ = false, click_queued_ = false;
  POINT down_point_{};
  translation_gesture::Gesture gesture_;
  std::optional<POINT> click_point_;
  DWORD last_up_ = 0;
  POINT last_up_point_{};
  ULONGLONG due_ = 0, expires_ = 0, started_ = 0;
  unsigned generation_ = 0;
  unsigned discovery_attempts_ = 0;
  ULONGLONG discovery_started_ = 0;
  std::function<void(HWND)> on_click_;
  std::function<void()> invalidate_click_;
  std::shared_ptr<Worker> worker_;
};
#endif
