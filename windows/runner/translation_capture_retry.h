#ifndef RUNNER_TRANSLATION_CAPTURE_RETRY_H_
#define RUNNER_TRANSLATION_CAPTURE_RETRY_H_
#include <cstdint>

namespace translation_retry {
constexpr unsigned kMaxAttempts = 4;
inline uint64_t Delay(unsigned completed_attempts) {
  return 80 * static_cast<uint64_t>(completed_attempts);
}
// The caller must already have affirmed non-password, text-control type,
// keyboard focus, source process and stable UIA element identity. This policy
// only budgets retries of incomplete initialization; empty/denied selections
// are not initialization failures. Reserve one bounded provider transaction.
inline bool CanRetry(bool incomplete, unsigned completed_attempts,
                     uint64_t now, uint64_t deadline, bool canceled = false) {
  return incomplete && !canceled && completed_attempts > 0 &&
      completed_attempts < kMaxAttempts && now < deadline &&
      deadline - now > Delay(completed_attempts) + 200;
}
// Windows UIA's timeout HRESULT. This is the sole pre-identity retry: it
// repeats only GetFocusedElement, before any text or control was accepted.
constexpr uint32_t kInitialFocusTimeout = 0x80131505u;
inline bool CanRetryInitialFocus(uint32_t hresult, bool identity_bound,
                                 bool same_foreground, unsigned completed_attempts,
                                 uint64_t now, uint64_t deadline, bool canceled = false) {
  return hresult == kInitialFocusTimeout && !identity_bound && same_foreground &&
      CanRetry(true, completed_attempts, now, deadline, canceled);
}
}  // namespace translation_retry
#endif
