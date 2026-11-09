#ifndef RUNNER_TRANSLATION_PANEL_GEOMETRY_H_
#define RUNNER_TRANSLATION_PANEL_GEOMETRY_H_
#include <algorithm>
#include <cmath>
#include <optional>

namespace translation_panel {
struct Rect {
  int left;
  int top;
  int right;
  int bottom;
};
constexpr int kCompactWidth = 360;
constexpr int kCompactHeight = 300;
struct Point { int x; int y; };

// Capture-time pointer coordinates, not the later cursor position after the
// Flutter view has rendered. A keyboard selection far from the pointer uses
// its final visible line's endpoint, never the beginning of a long selection.
inline Point FollowPoint(Point pointer, std::optional<Rect> selection, int near_distance,
                         std::optional<Rect> area = std::nullopt) {
  const auto proximity = area ? area : selection;
  if (!selection || (pointer.x >= proximity->left - near_distance &&
      pointer.x <= proximity->right + near_distance && pointer.y >= proximity->top - near_distance &&
      pointer.y <= proximity->bottom + near_distance)) return pointer;
  return {selection->right, selection->bottom};
}
inline Rect Inset(Rect work, int margin) {
  const int x = std::min(margin, std::max(0, (work.right - work.left - 1) / 2));
  const int y = std::min(margin, std::max(0, (work.bottom - work.top - 1) / 2));
  return {work.left + x, work.top + y, work.right - x, work.bottom - y};
}

// Physical screen coordinates throughout. Prefer the cursor's lower-right,
// flip left/up at edges, and avoid all visible selected lines where possible.
// The popup stays still while reading; only a fresh request calls this again.
inline Rect CompactPlacement(Point point, std::optional<Rect> selection,
                             Rect work, double scale) {
  const int gap = std::max(1, static_cast<int>(std::lround(10 * scale)));
  work = Inset(work, std::max(1, static_cast<int>(std::lround(8 * scale))));
  const int width = std::clamp(static_cast<int>(std::lround(kCompactWidth * scale)),
                             1, std::max(1, work.right - work.left));
  const int height = std::clamp(static_cast<int>(std::lround(kCompactHeight * scale)),
                              1, std::max(1, work.bottom - work.top));
  int left = point.x + gap;
  if (left + width > work.right) left = point.x - gap - width;
  const auto at = [&](int x, int y) {
    x = std::clamp(x, work.left, work.right - width);
    y = std::clamp(y, work.top, work.bottom - height);
    return Rect{x, y, x + width, y + height};
  };
  const auto overlap = [&](Rect r) -> long long {
    if (!selection) return 0;
    return static_cast<long long>(std::max(0, std::min(r.right, selection->right) -
        std::max(r.left, selection->left))) *
        std::max(0, std::min(r.bottom, selection->bottom) - std::max(r.top, selection->top));
  };
  const int bottom = selection ? std::max(point.y, selection->bottom) : point.y;
  const int top = selection ? std::min(point.y, selection->top) : point.y;
  const Rect candidates[] = {
    at(left, bottom + gap), at(left, top - gap - height),
    at(selection ? selection->right + gap : point.x + gap, point.y + gap),
    at(selection ? selection->left - gap - width : point.x - gap - width, point.y + gap),
  };
  Rect best = candidates[0];
  long long score = overlap(best);
  for (const Rect candidate : candidates) {
    const bool below = candidate.top >= bottom + gap;
    const bool above = candidate.bottom <= top - gap;
    const bool side = selection && (candidate.left >= selection->right + gap ||
                                   candidate.right <= selection->left - gap);
    if ((below || above || side) && overlap(candidate) == 0) return candidate;
    if (overlap(candidate) < score) { best = candidate; score = overlap(candidate); }
  }
  return best;  // A screen-sized selection leaves no nonoverlapping rectangle.
}
// UIA is an external provider: reject NaN, infinity, overflow, empty and
// unreasonable rectangles before converting its doubles to screen pixels.
inline std::optional<Rect> SelectionRect(double x, double y, double width,
                                         double height) {
  constexpr double limit = 1000000;
  if (!std::isfinite(x) || !std::isfinite(y) ||
      !std::isfinite(width) || !std::isfinite(height) ||
      width <= 0 || height <= 0 || width > limit || height > limit ||
      x < -limit || y < -limit || x + width > limit || y + height > limit)
    return std::nullopt;
  return Rect{static_cast<int>(std::floor(x)), static_cast<int>(std::floor(y)),
              static_cast<int>(std::ceil(x + width)),
              static_cast<int>(std::ceil(y + height))};
}
// All input rectangles use physical virtual-screen pixels, including negative
// monitor origins. Prefer below the selection; flip above before clamping.
inline Rect Place(Rect anchor, Rect work, int width, int height, int gap) {
  width = std::clamp(width, 1, std::max(1, work.right - work.left));
  height = std::clamp(height, 1, std::max(1, work.bottom - work.top));
  int top = anchor.bottom + gap;
  if (top + height > work.bottom) top = anchor.top - gap - height;
  const int left = std::clamp(anchor.left, work.left, work.right - width);
  top = std::clamp(top, work.top, work.bottom - height);
  return {left, top, left + width, top + height};
}
}  // namespace translation_panel
#endif
