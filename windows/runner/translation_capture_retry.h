#ifndef RUNNER_TRANSLATION_CAPTURE_RETRY_H_
#define RUNNER_TRANSLATION_CAPTURE_RETRY_H_
#include <cstdint>

namespace translation_retry {
constexpr unsigned kMaxAttempts = 4;
inline uint64_t Delay(unsigned completed_attempts) {
  return 80 * static_cast<uint64_t>(completed_attempts);
}
// Budget only: the caller must separately establish a permitted initial
// discovery category below, or an incomplete pattern on an already verified
// non-password focused text control with stable identity. Empty/denied
// selections do not qualify. Reserve one bounded provider transaction.
inline bool CanRetry(bool incomplete, unsigned completed_attempts,
                     uint64_t now, uint64_t deadline, bool canceled = false) {
  return incomplete && !canceled && completed_attempts > 0 &&
      completed_attempts < kMaxAttempts && now < deadline &&
      deadline - now > Delay(completed_attempts) + 200;
}
// Windows UIA's timeout HRESULT. This pre-identity retry
// repeats only GetFocusedElement, before any text or control was accepted.
constexpr uint32_t kInitialFocusTimeout = 0x80131505u;
inline bool CanRetryInitialFocus(uint32_t hresult, bool identity_bound,
                                 bool same_foreground, unsigned completed_attempts,
                                 uint64_t now, uint64_t deadline, bool canceled = false) {
  return hresult == kInitialFocusTimeout && !identity_bound && same_foreground &&
      CanRetry(true, completed_attempts, now, deadline, canceled);
}
// A Chromium accessibility root may exist before its actual focused text
// control. This permits metadata requery only, never accepting that Pane's
// focus state or reading its value/descendants. All properties must be known.
inline bool IsInitialChromiumPane(bool identity_bound, bool same_foreground,
                                  bool same_process, bool known_non_password,
                                  bool known_unfocused, bool is_pane,
                                  bool chromium_window) {
  return !identity_bound && same_foreground && same_process &&
      known_non_password && known_unfocused && is_pane && chromium_window;
}
// Final validation may wait for the already-bound element to become visible
// to UIA again. It must never adopt a replacement identity or reread text.
inline bool CanRetryFinalFocus(bool identity_bound, bool same_foreground,
                               bool exact_timeout, bool transient_chromium_pane,
                               unsigned completed_attempts, uint64_t now,
                               uint64_t deadline, bool canceled = false) {
  return identity_bound && same_foreground && completed_attempts < 3 &&
      CanRetry(exact_timeout || transient_chromium_pane, completed_attempts,
               now, deadline, canceled);
}
}  // namespace translation_retry
#endif
