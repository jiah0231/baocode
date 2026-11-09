#ifndef RUNNER_TRANSLATION_ACTION_VISUAL_H_
#define RUNNER_TRANSLATION_ACTION_VISUAL_H_
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>
#include "translation_panel_geometry.h"

// Shared by the native layered window and portable pixel/placement tests.
// All artwork is original vector geometry in DIP, independent of installed fonts.
namespace translation_action_visual {
constexpr int kTile = 30, kShadow = 3, kExtent = kTile + 2 * kShadow;
enum class State { normal, hover, pressed };
inline int Extent(double scale) { return std::max(1, static_cast<int>(std::lround(kExtent * scale))); }
inline translation_panel::Rect Place(translation_panel::Rect line,
    translation_panel::Rect work, double scale) {
  const int size = Extent(scale), gap = std::max(1, static_cast<int>(std::lround(4 * scale)));
  const int width = std::min({size, std::max(1, work.right - work.left),
                              std::max(1, work.bottom - work.top)});
  const int height = width;
  const auto at = [&](int x, int y) {
    x = std::clamp(x, work.left, work.right - width);
    y = std::clamp(y, work.top, work.bottom - height);
    return translation_panel::Rect{x, y, x + width, y + height};
  };
  const int centered = line.top + (line.bottom - line.top - height) / 2;
  const translation_panel::Rect candidates[] = {
    at(line.right + gap, centered), at(line.left - gap - width, centered),
    at(line.right - width, line.bottom + gap), at(line.right - width, line.top - gap - height)};
  auto best = candidates[0];
  long long score = INT64_MAX;
  for (auto r : candidates) {
    const long long overlap = static_cast<long long>(std::max(0,
        std::min(r.right, line.right) - std::max(r.left, line.left))) *
        std::max(0, std::min(r.bottom, line.bottom) - std::max(r.top, line.top));
    if (overlap < score) { best = r; score = overlap; }
    if (!overlap) break;
  }
  return best;
}
inline double RoundedDistance(double x, double y) {
  const double dx = std::abs(x - 18) - 7, dy = std::abs(y - 18) - 7;
  return std::hypot(std::max(0.0, dx), std::max(0.0, dy)) +
      std::min(std::max(dx, dy), 0.0) - 8;
}
inline bool Hit(double x, double y) { return RoundedDistance(x, y) <= 0; }
inline double Segment(double x, double y, double ax, double ay, double bx, double by) {
  const double dx = bx - ax, dy = by - ay;
  const double t = std::clamp(((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy), 0.0, 1.0);
  return std::hypot(x - ax - t * dx, y - ay - t * dy);
}
inline std::vector<uint32_t> Render(int size, bool dark, State state) {
  std::vector<uint32_t> pixels(static_cast<size_t>(size) * size);
  // A compact language-exchange mark: 文 with a small A, not a text-only button.
  constexpr double strokes[][4] = {{13,10,13,12},{8.5,13,18,13},{10,14,17,21},
      {16.5,13,9,22},{18,25,22,15},{22,15,26,25},{19.5,22,24.5,22}};
  const double shade = state == State::pressed ? (dark ? 69 : 226) :
      state == State::hover ? (dark ? 57 : 240) : (dark ? 40 : 253);
  for (int py = 0; py < size; ++py) for (int px = 0; px < size; ++px) {
    double a = 0, r = 0, g = 0, b = 0;
    for (int sy = 0; sy < 4; ++sy) for (int sx = 0; sx < 4; ++sx) {
      const double x = (px + (sx + .5) / 4) * kExtent / size;
      const double y = (py + (sy + .5) / 4) * kExtent / size;
      double alpha = 0, red = 0, green = 0, blue = 0;
      const double shadow = RoundedDistance(x, y - 1);
      if (shadow > 0 && shadow < 3) alpha = (dark ? .32 : .16) * std::pow(1 - shadow / 3, 2);
      const double edge = RoundedDistance(x, y);
      if (edge <= 0) {
        alpha = 1;
        const bool border = edge > -.8;
        red = border ? (dark ? 83 : 214) : shade;
        green = border ? (dark ? 87 : 219) : shade + (dark ? 3 : 0);
        blue = border ? (dark ? 99 : 228) : std::min(255.0, shade + (dark ? 10 : 2));
        const double shift = state == State::pressed ? .5 : 0;
        for (const auto& s : strokes) {
          if (Segment(x, y - shift, s[0], s[1], s[2], s[3]) <= .8) {
            red = dark ? 225 : 55; green = dark ? 231 : 67; blue = dark ? 255 : 104;
            break;
          }
        }
      }
      a += alpha; r += red * alpha; g += green * alpha; b += blue * alpha;
    }
    // UpdateLayeredWindow requires premultiplied BGRA, including AA edges.
    pixels[static_cast<size_t>(py) * size + px] =
        (static_cast<uint32_t>(std::lround(a * 255 / 16)) << 24) |
        (static_cast<uint32_t>(std::lround(r / 16)) << 16) |
        (static_cast<uint32_t>(std::lround(g / 16)) << 8) |
        static_cast<uint32_t>(std::lround(b / 16));
  }
  return pixels;
}
}  // namespace translation_action_visual
#endif
