// Standalone Windows SDK test, deliberately out-of-process UIA provider.
#include "../../windows/runner/translation_selection.h"
#include "../../windows/runner/translation_panel_keys.h"
#include "../../windows/runner/view_window_keys.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <limits>

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
  // Most native edit controls cannot hold embedded nulls. Exercise the same
  // post-capture guard directly with a length-delimited UIA-style string.
  translation_selection::Selection malformed{std::wstring(L"before\0after", 12), "ok", false};
  translation_selection::RejectEmbeddedNull(malformed);
  if (!malformed.text.empty() || malformed.status != "unsupported")
    return Fail("Embedded null selection was accepted or truncated");
  translation_selection::Selection valid{L"Selected words", "ok", false};
  translation_selection::RejectEmbeddedNull(valid);
  if (valid.text != L"Selected words" || valid.status != "ok")
    return Fail("Valid selection was rejected");
  using translation_panel::Place;
  using translation_panel::SelectionRect;
  const auto below = Place({100, 100, 200, 120}, {0, 0, 1920, 1040}, 480, 560, 10);
  if (below.left != 100 || below.top != 130 || below.right != 580 || below.bottom != 690)
    return Fail("Panel was not placed below selection");
  const auto above = Place({1800, 900, 1850, 920}, {0, 0, 1920, 1040}, 480, 560, 10);
  if (above.left != 1440 || above.top != 330 || above.bottom != 890)
    return Fail("Panel did not flip above selection and clamp right edge");
  const auto negative = Place({-50, -20, -40, -10}, {-1920, -1080, 0, 0}, 720, 840, 15);
  if (negative.left != -720 || negative.right != 0 || negative.top != -875)
    return Fail("Panel placement failed on negative-origin high-DPI monitor");
  const auto tiny = Place({300, 200, 301, 201}, {0, 0, 320, 240}, 960, 1120, 20);
  if (tiny.left != 0 || tiny.top != 0 || tiny.right != 320 || tiny.bottom != 240)
    return Fail("Panel overflowed a small monitor work area");
  if (SelectionRect(0, 0, 0, 10) || SelectionRect(0, 0, -1, 10) ||
      SelectionRect(std::numeric_limits<double>::quiet_NaN(), 0, 10, 10) ||
      SelectionRect(0, 0, std::numeric_limits<double>::infinity(), 10) ||
      SelectionRect(999999, 0, 100, 10) || SelectionRect(-1000001, 0, 10, 10))
    return Fail("Unsafe UIA bounding rectangle accepted");
  const auto fractional = SelectionRect(-1.5, 2.5, 10, 20);
  if (!fractional || fractional->left != -2 || fractional->top != 2 ||
      fractional->right != 9 || fractional->bottom != 23)
    return Fail("UIA bounding rectangle rounding failed");
  using translation_retry::CanRetry;
  if (!CanRetry(true, 1, 100, 1500) || !CanRetry(true, 3, 700, 1500) ||
      CanRetry(true, 4, 700, 1500) || CanRetry(false, 1, 100, 1500) ||
      CanRetry(true, 1, 100, 1500, true) || CanRetry(true, 1, 1500, 1500) ||
      CanRetry(true, 2, 1200, 1500) || CanRetry(true, 0, 100, 1500))
    return Fail("Cold-provider retry policy exceeded attempts/deadline or retried denial");
  using translation_retry::CanRetryInitialFocus;
  constexpr uint32_t timeout_hr = translation_retry::kInitialFocusTimeout;
  if (!CanRetryInitialFocus(timeout_hr, false, true, 1, 500, 1500) ||
      CanRetryInitialFocus(0x80004005u, false, true, 1, 500, 1500) ||
      CanRetryInitialFocus(timeout_hr, true, true, 1, 500, 1500) ||
      CanRetryInitialFocus(timeout_hr, false, false, 1, 500, 1500) ||
      CanRetryInitialFocus(timeout_hr, false, true, 1, 500, 1500, true) ||
      CanRetryInitialFocus(timeout_hr, false, true, 4, 500, 1500) ||
      CanRetryInitialFocus(timeout_hr, false, true, 1, 1400, 1500))
    return Fail("Initial focus timeout retry weakened identity/focus/error/deadline gates");
  using translation_retry::IsInitialChromiumPane;
  if (!IsInitialChromiumPane(false, true, true, true, true, true, true) ||
      IsInitialChromiumPane(true, true, true, true, true, true, true) ||
      IsInitialChromiumPane(false, false, true, true, true, true, true) ||
      IsInitialChromiumPane(false, true, false, true, true, true, true) ||
      IsInitialChromiumPane(false, true, true, false, true, true, true) ||
      IsInitialChromiumPane(false, true, true, true, false, true, true) ||
      IsInitialChromiumPane(false, true, true, true, true, false, true) ||
      IsInitialChromiumPane(false, true, true, true, true, true, false))
    return Fail("Initial Chromium Pane requery accepted unsafe or already bound metadata");
  using translation_retry::CanRetryFinalFocus;
  if (!CanRetryFinalFocus(true, true, true, false, 1, 500, 1500) ||
      !CanRetryFinalFocus(true, true, false, true, 1, 500, 1500) ||
      CanRetryFinalFocus(false, true, true, true, 1, 500, 1500) ||
      CanRetryFinalFocus(true, false, true, true, 1, 500, 1500) ||
      CanRetryFinalFocus(true, true, false, false, 1, 500, 1500) ||
      CanRetryFinalFocus(true, true, true, false, 3, 500, 1500) ||
      CanRetryFinalFocus(true, true, true, false, 1, 1400, 1500) ||
      CanRetryFinalFocus(true, true, true, false, 1, 500, 1500, true))
    return Fail("Final focus retry weakened pinned identity/foreground/deadline/cancel policy");
  translation_panel::CloseKeySequence close_key;
  using translation_panel::CloseKeyAction;
  if (close_key.Handle(true, false, false, false) != CloseKeyAction::pass ||
      close_key.Handle(false, true, false, false) != CloseKeyAction::pass ||
      close_key.Handle(true, false, true, false) != CloseKeyAction::close ||
      close_key.Handle(true, false, true, true) != CloseKeyAction::consume ||
      close_key.Handle(false, true, false, false) != CloseKeyAction::consume ||
      close_key.Handle(false, true, false, false) != CloseKeyAction::pass)
    return Fail("Popup Alt+F4 sequence escaped or closed twice");
  // The prior key-up may have gone to an external app after restoration.
  close_key.Handle(true, false, true, false);
  if (close_key.Handle(true, false, false, false) != CloseKeyAction::pass ||
      close_key.Handle(false, true, false, false) != CloseKeyAction::pass)
    return Fail("Popup close-key ownership leaked into a later plain F4");
  view_window_keys::OwnedKeyRelease owned_release;
  owned_release.Own(VK_F4);
  // Source=main: Alt released first, held F4 repeat, then F4 up. Only F4
  // belongs to the popup; Alt must still reach Flutter's modifier bookkeeping.
  if (owned_release.Consume(VK_MENU, false, true, false) ||
      !owned_release.Consume(VK_F4, true, false, true) ||
      !owned_release.Consume(VK_F4, false, true, false) ||
      owned_release.Consume(VK_F4, true, false, false))
    return Fail("Popup close gesture escaped into restored main view");
  owned_release.Own(VK_F4);
  if (!owned_release.Consume(VK_F4, false, true, false) ||
      owned_release.Consume(VK_MENU, false, true, false))
    return Fail("F4-first release swallowed an unrelated modifier");
  owned_release.Own(VK_F4);  // External source received the old key-up.
  if (owned_release.Consume(VK_F4, true, false, false) ||
      owned_release.Consume(VK_F4, false, true, false))
    return Fail("Old native ownership swallowed a new main-window gesture");
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
    const auto selected = translation_selection::Capture(fixture, true);
    // An explicit gesture alone never authorizes clipboard fallback for a
    // supported/collapsed selection, password, unknown control or stale focus.
    if (selected.copy_proof) result = Fail("Ineligible fixture minted clipboard-copy proof");
    if (mode == 5 && GetForegroundWindow() == fixture) { result = Fail("Fixture failed to switch focus"); break; }
    if (selected.self) result = Fail("External fixture incorrectly marked self");
    if (mode == 0 && (selected.status != "ok" || selected.text != L"Selected words"))
      result = Fail("UIA did not capture precisely the selected range");
    if (mode == 0 && selected.bounds) {
      RECT source = {}, intersection = {};
      GetWindowRect(fixture, &source);
      if (!IntersectRect(&intersection, &source, &*selected.bounds) ||
          !EqualRect(&intersection, &*selected.bounds))
        result = Fail("Selection anchor escaped source window bounds");
    }
    if (mode != 0 && selected.bounds) result = Fail("Rejected selection retained a stale anchor");
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
  if (!result) std::puts("PASS: selected range, no selection, password, unsupported, oversized, changed focus, embedded null rejection, clipboard unchanged, placement and bounds validation");
  return result;
}
