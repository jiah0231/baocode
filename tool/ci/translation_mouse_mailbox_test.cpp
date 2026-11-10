#include "../../windows/runner/translation_mouse_mailbox.h"
#include <cstdlib>
#include <chrono>
#include <cstdio>
#include <thread>

#define CHECK(condition) do { if (!(condition)) { \
  std::fprintf(stderr, "CHECK failed at line %d: %s\n", __LINE__, #condition); \
  std::abort(); \
} } while (false)

struct Snapshot {
  int value = 0;
  inline static std::atomic<bool> hold{false}, entered{false};
  Snapshot() = default;
  explicit Snapshot(int v) : value(v) {}
  Snapshot(Snapshot&& other) noexcept : value(other.value) {}
  Snapshot& operator=(Snapshot&& other) noexcept {
    if (hold.load()) {
      entered.store(true);
      while (hold.load()) std::this_thread::yield();
    }
    value = other.value;
    return *this;
  }
};
int main() {
  using Inbox = translation_mouse::Mailbox<int, Snapshot, 4>;
  Inbox inbox;
  const auto accept = [](const Snapshot&) { return false; };
  CHECK(inbox.Push(1, accept));
  CHECK(!inbox.Push(2, accept));
  auto batch = inbox.Take();
  CHECK(!batch.lost && batch.count == 2 && batch.events[0] == 1 && batch.events[1] == 2);
  CHECK(inbox.Take().count == 0);
  inbox.Publish(Snapshot(7));
  CHECK(!inbox.Push(3, [](const Snapshot& s) { return s.value == 7; }));
  CHECK(inbox.Take().count == 0);
  CHECK(inbox.Push(0, accept));
  for (int i = 1; i < 10000; ++i) CHECK(!inbox.Push(i, accept));
  batch = inbox.Take();
  CHECK(batch.lost && batch.count == 4); // Bounded even while UI is stopped.
  CHECK(inbox.Push(5, accept));
  inbox.PostFailed();
  CHECK(inbox.Push(6, accept));
  CHECK(inbox.Take().lost);

  // Hold the consumer's lock deliberately. The input producer must return,
  // report lost input and schedule invalidation without waiting for the UI.
  Snapshot::hold.store(true);
  std::thread ui([&] { inbox.Publish(Snapshot(8)); });
  while (!Snapshot::entered.load()) std::this_thread::yield();
  const auto start = std::chrono::steady_clock::now();
  CHECK(inbox.Push(7, accept));
  CHECK(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(100));
  Snapshot::hold.store(false);
  ui.join();
  batch = inbox.Take();
  CHECK(batch.lost && batch.count == 0);
  CHECK(inbox.Push(8, accept));
  batch = inbox.Take();
  CHECK(!batch.lost && batch.count == 1 && batch.events[0] == 8);
  std::atomic<bool> done{false};
  std::thread producer([&] {
    for (int n = 1; n <= 100000; ++n) inbox.Push(n, accept);
    done.store(true);
  });
  int previous = 0;
  do {
    const auto concurrent = inbox.Take();
    for (size_t n = 0; n < concurrent.count; ++n) {
      CHECK(concurrent.events[n] > previous);
      previous = concurrent.events[n];
    }
  } while (!done.load());
  producer.join();
  batch = inbox.Take();
  for (size_t n = 0; n < batch.count; ++n) {
    CHECK(batch.events[n] > previous);
    previous = batch.events[n];
  }
  std::puts("Mouse mailbox: bounded, ordered, coalesced, nonblocking and fail-closed");
}
