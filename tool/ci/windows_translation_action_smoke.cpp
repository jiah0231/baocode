// Disposable CI desktop only: SendInput must never run on a user's desktop.
#include "../../windows/runner/translation_selection_action.h"
#include <windows.h>
#include <cstdio>
#include <memory>
#include <string>
#include <mutex>
#include <atomic>
namespace {
HWND edit = nullptr;
HWND password = nullptr;
HWND ordinary_button = nullptr;
HWND alternate_edit = nullptr;
std::mutex capture_mutex;
translation_selection::Selection bound_result;
std::atomic<int> completions{0};
std::atomic<bool> cancel_capture{false};
int mutate_before_queue = -1;
int queued_clicks = 0;
bool mutation_verified = true;
std::unique_ptr<TranslationSelectionAction> action;
int clicks = 0;
HWND captured = nullptr;
constexpr UINT kPrepare = WM_APP + 22;
constexpr UINT kSwitchEdit = WM_APP + 23;
LRESULT CALLBACK Fixture(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_CREATE) {
    edit = CreateWindowW(L"RICHEDIT50W", L"Select these sample words for translation",
      WS_CHILD | WS_VISIBLE | ES_MULTILINE, 20, 20, 480, 80, hwnd, nullptr, nullptr, nullptr);
    password = CreateWindowW(L"EDIT", L"private password words", WS_CHILD | WS_VISIBLE | ES_PASSWORD,
      20, 110, 480, 30, hwnd, nullptr, nullptr, nullptr);
    ordinary_button = CreateWindowW(L"BUTTON", L"Ordinary button, not selectable text",
      WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 20, 155, 300, 35,
      hwnd, nullptr, nullptr, nullptr);
    alternate_edit = CreateWindowW(L"EDIT", L"Different source must never be returned",
      WS_CHILD | WS_VISIBLE, 20, 195, 480, 25, hwnd, nullptr, nullptr, nullptr);
    return 0;
  }
  if (message == kSwitchEdit) {
    SetFocus(alternate_edit);
    SendMessage(alternate_edit, EM_SETSEL, 0, -1);
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
  const HWND source_edit = FindWindowExW(fixture, nullptr, L"RICHEDIT50W", nullptr);
  DWORD selection_start = 0, selection_end = 0;
  SendMessage(source_edit, EM_GETSEL, reinterpret_cast<WPARAM>(&selection_start), reinterpret_cast<LPARAM>(&selection_end));
  GUITHREADINFO gui{}; gui.cbSize = sizeof(gui);
  const bool gui_ok = GetGUIThreadInfo(GetWindowThreadProcessId(fixture, nullptr), &gui) != FALSE;
  std::printf("ACTION_NATIVE_SELECTION|stage=%s|edit=%p|start=%lu|end=%lu|guiOk=%d|focus=%p|capture=%p\n",
      stage, static_cast<void*>(source_edit), selection_start, selection_end, gui_ok ? 1 : 0,
      static_cast<void*>(gui.hwndFocus), static_cast<void*>(gui.hwndCapture));
  std::fflush(stdout);
}
bool NativeSelectionEstablished(HWND fixture, HWND source_edit) {
  DWORD begin = 0, end = 0;
  SendMessage(source_edit, EM_GETSEL, reinterpret_cast<WPARAM>(&begin), reinterpret_cast<LPARAM>(&end));
  GUITHREADINFO gui{}; gui.cbSize = sizeof(gui);
  return begin != end && GetForegroundWindow() == fixture &&
      GetGUIThreadInfo(GetWindowThreadProcessId(fixture, nullptr), &gui) && gui.hwndFocus == source_edit;
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
  action = std::make_unique<TranslationSelectionAction>(dispatcher, [](HWND source) {
    ++clicks; captured = source;
    cancel_capture.store(false);
    // Deterministic capture race: physical click has been accepted, but the
    // source changes before the queued bound read. The source is a separate
    // process, so it handles real keyboard input while this callback waits.
    mutation_verified = mutate_before_queue < 0 || mutate_before_queue == 2;
    if (mutate_before_queue == 0) {
      HWND source_edit = FindWindowExW(source, nullptr, L"RICHEDIT50W", nullptr);
      DWORD before_start = 0, before_end = 0;
      SendMessage(source_edit, EM_GETSEL, reinterpret_cast<WPARAM>(&before_start), reinterpret_cast<LPARAM>(&before_end));
      INPUT keys[4]{};
      for (auto& key : keys) key.type = INPUT_KEYBOARD;
      keys[0].ki.wVk = VK_SHIFT;
      keys[1].ki.wVk = VK_END;
      keys[2].ki.wVk = VK_END; keys[2].ki.dwFlags = KEYEVENTF_KEYUP;
      keys[3].ki.wVk = VK_SHIFT; keys[3].ki.dwFlags = KEYEVENTF_KEYUP;
      const bool input_sent = SendInput(4, keys, sizeof(INPUT)) == 4;
      Sleep(60);
      DWORD after_start = 0, after_end = 0;
      SendMessage(source_edit, EM_GETSEL, reinterpret_cast<WPARAM>(&after_start), reinterpret_cast<LPARAM>(&after_end));
      mutation_verified = input_sent && (before_start != after_start || before_end != after_end);
    } else if (mutate_before_queue == 1) {
      SendMessage(source, kSwitchEdit, 0, 0);
      const HWND first_edit = FindWindowExW(source, nullptr, L"EDIT", nullptr);
      const HWND second_edit = FindWindowExW(source, first_edit, L"EDIT", nullptr);
      GUITHREADINFO gui{}; gui.cbSize = sizeof(gui);
      mutation_verified = second_edit && GetGUIThreadInfo(GetWindowThreadProcessId(source, nullptr), &gui) &&
          gui.hwndFocus == second_edit;
    }
    const bool queued = action->CaptureClickedSelection(source, GetTickCount64() + 1500,
        [] { return cancel_capture.load(); },
        [](translation_selection::Selection selected) {
          { std::lock_guard<std::mutex> lock(capture_mutex); bound_result = std::move(selected); }
          ++completions;
        }, [] { cancel_capture.store(true); });
    if (queued) ++queued_clicks;
    if (queued && mutate_before_queue == 2) action->Hide();
    if (!queued) {
      { std::lock_guard<std::mutex> lock(capture_mutex);
        bound_result = translation_selection::Selection{}; bound_result.status = "notQueued"; }
      ++completions;
    }
  });
  action->Configure(true, false);
  SendMessage(fixture, kPrepare, 0, 0); Pump(200);
  HWND control = FindWindowExW(fixture, nullptr, L"RICHEDIT50W", nullptr);
  RECT rect{}; GetWindowRect(control, &rect);
  SetCursorPos(rect.left + 3, rect.top + 8); Mouse(MOUSEEVENTF_LEFTDOWN); Mouse(MOUSEEVENTF_LEFTUP); Pump(900);
  int result = 0;
  if (Visible() || clicks) result = Fail("No-selection click showed an entry or captured text");
  SetCursorPos(rect.left + 3, rect.top + 8); Mouse(MOUSEEVENTF_LEFTDOWN);
  for (int i = 1; i <= 8; ++i) { SetCursorPos(rect.left + 3 + i * 15, rect.top + 8); Pump(35); }
  Mouse(MOUSEEVENTF_LEFTUP);
  Diagnose("immediately_after_drag", fixture);
  const bool initial_selection_proven = NativeSelectionEstablished(fixture, control);
  if (!initial_selection_proven) result = Fail("Real drag did not establish a nonempty native RichEdit selection and focus");
  // Observe this single gesture for the production discovery budget. No new
  // input, provider preflight, second selection or extra capture is performed.
  const ULONGLONG discovery_end = GetTickCount64() + 1500;
  while (!Visible() && GetTickCount64() < discovery_end) Pump(10);
  Diagnose("after_drag", fixture);
  if (initial_selection_proven && !Visible()) result = Fail("Proven native drag selection did not show entry within discovery budget");
  if (clicks || GetForegroundWindow() != fixture) result = Fail("Entry activated or invoked capture before click");
  HWND entry = FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr);
  Diagnose("before_entry_click", fixture);
  bool click_attempted = false;
  if (entry && IsWindowVisible(entry)) {
    click_attempted = true;
    RECT button{}; GetWindowRect(entry, &button);
    // Fully transparent corners pass to the separate source process, while
    // painted shadow pixels deliberately share the entry's native/hook hit area.
    const POINT corner{button.left, button.top};
    if (GetAncestor(WindowFromPoint(corner), GA_ROOT) != fixture)
      result = Fail("Transparent entry corner intercepted the external source");
    const POINT shadow{(button.left + button.right) / 2, button.bottom - 2};
    SetCursorPos(shadow.x, shadow.y); Pump(50);
    if (GetAncestor(WindowFromPoint(shadow), GA_ROOT) != entry)
      result = Fail("Painted entry shadow disagrees with the native hit region");
    Mouse(MOUSEEVENTF_LEFTDOWN); Mouse(MOUSEEVENTF_LEFTUP);
    for (int i = 0; i < 160 && completions.load() == 0; ++i) Pump(10);
    DWORD start = 0, end = 0; SendMessage(control, EM_GETSEL, reinterpret_cast<WPARAM>(&start), reinterpret_cast<LPARAM>(&end));
    if (clicks != 1 || captured != fixture || GetForegroundWindow() != fixture || start == end)
      result = Fail("Click lost selection/focus or failed capture callback");
  }
  Diagnose("after_entry_click", fixture);
  { std::lock_guard<std::mutex> lock(capture_mutex);
    if (completions.load() != 1 || bound_result.status != "ok" || bound_result.text.empty())
      result = Fail("Unchanged entry click did not complete bound source capture");
  }
  if (!click_attempted || clicks != 1 || captured != fixture)
    result = Fail("Positive entry click did not complete; negative-case click baseline is invalid");
  action->Hide();
  if (!cancel_capture.load()) result = Fail("Finished click lost invalidation link before delivery");
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
  // Re-arm a real entry. Its accepted physical click changes the selection or
  // focused edit in the SAME source HWND immediately before queueing the read.
  // This ensures the verifier is exercised rather than a prior timer hiding it.
  for (int mutation = 0; mutation < 3; ++mutation) {
    SendMessage(fixture, kPrepare, 0, 0); Pump(150);
    SetCursorPos(rect.left + 3, rect.top + 8); Mouse(MOUSEEVENTF_LEFTDOWN);
    for (int i = 1; i <= 8; ++i) { SetCursorPos(rect.left + 3 + i * 15, rect.top + 8); Pump(35); }
    Mouse(MOUSEEVENTF_LEFTUP);
    Diagnose("mutation_entry_after_drag", fixture);
    if (!NativeSelectionEstablished(fixture, control)) {
      result = Fail("Mutation setup drag did not establish a nonempty native selection and focus");
      continue;
    }
    for (int i = 0; i < 150 && !Visible(); ++i) Pump(10);
    HWND old_entry = FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr);
    RECT old_button{};
    if (!old_entry || !IsWindowVisible(old_entry) || !GetWindowRect(old_entry, &old_button)) {
      result = Fail("Mutation regression could not establish its old visible entry");
      continue;
    }
    const int before_clicks = clicks;
    const int before_queued = queued_clicks;
    const int before_completions = completions.load();
    mutate_before_queue = mutation;
    SetCursorPos((old_button.left + old_button.right) / 2, (old_button.top + old_button.bottom) / 2);
    INPUT mouse[2]{};
    mouse[0].type = mouse[1].type = INPUT_MOUSE;
    mouse[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    mouse[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    if (SendInput(2, mouse, sizeof(INPUT)) != 2) result = Fail("Old-entry click input failed");
    for (int i = 0; i < 160 && completions.load() == before_completions; ++i) Pump(10);
    mutate_before_queue = -1;
    Diagnose(mutation == 0 ? "changed_range_before_read" : (mutation == 1 ? "changed_control_before_read" : "cancel_after_queue"), fixture);
    { std::lock_guard<std::mutex> lock(capture_mutex);
      if (clicks != before_clicks + 1 || queued_clicks != before_queued + 1 ||
          completions.load() != before_completions + 1 || !mutation_verified || bound_result.status == "notQueued")
        result = Fail("Mutation regression did not execute a verified change and queued bound capture");
      else if (bound_result.status == "ok" || !bound_result.text.empty())
        result = Fail("Old entry captured replacement range or focused control");
    }
  }
  action->Configure(false, false); Pump(200);
  if (Visible()) result = Fail("Disable did not hide entry");
  action.reset();
  if (FindWindowW(L"BaoCodeTranslationSelectionAction", nullptr)) result = Fail("Destructor leaked entry window");
  DestroyWindow(dispatcher); PostMessage(fixture, WM_CLOSE, 0, 0);
  WaitForSingleObject(process.hProcess, 2000); CloseHandle(process.hProcess); CloseHandle(process.hThread);
  if (!result) std::puts("Translation action drag/no-selection/non-text/password/nonactivation/click/cleanup passed");
  return result;
}
