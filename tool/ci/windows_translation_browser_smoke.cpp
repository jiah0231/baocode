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
void FocusDiagnostics() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return;
  {
    Microsoft::WRL::ComPtr<IUIAutomation> uia;
    Microsoft::WRL::ComPtr<IUIAutomationElement> focus;
    if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia))) &&
        SUCCEEDED(uia->GetFocusedElement(&focus)) && focus) {
      CONTROLTYPEID type = 0; int pid = 0; BOOL hasFocus = FALSE, password = TRUE;
      focus->get_CurrentControlType(&type); focus->get_CurrentProcessId(&pid);
      focus->get_CurrentHasKeyboardFocus(&hasFocus); focus->get_CurrentIsPassword(&password);
      DWORD owner = 0; GetWindowThreadProcessId(browser, &owner);
      std::printf("Browser UIA diagnostics: type=%d, focusedPID=%d, ownerPID=%lu, hasFocus=%d, password=%d\n", type, pid, owner, hasFocus, password);
    }
  }
  CoUninitialize();
}
}
int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  titleToken = argv[1];
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
      const auto capture = translation_selection::Capture(browser, true, nullptr, 0, &diagnostics);
      std::printf("DEFAULT_EDGE_CAPTURE_DIAGNOSTICS|%s|stage=%s|HRESULT=0x%08lX|attempts=%u\n",
        line ? "repeat" : "cold", diagnostics.last_failure_stage,
        static_cast<unsigned long>(diagnostics.last_failure), diagnostics.attempts);
      std::wstring actual = capture.text;
      while (!actual.empty() && (actual.back() == L'\r' || actual.back() == L'\n')) actual.pop_back();
      const std::wstring expected = line ? L"Browser synthetic selection Foxtrot" : L"Browser synthetic selection Echo";
      const bool sourcePassed = capture.status == "ok" && actual == expected && !capture.self;
      bool geometryPassed = line == 0; // Cold capture may use documented pointer fallback.
      if (capture.bounds) {
        const RECT& bounds = *capture.bounds;
        RECT frame{}, clipped{};
        geometryPassed = bounds.right > bounds.left && bounds.bottom > bounds.top &&
            GetWindowRect(browser, &frame) && IntersectRect(&clipped, &bounds, &frame) &&
            EqualRect(&clipped, &bounds) && MonitorFromRect(&bounds, MONITOR_DEFAULTTONULL);
      }
      const bool clipboardPassed = GetClipboardSequenceNumber() == sequence;
      // Require valid selection geometry on repeat to retain browser geometry
      // coverage, but do not conflate optional cold bounds with failed capture.
      const bool passed = sourcePassed && geometryPassed && clipboardPassed;
      const char* placement = capture.bounds ? (geometryPassed ? "selection_bounds" : "invalid_geometry") :
          (line == 0 ? "pointer_fallback" : "missing_repeat_bounds");
      std::printf("DEFAULT_EDGE_CAPTURE|%s|status=%s|units=%zu|bounds=%d|copyProof=%d|placement=%s|%s\n",
        line ? "repeat" : "cold", capture.status.c_str(), capture.text.size(),
        capture.bounds.has_value() ? 1 : 0, capture.copy_proof.has_value() ? 1 : 0, placement, passed ? "PASS" : "FAIL");
      if (sourcePassed && geometryPassed && !capture.bounds) {
        POINT pointer{};
        Check(GetCursorPos(&pointer) != 0, "Cold capture fallback pointer unavailable");
        std::printf("DEFAULT_EDGE_PLACEMENT|cold|placement=pointer_fallback|pointer=%ld,%ld|contract=optional_bounds\n",
          pointer.x, pointer.y);
      }
      if (!passed) {
        allPassed = false;
        if (!sourcePassed) SyntheticMismatch(capture.text, expected);
        RECT frame{}, content{}; GetWindowRect(browser, &frame); GetWindowRect(renderer, &content);
        std::printf("SYNTHETIC_EDGE_GEOMETRY|dpi=%u|frame=%ld,%ld,%ld,%ld|renderer=%ld,%ld,%ld,%ld\n",
          GetDpiForWindow(browser), frame.left, frame.top, frame.right, frame.bottom,
          content.left, content.top, content.right, content.bottom);
        SyntheticScreenshot(std::wstring(argv[2]) + (line ? L"\\repeat-mismatch.bmp" : L"\\cold-mismatch.bmp"));
        FocusDiagnostics();
      }
      Check(GetClipboardSequenceNumber() == sequence, "Browser capture changed clipboard");
    }
    Check(allPassed, "Default Edge UIA selection failed (see cold/repeat diagnostics); no accessibility override or Document Ctrl+C fallback used");
    std::puts("PASS: default Edge real mouse selections, production Capture, exact fresh source, optional cold bounds/pointer fallback, required repeat bounds, clipboard unchanged");
  } catch (const std::exception& error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); result = 1; }
  if (browser) PostMessageW(browser, WM_CLOSE, 0, 0);
  return result;
}
