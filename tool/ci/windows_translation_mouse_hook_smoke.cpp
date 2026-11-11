// Real WH_MOUSE_LL regression, not a source-string assertion. Run ONLY on an
// explicitly enabled disposable Windows CI desktop: it injects wheel
// input. The owning UI thread never pumps messages while the probes execute.
#include "../../windows/runner/translation_mouse_hook.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <future>

namespace {
constexpr UINT kWake = WM_APP + 0x391;
bool Inject(DWORD timestamp) {
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = MOUSEEVENTF_WHEEL;
  input.mi.mouseData = WHEEL_DELTA;
  input.mi.time = timestamp;
  return SendInput(1, &input, sizeof(input)) == 1;
}
std::atomic<ULONGLONG> control_seen{0};
LRESULT CALLBACK Control(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION && wparam == WM_MOUSEWHEEL &&
      reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam)->time == 0x34560000) {
    control_seen.store(GetTickCount64());
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}
int NegativeControl() {
  const HHOOK hook = SetWindowsHookExW(WH_MOUSE_LL, Control, GetModuleHandleW(nullptr), 0);
  if (!hook) return 10;
  std::atomic<ULONGLONG> began{0};
  auto injection = std::async(std::launch::async, [&] {
    began.store(GetTickCount64());
    return Inject(0x34560000);
  });
  while (!began.load()) Sleep(1);
  Sleep(200); // Deliberately reproduce the old UI-thread installation.
  const bool blocked = control_seen.load() == 0;
  const ULONGLONG deadline = GetTickCount64() + 1000;
  while (!control_seen.load() && GetTickCount64() < deadline) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    Sleep(1);
  }
  const bool inserted = injection.get();
  UnhookWindowsHookEx(hook);
  const ULONGLONG seen = control_seen.load();
  std::printf("HOOK_CONTROL_CHECK|blocked=%d|inserted=%d|seen=%llu|began=%llu\n",
      blocked ? 1 : 0, inserted ? 1 : 0, seen, began.load());
  if (!blocked || !inserted || !seen || seen - began.load() < 150) return 11;
  std::printf("HOOK_UI_THREAD_CONTROL|blockedMs=%llu\n", seen - began.load());
  return 0;
}
int Probe(translation_mouse::Hook& hook) {
  DWORD worst = 0;
  for (DWORD i = 0; i < 20; ++i) {
    const DWORD timestamp = 0x12340000 + i;
    const DWORD began = GetTickCount();
    if (!Inject(timestamp)) return 2;
    bool seen = false;
    while (GetTickCount() - began < 250 && !seen) {
      const auto batch = hook.Take();
      if (batch.lost) {
        // Contention intentionally drops input. Retry the marked probe within
        // the SAME latency budget rather than making a permitted drop flaky.
        if (!Inject(timestamp)) return 3;
        continue;
      }
      for (size_t n = 0; n < batch.count; ++n) {
        if (batch.events[n].message == WM_MOUSEWHEEL && batch.events[n].time == timestamp) seen = true;
      }
      if (!seen) Sleep(1);
    }
    if (!seen) { std::printf("HOOK_PROBE_TIMEOUT|probe=%lu|elapsedMs=%lu\n", i, GetTickCount() - began); return 4; }
    worst = (std::max)(worst, GetTickCount() - began);
    Sleep(10);
  }
  std::printf("HOOK_UI_BLOCKED|probes=20|worstMs=%lu\n", worst);
  return worst < 150 ? 0 : 5;
}
}  // namespace
int main() {
  wchar_t enabled[8]{}, actions[8]{};
  if (!GetEnvironmentVariableW(L"BAOCODE_DISPOSABLE_UI_TEST", enabled, 8) ||
      wcscmp(enabled, L"1") != 0 || !GetEnvironmentVariableW(L"GITHUB_ACTIONS", actions, 8) ||
      wcscmp(actions, L"true") != 0) return 90;
  const HWND dispatcher = CreateWindowExW(0, L"STATIC", L"hook-test", 0,
      0, 0, 1, 1, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!dispatcher) return 1;
  const int control = NegativeControl();
  if (control) return control;
  for (int cycle = 0; cycle < 3; ++cycle) {
    translation_mouse::Hook hook(dispatcher, kWake);
    if (!hook.Start()) return 6;
    auto probes = std::async(std::launch::async, [&] { return Probe(hook); });
    // No GetMessage/PeekMessage/MsgWait here: the UI thread is blocked. Moving
    // hook installation back to this thread makes the marked probes time out.
    const int result = probes.get();
    if (result) return result;
    MSG message{};
    while (PeekMessageW(&message, dispatcher, kWake, kWake, PM_REMOVE)) {}
    auto flood = std::async(std::launch::async, [] {
      for (DWORD i = 0; i < 200; ++i) if (!Inject(0x23450000 + i)) return false;
      Sleep(200);
      return true;
    });
    if (!flood.get()) return 7;
    const auto batch = hook.Take();
    if (!batch.lost || batch.count != 32) return 8;
    unsigned wakes = 0;
    while (PeekMessageW(&message, dispatcher, kWake, kWake, PM_REMOVE)) ++wakes;
    if (wakes != 1) return 9;
  } // Repeated installation and synchronous teardown before destroying HWND.
  DestroyWindow(dispatcher);
  std::puts("PASS dedicated mouse pump: blocked UI, bounded flood, coalesced wake, restart/teardown");
  return 0;
}
