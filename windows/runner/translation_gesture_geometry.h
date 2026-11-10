#ifndef RUNNER_TRANSLATION_GESTURE_GEOMETRY_H_
#define RUNNER_TRANSLATION_GESTURE_GEOMETRY_H_
#include <cstdint>
#include "translation_panel_geometry.h"

namespace translation_gesture {
using translation_panel::Point;
using translation_panel::Rect;
// The completed selection gesture, never the cursor's position at icon click.
// All coordinates and tolerance use physical virtual-screen pixels.
struct Gesture {
  Point start{}, end{};
  int tolerance = 0;
};
class BoundsMatch {
 public:
  explicit BoundsMatch(Gesture gesture) : gesture_(gesture) {}
  void Add(Rect line) {
    if (line.right <= line.left || line.bottom <= line.top) return;
    start_ = start_ || Near(gesture_.start, line);
    end_ = end_ || Near(gesture_.end, line);
  }
  // Either endpoint may be outside the text: dragging into a margin or
  // auto-scrolling a long selection is valid. Requiring one actual line near
  // either endpoint catches wholly unrelated ranges without rejecting those
  // gestures. This is a disagreement guard, not proof of the returned text.
  bool Matches() const { return start_ || end_; }
 private:
  bool Near(Point point, Rect line) const {
    const int64_t gap = std::max(0, gesture_.tolerance);
    return static_cast<int64_t>(point.x) >= static_cast<int64_t>(line.left) - gap &&
        static_cast<int64_t>(point.x) <= static_cast<int64_t>(line.right) + gap &&
        static_cast<int64_t>(point.y) >= static_cast<int64_t>(line.top) - gap &&
        static_cast<int64_t>(point.y) <= static_cast<int64_t>(line.bottom) + gap;
  }
  Gesture gesture_;
  bool start_ = false, end_ = false;
};
}  // namespace translation_gesture
#endif
