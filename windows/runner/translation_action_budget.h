#ifndef RUNNER_TRANSLATION_ACTION_BUDGET_H_
#define RUNNER_TRANSLATION_ACTION_BUDGET_H_
#include <cstdint>
namespace translation_action_budget {
// The first UIA connection can be cold. All attempts share the original
// gesture's lifetime, including debounce and queueing; retries never renew it.
constexpr uint64_t kDiscoveryMs = 1500;
constexpr uint64_t kRefreshMs = 700;
constexpr uint64_t DiscoveryDeadline(uint64_t gesture_started) {
  return gesture_started + kDiscoveryMs;
}
constexpr uint64_t RequestDeadline(bool shown, uint64_t gesture_started,
                                   uint64_t request_started) {
  return shown ? request_started + kRefreshMs : DiscoveryDeadline(gesture_started);
}
constexpr bool Expired(uint64_t now, uint64_t deadline) {
  return now >= deadline;
}
}  // namespace translation_action_budget
#endif
