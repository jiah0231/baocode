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
constexpr int kCloseModeCount = 7;
constexpr int kAltF4StressCount = 6;
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
    const wchar_t* text = a == 2 ? L"Mouse selection Charlie" :
        a == 3 ? L"Mouse selection Delta" :
        a ? L"Fresh synthetic selection Bravo" : L"Synthetic selection Alpha";
    SetWindowTextW(edit, text);
    ShowWindow(w, SW_SHOW); SetForegroundWindow(w); SetFocus(edit);
    SendMessageW(edit, EM_SETSEL, 0, b ? 0 : -1); return 1;
  }
  if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(w, m, a, b);
}
BOOL CALLBACK FindApp(HWND w, LPARAM) {
  DWORD pid; GetWindowThreadProcessId(w, &pid);
  if (pid != appPid) return TRUE;
  wchar_t title[256]{}, cls[256]{}; GetWindowTextW(w, title, 256); GetClassNameW(w, cls, 256);
  if (std::wstring(title) == L"BaoCode Translate") popup = w;
  else if (!mainWindow && std::wstring(cls) == L"FLUTTER_RUNNER_WIN32_WINDOW" &&
      IsWindowVisible(w) && !(GetWindowLongPtrW(w, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) mainWindow = w;
  return TRUE;
}
std::string MetadataUtf8(const wchar_t* value) {
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  if (bytes <= 1) return {};
  std::string result(static_cast<size_t>(bytes), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), bytes, nullptr, nullptr);
  result.pop_back(); return result;
}
void TraceMain(int state, int close, const char* stage, BOOL expectedVisible, BOOL expectedIconic) {
  // Owned isolated-app window metadata only, never selected text or UIA content.
  wchar_t title[256]{}, cls[256]{};
  GetWindowTextW(mainWindow, title, 256); GetClassNameW(mainWindow, cls, 256);
  const BOOL visible = IsWindowVisible(mainWindow), iconic = IsIconic(mainWindow);
  HWND foreground = GetForegroundWindow(); DWORD foregroundPid = 0;
  if (foreground) GetWindowThreadProcessId(foreground, &foregroundPid);
  WINDOWPLACEMENT placement{}; placement.length = sizeof(placement);
  const BOOL placementRead = GetWindowPlacement(mainWindow, &placement);
  const char* modes[] = {"Escape", "WM_CLOSE", "AltF4", "blur", "hotkey_toggle", "CtrlW", "CtrlShiftW"};
  std::printf("WINDOW_STATE|state=%s|close=%s|stage=%s|main=%p|title=%s|class=%s|exists=%d|expectedVisibleRaw=%d|visibleRaw=%d|expectedIconicRaw=%d|iconicRaw=%d|expectedVisibleBool=%d|visibleBool=%d|expectedIconicBool=%d|iconicBool=%d|foreground=%p|foregroundPID=%lu|popup=%p|placementRead=%d|showCmd=%u|flags=%u\n",
    state == 0 ? "tray_hidden" : state == 1 ? "minimized" : state == 2 ? "main_visible" : "startup",
    close >= 0 && close < kCloseModeCount ? modes[close] : "none", stage,
    static_cast<void*>(mainWindow), MetadataUtf8(title).c_str(), MetadataUtf8(cls).c_str(),
    IsWindow(mainWindow), expectedVisible, visible, expectedIconic, iconic,
    expectedVisible != 0 ? 1 : 0, visible != 0 ? 1 : 0,
    expectedIconic != 0 ? 1 : 0, iconic != 0 ? 1 : 0,
    static_cast<void*>(foreground), foregroundPid, static_cast<void*>(popup),
    placementRead, placement.showCmd, placement.flags);
  std::fflush(stdout);
}
BOOL CALLBACK TraceAppCandidate(HWND w, LPARAM) {
  DWORD pid = 0; GetWindowThreadProcessId(w, &pid);
  if (pid != appPid) return TRUE;
  wchar_t title[256]{}, cls[256]{}; GetWindowTextW(w, title, 256); GetClassNameW(w, cls, 256);
  std::printf("WINDOW_CANDIDATE|hwnd=%p|chosen=%d|title=%s|class=%s|visibleRaw=%d|iconicRaw=%d|exstyle=0x%llX|owner=%p\n",
    static_cast<void*>(w), w == mainWindow ? 1 : 0, MetadataUtf8(title).c_str(), MetadataUtf8(cls).c_str(),
    IsWindowVisible(w), IsIconic(w), static_cast<unsigned long long>(GetWindowLongPtrW(w, GWL_EXSTYLE)),
    static_cast<void*>(GetWindow(w, GW_OWNER)));
  return TRUE;
}
void Keys(std::initializer_list<WORD> keys) {
  std::vector<INPUT> input;
  for (auto k : keys) { INPUT i{}; i.type = INPUT_KEYBOARD; i.ki.wVk = k; input.push_back(i); }
  for (auto i = keys.end(); i != keys.begin();) { INPUT k{}; k.type = INPUT_KEYBOARD; k.ki.wVk = *--i; k.ki.dwFlags = KEYEVENTF_KEYUP; input.push_back(k); }
  Check(SendInput(static_cast<UINT>(input.size()), input.data(), sizeof(INPUT)) == input.size(), "SendInput failed");
}
void AltF4ReleaseOrder(bool altFirst) {
  INPUT down[2]{};
  down[0].type = INPUT_KEYBOARD; down[0].ki.wVk = VK_MENU;
  down[1].type = INPUT_KEYBOARD; down[1].ki.wVk = VK_F4;
  Check(SendInput(2, down, sizeof(INPUT)) == 2, "AltF4 stress key-down failed");
  Sleep(10); // Let native close race with Flutter's queued keyboard callbacks.
  INPUT up{}; up.type = INPUT_KEYBOARD; up.ki.dwFlags = KEYEVENTF_KEYUP;
  up.ki.wVk = altFirst ? VK_MENU : VK_F4;
  const UINT first = SendInput(1, &up, sizeof(INPUT));
  Sleep(10);
  up.ki.wVk = altFirst ? VK_F4 : VK_MENU;
  const UINT second = SendInput(1, &up, sizeof(INPUT));
  Check(first == 1 && second == 1, "AltF4 stress key-up failed");
}
void Mouse(POINT point, DWORD flags) {
  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  Check(width > 1 && height > 1, "Interactive runner desktop unavailable");
  INPUT input{}; input.type = INPUT_MOUSE;
  input.mi.dx = MulDiv(point.x - left, 65535, width - 1);
  input.mi.dy = MulDiv(point.y - top, 65535, height - 1);
  input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | flags;
  Check(SendInput(1, &input, sizeof(INPUT)) == 1, "Real mouse input failed");
}
void DragFixture(HWND fixture) {
  HWND rich = FindWindowExW(fixture, nullptr, L"RICHEDIT50W", nullptr);
  RECT bounds{};
  Check(rich && GetWindowRect(rich, &bounds), "External mouse fixture control unavailable");
  // One ASCII line, with room to drag beyond its end. No EM_SETSEL selects it:
  // only genuine SendInput mouse down/moves/up can create this selection.
  POINT start{bounds.left + 1, bounds.top + 8};
  POINT end{bounds.right - 20, bounds.top + 8};
  Mouse(start, 0); Sleep(80); Mouse(start, MOUSEEVENTF_LEFTDOWN);
  for (int step = 1; step <= 12; ++step) {
    Mouse(POINT{start.x + (end.x - start.x) * step / 12, start.y}, 0); Sleep(20);
  }
  Mouse(end, MOUSEEVENTF_LEFTUP);
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
void Screenshot(HWND w, const std::wstring& path, HWND syntheticSource = nullptr) {
  if (!syntheticSource) {
    Check(GetForegroundWindow() == w, "Refusing screenshot of obscured popup");
  } else {
    // The entry intentionally never activates. Permit only our app's exact
    // entry class over the known synthetic fixture, never an arbitrary window.
    wchar_t cls[128]{}; GetClassNameW(w, cls, 128);
    wchar_t sourceClass[128]{}; GetClassNameW(syntheticSource, sourceClass, 128);
    DWORD owner = 0; GetWindowThreadProcessId(w, &owner);
    Check(owner == appPid && std::wstring(cls) == L"BaoCodeTranslationSelectionAction" &&
        std::wstring(sourceClass) == L"BaoTranslationWindowFixture" &&
        GetForegroundWindow() == syntheticSource && IsWindowVisible(w) &&
        (GetWindowLongPtrW(w, GWL_EXSTYLE) & WS_EX_NOACTIVATE),
        "Refusing screenshot of unverified nonactivating entry");
  }
  RECT r{}; Check(GetWindowRect(w, &r) != 0, "Popup rectangle missing");
  if (syntheticSource) {
    const POINT corners[] = {{r.left, r.top}, {r.right-1, r.top},
        {r.left, r.bottom-1}, {r.right-1, r.bottom-1}};
    for (const POINT point : corners) {
      Check(GetAncestor(WindowFromPoint(point), GA_ROOT) == w,
          "Refusing screenshot of obscured selection entry");
    }
  }
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
    EnumWindows(TraceAppCandidate, 0);
    TraceMain(-1, -1, "selected_main", IsWindowVisible(mainWindow), IsIconic(mainWindow));
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
      for (int iteration = 0; iteration < kCloseModeCount + kAltF4StressCount; ++iteration) {
        // Keep the original seven-mode matrix intact, then rapidly reopen and
        // close six extra times per main state, alternating actual source text.
        const bool stress = iteration >= kCloseModeCount;
        const int stressIndex = iteration - kCloseModeCount;
        const int close = stress ? 2 : iteration;
        const bool altFirst = stress && stressIndex % 2 == 0;
        if (stress) {
          std::printf("ALT_F4_STRESS|state=%s|iteration=%d|releaseOrder=%s\n",
            state == 0 ? "tray_hidden" : "minimized", stressIndex + 1,
            altFirst ? "Alt_then_F4" : "F4_then_Alt");
          std::fflush(stdout);
        }
        AllowSetForegroundWindow(fixtureProcess.dwProcessId);
        SendMessageW(fixture, kPrepare, iteration % 2, 0);
        Check(Wait([&] { return GetForegroundWindow() == fixture; }), "Fixture could not take foreground");
        TraceMain(state, close, "before_open", visible, iconic);
        Keys({VK_CONTROL, VK_MENU, 'Y'});
        Check(Wait([] { EnumWindows(FindApp, 0); return popup && IsWindowVisible(popup); }), "Real global shortcut did not open popup");
        TraceMain(state, close, "after_open", visible, iconic);
        Check(popup != mainWindow, "Translation reused the main HWND");
        Check((IsWindowVisible(mainWindow) != FALSE) == (visible != FALSE) && (IsIconic(mainWindow) != FALSE) == (iconic != FALSE), "Shortcut changed main hidden/minimized state");
        const auto style = GetWindowLongPtrW(popup, GWL_EXSTYLE);
        Check((style & WS_EX_TOOLWINDOW) && !(style & WS_EX_APPWINDOW), "Popup is taskbar/AltTab eligible");
        RECT r{}, anchor{}; GetWindowRect(popup, &r); GetWindowRect(fixture, &anchor);
        MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
        GetMonitorInfoW(MonitorFromWindow(fixture, MONITOR_DEFAULTTONEAREST), &monitor);
        Check(r.left >= monitor.rcWork.left && r.top >= monitor.rcWork.top && r.right <= monitor.rcWork.right && r.bottom <= monitor.rcWork.bottom, "Popup outside selection work area");
        Check(abs(r.left - (anchor.left+24)) < 800 && abs(r.top - (anchor.top+24)) < 500, "Popup not near selection fixture");
        const std::wstring expected = iteration % 2 ? L"Fresh synthetic selection Bravo" : L"Synthetic selection Alpha";
        const std::wstring stale = iteration % 2 ? L"Synthetic selection Alpha" : L"Fresh synthetic selection Bravo";
        Check(Wait([&] { auto text = AccessibleText(uia, popup); return text.find(expected) != std::wstring::npos && text.find(stale) == std::wstring::npos && text.find(L"Synthetic clipboard decoy") == std::wstring::npos; }), "Popup UIA missing fresh selection or retaining stale text");
        Check(Wait([] { return GetForegroundWindow() == popup; }), "Popup not active");
        if (state == 0 && close == 0) { Sleep(500); Screenshot(popup, argv[2]); }
        TraceMain(state, close, "before_close", visible, iconic);
        if (close == 0) Keys({VK_ESCAPE});
        if (close == 1) PostMessageW(popup, WM_CLOSE, 0, 0); // Native caption X message.
        if (close == 2) {
          if (stress) AltF4ReleaseOrder(altFirst);
          else Keys({VK_MENU, VK_F4});
        }
        if (close == 4) Keys({VK_CONTROL, VK_MENU, 'Y'});
        if (close == 5) Keys({VK_CONTROL, 'W'});
        if (close == 6) Keys({VK_CONTROL, VK_SHIFT, 'W'});
        if (close == 3) { AllowSetForegroundWindow(fixtureProcess.dwProcessId); SendMessageW(fixture, kPrepare, 0, 0); }
        TraceMain(state, close, "after_close_input", visible, iconic);
        Check(Wait([] { return !IsWindowVisible(popup); }), "Popup failed to dismiss");
        Check(Wait([&] { return GetForegroundWindow() == fixture; }), "Dismissal failed to restore prior app focus");
        if (stress) {
          Sleep(40); // Also catch deferred Dart callbacks after both key-ups.
          Check(!IsWindowVisible(popup), "AltF4 stress popup reopened after key release");
          Check(GetForegroundWindow() == fixture, "AltF4 stress lost restored source focus after key release");
        }
        TraceMain(state, close, "after_close_settled", visible, iconic);
        Check(IsWindow(mainWindow) != 0, "Popup close quit the application");
        Check((IsWindowVisible(mainWindow) != FALSE) == (visible != FALSE) && (IsIconic(mainWindow) != FALSE) == (iconic != FALSE), "Dismissal changed main state");
        Check(GetClipboardSequenceNumber() == sequence, "Translation modified clipboard");
      }
    }
    // Exercise the passive selection entry with real cross-process mouse input.
    // Return to tray-hidden state, independently of the earlier minimized cases.
    ShowWindow(mainWindow, SW_RESTORE);
    PostMessageW(mainWindow, WM_CLOSE, 0, 0);
    Check(Wait([] { return IsWindow(mainWindow) && !IsWindowVisible(mainWindow); }), "Main did not return to tray for mouse test");
    for (int selection = 0; selection < 2; ++selection) {
      AllowSetForegroundWindow(fixtureProcess.dwProcessId);
      SendMessageW(fixture, kPrepare, 2 + selection, 1);
      Check(Wait([&] { return GetForegroundWindow() == fixture; }), "Mouse fixture could not take foreground");
      DragFixture(fixture);
      HWND action = nullptr;
      Check(Wait([&] {
        action = FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr);
        DWORD pid = 0; if (action) GetWindowThreadProcessId(action, &pid);
        return action && pid == appPid && IsWindowVisible(action);
      }), "Real mouse drag did not expose translation selection entry");
      Check(GetForegroundWindow() == fixture, "Selection entry stole external app focus");
      Check(!IsWindowVisible(mainWindow), "Selection entry activated hidden main window");
      Check(!popup || !IsWindowVisible(popup), "Mouse selection translated without entry click");
      Check(GetClipboardSequenceNumber() == sequence, "Passive selection entry touched clipboard");
      const auto actionStyle = GetWindowLongPtrW(action, GWL_EXSTYLE);
      Check((actionStyle & WS_EX_NOACTIVATE) && (actionStyle & WS_EX_TOOLWINDOW), "Selection entry is activating or taskbar eligible");
      RECT bounds{}; Check(GetWindowRect(action, &bounds) != 0, "Selection entry bounds missing");
      const POINT center{(bounds.left + bounds.right) / 2, (bounds.top + bounds.bottom) / 2};
      if (selection == 0) {
        Sleep(150); // Allow the real entry's first WM_PAINT before cropping it.
        Screenshot(action, std::wstring(argv[2]) + L".entry.bmp", fixture);
      }
      Mouse(center, 0); Mouse(center, MOUSEEVENTF_LEFTDOWN); Sleep(50); Mouse(center, MOUSEEVENTF_LEFTUP);
      Check(Wait([] { EnumWindows(FindApp, 0); return popup && IsWindowVisible(popup); }), "Clicking selection entry did not open independent popup");
      Check(popup != mainWindow && !IsWindowVisible(mainWindow), "Selection entry reused or revealed main window");
      Check(Wait([&] { return !IsWindowVisible(action); }), "Clicked selection entry did not dismiss");
      const std::wstring expected = selection ? L"Mouse selection Delta" : L"Mouse selection Charlie";
      const std::wstring stale = selection ? L"Mouse selection Charlie" : L"Synthetic selection Alpha";
      Check(Wait([&] {
        const auto text = AccessibleText(uia, popup);
        return text.find(expected) != std::wstring::npos && text.find(stale) == std::wstring::npos &&
            text.find(L"Synthetic clipboard decoy") == std::wstring::npos;
      }), "Mouse popup missing drag-selected source or retaining prior source");
      Check(Wait([] { return GetForegroundWindow() == popup; }), "Mouse popup did not receive focus");
      if (selection == 0) {
        Sleep(500);
        Screenshot(popup, std::wstring(argv[2]) + L".mouse.bmp");
      }
      Keys({VK_ESCAPE});
      Check(Wait([] { return !IsWindowVisible(popup); }), "Mouse popup Escape failed");
      Check(Wait([&] { return GetForegroundWindow() == fixture; }), "Mouse popup failed to restore external focus");
      Check(!IsWindowVisible(mainWindow), "Closing mouse popup revealed main window");
      Check(GetClipboardSequenceNumber() == sequence, "Mouse translation changed clipboard");
      Check(Wait([&] { return AccessibleText(uia, popup).find(expected) == std::wstring::npos; }), "Dismissed mouse popup retained accessible source text");
    }
    // The source is now BaoCode's own main view. Releasing a popup's F4 after
    // focus restoration must not produce a synthetic down in the main engine.
    // A subsequent genuinely new main AltF4 must still work (no stale swallow).
    for (int order = 0; order < 2; ++order) {
      const bool altFirst = order == 0;
      ShowWindow(mainWindow, SW_RESTORE); SetForegroundWindow(mainWindow);
      Check(Wait([] { return IsWindowVisible(mainWindow) && !IsIconic(mainWindow) && GetForegroundWindow() == mainWindow; }),
          "Main-source test could not restore/focus actual main window");
      std::printf("ALT_F4_MAIN_SOURCE|iteration=%d|releaseOrder=%s\n", order + 1,
          altFirst ? "Alt_then_F4" : "F4_then_Alt");
      TraceMain(2, 2, "before_open", TRUE, FALSE);
      Keys({VK_CONTROL, VK_MENU, 'Y'});
      Check(Wait([] { EnumWindows(FindApp, 0); return popup && IsWindowVisible(popup) && GetForegroundWindow() == popup; }),
          "Main-source shortcut did not open independent popup");
      Check(popup != mainWindow, "Main-source popup reused main HWND");
      TraceMain(2, 2, "after_open", TRUE, FALSE);
      Check(IsWindowVisible(mainWindow) && !IsIconic(mainWindow), "Opening main-source popup changed main state");
      Check(Wait([&] {
        const auto text = AccessibleText(uia, popup);
        return text.find(L"Mouse selection Charlie") == std::wstring::npos &&
            text.find(L"Mouse selection Delta") == std::wstring::npos &&
            text.find(L"Synthetic clipboard decoy") == std::wstring::npos;
      }), "Main-source popup retained external source or clipboard decoy");
      TraceMain(2, 2, "before_close", TRUE, FALSE);
      AltF4ReleaseOrder(altFirst);
      Check(Wait([] { return !IsWindowVisible(popup) && GetForegroundWindow() == mainWindow; }),
          "Main-source popup close failed to restore main focus");
      Sleep(40);
      TraceMain(2, 2, "after_close_settled", TRUE, FALSE);
      Check(IsWindow(mainWindow) && IsWindowVisible(mainWindow) && !IsIconic(mainWindow),
          "Popup F4 key release leaked into its main-window source");
      Check(!IsWindowVisible(popup) && GetForegroundWindow() == mainWindow,
          "Main-source popup visibility/focus changed after F4 release");
      Check(GetClipboardSequenceNumber() == sequence, "Main-source translation modified clipboard");
      // No pointer or programmatic close here: this is a genuinely new chord.
      Keys({VK_MENU, VK_F4});
      Check(Wait([] { return IsWindow(mainWindow) && !IsWindowVisible(mainWindow); }),
          "A new main AltF4 was swallowed instead of hiding main to tray");
      TraceMain(0, 2, "genuine_main_chord_hid_to_tray", FALSE, FALSE);
    }
    // Native application cleanup route, not full Dart graceful-quit confirmation.
    // Registration must be released without forcibly terminating the process.
    PostMessageW(mainWindow, WM_APP + 0x42, 0, 0);
    Check(Wait([] { return !IsWindow(mainWindow); }), "Native quit did not close main");
    Check(Wait([] { if (!RegisterHotKey(nullptr, 0x6123, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'Y')) return false; UnregisterHotKey(nullptr, 0x6123); return true; }), "Quit leaked global hotkey");
    std::puts("PASS actual release app: selection UIA, hidden/minimized independence, toolwindow, positioning, Escape/X/Alt+F4/blur/hotkey toggle/Ctrl+W/Ctrl+Shift+W, fresh reopen, six extra AltF4 cycles per main state with both release orders, main-source release isolation and fresh main chord, clipboard sequence, mouse drag/entry click/fresh reopen/focus, native cleanup and hotkey release");
  } catch (const std::exception& e) { std::fprintf(stderr, "FAIL: %s\n", e.what()); result = 1; }
  if (fixture) PostMessageW(fixture, WM_CLOSE, 0, 0);
  if (fixtureProcess.hProcess) { if (WaitForSingleObject(fixtureProcess.hProcess, 3000) == WAIT_TIMEOUT) TerminateProcess(fixtureProcess.hProcess, 1); CloseHandle(fixtureProcess.hProcess); CloseHandle(fixtureProcess.hThread); }
  if (uia) uia->Release(); CoUninitialize(); return result;
}
