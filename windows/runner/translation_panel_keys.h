#ifndef RUNNER_TRANSLATION_PANEL_KEYS_H_
#define RUNNER_TRANSLATION_PANEL_KEYS_H_
namespace translation_panel {
enum class CloseKeyAction { pass, consume, close };
// Called only for F4 messages delivered to the popup's own child HWND. Own
// this exact key sequence, not a time interval or unrelated keyboard input.
class CloseKeySequence {
 public:
  CloseKeyAction Handle(bool down, bool up, bool alt, bool repeat) {
    if (down && alt) {
      armed_ = true;
      return repeat ? CloseKeyAction::consume : CloseKeyAction::close;
    }
    if (up && armed_) {
      armed_ = false;
      return CloseKeyAction::consume;
    }
    // Key-up can go to the restored external source. A later plain F4 must
    // not inherit that old sequence, even though its key-up was never ours.
    if (down) armed_ = false;
    return CloseKeyAction::pass;
  }
 private:
  bool armed_ = false;
};
}  // namespace translation_panel
#endif
