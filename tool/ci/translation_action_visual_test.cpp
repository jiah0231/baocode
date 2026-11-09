#include "../../windows/runner/translation_action_visual.h"
#include <cassert>
#include <cstdio>
#include <fstream>
using namespace translation_action_visual;
int main(int argc, char** argv) {
  for (double scale : {1., 1.25, 1.5, 2., 3.}) {
    const int size = Extent(scale);
    for (bool dark : {false, true}) {
      const auto normal = Render(size, dark, State::normal);
      const auto hover = Render(size, dark, State::hover);
      const auto pressed = Render(size, dark, State::pressed);
      assert(normal != hover && hover != pressed && normal != pressed);
      assert(normal.front() == 0 && normal.back() == 0);
      int opaque = 0, partial = 0, ink = 0;
      for (auto p : normal) {
        const unsigned a = p >> 24, r = (p >> 16) & 255, g = (p >> 8) & 255, b = p & 255;
        assert(r <= a && g <= a && b <= a); // Premultiplied, never edge halos.
        opaque += a == 255;
        partial += a > 0 && a < 255;
        ink += a == 255 && (dark ? r > 180 : r < 100);
      }
      assert(opaque > size * size / 2 && partial > size && ink > 10 * scale * scale);
      assert(normal == Render(size, dark, State::normal));
      for (const auto& pixels : {normal, hover, pressed}) {
        int shadow_hits = 0;
        for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
          const bool hit = PixelHit(pixels, size, x, y);
          assert(hit == ((pixels[y * size + x] >> 24) != 0));
          if (hit && RoundedDistance((x + .5) * kExtent / size,
                                     (y + .5) * kExtent / size) > 0) ++shadow_hits;
        }
        assert(shadow_hits > 0); // The visible shadow belongs to the button too.
        assert(!PixelHit(pixels, size, 0, 0)); // Fully transparent corners pass through.
        assert(!PixelHit(pixels, size, -1, size / 2));
        assert(!PixelHit(pixels, size, size, size / 2));
        assert(!PixelHit(pixels, size, size / 2, -1));
        assert(!PixelHit(pixels, size, size / 2, size));
      }
    }
    for (auto work : {translation_panel::Rect{0,0,1920,1040},
                      translation_panel::Rect{-1920,-1080,0,0}}) {
      for (int x : {work.left, work.left + 500, work.right - 300}) {
        for (int y : {work.top, work.top + 400, work.bottom - 20}) {
          const translation_panel::Rect line{x,y,x+300,y+20};
          const auto r = Place(line, work, scale);
          assert(r.left >= work.left && r.top >= work.top && r.right <= work.right && r.bottom <= work.bottom);
          assert(r.right - r.left == size && r.bottom - r.top == size);
          assert(r.right <= line.left || r.left >= line.right || r.bottom <= line.top || r.top >= line.bottom);
        }
      }
    }
  }
  auto r = Place({100,100,300,120}, {0,0,1920,1040}, 1);
  assert(r.left == 304 && r.top == 92); // Beside the final line, not below a cursor.
  r = Place({1600,100,1920,120}, {0,0,1920,1040}, 1);
  assert(r.right == 1596); // Flip left at the right screen edge.
  r = Place({0,100,1920,120}, {0,0,1920,1040}, 1);
  assert(r.top == 124); // Full-width line uses below instead of covering text.
  assert(!PixelHit({}, 36, 18, 18) && !PixelHit({}, 0, 0, 0));
  if (argc > 1) {
    // Optional contact sheet from the exact production rasterizer, not a mock.
    constexpr int cell = 108, width = cell * 3, height = cell * 2;
    std::vector<uint32_t> sheet(width * height);
    for (int row = 0; row < 2; ++row) for (int col = 0; col < 3; ++col) {
      const auto icon = Render(cell, row != 0, static_cast<State>(col));
      for (int y = 0; y < cell; ++y) for (int x = 0; x < cell; ++x) {
        const auto p = icon[y * cell + x];
        const int a = p >> 24, bg = row ? 24 : 238;
        uint32_t rgb = 0;
        for (int shift : {0,8,16}) rgb |= (std::min(255, static_cast<int>((p >> shift) & 255) + bg * (255-a) / 255) << shift);
        sheet[(row * cell + y) * width + col * cell + x] = rgb;
      }
    }
    std::ofstream out(argv[1], std::ios::binary);
    out << "P6\n" << width << ' ' << height << "\n255\n";
    for (auto p : sheet) for (int shift : {16,8,0}) out.put(static_cast<char>((p >> shift) & 255));
    assert(out.good());
  }
  std::puts("PASS selection entry: original vector pixels, alpha/AA, theme/states, DPI, edge placement");
}
