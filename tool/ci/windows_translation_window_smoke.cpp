// Runs ONLY from the guarded Actions script. Tests the actual release executable.
#include <windows.h>
#include <UIAutomation.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <stdexcept>
#include <functional>

namespace {
constexpr UINT kPrepare = WM_APP + 23;
HWND edit = nullptr;
DWORD appPid = 0;
HWND mainWindow = nullptr;
HWND popup = nullptr;
void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
bool Wait(const std::function<bool()>& predicate, int attempts = 100) {
  for (int i = 0; i < attempts; ++i) { if (predicate()) return true; Sleep(100); }
  return false;
}
LRESULT CALLBACK Fixture(HWND w, UINT m, WPARAM a, LPARAM b) {
  if (m == WM_CREATE) {
    edit = CreateWindowW(L"RICHEDIT50W", L"", WS_CHILD | WS_VISIBLE | ES_MULTILINE,
      24, 24, 660, 200, w, nullptr, nullptr, nullptr);
    return 0;
  }
  if (m == kPrepare) {
    SetWindowTextW(edit, a ? L"Fresh synthetic selection Bravo" : L"Synthetic selection Alpha");
    ShowWindow(w, SW_SHOW); SetForegroundWindow(w); SetFocus(edit);
    SendMessageW(edit, EM_SETSEL, 0, -1); return 1;
  }
  if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(w, m, a, b);
}
BOOL CALLBACK FindApp(HWND w, LPARAM) {
  DWORD pid; GetWindowThreadProcessId(w, &pid);
  if (pid != appPid) return TRUE;
  wchar_t title[256]{}; GetWindowTextW(w, title, 256);
  if (std::wstring(title) == L"BaoCode Translate") popup = w;
  else if (!mainWindow && IsWindowVisible(w) && !(GetWindowLongPtrW(w, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) mainWindow = w;
  return TRUE;
}
void Keys(std::initializer_list<WORD> keys) {
  std::vector<INPUT> input;
  for (auto k : keys) { INPUT i{}; i.type = INPUT_KEYBOARD; i.ki.wVk = k; input.push_back(i); }
  for (auto i = keys.end(); i != keys.begin();) { INPUT k{}; k.type = INPUT_KEYBOARD; k.ki.wVk = *--i; k.ki.dwFlags = KEYEVENTF_KEYUP; input.push_back(k); }
  Check(SendInput(static_cast<UINT>(input.size()), input.data(), sizeof(INPUT)) == input.size(), "SendInput failed");
}
std::wstring AccessibleText(IUIAutomation* uia, HWND w) {
  IUIAutomationElement* root = nullptr;
  if (FAILED(uia->ElementFromHandle(w, &root)) || !root) return L"";
  IUIAutomationCondition* condition = nullptr; uia->CreateTrueCondition(&condition);
  IUIAutomationElementArray* elements = nullptr;
  if (condition) root->FindAll(TreeScope_Subtree, condition, &elements);
  std::wstring text;
  if (elements) {
    int count = 0; elements->get_Length(&count);
    for (int i = 0; i < count; ++i) {
      IUIAutomationElement* e = nullptr; elements->GetElement(i, &e); if (!e) continue;
      BSTR name = nullptr; e->get_CurrentName(&name); if (name) { text += name; text += L"\n"; SysFreeString(name); }
      VARIANT value; VariantInit(&value);
      e->GetCurrentPropertyValue(UIA_ValueValuePropertyId, &value);
      if (value.vt == VT_BSTR && value.bstrVal) text += value.bstrVal;
      VariantClear(&value); e->Release();
    }
    elements->Release();
  }
  if (condition) condition->Release(); root->Release(); return text;
}
void Screenshot(HWND w, const std::wstring& path) {
  Check(GetForegroundWindow() == w, "Refusing screenshot of obscured popup");
  RECT r{}; Check(GetWindowRect(w, &r) != 0, "Popup rectangle missing");
  const int width = r.right-r.left, height = r.bottom-r.top;
  HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr; HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  Check(bitmap && pixels, "Screenshot allocation failed");
  auto old = SelectObject(dc, bitmap);
  Check(BitBlt(dc, 0, 0, width, height, screen, r.left, r.top, SRCCOPY) != 0, "Screenshot failed");
  GdiFlush();
  BITMAPFILEHEADER header{}; header.bfType = 0x4d42;
  header.bfOffBits = sizeof(header) + sizeof(BITMAPINFOHEADER);
  const DWORD bytes = static_cast<DWORD>(width * height * 4); header.bfSize = header.bfOffBits + bytes;
  FILE* file = nullptr; _wfopen_s(&file, path.c_str(), L"wb"); Check(file != nullptr, "Screenshot file failed");
  fwrite(&header, sizeof(header), 1, file); fwrite(&info.bmiHeader, sizeof(BITMAPINFOHEADER), 1, file); fwrite(pixels, bytes, 1, file); fclose(file);
  SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr, screen);
}
}
int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--fixture") {
    LoadLibraryW(L"Msftedit.dll"); WNDCLASSW c{}; c.lpfnWndProc = Fixture;
    c.hInstance = GetModuleHandleW(nullptr); c.lpszClassName = L"BaoTranslationWindowFixture"; RegisterClassW(&c);
    HWND w = CreateWindowW(c.lpszClassName, L"Synthetic translation fixture", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
      50, 50, 760, 400, nullptr, nullptr, c.hInstance, nullptr);
    if (!w || !edit) return 2;
    MSG m; while (GetMessageW(&m, nullptr, 0, 0) > 0) { TranslateMessage(&m); DispatchMessageW(&m); } return 0;
  }
  if (argc != 3) return 2;
  appPid = wcstoul(argv[1], nullptr, 10);
  PROCESS_INFORMATION fixtureProcess{}; HWND fixture = nullptr;
  IUIAutomation* uia = nullptr; int result = 0;
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  try {
    Check(SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia))), "UIA unavailable");
    Check(Wait([] { EnumWindows(FindApp, 0); return mainWindow != nullptr; }), "Release app main HWND not found");
    wchar_t self[MAX_PATH]{}; GetModuleFileNameW(nullptr, self, MAX_PATH);
    std::wstring command = L"\"" + std::wstring(self) + L"\" --fixture";
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    Check(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &fixtureProcess) != 0, "Fixture launch failed");
    Check(Wait([&] { fixture = FindWindowW(L"BaoTranslationWindowFixture", nullptr); return fixture != nullptr; }), "Fixture unavailable");
    // Seed a decoy, then require sequence and Unicode content to survive every interaction.
    Check(OpenClipboard(fixture) != 0, "Clipboard unavailable"); EmptyClipboard();
    const wchar_t decoy[] = L"Synthetic clipboard decoy: must never be translated";
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, sizeof(decoy)); Check(data != nullptr, "Clipboard allocation failed");
    void* mem = GlobalLock(data); Check(mem != nullptr, "Clipboard lock failed"); memcpy(mem, decoy, sizeof(decoy)); GlobalUnlock(data);
    Check(SetClipboardData(CF_UNICODETEXT, data) != nullptr, "Clipboard seed failed"); CloseClipboard();
    const DWORD sequence = GetClipboardSequenceNumber();
    for (int state = 0; state < 2; ++state) {
      if (state == 0) {
        PostMessageW(mainWindow, WM_CLOSE, 0, 0);
        Check(Wait([] { return IsWindow(mainWindow) && !IsWindowVisible(mainWindow); }), "Main close did not hide to tray");
      } else {
        ShowWindow(mainWindow, SW_SHOW); ShowWindow(mainWindow, SW_MINIMIZE);
        Check(Wait([] { return IsIconic(mainWindow) != 0; }), "Main minimization failed");
      }
      const BOOL visible = IsWindowVisible(mainWindow), iconic = IsIconic(mainWindow);
      for (int close = 0; close < 5; ++close) {
        AllowSetForegroundWindow(fixtureProcess.dwProcessId);
        SendMessageW(fixture, kPrepare, close % 2, 0);
        Check(Wait([&] { return GetForegroundWindow() == fixture; }), "Fixture could not take foreground");
        Keys({VK_CONTROL, VK_MENU, 'Y'});
        Check(Wait([] { EnumWindows(FindApp, 0); return popup && IsWindowVisible(popup); }), "Real global shortcut did not open popup");
        Check(popup != mainWindow, "Translation reused the main HWND");
        Check(IsWindowVisible(mainWindow) == visible && IsIconic(mainWindow) == iconic, "Shortcut changed main hidden/minimized state");
        const auto style = GetWindowLongPtrW(popup, GWL_EXSTYLE);
        Check((style & WS_EX_TOOLWINDOW) && !(style & WS_EX_APPWINDOW), "Popup is taskbar/AltTab eligible");
        RECT r{}, anchor{}; GetWindowRect(popup, &r); GetWindowRect(fixture, &anchor);
        MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
        GetMonitorInfoW(MonitorFromWindow(fixture, MONITOR_DEFAULTTONEAREST), &monitor);
        Check(r.left >= monitor.rcWork.left && r.top >= monitor.rcWork.top && r.right <= monitor.rcWork.right && r.bottom <= monitor.rcWork.bottom, "Popup outside selection work area");
        Check(abs(r.left - (anchor.left+24)) < 800 && abs(r.top - (anchor.top+24)) < 500, "Popup not near selection fixture");
        const std::wstring expected = close % 2 ? L"Fresh synthetic selection Bravo" : L"Synthetic selection Alpha";
        const std::wstring stale = close % 2 ? L"Synthetic selection Alpha" : L"Fresh synthetic selection Bravo";
        Check(Wait([&] { auto text = AccessibleText(uia, popup); return text.find(expected) != std::wstring::npos && text.find(stale) == std::wstring::npos && text.find(L"Synthetic clipboard decoy") == std::wstring::npos; }), "Popup UIA missing fresh selection or retaining stale text");
        Check(Wait([] { return GetForegroundWindow() == popup; }), "Popup not active");
        if (state == 0 && close == 0) { Sleep(500); Screenshot(popup, argv[2]); }
        if (close == 0) Keys({VK_ESCAPE});
        if (close == 1) PostMessageW(popup, WM_CLOSE, 0, 0); // Native caption X message.
        if (close == 2) Keys({VK_MENU, VK_F4});
        if (close == 4) Keys({VK_CONTROL, VK_MENU, 'Y'});
        if (close == 3) { AllowSetForegroundWindow(fixtureProcess.dwProcessId); SendMessageW(fixture, kPrepare, 0, 0); }
        Check(Wait([] { return !IsWindowVisible(popup); }), "Popup failed to dismiss");
        Check(Wait([&] { return GetForegroundWindow() == fixture; }), "Dismissal failed to restore prior app focus");
        Check(IsWindow(mainWindow) != 0, "Popup close quit the application");
        Check(IsWindowVisible(mainWindow) == visible && IsIconic(mainWindow) == iconic, "Dismissal changed main state");
        Check(GetClipboardSequenceNumber() == sequence, "Translation modified clipboard");
      }
    }
    // Native application quit route, not forced termination; registration must be released.
    PostMessageW(mainWindow, WM_APP + 0x42, 0, 0);
    Check(Wait([] { return !IsWindow(mainWindow); }), "Native quit did not close main");
    Check(Wait([] { if (!RegisterHotKey(nullptr, 0x6123, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'Y')) return false; UnregisterHotKey(nullptr, 0x6123); return true; }), "Quit leaked global hotkey");
    std::puts("PASS actual release app: selection UIA, hidden/minimized independence, toolwindow, positioning, Escape/X/Alt+F4/blur/hotkey toggle, fresh reopen, clipboard sequence, native quit and hotkey release");
  } catch (const std::exception& e) { std::fprintf(stderr, "FAIL: %s\n", e.what()); result = 1; }
  if (fixture) PostMessageW(fixture, WM_CLOSE, 0, 0);
  if (fixtureProcess.hProcess) { if (WaitForSingleObject(fixtureProcess.hProcess, 3000) == WAIT_TIMEOUT) TerminateProcess(fixtureProcess.hProcess, 1); CloseHandle(fixtureProcess.hProcess); CloseHandle(fixtureProcess.hThread); }
  if (uia) uia->Release(); CoUninitialize(); return result;
}
