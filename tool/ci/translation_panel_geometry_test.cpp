#include "../../windows/runner/translation_panel_geometry.h"
#include <cassert>
#include <cstdio>
using namespace translation_panel;
bool Same(Rect a, Rect b) { return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom; }
bool Inside(Rect a, Rect b) { return a.left >= b.left && a.top >= b.top && a.right <= b.right && a.bottom <= b.bottom; }
bool Overlaps(Rect a, Rect b) { return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top; }
int main() {
  const Rect work{0, 0, 1920, 1040};
  const Rect line{100, 100, 900, 120};
  const auto p = FollowPoint({895, 111}, line, 48);
  assert(p.x == 895 && p.y == 111);
  auto r = CompactPlacement(p, line, work, 1);
  assert(Same(r, {905, 130, 1265, 430}));
  const auto reverse = FollowPoint({105, 111}, line, 48);
  assert(reverse.x == 105);
  assert(CompactPlacement(reverse, line, work, 1).left == 115);
  const auto keyboard = FollowPoint({1800, 800}, line, 48);
  assert(keyboard.x == 899 && keyboard.y == 119);
  // Neighboring displays need not share DPI: proximity belongs to the
  // pointer display (200%), then placement uses the resolved display (200%).
  const Rect neighboring_selection{-300, 100, 0, 120};
  const auto mixed = FollowPoint({70,110}, neighboring_selection, 96);
  assert(mixed.x == 70 && mixed.y == 110);
  r = CompactPlacement(mixed, neighboring_selection, {0,0,1920,1040}, 2);
  assert(r.left == 90 && r.right-r.left == 720);
  const auto remote_keyboard = FollowPoint({500,110}, neighboring_selection, 96);
  assert(remote_keyboard.x == -1 && remote_keyboard.y == 119);
  r = CompactPlacement(remote_keyboard, neighboring_selection, {-1920,0,0,1040}, 1.25);
  assert(r.right < 0 && r.right-r.left == 450);
  const auto multiline = FollowPoint({120, 120}, Rect{100, 180, 300, 200}, 48, Rect{100,100,900,200});
  assert(multiline.x == 120 && multiline.y == 120);
  r = CompactPlacement({1870, 1000}, Rect{1600,980,1880,1010}, work, 1);
  assert(Same(r, {1500, 670, 1860, 970}));
  r = CompactPlacement({-40, -40}, Rect{-300,-60,-30,-20}, {-1920,-1080,0,0}, 1.5);
  assert(Same(r, {-595,-525,-55,-75}));
  for (double scale : {1., 1.25, 1.5, 2.}) {
    for (Rect monitor : {work, Rect{-1920, 0, 0, 1040}, Rect{1920,-1080,3840,0}}) {
      for (Point pointer : {Point{monitor.left+20,monitor.top+20}, Point{monitor.right-20,monitor.bottom-20}, Point{monitor.left+500,monitor.top+500}}) {
        const Rect selected{pointer.x-100,pointer.y-10,pointer.x,pointer.y+10};
        r = CompactPlacement(pointer, selected, monitor, scale);
        assert(Inside(r, monitor)); assert(!Overlaps(r, selected));
        assert(r.right-r.left == static_cast<int>(std::lround(360*scale)));
        assert(r.bottom-r.top == static_cast<int>(std::lround(300*scale)));
      }
    }
  }
  r = CompactPlacement({200,200}, Rect{5,5,315,235}, {0,0,320,240}, 2);
  assert(Inside(r,{0,0,320,240}));
  const Rect tall{100,0,200,1040};
  r = CompactPlacement({180,500}, tall, work, 1);
  assert(!Overlaps(r,tall) && r.left == 210);
  puts("PASS: compact cursor/keyboard anchoring, reverse selection, all edges, negative monitors, 100-200% DPI, multiline avoidance, tiny work area");
}
