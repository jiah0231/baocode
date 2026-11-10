// Default Edge + local synthetic HTML, no forced accessibility switches.
// Calls the production capture header; never sends Ctrl+C or reads document text.
#include "../../windows/runner/translation_selection.h"
#include <dwmapi.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace {
HWND browser = nullptr;
HWND renderer = nullptr;
std::wstring titleToken;
LONG rendererArea = 0;
void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
BOOL CALLBACK FindBrowser(HWND w, LPARAM) {
  wchar_t title[512]{}; GetWindowTextW(w, title, 512);
  wchar_t cls[128]{}; GetClassNameW(w, cls, 128);
  if (IsWindowVisible(w) && std::wstring(cls) == L"Chrome_WidgetWin_1" &&
      std::wstring(title).find(titleToken) != std::wstring::npos) browser = w;
  return TRUE;
}
BOOL CALLBACK FindRenderer(HWND w, LPARAM) {
  wchar_t cls[128]{}; GetClassNameW(w, cls, 128);
  RECT r{}; GetWindowRect(w, &r);
  const LONG area = (r.right-r.left) * (r.bottom-r.top);
  if (IsWindowVisible(w) && std::wstring(cls) == L"Chrome_RenderWidgetHostHWND" && area > rendererArea) {
    rendererArea = area; renderer = w;
  }
  return TRUE;
}
void Mouse(POINT p, DWORD flags) {
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  Check(width > 1 && height > 1, "Interactive desktop unavailable");
  INPUT input{}; input.type = INPUT_MOUSE;
  input.mi.dx = MulDiv(p.x-GetSystemMetrics(SM_XVIRTUALSCREEN), 65535, width-1);
  input.mi.dy = MulDiv(p.y-GetSystemMetrics(SM_YVIRTUALSCREEN), 65535, height-1);
  input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | flags;
  Check(SendInput(1, &input, sizeof(INPUT)) == 1, "Browser mouse input failed");
}
void DragLine(int line) {
  RECT r{}; Check(GetWindowRect(renderer, &r) != 0, "Renderer bounds unavailable");
  const int dpi = static_cast<int>(GetDpiForWindow(browser));
  // First click an actual glyph to give the document keyboard focus, rather
  // than starting from paragraph padding. No UIA warm-up or scripted selection.
  // CSS paragraph left40 + padding32 places its first glyph at72. Start one
  // pixel into that glyph's leading half, which maps to its initial caret.
  const POINT from{r.left+MulDiv(73, dpi, 96), r.top+MulDiv(92+100*line, dpi, 96)};
  const POINT focus{r.left+MulDiv(120, dpi, 96), from.y};
  const POINT to{r.left+MulDiv(800, dpi, 96), from.y};
  Check(to.x < r.right && to.y < r.bottom, "Browser viewport too small for fixture");
  Mouse(focus, 0); Mouse(focus, MOUSEEVENTF_LEFTDOWN); Sleep(40); Mouse(focus, MOUSEEVENTF_LEFTUP);
  Sleep(GetDoubleClickTime() + 80); // Next down must be a drag, not word selection.
  Mouse(from, 0); Sleep(80); Mouse(from, MOUSEEVENTF_LEFTDOWN);
  for (int i = 1; i <= 16; ++i) {
    Mouse(POINT{from.x+(to.x-from.x)*i/16, from.y}, 0); Sleep(20);
  }
  Mouse(to, MOUSEEVENTF_LEFTUP);
  // Edge's default selection mini-menu can appear beside the release point.
  // Move away without clicking or pressing Escape, preserving selection/focus.
  Mouse(POINT{r.left+MulDiv(24, dpi, 96), r.top+MulDiv(400, dpi, 96)}, 0);
  Sleep(350);
}
void SyntheticMismatch(const std::wstring& actual, const std::wstring& expected) {
  // Test fixture only: never add selected-text diagnostics to production code.
  std::printf("SYNTHETIC_EDGE_MISMATCH|expectedUnits=%zu|actualUnits=%zu|actual=", expected.size(), actual.size());
  for (size_t i = 0; i < actual.size() && i < 160; ++i) {
    const unsigned unit = static_cast<unsigned>(actual[i]);
    if (unit >= 32 && unit <= 126) std::putchar(static_cast<int>(unit));
    else std::printf("\\u%04X", unit);
  }
  std::printf("|codepoints=");
  for (size_t i = 0; i < actual.size() && i < 160; ++i) {
    unsigned cp = static_cast<unsigned>(actual[i]);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < actual.size()) {
      const unsigned next = static_cast<unsigned>(actual[i + 1]);
      if (next >= 0xdc00 && next <= 0xdfff) { cp = 0x10000 + ((cp - 0xd800) << 10) + next - 0xdc00; ++i; }
    }
    std::printf("U+%04X ", cp);
  }
  std::printf("\n");
}
void SyntheticScreenshot(const std::wstring& path) {
  // Only the isolated browser's rectangle, while foreground, on guarded CI.
  Check(GetForegroundWindow() == browser, "Refusing screenshot of background browser");
  RECT r{};
  Check(SUCCEEDED(DwmGetWindowAttribute(browser, DWMWA_EXTENDED_FRAME_BOUNDS,
      &r, sizeof(r))), "Browser visible-frame screenshot bounds unavailable");
  // GetWindowRect includes invisible resize borders and can capture desktop
  // strips. DWM's visible frame is required; do not fall back to outer bounds.
  const int width = r.right-r.left, height = r.bottom-r.top;
  Check(width > 0 && height > 0, "Browser screenshot dimensions invalid");
  HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  Check(bitmap && pixels, "Browser screenshot allocation failed");
  auto old = SelectObject(dc, bitmap);
  Check(BitBlt(dc, 0, 0, width, height, screen, r.left, r.top, SRCCOPY) != 0, "Browser screenshot failed");
  GdiFlush();
  BITMAPFILEHEADER header{}; header.bfType = 0x4d42;
  header.bfOffBits = sizeof(header) + sizeof(BITMAPINFOHEADER);
  const DWORD bytes = static_cast<DWORD>(width * height * 4);
  header.bfSize = header.bfOffBits + bytes;
  FILE* file = nullptr; _wfopen_s(&file, path.c_str(), L"wb"); Check(file != nullptr, "Browser screenshot file failed");
  fwrite(&header, sizeof(header), 1, file); fwrite(&info.bmiHeader, sizeof(BITMAPINFOHEADER), 1, file);
  fwrite(pixels, bytes, 1, file); fclose(file);
  SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr, screen);
}
struct NativeWindowSnapshot {
  HWND window = nullptr, root = nullptr;
  DWORD process = 0, thread = 0, cloaked = 0;
  UINT dpi = 0;
  BOOL visible = FALSE, iconic = FALSE, rect_ok = FALSE;
  HRESULT cloak_result = E_FAIL;
  RECT rect{};
  wchar_t window_class[128]{};
};
NativeWindowSnapshot ReadNativeWindow(HWND window) {
  NativeWindowSnapshot snapshot;
  snapshot.window = window;
  if (!window) return snapshot;
  snapshot.root = GetAncestor(window, GA_ROOT);
  snapshot.thread = GetWindowThreadProcessId(window, &snapshot.process);
  snapshot.dpi = GetDpiForWindow(window);
  snapshot.visible = IsWindowVisible(window);
  snapshot.iconic = IsIconic(window);
  snapshot.rect_ok = GetWindowRect(window, &snapshot.rect);
  GetClassNameW(window, snapshot.window_class, 128);
  snapshot.cloak_result = DwmGetWindowAttribute(window, DWMWA_CLOAKED,
      &snapshot.cloaked, sizeof(snapshot.cloaked));
  return snapshot;
}
struct NativeFocusSnapshot {
  ULONGLONG tick = 0;
  NativeWindowSnapshot source, content, foreground, focus;
  GUITHREADINFO source_gui{}, foreground_gui{};
  BOOL source_gui_ok = FALSE, foreground_gui_ok = FALSE;
};
NativeFocusSnapshot ReadNativeFocus() {
  // Win32 only: observing input focus must not awaken the UIA provider before
  // the cold production Capture call. Save both snapshots before printing.
  NativeFocusSnapshot snapshot;
  snapshot.tick = GetTickCount64();
  snapshot.source = ReadNativeWindow(browser);
  snapshot.content = ReadNativeWindow(renderer);
  snapshot.foreground = ReadNativeWindow(GetForegroundWindow());
  snapshot.source_gui.cbSize = sizeof(snapshot.source_gui);
  snapshot.foreground_gui.cbSize = sizeof(snapshot.foreground_gui);
  if (snapshot.source.thread)
    snapshot.source_gui_ok = GetGUIThreadInfo(snapshot.source.thread, &snapshot.source_gui);
  if (snapshot.foreground.thread)
    snapshot.foreground_gui_ok = GetGUIThreadInfo(snapshot.foreground.thread, &snapshot.foreground_gui);
  snapshot.focus = ReadNativeWindow(snapshot.source_gui.hwndFocus);
  return snapshot;
}
void PrintNativeWindow(const char* selection, const char* phase, const char* role,
                       const NativeWindowSnapshot& snapshot) {
  std::printf("DEFAULT_EDGE_NATIVE_WINDOW|%s|%s|role=%s|hwnd=%p|root=%p|pid=%lu|tid=%lu|class=%ls|visible=%d|iconic=%d|dpi=%u|rectOK=%d|rect=%ld,%ld,%ld,%ld|cloakHR=0x%08lX|cloaked=%lu\n",
      selection, phase, role, static_cast<void*>(snapshot.window),
      static_cast<void*>(snapshot.root), snapshot.process, snapshot.thread,
      snapshot.window_class, snapshot.visible, snapshot.iconic, snapshot.dpi,
      snapshot.rect_ok, snapshot.rect.left, snapshot.rect.top,
      snapshot.rect.right, snapshot.rect.bottom,
      static_cast<unsigned long>(snapshot.cloak_result), snapshot.cloaked);
}
void PrintNativeFocus(const char* selection, const char* phase,
                      const NativeFocusSnapshot& snapshot) {
  std::printf("DEFAULT_EDGE_NATIVE_FOCUS|%s|%s|tick=%llu|sourceGUI=%d|sourceFlags=0x%08lX|sourceActive=%p|sourceFocus=%p|sourceCapture=%p|foregroundGUI=%d|foregroundFlags=0x%08lX|foregroundActive=%p|foregroundFocus=%p|foregroundCapture=%p\n",
      selection, phase, static_cast<unsigned long long>(snapshot.tick),
      snapshot.source_gui_ok, snapshot.source_gui.flags,
      static_cast<void*>(snapshot.source_gui.hwndActive),
      static_cast<void*>(snapshot.source_gui.hwndFocus),
      static_cast<void*>(snapshot.source_gui.hwndCapture),
      snapshot.foreground_gui_ok, snapshot.foreground_gui.flags,
      static_cast<void*>(snapshot.foreground_gui.hwndActive),
      static_cast<void*>(snapshot.foreground_gui.hwndFocus),
      static_cast<void*>(snapshot.foreground_gui.hwndCapture));
  PrintNativeWindow(selection, phase, "source", snapshot.source);
  PrintNativeWindow(selection, phase, "renderer", snapshot.content);
  PrintNativeWindow(selection, phase, "foreground", snapshot.foreground);
  PrintNativeWindow(selection, phase, "sourceFocus", snapshot.focus);
}
bool VerifyPointerPlacement(const char* selection, POINT pointer, UINT dpi) {
  // Match ShowPanel's pointer-anchor path using the real capture pointer and
  // monitor work area. This checks placement math, not a rendered panel window.
  const RECT anchor{pointer.x, pointer.y, pointer.x, pointer.y};
  const HMONITOR monitor = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{}; info.cbSize = sizeof(info);
  const bool monitor_ok = monitor &&
      monitor == MonitorFromPoint(pointer, MONITOR_DEFAULTTONULL) &&
      monitor == MonitorFromWindow(browser, MONITOR_DEFAULTTONEAREST) &&
      GetMonitorInfoW(monitor, &info) && dpi > 0;
  if (!monitor_ok || info.rcWork.right <= info.rcWork.left ||
      info.rcWork.bottom <= info.rcWork.top) {
    std::printf("DEFAULT_EDGE_PLACEMENT|%s|placement=pointer_fallback|pointer=%ld,%ld|dpi=%u|reason=invalid_source_monitor|FAIL\n",
        selection, pointer.x, pointer.y, dpi);
    return false;
  }
  // The pointer is required to remain on the source monitor, so the source
  // window's effective DPI is also the placement monitor's effective DPI.
  const double scale = dpi / 96.0;
  const int requested_width = static_cast<int>(std::lround(translation_panel::kCompactWidth * scale));
  const int requested_height = static_cast<int>(std::lround(translation_panel::kCompactHeight * scale));
  const int gap = static_cast<int>(std::lround(10 * scale));
  const int margin = static_cast<int>(std::lround(8 * scale));
  const RECT work{info.rcWork.left + margin, info.rcWork.top + margin,
                  info.rcWork.right - margin, info.rcWork.bottom - margin};
  const auto placed = translation_panel::CompactPlacement(
      {static_cast<int>(pointer.x), static_cast<int>(pointer.y)}, std::nullopt,
      {static_cast<int>(info.rcWork.left), static_cast<int>(info.rcWork.top),
       static_cast<int>(info.rcWork.right), static_cast<int>(info.rcWork.bottom)}, scale);
  const RECT panel{placed.left, placed.top, placed.right, placed.bottom};
  RECT clipped{};
  const int width = std::min(requested_width, static_cast<int>(work.right - work.left));
  const int height = std::min(requested_height, static_cast<int>(work.bottom - work.top));
  LONG expected_left = pointer.x + gap;
  if (expected_left + width > work.right) expected_left = pointer.x - gap - width;
  expected_left = std::clamp(expected_left, work.left, work.right - width);
  LONG expected_top = pointer.y + gap;
  if (expected_top + height > work.bottom) expected_top = pointer.y - gap - height;
  expected_top = std::clamp(expected_top, work.top, work.bottom - height);
  const bool passed = panel.right > panel.left && panel.bottom > panel.top &&
      panel.right - panel.left == width && panel.bottom - panel.top == height &&
      panel.left == expected_left && panel.top == expected_top &&
      IntersectRect(&clipped, &panel, &work) && EqualRect(&clipped, &panel) &&
      MonitorFromRect(&panel, MONITOR_DEFAULTTONULL) == monitor;
  std::printf("DEFAULT_EDGE_PLACEMENT|%s|placement=pointer_fallback|pointer=%ld,%ld|dpi=%u|gap=%d|work=%ld,%ld,%ld,%ld|panel=%ld,%ld,%ld,%ld|contract=optional_bounds|%s\n",
      selection, pointer.x, pointer.y, dpi, gap,
      work.left, work.top, work.right, work.bottom,
      panel.left, panel.top, panel.right, panel.bottom, passed ? "PASS" : "FAIL");
  return passed;
}
#if !defined(BAOCODE_SKIP_POST_FAILURE_UIA_DIAGNOSTICS)
void FocusDiagnostics() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return;
  {
    Microsoft::WRL::ComPtr<IUIAutomation> uia;
    Microsoft::WRL::ComPtr<IUIAutomationElement> focus;
    const HRESULT created = CoCreateInstance(CLSID_CUIAutomation8, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia));
    Microsoft::WRL::ComPtr<IUIAutomation2> bounded;
    HRESULT focused = E_FAIL;
    if (SUCCEEDED(created) && SUCCEEDED(uia.As(&bounded)) &&
        SUCCEEDED(bounded->put_ConnectionTimeout(150)) &&
        SUCCEEDED(bounded->put_TransactionTimeout(200))) {
      focused = uia->GetFocusedElement(&focus);
    }
    std::printf("DEFAULT_EDGE_POST_FAILURE_UIA|createHR=0x%08lX|focusHR=0x%08lX\n",
        static_cast<unsigned long>(created), static_cast<unsigned long>(focused));
    if (SUCCEEDED(focused) && focus) {
      CONTROLTYPEID type = 0; int pid = 0;
      BOOL hasFocus = FALSE, password = TRUE, offscreen = TRUE;
      UIA_HWND native{}; RECT rect{};
      const HRESULT type_hr = focus->get_CurrentControlType(&type);
      const HRESULT pid_hr = focus->get_CurrentProcessId(&pid);
      const HRESULT focus_hr = focus->get_CurrentHasKeyboardFocus(&hasFocus);
      const HRESULT password_hr = focus->get_CurrentIsPassword(&password);
      const HRESULT offscreen_hr = focus->get_CurrentIsOffscreen(&offscreen);
      const HRESULT native_hr = focus->get_CurrentNativeWindowHandle(&native);
      const HRESULT rect_hr = focus->get_CurrentBoundingRectangle(&rect);
      DWORD owner = 0; GetWindowThreadProcessId(browser, &owner);
      std::printf("DEFAULT_EDGE_POST_FAILURE_FOCUS|type=%d|typeHR=0x%08lX|focusedPID=%d|pidHR=0x%08lX|ownerPID=%lu|hasFocus=%d|focusHR=0x%08lX|isPassword=%d|passwordHR=0x%08lX|offscreen=%d|offscreenHR=0x%08lX|native=%p|nativeHR=0x%08lX|rect=%ld,%ld,%ld,%ld|rectHR=0x%08lX\n",
          type, static_cast<unsigned long>(type_hr), pid,
          static_cast<unsigned long>(pid_hr), owner, hasFocus,
          static_cast<unsigned long>(focus_hr), password,
          static_cast<unsigned long>(password_hr), offscreen,
          static_cast<unsigned long>(offscreen_hr), reinterpret_cast<void*>(native),
          static_cast<unsigned long>(native_hr), rect.left, rect.top, rect.right,
          rect.bottom, static_cast<unsigned long>(rect_hr));
    }
  }
  CoUninitialize();
}
#endif
}
int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  titleToken = argv[1];
#if defined(BAOCODE_CAPTURE_FOREGROUND_CONNECTION_EXPERIMENT)
  std::puts("DEFAULT_EDGE_CAPTURE_VARIANT|foreground_connection|deadlineMs=1500");
#else
  std::puts("DEFAULT_EDGE_CAPTURE_VARIANT|baseline|deadlineMs=1500");
#endif
  int result = 0;
  try {
    for (int i = 0; i < 200 && !browser; ++i) { EnumWindows(FindBrowser, 0); Sleep(100); }
    Check(browser != nullptr, "Isolated default Edge fixture window did not load");
    DWORD pid = 0; GetWindowThreadProcessId(browser, &pid);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    Check(process != nullptr, "Cannot verify browser executable");
    wchar_t path[32768]{}; DWORD length = 32768;
    const BOOL queried = QueryFullProcessImageNameW(process, 0, path, &length); CloseHandle(process);
    Check(queried && std::wstring(path).find(L"msedge.exe") != std::wstring::npos, "Fixture is not Microsoft Edge");
    ShowWindow(browser, SW_RESTORE); SetForegroundWindow(browser); Sleep(1000);
    EnumChildWindows(browser, FindRenderer, 0);
    Check(renderer != nullptr, "Default Edge renderer HWND unavailable; no coordinate fallback permitted");
    Check(GetForegroundWindow() == browser, "Default Edge is not foreground");
    Check(OpenClipboard(browser) != 0, "Clipboard unavailable"); EmptyClipboard();
    const wchar_t decoy[] = L"Synthetic browser clipboard decoy";
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(decoy)); Check(memory != nullptr, "Clipboard allocation failed");
    void* data = GlobalLock(memory); Check(data != nullptr, "Clipboard lock failed");
    memcpy(data, decoy, sizeof(decoy)); GlobalUnlock(memory);
    Check(SetClipboardData(CF_UNICODETEXT, memory) != nullptr, "Clipboard seed failed"); CloseClipboard();
    const DWORD sequence = GetClipboardSequenceNumber();
    bool allPassed = true;
    for (int line = 0; line < 2; ++line) {
      DragLine(line);
      Check(GetForegroundWindow() == browser, "Drag changed browser foreground");
      // First call is intentionally cold: no prior UIA traversal, screen-reader
      // launch, Chromium accessibility flag, CDP, or script-created selection.
      translation_selection::CaptureDiagnostics diagnostics;
      const NativeFocusSnapshot before = ReadNativeFocus();
      POINT capture_pointer{}, after_pointer{};
      const bool have_pointer = GetCursorPos(&capture_pointer) != 0;
      const ULONGLONG capture_started = GetTickCount64();
      const auto capture = translation_selection::Capture(browser, true, nullptr, 0, &diagnostics);
      const ULONGLONG capture_elapsed = GetTickCount64() - capture_started;
      const bool have_after_pointer = GetCursorPos(&after_pointer) != 0;
      const NativeFocusSnapshot after = ReadNativeFocus();
      PrintNativeFocus(line ? "repeat" : "cold", "before", before);
      PrintNativeFocus(line ? "repeat" : "cold", "after", after);
      const auto print_attempt = [&](const char* phase, unsigned attempt,
          const translation_selection::FocusAttemptDiagnostics& record) {
        if (!record.completed) return;
        std::printf("DEFAULT_EDGE_PROVIDER_ATTEMPT|%s|phase=%s|attempt=%u|startMs=%llu|endMs=%llu|elapsedMs=%llu|startBudgetMs=%llu|remainingMs=%llu|connectionMs=%lu|transactionMs=%lu|HRESULT=0x%08lX\n",
            line ? "repeat" : "cold", phase, attempt, record.started_ms,
            record.started_ms + record.elapsed_ms, record.elapsed_ms,
            record.starting_remaining_ms, record.remaining_ms, record.connection_ms,
            record.transaction_ms, static_cast<unsigned long>(record.result));
      };
      print_attempt("com_initialize", 1, diagnostics.com_initialize);
      print_attempt("automation_create", 1, diagnostics.automation_create);
      print_attempt("foreground_connection", 1, diagnostics.foreground_connection);
      for (unsigned i = 0; i < translation_retry::kMaxAttempts; ++i)
        print_attempt("initial_focus", i + 1, diagnostics.focus_attempts[i]);
      for (unsigned i = 0; i < 3; ++i)
        print_attempt("final_focus", i + 1, diagnostics.final_focus_attempts[i]);
      std::printf("DEFAULT_EDGE_CAPTURE_DIAGNOSTICS|%s|stage=%s|HRESULT=0x%08lX|attempts=%u|finalAttempts=%u|elapsedMs=%llu\n",
        line ? "repeat" : "cold", diagnostics.last_failure_stage,
        static_cast<unsigned long>(diagnostics.last_failure), diagnostics.attempts,
        diagnostics.final_attempts, static_cast<unsigned long long>(capture_elapsed));
      std::printf("DEFAULT_EDGE_TARGET_DIAGNOSTICS|%s|stage=%s|HRESULT=0x%08lX|pid=%d|isPassword=%d|offscreen=%d|hasFocus=%d|same=%d|type=%d\n",
        line ? "repeat" : "cold", diagnostics.target.stage,
        static_cast<unsigned long>(diagnostics.target.result), diagnostics.target.process,
        diagnostics.target.password, diagnostics.target.offscreen,
        diagnostics.target.has_focus, diagnostics.target.same, diagnostics.target.type);
      std::printf("DEFAULT_EDGE_BOUNDS_DIAGNOSTICS|%s|stage=%s|HRESULT=0x%08lX|rectangles=%u|dimensions=%u|vartype=%u|lower=%ld|upper=%ld|first=%.3f,%.3f,%.3f,%.3f|source=%ld,%ld,%ld,%ld\n",
        line ? "repeat" : "cold", diagnostics.bounds_stage,
        static_cast<unsigned long>(diagnostics.bounds_result), diagnostics.bounds_rectangles,
        diagnostics.bounds_dimensions, static_cast<unsigned>(diagnostics.bounds_vartype),
        diagnostics.bounds_lower, diagnostics.bounds_upper,
        diagnostics.bounds_first[0], diagnostics.bounds_first[1],
        diagnostics.bounds_first[2], diagnostics.bounds_first[3],
        diagnostics.bounds_source.left, diagnostics.bounds_source.top,
        diagnostics.bounds_source.right, diagnostics.bounds_source.bottom);
      std::wstring actual = capture.text;
      while (!actual.empty() && (actual.back() == L'\r' || actual.back() == L'\n')) actual.pop_back();
      const std::wstring expected = line ? L"Browser synthetic selection Foxtrot" : L"Browser synthetic selection Echo";
      const bool sourcePassed = capture.status == "ok" && actual == expected &&
          !capture.self && !capture.copy_proof;
      const bool pointerUnchanged = have_pointer && have_after_pointer &&
          capture_pointer.x == after_pointer.x && capture_pointer.y == after_pointer.y;
      const bool sourceUnchanged = before.foreground.window == browser &&
          after.foreground.window == browser && before.source.process == after.source.process &&
          before.source.thread == after.source.thread && before.source.dpi == after.source.dpi &&
          before.content.process == after.content.process && before.content.thread == after.content.thread &&
          before.content.root == browser && after.content.root == browser &&
          before.source.rect_ok && after.source.rect_ok &&
          before.content.rect_ok && after.content.rect_ok &&
          EqualRect(&before.source.rect, &after.source.rect) &&
          EqualRect(&before.content.rect, &after.content.rect) &&
          before.source_gui_ok && after.source_gui_ok &&
          before.source_gui.hwndActive == browser && after.source_gui.hwndActive == browser &&
          before.source_gui.hwndFocus == after.source_gui.hwndFocus &&
          before.focus.root == browser && after.focus.root == browser &&
          !before.source_gui.hwndCapture && !after.source_gui.hwndCapture;
      bool geometryPassed = false;
      if (capture.bounds) {
        const RECT& bounds = *capture.bounds;
        RECT frame{}, clipped{};
        geometryPassed = bounds.right > bounds.left && bounds.bottom > bounds.top &&
            GetWindowRect(browser, &frame) && IntersectRect(&clipped, &bounds, &frame) &&
            EqualRect(&clipped, &bounds) && MonitorFromRect(&bounds, MONITOR_DEFAULTTONULL);
      } else if (pointerUnchanged) {
        geometryPassed = VerifyPointerPlacement(line ? "repeat" : "cold",
            capture_pointer, before.source.dpi);
      }
      const bool clipboardPassed = GetClipboardSequenceNumber() == sequence;
      // ReadBounds is optional on every capture, including repeats. When Edge
      // legitimately supplies no rectangles, verify the existing pointer path
      // rather than requiring a stronger provider contract than the product.
      const bool passed = sourcePassed && sourceUnchanged && pointerUnchanged &&
          geometryPassed && clipboardPassed;
      const char* placement = capture.bounds ? (geometryPassed ? "selection_bounds" : "invalid_geometry") :
          (geometryPassed ? "pointer_fallback" : "invalid_pointer_fallback");
      std::printf("DEFAULT_EDGE_IMMUTABILITY|%s|source=%d|pointer=%d|clipboard=%d|capturePointer=%ld,%ld|afterPointer=%ld,%ld\n",
        line ? "repeat" : "cold", sourceUnchanged ? 1 : 0, pointerUnchanged ? 1 : 0,
        clipboardPassed ? 1 : 0, capture_pointer.x, capture_pointer.y, after_pointer.x, after_pointer.y);
      std::printf("DEFAULT_EDGE_CAPTURE|%s|status=%s|units=%zu|bounds=%d|copyProof=%d|placement=%s|%s\n",
        line ? "repeat" : "cold", capture.status.c_str(), capture.text.size(),
        capture.bounds.has_value() ? 1 : 0, capture.copy_proof.has_value() ? 1 : 0, placement, passed ? "PASS" : "FAIL");
      if (!passed) {
        allPassed = false;
        if (!sourcePassed) SyntheticMismatch(capture.text, expected);
        RECT frame{}, content{}; GetWindowRect(browser, &frame); GetWindowRect(renderer, &content);
        std::printf("SYNTHETIC_EDGE_GEOMETRY|dpi=%u|frame=%ld,%ld,%ld,%ld|renderer=%ld,%ld,%ld,%ld\n",
          GetDpiForWindow(browser), frame.left, frame.top, frame.right, frame.bottom,
          content.left, content.top, content.right, content.bottom);
        SyntheticScreenshot(std::wstring(argv[2]) + (line ? L"\\repeat-mismatch.bmp" : L"\\cold-mismatch.bmp"));
#if !defined(BAOCODE_SKIP_POST_FAILURE_UIA_DIAGNOSTICS)
        FocusDiagnostics();
#else
        std::puts("DEFAULT_EDGE_POST_FAILURE_UIA|skipped=explicit_diagnostic_build");
#endif
      }
      Check(GetClipboardSequenceNumber() == sequence, "Browser capture changed clipboard");
    }
    Check(allPassed, "Default Edge UIA selection failed (see cold/repeat diagnostics); no accessibility override or Document Ctrl+C fallback used");
    std::puts("PASS: default Edge real mouse selections, production Capture, exact fresh source, supplied bounds or verified pointer placement, source/focus/pointer/clipboard unchanged");
  } catch (const std::exception& error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); result = 1; }
  if (browser) PostMessageW(browser, WM_CLOSE, 0, 0);
  return result;
}
