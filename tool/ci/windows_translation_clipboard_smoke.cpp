// Intrusive synthetic test. Run only on disposable Windows CI desktops.
#include "../../windows/runner/translation_clipboard_capture.h"
#include <cstdio>
namespace {
constexpr UINT kPrepare = WM_APP + 71;
HWND edit = nullptr, other = nullptr;
WNDPROC original = nullptr;
int mode = 0, copies = 0;
bool Put(HWND owner, const std::wstring& text, bool locale = false) {
  if (!OpenClipboard(owner)) return false;
  bool ok = EmptyClipboard() != FALSE;
  HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, (text.size() + 1) * sizeof(wchar_t));
  void* buffer = data ? GlobalLock(data) : nullptr;
  if (buffer) {
    memcpy(buffer, text.c_str(), (text.size() + 1) * sizeof(wchar_t)); GlobalUnlock(data);
    if (!SetClipboardData(CF_UNICODETEXT, data)) { GlobalFree(data); ok = false; }
  } else { if (data) GlobalFree(data); ok = false; }
  if (locale) {
    HGLOBAL value = GlobalAlloc(GMEM_MOVEABLE, sizeof(LCID));
    auto* ptr = value ? static_cast<LCID*>(GlobalLock(value)) : nullptr;
    if (ptr) { *ptr = 0x0409; GlobalUnlock(value); if (!SetClipboardData(CF_LOCALE, value)) { GlobalFree(value); ok = false; } }
    else { if (value) GlobalFree(value); ok = false; }
  }
  CloseClipboard(); return ok;
}
LRESULT CALLBACK EditProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  // Simulate a control with no selected-text UIA provider, but standard edit
  // semantics and a copy command. The actual physical path is SendInput.
  if (message == WM_GETOBJECT) return 0;
  if (message == WM_KEYDOWN && wparam == 'C' && (GetKeyState(VK_CONTROL) & 0x8000)) {
    ++copies;
    if (mode == 9) {
      if (copies == 1) {
        // Queue a second, independent copy gesture in the SAME target. This
        // cannot be rejected using clipboard owner/sequence/focus alone.
        const DWORD capture_time = static_cast<DWORD>(GetMessageTime());
        Sleep(25);
        DWORD concurrent_time = GetTickCount();
        if (!concurrent_time || concurrent_time == capture_time) concurrent_time = capture_time + 1;
        if (!concurrent_time) concurrent_time = 1;
        INPUT user_copy[4]{};
        for (auto& key : user_copy) { key.type = INPUT_KEYBOARD; key.ki.time = concurrent_time; }
        user_copy[0].ki.wVk = VK_CONTROL; user_copy[1].ki.wVk = 'C';
        user_copy[2].ki.wVk = 'C'; user_copy[2].ki.dwFlags = KEYEVENTF_KEYUP;
        user_copy[3].ki.wVk = VK_CONTROL; user_copy[3].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(4, user_copy, sizeof(INPUT));
      } else Put(window, L"SAME TARGET USER COPY SENTINEL");
      return 0;
    }
    if (mode == 1) return 0;
    if (mode == 2) { Put(other, L"CONCURRENT COPY SENTINEL"); return 0; }
    if (mode == 3) { ShowWindow(other, SW_SHOW); SetForegroundWindow(other); return 0; }
    if (mode == 4) { Put(window, std::wstring(8001, L'x')); return 0; }
    if (mode == 5) { Put(window, std::wstring(L"part\0hidden", 11)); return 0; }
    Put(window, L"Selected source only"); return 0;
  }
  return CallWindowProcW(original, window, message, wparam, lparam);
}
LRESULT CALLBACK Fixture(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_CREATE) {
    edit = CreateWindowW(L"EDIT", L"Selected source only plus unselected",
      WS_CHILD | WS_VISIBLE, 0, 0, 400, 100, window, nullptr, nullptr, nullptr);
    original = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(edit, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(EditProc)));
    other = CreateWindowW(L"STATIC", L"Concurrent writer", WS_OVERLAPPEDWINDOW,
      20, 20, 150, 100, nullptr, nullptr, nullptr, nullptr);
    return 0;
  }
  if (message == kPrepare) {
    mode = static_cast<int>(wparam); copies = 0;
    SetWindowLongPtrW(edit, GWL_STYLE, WS_CHILD | WS_VISIBLE | (mode == 6 ? ES_PASSWORD : 0));
    ShowWindow(window, SW_SHOW); SetForegroundWindow(window); SetFocus(edit);
    SendMessageW(edit, EM_SETSEL, 0, mode == 8 ? 0 : 20);
    return reinterpret_cast<LRESULT>(edit);
  }
  if (message == kPrepare + 1) return copies;
  if (message == WM_DESTROY) { DestroyWindow(other); PostQuitMessage(0); return 0; }
  return DefWindowProcW(window, message, wparam, lparam);
}
// Hosted Windows runners may be elevated. Exercise the production medium-
// integrity guard rather than adding a test-only bypass to the capture helper.
bool StartFixture(std::wstring& command, STARTUPINFOW& startup, PROCESS_INFORMATION& child) {
  HANDLE token = nullptr, restricted = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE |
        TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT, &token)) return false;
  bool success = false;
  if (CreateRestrictedToken(token, LUA_TOKEN, 0, nullptr, 0, nullptr, 0, nullptr, &restricted)) {
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_MANDATORY_LABEL_AUTHORITY;
    PSID sid = nullptr;
    if (AllocateAndInitializeSid(&authority, 1, SECURITY_MANDATORY_MEDIUM_RID,
          0, 0, 0, 0, 0, 0, 0, &sid)) {
      TOKEN_MANDATORY_LABEL label{};
      label.Label.Attributes = SE_GROUP_INTEGRITY; label.Label.Sid = sid;
      if (SetTokenInformation(restricted, TokenIntegrityLevel, &label,
            static_cast<DWORD>(sizeof(label)) + GetLengthSid(sid))) {
        success = CreateProcessAsUserW(restricted, nullptr, command.data(), nullptr,
          nullptr, FALSE, 0, nullptr, nullptr, &startup, &child) != FALSE;
      }
      FreeSid(sid);
    }
    CloseHandle(restricted);
  }
  CloseHandle(token);
  return success;
}
int Fail(const char* why) { std::fprintf(stderr, "%s\n", why); return 1; }
}
int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--fixture") {
    WNDCLASSW cls{}; cls.lpfnWndProc = Fixture; cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"BaoClipboardFixture"; RegisterClassW(&cls);
    std::wstring title = L"Clipboard fixture " + std::to_wstring(GetCurrentProcessId());
    if (!CreateWindowW(cls.lpszClassName, title.c_str(), WS_OVERLAPPEDWINDOW | WS_VISIBLE,
          50, 50, 450, 200, nullptr, nullptr, cls.hInstance, nullptr)) return 2;
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
    return 0;
  }
  // Exercise the exact production finalization path without forcing destructive
  // OS allocation failures. Every focus/input/cancellation combination must
  // preserve the restoration warning, while never delivering source text.
  for (int mask = 0; mask < 8; ++mask) {
    const bool same_focus = (mask & 1) != 0;
    const bool same_input = (mask & 2) != 0;
    const bool canceled = (mask & 4) != 0;
    translation_clipboard::Result failed{L"must not escape", "clipboardRestoreFailed"};
    translation_clipboard::FinalizeCaptureResult(failed, same_focus, same_input, canceled);
    if (!failed.text.empty() || failed.status != "clipboardRestoreFailed")
      return Fail("Restoration warning lost after focus/input change or cancellation");
    translation_clipboard::Result ordinary{L"selected", "ok"};
    translation_clipboard::FinalizeCaptureResult(ordinary, same_focus, same_input, canceled);
    const std::string expected = !same_focus ? "focusChanged" :
      (!same_input ? "clipboardChanged" : (canceled ? "canceled" : "ok"));
    if (ordinary.status != expected ||
        ordinary.text != (expected == "ok" ? L"selected" : L""))
      return Fail("Ordinary capture finalization changed status priority or leaked stale text");
  }
  wchar_t executable[MAX_PATH]{}; GetModuleFileNameW(nullptr, executable, MAX_PATH);
  std::wstring command = L"\"" + std::wstring(executable) + L"\" --fixture";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION child{};
  if (!StartFixture(command, startup, child))
    return Fail("Cannot launch clipboard fixture");
  AllowSetForegroundWindow(child.dwProcessId);
  const std::wstring title = L"Clipboard fixture " + std::to_wstring(child.dwProcessId);
  HWND fixture = nullptr;
  for (int i = 0; i < 100 && !fixture; ++i) { Sleep(30); fixture = FindWindowW(L"BaoClipboardFixture", title.c_str()); }
  HWND owner = CreateWindowW(L"STATIC", L"Snapshot owner", 0, 0, 0, 1, 1, nullptr, nullptr, nullptr, nullptr);
  int result = !fixture || !owner ? Fail("Fixture unavailable") : 0;
  for (int test = 0; test < 10 && !result; ++test) {
    AllowSetForegroundWindow(child.dwProcessId);
    DWORD_PTR target = 0;
    if (!SendMessageTimeoutW(fixture, kPrepare, test, 0, SMTO_ABORTIFHUNG, 2000, &target)) {
      result = Fail("Cannot prepare fixture"); break;
    }
    Sleep(50);
    translation_clipboard::Proof proof;
    proof.foreground = fixture; proof.focused = reinterpret_cast<HWND>(target);
    proof.thread = GetWindowThreadProcessId(fixture, &proof.process);
    proof.explicit_shortcut = proof.non_password = proof.safe_text_control = true;
    if (!Put(owner, L"ORIGINAL UNICODE \u4e2d\u6587", true)) { result = Fail("Cannot seed snapshot"); break; }
    const DWORD sequence = GetClipboardSequenceNumber();
    if (test == 7) {
      INPUT held{}; held.type = INPUT_KEYBOARD; held.ki.wVk = VK_SHIFT;
      SendInput(1, &held, sizeof(INPUT)); Sleep(30);
    }
    const auto captured = translation_clipboard::CopySelection(owner, proof);
    if (test == 7) {
      INPUT release{}; release.type = INPUT_KEYBOARD; release.ki.wVk = VK_SHIFT;
      release.ki.dwFlags = KEYEVENTF_KEYUP; SendInput(1, &release, sizeof(INPUT));
    }
    DWORD_PTR count = 0;
    SendMessageTimeoutW(fixture, kPrepare + 1, 0, 0, SMTO_ABORTIFHUNG, 2000, &count);
    if (test == 0 && (captured.status != "ok" || captured.text != L"Selected source only" || count != 1))
      result = Fail("Actual SendInput copy did not capture exact selection");
    if (test == 1 && (captured.status != "clipboardTimeout" || GetClipboardSequenceNumber() != sequence))
      result = Fail("Unchanged/stale clipboard accepted or overwritten");
    if (test == 2 && captured.status != "clipboardChanged") result = Fail("Concurrent writer accepted");
    if (test == 3 && captured.status != "focusChanged") result = Fail("Foreground change accepted");
    if (test == 4 && captured.status != "tooLong") result = Fail("Oversized selection accepted");
    if (test == 5 && (!captured.text.empty() || captured.status != "unsupported")) result = Fail("Embedded NUL accepted");
    if (test == 6 && (count || captured.status != "unsupported")) result = Fail("Password copy was injected");
    if (test == 7 && (count || captured.status != "keysHeld")) result = Fail("Copy injected with shortcut modifier held");
    if (test == 8 && (count || captured.status != "noSelection")) result = Fail("Collapsed selection copied whole document");
    if (test == 9 && (count != 2 || !captured.text.empty() || captured.status != "clipboardChanged"))
      result = Fail("Same-target concurrent user copy was read or accepted");
    if (!OpenClipboard(owner)) result = Fail("Cannot inspect final clipboard");
    else {
      const auto clipboard = translation_clipboard::ReadUnicode();
      const std::wstring expected = test == 2 ? L"CONCURRENT COPY SENTINEL" :
        (test == 9 ? L"SAME TARGET USER COPY SENTINEL" : L"ORIGINAL UNICODE \u4e2d\u6587");
      if (clipboard.text != expected) result = Fail("Original or concurrent clipboard was not preserved");
      if (test != 2 && test != 9) {
        HANDLE data = GetClipboardData(CF_LOCALE);
        const auto* value = data ? static_cast<const LCID*>(GlobalLock(data)) : nullptr;
        if (!value || *value != 0x0409) result = Fail("Binary locale snapshot was not restored");
        if (value) GlobalUnlock(data);
      }
      CloseClipboard();
    }
  }
  if (fixture) PostMessageW(fixture, WM_CLOSE, 0, 0);
  if (WaitForSingleObject(child.hProcess, 2000) != WAIT_OBJECT_0) TerminateProcess(child.hProcess, 2);
  CloseHandle(child.hThread); CloseHandle(child.hProcess); if (owner) DestroyWindow(owner);
  if (!result) std::puts("PASS: separate-process SendInput clipboard capture, snapshot, races and rejection guards");
  return result;
}
