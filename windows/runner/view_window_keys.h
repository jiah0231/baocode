#ifndef RUNNER_VIEW_WINDOW_KEYS_H_
#define RUNNER_VIEW_WINDOW_KEYS_H_
#include <cstdint>
namespace view_window_keys {
// A tool window can finish a native key gesture after its focus returns to
// another view of the same engine. Ownership ends on key-up, not elapsed time.
class OwnedKeyRelease {
 public:
  void Own(uint32_t key) { key_ = key; }
  bool Consume(uint32_t key, bool down, bool up, bool repeat) {
    if (!key_ || key != key_) return false;
    if (up) { key_ = 0; return true; }
    if (down && repeat) return true;
    // Its release may have gone to another process. A new physical press
    // starts a distinct gesture and must retain the normal app binding.
    if (down) key_ = 0;
    return false;
  }
 private:
  uint32_t key_ = 0;
};
}  // namespace view_window_keys
#endif
