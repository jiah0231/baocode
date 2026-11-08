// Standalone Windows SDK test, deliberately out-of-process UIA provider.
#include "../../windows/runner/translation_selection.h"
#include <cstdio>
#include <cstring>
#include <string>

namespace {
constexpr UINT kPrepare = WM_APP + 19;
HWND rich = nullptr;
HWND password = nullptr;
HWND button = nullptr;
HWND alternate = nullptr;
LRESULT CALLBACK Fixture(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_CREATE) {
    rich = CreateWindowExW(0, L"RICHEDIT50W", L"Selected words and untouched words",
        WS_CHILD | WS_VISIBLE | ES_MULTILINE, 10, 10, 420, 100, window, nullptr, nullptr, nullptr);
    password = CreateWindowExW(0, L"EDIT", L"private password",
        WS_CHILD | WS_VISIBLE | ES_PASSWORD, 10, 130, 420, 40, window, nullptr, nullptr, nullptr);
    button = CreateWindowExW(0, L"BUTTON", L"No text pattern",
        WS_CHILD | WS_VISIBLE, 10, 180, 200, 30, window, nullptr, nullptr, nullptr);
    return 0;
  }
  if (message == kPrepare) {
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
    if (wparam == 5) {
      alternate = CreateWindowExW(0, L"STATIC", L"Another foreground window",
          WS_OVERLAPPEDWINDOW | WS_VISIBLE, 80, 80, 200, 100,
          nullptr, nullptr, nullptr, nullptr);
      SetForegroundWindow(alternate);
      return 1;
    }
    if (wparam == 4) {
      const std::wstring oversized(9000, L'x');
      SetWindowTextW(rich, oversized.c_str());
    }
    HWND target = wparam == 2 ? password : (wparam == 3 ? button : rich);
    SetFocus(target);
    SendMessageW(target, EM_SETSEL, 0, wparam == 1 ? 0 : (wparam == 2 || wparam == 4 ? -1 : 14));
    return 1;
  }
  if (message == WM_DESTROY) {
    if (alternate) DestroyWindow(alternate);
    PostQuitMessage(0); return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
int Fail(const char* message) { std::fprintf(stderr, "%s\n", message); return 1; }
}
int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--fixture") {
    LoadLibraryW(L"Msftedit.dll");
    WNDCLASSW cls{}; cls.lpfnWndProc = Fixture; cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"BaoCodeTranslationTestFixture";
    RegisterClassW(&cls);
    const std::wstring title = L"BaoCode translation fixture " + std::to_wstring(GetCurrentProcessId());
    HWND window = CreateWindowW(cls.lpszClassName, title.c_str(), WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        40, 40, 480, 260, nullptr, nullptr, cls.hInstance, nullptr);
    if (!window || !rich || !password) return 2;
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    return 0;
  }
  wchar_t executable[MAX_PATH]; GetModuleFileNameW(nullptr, executable, MAX_PATH);
  std::wstring command = L"\"" + std::wstring(executable) + L"\" --fixture";
  STARTUPINFOW startup{}; startup.cb = static_cast<DWORD>(sizeof(startup));
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr,
                       &startup, &process)) return Fail("Cannot start external fixture");
  AllowSetForegroundWindow(process.dwProcessId);
  const std::wstring title = L"BaoCode translation fixture " + std::to_wstring(process.dwProcessId);
  HWND fixture = nullptr;
  for (int i = 0; i < 100 && !fixture; ++i) {
    Sleep(50); fixture = FindWindowW(L"BaoCodeTranslationTestFixture", title.c_str());
  }
  int result = 0;
  if (!fixture) result = Fail("Fixture window unavailable");
  // Seed clipboard with a decoy and verify the sequence stays unchanged.
  if (fixture && OpenClipboard(fixture)) {
    EmptyClipboard();
    constexpr wchar_t decoy[] = L"STALE CLIPBOARD MUST NEVER BE TRANSLATED";
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, sizeof(decoy));
    if (data) {
      void* buffer = GlobalLock(data);
      if (buffer) { memcpy(buffer, decoy, sizeof(decoy)); GlobalUnlock(data); SetClipboardData(CF_UNICODETEXT, data); }
      else GlobalFree(data);
    }
    CloseClipboard();
  } else if (fixture) result = Fail("Cannot seed clipboard");
  const DWORD clipboard = GetClipboardSequenceNumber();
  for (int mode = 0; mode < 6 && !result; ++mode) {
    AllowSetForegroundWindow(process.dwProcessId);
    DWORD_PTR response = 0;
    if (!SendMessageTimeoutW(fixture, kPrepare, mode, 0, SMTO_ABORTIFHUNG, 2000, &response)) {
      result = Fail("Fixture failed to prepare selection"); break;
    }
    Sleep(100);
    if (mode != 5 && GetForegroundWindow() != fixture) { result = Fail("Fixture could not acquire foreground"); break; }
    const auto selected = translation_selection::Capture(fixture);
    if (mode == 5 && GetForegroundWindow() == fixture) { result = Fail("Fixture failed to switch focus"); break; }
    if (selected.self) result = Fail("External fixture incorrectly marked self");
    if (mode == 0 && (selected.status != "ok" || selected.text != L"Selected words"))
      result = Fail("UIA did not capture precisely the selected range");
    if (mode == 1 && (selected.status != "noSelection" || !selected.text.empty()))
      result = Fail("Collapsed selection returned text");
    if (mode == 2 && (selected.status != "password" || !selected.text.empty()))
      result = Fail("Password was not rejected");
    if (mode == 3 && (selected.status != "unsupported" || !selected.text.empty()))
      result = Fail("Unsupported control returned text");
    if (mode == 4 && (selected.status != "tooLong" || !selected.text.empty()))
      result = Fail("Oversized selection was accepted or truncated");
    if (mode == 5 && (selected.status != "focusChanged" || !selected.text.empty()))
      result = Fail("Changed foreground accepted stale selection");
    if (GetClipboardSequenceNumber() != clipboard) result = Fail("Capture changed clipboard");
  }
  if (fixture) PostMessageW(fixture, WM_CLOSE, 0, 0);
  if (WaitForSingleObject(process.hProcess, 3000) != WAIT_OBJECT_0) TerminateProcess(process.hProcess, 3);
  CloseHandle(process.hThread); CloseHandle(process.hProcess);
  if (!result) std::puts("PASS: selected range, no selection, password, unsupported, oversized, changed focus, clipboard unchanged");
  return result;
}
