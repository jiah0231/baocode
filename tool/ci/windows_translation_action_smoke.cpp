// Disposable CI desktop only: SendInput must never run on a user's desktop.
#include "../../windows/runner/translation_selection_action.h"
#include <windows.h>
#include <cstdio>
#include <memory>
#include <string>
namespace {
HWND edit = nullptr;
HWND password = nullptr;
HWND ordinary_button = nullptr;
std::unique_ptr<TranslationSelectionAction> action;
int clicks = 0;
HWND captured = nullptr;
constexpr UINT kPrepare = WM_APP + 22;
LRESULT CALLBACK Fixture(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_CREATE) {
    edit = CreateWindowW(L"RICHEDIT50W", L"Select these sample words for translation",
      WS_CHILD | WS_VISIBLE | ES_MULTILINE, 20, 20, 480, 80, hwnd, nullptr, nullptr, nullptr);
    password = CreateWindowW(L"EDIT", L"private password words", WS_CHILD | WS_VISIBLE | ES_PASSWORD,
      20, 110, 480, 30, hwnd, nullptr, nullptr, nullptr);
    ordinary_button = CreateWindowW(L"BUTTON", L"Ordinary button, not selectable text",
      WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 20, 155, 300, 35,
      hwnd, nullptr, nullptr, nullptr);
    return 0;
  }
  if (message == kPrepare) {
    SetForegroundWindow(hwnd);
    const HWND target = wparam == 2 ? ordinary_button : (wparam == 1 ? password : edit);
    SetFocus(target);
    if (wparam != 2) SendMessage(target, EM_SETSEL, 0, 0);
    return 0;
  }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
LRESULT CALLBACK Dispatch(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  LRESULT result = 0;
  if (action && action->HandleMessage(message, wparam, lparam, &result)) return result;
  return DefWindowProc(hwnd, message, wparam, lparam);
}
void Pump(DWORD duration) {
  const ULONGLONG end = GetTickCount64() + duration;
  while (GetTickCount64() < end) {
    MSG msg;
    while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessage(&msg); }
    Sleep(5);
  }
}
void Mouse(DWORD flags) { INPUT input{}; input.type = INPUT_MOUSE; input.mi.dwFlags = flags; SendInput(1, &input, sizeof(input)); Pump(40); }
bool Visible() { HWND entry = FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr); return entry && IsWindowVisible(entry); }
void Diagnose(const char* stage, HWND fixture) {
  const HWND entry = FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr);
  DWORD foreground_pid = 0;
  const HWND foreground = GetForegroundWindow();
  GetWindowThreadProcessId(foreground, &foreground_pid);
  std::printf("ACTION_STATE|stage=%s|entry=%p|visible=%d|clicks=%d|captured=%p|fixture=%p|foreground=%p|foregroundPid=%lu\n",
      stage, static_cast<void*>(entry), entry && IsWindowVisible(entry) ? 1 : 0, clicks,
      static_cast<void*>(captured), static_cast<void*>(fixture),
      static_cast<void*>(foreground), foreground_pid);
  std::fflush(stdout);
}
int Fail(const char* reason) { std::fprintf(stderr, "%s\n", reason); return 1; }
}
int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--fixture") {
    LoadLibraryW(L"Msftedit.dll");
    WNDCLASSW cls{}; cls.lpfnWndProc = Fixture; cls.hInstance = GetModuleHandle(nullptr); cls.lpszClassName = L"BaoCodeActionFixture";
    RegisterClassW(&cls);
    const std::wstring title = L"Action fixture " + std::to_wstring(GetCurrentProcessId());
    CreateWindowW(cls.lpszClassName, title.c_str(), WS_OVERLAPPEDWINDOW | WS_VISIBLE,
       100, 100, 540, 260, nullptr, nullptr, cls.hInstance, nullptr);
    MSG msg; while (GetMessage(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessage(&msg); }
    return 0;
  }
  wchar_t guard[16]{};
  if (!GetEnvironmentVariableW(L"BAOCODE_DISPOSABLE_UI_TEST", guard, 16) || std::wstring(guard) != L"1")
    return Fail("Requires BAOCODE_DISPOSABLE_UI_TEST=1 on a disposable CI desktop");
  wchar_t exe[MAX_PATH]{}; GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring command = L"\"" + std::wstring(exe) + L"\" --fixture";
  STARTUPINFO startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION process{};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process)) return Fail("Fixture failed");
  AllowSetForegroundWindow(process.dwProcessId);
  const std::wstring title = L"Action fixture " + std::to_wstring(process.dwProcessId);
  HWND fixture = nullptr;
  for (int i = 0; i < 100 && !fixture; ++i) { fixture = FindWindowW(L"BaoCodeActionFixture", title.c_str()); Sleep(20); }
  if (!fixture) return Fail("Fixture missing");
  WNDCLASSW cls{}; cls.lpfnWndProc = Dispatch; cls.hInstance = GetModuleHandle(nullptr); cls.lpszClassName = L"BaoCodeActionDispatch"; RegisterClassW(&cls);
  HWND dispatcher = CreateWindowW(cls.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, cls.hInstance, nullptr);
  action = std::make_unique<TranslationSelectionAction>(dispatcher, [](HWND source) { ++clicks; captured = source; });
  action->Configure(true, false);
  SendMessage(fixture, kPrepare, 0, 0); Pump(200);
  HWND control = FindWindowExW(fixture, nullptr, L"RICHEDIT50W", nullptr);
  RECT rect{}; GetWindowRect(control, &rect);
  SetCursorPos(rect.left + 3, rect.top + 8); Mouse(MOUSEEVENTF_LEFTDOWN); Mouse(MOUSEEVENTF_LEFTUP); Pump(900);
  int result = 0;
  if (Visible() || clicks) result = Fail("No-selection click showed an entry or captured text");
  SetCursorPos(rect.left + 3, rect.top + 8); Mouse(MOUSEEVENTF_LEFTDOWN);
  for (int i = 1; i <= 8; ++i) { SetCursorPos(rect.left + 3 + i * 15, rect.top + 8); Pump(35); }
  Mouse(MOUSEEVENTF_LEFTUP); Pump(600);
  Diagnose("after_drag", fixture);
  if (!Visible()) result = Fail("Deliberate drag selection did not show entry");
  if (clicks || GetForegroundWindow() != fixture) result = Fail("Entry activated or invoked capture before click");
  HWND entry = FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr);
  Diagnose("before_entry_click", fixture);
  bool click_attempted = false;
  if (entry && IsWindowVisible(entry)) {
    click_attempted = true;
    RECT button{}; GetWindowRect(entry, &button);
    SetCursorPos((button.left + button.right) / 2, (button.top + button.bottom) / 2);
    Mouse(MOUSEEVENTF_LEFTDOWN); Mouse(MOUSEEVENTF_LEFTUP); Pump(100);
    DWORD start = 0, end = 0; SendMessage(control, EM_GETSEL, reinterpret_cast<WPARAM>(&start), reinterpret_cast<LPARAM>(&end));
    if (clicks != 1 || captured != fixture || GetForegroundWindow() != fixture || start == end)
      result = Fail("Click lost selection/focus or failed capture callback");
  }
  Diagnose("after_entry_click", fixture);
  if (!click_attempted || clicks != 1 || captured != fixture)
    result = Fail("Positive entry click did not complete; negative-case click baseline is invalid");
  // A drag gesture is not evidence of selected text. Keep the earlier
  // RichEdit selection intact and verify a focused ordinary button cannot
  // cause a stale selection from another control to expose an entry.
  SendMessage(fixture, kPrepare, 2, 0); Pump(150);
  HWND ordinary = FindWindowExW(fixture, nullptr, L"BUTTON", nullptr);
  RECT ordinary_rect{};
  if (!ordinary || !GetWindowRect(ordinary, &ordinary_rect)) {
    result = Fail("Non-text button fixture missing");
  } else {
    SetCursorPos(ordinary_rect.left + 15, ordinary_rect.top + 15); Mouse(MOUSEEVENTF_LEFTDOWN);
    for (int i = 1; i <= 8; ++i) {
      SetCursorPos(ordinary_rect.left + 15 + i * 20, ordinary_rect.top + 15); Pump(35);
    }
    Mouse(MOUSEEVENTF_LEFTUP); Pump(900);
    Diagnose("ordinary_button_negative", fixture);
    if (Visible() || clicks != 1)
      result = Fail("Ordinary button drag exposed an entry or capture");
    // Also drag over an empty part of the client area, without selecting text.
    POINT empty{350, 175}; ClientToScreen(fixture, &empty);
    SetCursorPos(empty.x, empty.y); Mouse(MOUSEEVENTF_LEFTDOWN);
    for (int i = 1; i <= 6; ++i) {
      SetCursorPos(empty.x + i * 20, empty.y); Pump(35);
    }
    Mouse(MOUSEEVENTF_LEFTUP); Pump(900);
    Diagnose("empty_client_negative", fixture);
    if (Visible() || clicks != 1)
      result = Fail("Empty client-area drag exposed an entry or capture");
  }
  SendMessage(fixture, kPrepare, 1, 0); Pump(150);
  HWND secret = FindWindowExW(fixture, nullptr, L"EDIT", nullptr);
  RECT secret_rect{}; GetWindowRect(secret, &secret_rect);
  SetCursorPos(secret_rect.left + 3, secret_rect.top + 8); Mouse(MOUSEEVENTF_LEFTDOWN);
  SetCursorPos(secret_rect.left + 100, secret_rect.top + 8); Pump(100); Mouse(MOUSEEVENTF_LEFTUP); Pump(900);
  Diagnose("password_negative", fixture);
  if (Visible() || clicks != 1) result = Fail("Password selection exposed an entry or capture");
  action->Configure(false, false); Pump(200);
  if (Visible()) result = Fail("Disable did not hide entry");
  action.reset();
  if (FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr)) result = Fail("Destructor leaked entry window");
  DestroyWindow(dispatcher); PostMessage(fixture, WM_CLOSE, 0, 0);
  WaitForSingleObject(process.hProcess, 2000); CloseHandle(process.hProcess); CloseHandle(process.hThread);
  if (!result) std::puts("Translation action drag/no-selection/non-text/password/nonactivation/click/cleanup passed");
  return result;
}
