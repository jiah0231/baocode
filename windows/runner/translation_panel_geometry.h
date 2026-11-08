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
