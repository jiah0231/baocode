#ifndef RUNNER_TRANSLATION_MOUSE_MAILBOX_H_
#define RUNNER_TRANSLATION_MOUSE_MAILBOX_H_
#include <array>
#include <atomic>
#include <cstddef>
#include <mutex>
#include <utility>

namespace translation_mouse {
// Bounded metadata handoff. The producer (a system input callback) NEVER waits
// for the consumer. Lost input invalidates a gesture instead of replaying it.
template <typename Event, typename Snapshot, size_t Capacity = 32>
class Mailbox {
 public:
  struct Batch {
    std::array<Event, Capacity> events{};
    size_t count = 0;
    bool lost = false;
  };
  template <typename Skip>
  bool Push(const Event& event, Skip skip) {
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock()) {
      lost_.store(true);
    } else if (skip(snapshot_)) {
      return false;
    } else if (batch_.count == Capacity) {
      lost_.store(true);
    } else {
      batch_.events[batch_.count++] = event;
    }
    return !notified_.exchange(true);
  }
  Batch Take() {
    std::lock_guard<std::mutex> lock(mutex_);
    Batch result = batch_;
    batch_.count = 0;
    notified_.store(false);
    result.lost = lost_.exchange(false);
    return result;
  }
  void Publish(Snapshot snapshot) {
    // Destroy the old snapshot after releasing the lock.
    { std::lock_guard<std::mutex> lock(mutex_); std::swap(snapshot_, snapshot); }
  }
  void PostFailed() {
    lost_.store(true);
    notified_.store(false);
  }
 private:
  std::mutex mutex_;
  Snapshot snapshot_{};
  Batch batch_{};
  std::atomic<bool> lost_{false}, notified_{false};
};
}  // namespace translation_mouse
#endif
