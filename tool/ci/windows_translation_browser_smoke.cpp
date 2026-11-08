// Default Edge + local synthetic HTML, no forced accessibility switches.
// Calls the production capture header; never sends Ctrl+C or reads document text.
#include "../../windows/runner/translation_selection.h"
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
  // Matches the local HTML's fixed CSS coordinates, accounting for DPI.
  const POINT from{r.left+MulDiv(40, dpi, 96), r.top+MulDiv(92+100*line, dpi, 96)};
  const POINT to{r.left+MulDiv(800, dpi, 96), from.y};
  Check(to.x < r.right && to.y < r.bottom, "Browser viewport too small for fixture");
  Mouse(from, 0); Sleep(80); Mouse(from, MOUSEEVENTF_LEFTDOWN);
  for (int i = 1; i <= 16; ++i) {
    Mouse(POINT{from.x+(to.x-from.x)*i/16, from.y}, 0); Sleep(20);
  }
  Mouse(to, MOUSEEVENTF_LEFTUP); Sleep(300);
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
  if (argc != 2) return 2;
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
      const auto capture = translation_selection::Capture(browser, true);
      std::wstring actual = capture.text;
      while (!actual.empty() && (actual.back() == L'\r' || actual.back() == L'\n')) actual.pop_back();
      const std::wstring expected = line ? L"Browser synthetic selection Foxtrot" : L"Browser synthetic selection Echo";
      const bool passed = capture.status == "ok" && actual == expected && !capture.self && capture.bounds.has_value();
      std::printf("DEFAULT_EDGE_CAPTURE|%s|status=%s|units=%zu|bounds=%d|copyProof=%d|%s\n",
        line ? "repeat" : "cold", capture.status.c_str(), capture.text.size(),
        capture.bounds.has_value() ? 1 : 0, capture.copy_proof.has_value() ? 1 : 0, passed ? "PASS" : "FAIL");
      if (!passed) { allPassed = false; FocusDiagnostics(); }
      Check(GetClipboardSequenceNumber() == sequence, "Browser capture changed clipboard");
    }
    Check(allPassed, "Default Edge UIA selection failed (see cold/repeat diagnostics); no accessibility override or Document Ctrl+C fallback used");
    std::puts("PASS: default Edge real mouse selections, production Capture, exact fresh source, selection bounds, clipboard unchanged");
  } catch (const std::exception& error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); result = 1; }
  if (browser) PostMessageW(browser, WM_CLOSE, 0, 0);
  return result;
}
