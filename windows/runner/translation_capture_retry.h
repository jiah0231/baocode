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
}  // namespace translation_retry
#endif
