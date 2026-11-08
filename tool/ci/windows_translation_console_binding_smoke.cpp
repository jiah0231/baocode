// Deterministic production ancestry checks plus real Win32 rejection fixtures.
// Run only on a disposable Windows CI desktop. No clipboard access, input
// injection, text reading, settings changes, or existing-app inspection.
#include "../../windows/runner/translation_console_binding.h"
#include "windows_translation_medium_fixture.h"
#include <array>
#include <cstring>
#include <sddl.h>
#include <cstdio>
#include <stdexcept>

namespace {
using translation_selection::ConsoleBinding;
namespace detail = translation_selection::console_binding_detail;
using translation_test_fixture::Integrity;
using translation_test_fixture::FixtureIpcSecurity;
using Microsoft::WRL::ComPtr;
void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
constexpr DWORD kProvider = 42;
HWND SyntheticHandle() { return reinterpret_cast<HWND>(static_cast<UINT_PTR>(1234)); }
struct Node {
  int process = static_cast<int>(kProvider);
  BOOL password = FALSE;
  BOOL offscreen = FALSE;
  CONTROLTYPEID type = UIA_DocumentControlTypeId;
  UIA_HWND native{};
  Node* parent = nullptr;
};
struct FakeTree {
  using Element = Node*;
  Node root;
  Node focus;
  Element returned_root = &root;
  bool walker = true, alive = true, foreground = true;
  bool canceled = false, expired = false;
  unsigned calls = 0, parents = 0, fail_at = 0, cancel_at = 0, expire_at = 0;
  FakeTree() {
    root.type = UIA_WindowControlTypeId;
    root.native = reinterpret_cast<UIA_HWND>(SyntheticHandle());
    focus.parent = &root;
  }
  bool Call() {
    ++calls;
    if (calls == cancel_at) canceled = true;
    if (calls == expire_at) expired = true;
    return calls != fail_at;
  }
  bool Root(HWND, Element* out) { if (!Call()) return false; *out = returned_root; return true; }
  bool Native(Element node, UIA_HWND* out) { if (!Call()) return false; *out = node->native; return true; }
  bool Type(Element node, CONTROLTYPEID* out) { if (!Call()) return false; *out = node->type; return true; }
  bool Process(Element node, int* out) { if (!Call()) return false; *out = node->process; return true; }
  bool Password(Element node, BOOL* out) { if (!Call()) return false; *out = node->password; return true; }
  bool Offscreen(Element node, BOOL* out) { if (!Call()) return false; *out = node->offscreen; return true; }
  bool Walker() { return Call() && walker; }
  bool Same(Element first, Element second, BOOL* out) {
    if (!Call()) return false;
    *out = first == second ? TRUE : FALSE;
    return true;
  }
  bool Parent(Element node, Element* out) {
    ++parents;
    if (!Call()) return false;
    *out = node->parent;
    return true;
  }
  bool Verify(Element focused) {
    return detail::VerifyAncestry(*this, SyntheticHandle(), kProvider, focused,
        [&] { return !canceled && !expired && foreground; }, [&] { return alive; });
  }
  bool Verify() { return Verify(&focus); }
};
void DeterministicChecks() {
  static_assert((translation_test_fixture::kRestrictedFixtureTokenAccess & TOKEN_ADJUST_DEFAULT) != 0,
      "CreateRestrictedToken must inherit ADJUST_DEFAULT for the disposable integrity setter");
  static_assert((translation_test_fixture::kRestrictedFixtureTokenAccess &
      (TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY)) ==
      (TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY),
      "Restricted fixture launch requires query, duplicate, and primary-token access");
  using translation_test_fixture::ConfirmedElevatedRejection;
  Check(ConfirmedElevatedRejection(false, "Console.HostIntegrity", 0x3000, 0) &&
      ConfirmedElevatedRejection(false, "Console.ClientIntegrity", 0x2000, 0x3000),
      "Confirmed elevated-integrity rejection was not recognized");
  Check(!ConfirmedElevatedRejection(true, "Console.HostIntegrity", 0x3000, 0x3000) &&
      !ConfirmedElevatedRejection(false, "Console.HostIntegrity", 0x2000, 0x3000) &&
      !ConfirmedElevatedRejection(false, "Console.ClientIntegrity", 0x3000, 0x2000) &&
      !ConfirmedElevatedRejection(false, "Console.AncestryOrDeadline", 0x3000, 0x3000) &&
      !ConfirmedElevatedRejection(false, nullptr, 0x3000, 0x3000),
      "Medium-launch authorization gate accepted unrelated or insufficient evidence");
  using translation_test_fixture::SupportedMediumFixtureTransition;
  Check(SupportedMediumFixtureTransition(0x3000, "Console.HostIntegrity", 0x3000, 0) &&
      SupportedMediumFixtureTransition(0x2000, "Console.ClientIntegrity", 0x2000, 0x3000),
      "Controlled high-to-medium fixture transition was rejected");
  Check(!SupportedMediumFixtureTransition(0x4000, "Console.HostIntegrity", 0x4000, 0) &&
      !SupportedMediumFixtureTransition(0x1000, "Console.HostIntegrity", 0x3000, 0) &&
      !SupportedMediumFixtureTransition(0x2100, "Console.HostIntegrity", 0x3000, 0) &&
      !SupportedMediumFixtureTransition(0x3000, "Console.HostIntegrity", 0x4000, 0) &&
      !SupportedMediumFixtureTransition(0x3000, "Console.ClientIntegrity", 0, 0x5000),
      "Unsupported SYSTEM, protected, low, or unknown token transition was accepted");
  FakeTree accepted;
  Check(accepted.Verify(), "A safe host document did not reach the exact HWND root");
  const unsigned complete_calls = accepted.calls;
  Check(accepted.parents == 1, "Expected the observed document-to-console-root chain");
  // Every property failure, including the final comparison, must fail closed.
  // Cancel/expiry immediately after ANY UIA call must prevent the NEXT call.
  for (unsigned i = 1; i <= complete_calls; ++i) {
    FakeTree failing;
    failing.fail_at = i;
    Check(!failing.Verify() && failing.calls == i, "UIA failure did not stop immediately");
    FakeTree canceled;
    canceled.cancel_at = i;
    Check(!canceled.Verify() && canceled.calls == i, "UIA continued after cancellation");
    FakeTree expired;
    expired.expire_at = i;
    Check(!expired.Verify() && expired.calls == i, "UIA continued after deadline");
  }
  {
    FakeTree tree; tree.canceled = true;
    Check(!tree.Verify() && !tree.calls, "Pre-canceled request touched UIA");
  }
  {
    FakeTree tree; tree.expired = true;
    Check(!tree.Verify() && !tree.calls, "Expired request touched UIA");
  }
  {
    FakeTree tree; tree.foreground = false;
    Check(!tree.Verify() && !tree.calls, "Background request touched UIA");
  }
  {
    FakeTree tree;
    Check(!tree.Verify(nullptr) && !tree.calls, "Null focused element was accepted");
  }
  {
    FakeTree tree; tree.returned_root = nullptr;
    Check(!tree.Verify(), "Missing source root was accepted");
  }
  {
    FakeTree tree; tree.root.native = {};
    Check(!tree.Verify(), "Root without exact source HWND was accepted");
  }
  {
    FakeTree tree; tree.root.type = UIA_PaneControlTypeId;
    Check(!tree.Verify(), "Non-window source root was accepted");
  }
  {
    FakeTree tree; tree.walker = false;
    Check(!tree.Verify(), "Unavailable raw walker was accepted");
  }
  {
    FakeTree tree; Node other; tree.focus.parent = &other;
    Check(!tree.Verify(), "Focused element in another root was accepted");
  }
  {
    FakeTree tree; tree.focus.parent = &tree.focus;
    Check(!tree.Verify() && tree.parents == 8, "Ancestry cycle was not bounded");
  }
  for (unsigned where = 0; where < 3; ++where) {
    for (unsigned unsafe = 0; unsafe < 5; ++unsafe) {
      FakeTree tree; Node middle; middle.parent = &tree.root; tree.focus.parent = &middle;
      Node* node = where == 0 ? &tree.focus : (where == 1 ? &middle : &tree.root);
      if (unsafe == 0) node->password = TRUE;
      if (unsafe == 1) node->offscreen = TRUE;
      if (unsafe == 2) node->process = static_cast<int>(kProvider + 1);
      if (unsafe == 3) node->process = 0;
      if (unsafe == 4) node->password = 2;  // Unknown is not an affirmative false.
      Check(!tree.Verify(), "Unsafe focused, ancestor, or root metadata was accepted");
    }
  }
  {
    FakeTree tree; std::array<Node, 6> middle;
    tree.focus.parent = &middle[0];
    for (size_t i = 0; i < middle.size(); ++i)
      middle[i].parent = i + 1 < middle.size() ? &middle[i + 1] : &tree.root;
    Check(tree.Verify() && tree.parents == 7, "Valid eight-node chain was rejected");
  }
  {
    FakeTree tree; std::array<Node, 7> middle;
    tree.focus.parent = &middle[0];
    for (size_t i = 0; i < middle.size(); ++i)
      middle[i].parent = i + 1 < middle.size() ? &middle[i + 1] : &tree.root;
    Check(!tree.Verify() && tree.parents == 8, "Over-depth ancestry was accepted");
  }
  {
    FakeTree tree; tree.alive = false;
    Check(!tree.Verify(), "Process/thread exit during UIA verification was accepted");
  }
  std::printf("CONSOLE_BINDING|deterministic|passed|faultBoundaries=%u\n", complete_calls);
}

class FixtureProcess {
 public:
  FixtureProcess() {
    wchar_t executable[32768]{};
    const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
    Check(length && length < 32768, "Cannot resolve the test executable");
    std::wstring command = L"\"" + std::wstring(executable) + L"\" --idle";
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    Check(CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process_) != FALSE,
        "Cannot create independent synthetic process");
  }
  ~FixtureProcess() {
    Stop();
    if (process_.hThread) CloseHandle(process_.hThread);
    if (process_.hProcess) CloseHandle(process_.hProcess);
  }
  FixtureProcess(const FixtureProcess&) = delete;
  FixtureProcess& operator=(const FixtureProcess&) = delete;
  DWORD id() const { return process_.dwProcessId; }
  HANDLE handle() const { return process_.hProcess; }
  void Stop() {
    if (detail::Live(process_.hProcess)) {
      // This is the retained handle for ONLY the child this test created.
      TerminateProcess(process_.hProcess, 0);
      WaitForSingleObject(process_.hProcess, 5000);
    }
  }
 private:
  PROCESS_INFORMATION process_{};
};
class FixtureWindow {
 public:
  explicit FixtureWindow(const wchar_t* name) : name_(name) {
    WNDCLASSW cls{}; cls.lpfnWndProc = DefWindowProcW;
    cls.hInstance = GetModuleHandleW(nullptr); cls.lpszClassName = name_;
    Check(RegisterClassW(&cls) != 0, "Cannot register the synthetic local window class");
    window_ = CreateWindowW(name_, L"BaoCode synthetic binding rejection fixture",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, 480, 260,
        nullptr, nullptr, cls.hInstance, nullptr);
    Check(window_ != nullptr, "Cannot create synthetic window");
  }
  ~FixtureWindow() {
    if (window_) DestroyWindow(window_);
    UnregisterClassW(name_, GetModuleHandleW(nullptr));
  }
  FixtureWindow(const FixtureWindow&) = delete;
  FixtureWindow& operator=(const FixtureWindow&) = delete;
  HWND get() const { return window_; }
  void Foreground() {
    ShowWindow(window_, SW_SHOW);
    SetForegroundWindow(window_);
    const ULONGLONG end = GetTickCount64() + 1500;
    while (GetTickCount64() < end) {
      MSG message{};
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message); DispatchMessageW(&message);
      }
      if (GetForegroundWindow() == window_) return;
      Sleep(10);
    }
    throw std::runtime_error("Synthetic fixture cannot acquire the disposable desktop foreground");
  }
 private:
  const wchar_t* name_;
  HWND window_ = nullptr;
};
// The fixture handshake never enumerates another application's content. The
// parent owns both explicit conhost launches and verifies the returned client's
// parent PID and executable before retaining a handle that can terminate it.
struct ConsoleState {
  DWORD controller = 0;
  volatile LONG expected_host = 0;
  DWORD client = 0;
  ULONG_PTR window = 0;
  DWORD failure = 0;
};
DWORD ParentProcess(DWORD process) {
  detail::Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  if (snapshot.get() == INVALID_HANDLE_VALUE) return 0;
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
  for (BOOL more = Process32FirstW(snapshot.get(), &entry); more;
       more = Process32NextW(snapshot.get(), &entry)) {
    if (entry.th32ProcessID == process) return entry.th32ParentProcessID;
  }
  return 0;
}
std::wstring ProcessImage(HANDLE process) {
  wchar_t path[32768]{}; DWORD length = 32768;
  return QueryFullProcessImageNameW(process, 0, path, &length) ?
      std::wstring(path, length) : std::wstring{};
}

void RequireDisposableDesktop() {
  wchar_t guard[16]{}, actions[16]{};
  GetEnvironmentVariableW(L"BAOCODE_DISPOSABLE_UI_TEST", guard, 16);
  GetEnvironmentVariableW(L"GITHUB_ACTIONS", actions, 16);
  Check(std::wstring(guard) == L"1" && std::wstring(actions) == L"true",
      "Requires BAOCODE_DISPOSABLE_UI_TEST=1 and GITHUB_ACTIONS=true on a disposable CI desktop");
}
int ConsoleClient(const std::wstring& name) {
  RequireDisposableDesktop();
  detail::Handle mapping(OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, name.c_str()));
  detail::Handle ready(OpenEventW(EVENT_MODIFY_STATE, FALSE, (name + L".ready").c_str()));
  detail::Handle stop(OpenEventW(SYNCHRONIZE, FALSE, (name + L".stop").c_str()));
  if (!mapping.get() || !ready.get() || !stop.get()) return 10;
  auto* state = static_cast<ConsoleState*>(MapViewOfFile(mapping.get(), FILE_MAP_ALL_ACCESS,
      0, 0, sizeof(ConsoleState)));
  if (!state) return 11;
  const ULONGLONG deadline = GetTickCount64() + 10000;
  HWND window = nullptr;
  DWORD host = 0;
  while (GetTickCount64() < deadline && WaitForSingleObject(stop.get(), 0) == WAIT_TIMEOUT) {
    host = static_cast<DWORD>(InterlockedCompareExchange(&state->expected_host, 0, 0));
    window = GetConsoleWindow();
    if (host && window && IsWindowVisible(window)) break;
    Sleep(20);
  }
  DWORD attached[2]{};
  const DWORD attached_count = GetConsoleProcessList(attached, 2);
  DWORD nominal = 0;
  GetWindowThreadProcessId(window, &nominal);
  wchar_t cls[64]{};
  GetClassNameW(window, cls, 64);
  const DWORD self = GetCurrentProcessId();
  const bool valid = GetTickCount64() < deadline && window && IsWindowVisible(window) &&
      host && ParentProcess(self) == host && attached_count == 1 && attached[0] == self &&
      nominal == self && GetAncestor(window, GA_ROOT) == window &&
      wcscmp(cls, L"ConsoleWindowClass") == 0 && state->controller != 0;
  state->client = self;
  state->window = reinterpret_cast<ULONG_PTR>(window);
  state->failure = valid ? 0 : 12;
  if (valid) AllowSetForegroundWindow(state->controller);
  SetEvent(ready.get());
  // No console output, selection, keyboard/mouse injection, or persistent setup.
  if (valid) WaitForSingleObject(stop.get(), 60000);
  UnmapViewOfFile(state);
  return valid ? 0 : 12;
}
class ConsoleHostFixture {
 public:
  ConsoleHostFixture() = default;
  ~ConsoleHostFixture() {
    if (stop_) SetEvent(stop_);
    StopOwned(client_);
    StopOwned(host_.hProcess);
    if (owner_thread_) CloseHandle(owner_thread_);
    if (client_) CloseHandle(client_);
    if (host_.hThread) CloseHandle(host_.hThread);
    if (host_.hProcess) CloseHandle(host_.hProcess);
    if (state_) UnmapViewOfFile(state_);
    if (stop_) CloseHandle(stop_);
    if (ready_) CloseHandle(ready_);
    if (mapping_) CloseHandle(mapping_);
  }
  ConsoleHostFixture(const ConsoleHostFixture&) = delete;
  ConsoleHostFixture& operator=(const ConsoleHostFixture&) = delete;
  void Start(unsigned index, const translation_selection::ConsoleBindingDiagnostics* elevated_rejection = nullptr) {
    FixtureIpcSecurity ipc_security;
    const std::wstring name = L"Local\\BaoCodeConsoleBinding." + std::to_wstring(GetCurrentProcessId()) +
        L"." + std::to_wstring(GetTickCount64()) + L"." + std::to_wstring(index);
    mapping_ = CreateFileMappingW(INVALID_HANDLE_VALUE, ipc_security.get(), PAGE_READWRITE, 0,
        static_cast<DWORD>(sizeof(ConsoleState)), name.c_str());
    Check(mapping_ && GetLastError() != ERROR_ALREADY_EXISTS, "Cannot create fresh console fixture mapping");
    state_ = static_cast<ConsoleState*>(MapViewOfFile(mapping_, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(ConsoleState)));
    Check(state_ != nullptr, "Cannot map console fixture state");
    *state_ = ConsoleState{};
    state_->controller = GetCurrentProcessId();
    ready_ = CreateEventW(ipc_security.get(), TRUE, FALSE, (name + L".ready").c_str());
    Check(ready_ && GetLastError() != ERROR_ALREADY_EXISTS, "Cannot create fresh console ready event");
    stop_ = CreateEventW(ipc_security.get(), TRUE, FALSE, (name + L".stop").c_str());
    Check(stop_ && GetLastError() != ERROR_ALREADY_EXISTS, "Cannot create fresh console stop event");
    wchar_t system[MAX_PATH]{}, executable[32768]{};
    const UINT system_length = GetSystemDirectoryW(system, MAX_PATH);
    const DWORD executable_length = GetModuleFileNameW(nullptr, executable, 32768);
    Check(system_length && system_length < MAX_PATH && executable_length && executable_length < 32768,
        "Cannot resolve official conhost and fixture executable paths");
    const std::wstring image = std::wstring(system, system_length) + L"\\conhost.exe";
    std::wstring command = L"\"" + image + L"\" \"" + std::wstring(executable) +
        L"\" --console-fixture \"" + name + L"\"";
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_SHOWNORMAL;
    if (elevated_rejection) {
      translation_test_fixture::LaunchMediumConsole(image, command, &startup, &host_,
          elevated_rejection->stage, elevated_rejection->host_integrity, elevated_rejection->client_integrity);
    } else {
      Check(CreateProcessW(image.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
          nullptr, nullptr, &startup, &host_) != FALSE,
          "Inherited-token System32 conhost launch failed");
    }
    Check(_wcsicmp(ProcessImage(host_.hProcess).c_str(), image.c_str()) == 0,
        "Launched console host image is not the official System32 executable");
    InterlockedExchange(&state_->expected_host, static_cast<LONG>(host_.dwProcessId));
    Check(WaitForSingleObject(ready_, 12000) == WAIT_OBJECT_0, "Console fixture handshake timed out");
    std::printf("CONSOLE_BINDING|hostFixture|index=%u|host=%lu|client=%lu|window=%llu|failure=%lu\n",
        index, host_.dwProcessId, state_->client,
        static_cast<unsigned long long>(state_->window), state_->failure);
    Check(state_->failure == 0 && state_->client && state_->window,
        "Console fixture failed exact host/client/window provenance checks");
    Check(ParentProcess(state_->client) == host_.dwProcessId,
        "Console client does not belong to the explicitly launched host");
    HANDLE candidate = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | PROCESS_TERMINATE,
        FALSE, state_->client);
    Check(candidate != nullptr, "Cannot retain synthetic console client handle");
    if (_wcsicmp(ProcessImage(candidate).c_str(), executable) != 0) {
      CloseHandle(candidate);
      throw std::runtime_error("Console client is not this synthetic fixture executable");
    }
    client_ = candidate;
    Check(detail::Live(host_.hProcess) && detail::Live(client_), "Console fixture exited before verification");
    std::printf("CONSOLE_BINDING|integrity|index=%u|host=%lu|client=%lu\n",
        index, Integrity(host_.hProcess), Integrity(client_));
    PinOwnerThread();
  }
  HWND window() const { return reinterpret_cast<HWND>(state_->window); }
  DWORD client() const { return state_->client; }
  DWORD provider() const { return host_.dwProcessId; }
  bool IsMedium() const {
    return Integrity(host_.hProcess) == SECURITY_MANDATORY_MEDIUM_RID &&
        Integrity(client_) == SECURITY_MANDATORY_MEDIUM_RID;
  }
  bool IsLive() const {
    return detail::Live(host_.hProcess) && detail::Live(client_) && detail::Live(owner_thread_);
  }
  void Foreground() const {
    Check(detail::Live(host_.hProcess) && detail::Live(client_), "Cannot foreground an exited fixture");
    ShowWindow(window(), SW_SHOW);
    SetForegroundWindow(window());
    const ULONGLONG deadline = GetTickCount64() + 2000;
    while (GetTickCount64() < deadline) {
      MSG message{};
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message); DispatchMessageW(&message);
      }
      if (GetForegroundWindow() == window()) return;
      Sleep(10);
    }
    throw std::runtime_error("Owned console fixture could not acquire CI foreground");
  }
  void ExitHostAndThread() {
    Check(detail::Live(host_.hProcess) && detail::Live(owner_thread_), "Host/thread exited before the test action");
    Check(TerminateProcess(host_.hProcess, 0) != FALSE, "Cannot terminate owned synthetic host");
    Check(WaitForSingleObject(host_.hProcess, 5000) == WAIT_OBJECT_0 &&
        WaitForSingleObject(owner_thread_, 5000) == WAIT_OBJECT_0,
        "Owned host or retained owner thread did not exit");
    Check(!detail::Live(host_.hProcess) && !detail::Live(owner_thread_),
        "Exited host/thread handles were still considered live");
  }
  void ExitClient() {
    Check(detail::Live(client_), "Client exited before the test action");
    Check(TerminateProcess(client_, 0) != FALSE, "Cannot terminate owned synthetic console client");
    Check(WaitForSingleObject(client_, 5000) == WAIT_OBJECT_0 && !detail::Live(client_),
        "Owned synthetic client did not exit");
  }
 private:
  static void StopOwned(HANDLE process) {
    if (process && WaitForSingleObject(process, 1000) == WAIT_TIMEOUT) {
      TerminateProcess(process, 0);
      WaitForSingleObject(process, 3000);
    }
  }
  struct Membership { HWND source; bool found = false; };
  static BOOL CALLBACK FindOwnedWindow(HWND candidate, LPARAM value) {
    auto* membership = reinterpret_cast<Membership*>(value);
    if (candidate != membership->source) return TRUE;
    membership->found = true;
    return FALSE;
  }
  void PinOwnerThread() {
    detail::Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0));
    Check(snapshot.get() != INVALID_HANDLE_VALUE, "Cannot enumerate synthetic host threads");
    THREADENTRY32 entry{}; entry.dwSize = sizeof(entry);
    const ULONGLONG deadline = GetTickCount64() + 2000;
    for (BOOL more = Thread32First(snapshot.get(), &entry); more && GetTickCount64() < deadline;
         more = Thread32Next(snapshot.get(), &entry)) {
      if (entry.th32OwnerProcessID != provider()) continue;
      detail::Handle thread(OpenThread(THREAD_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
          FALSE, entry.th32ThreadID));
      if (!detail::Live(thread.get()) || GetProcessIdOfThread(thread.get()) != provider()) continue;
      Membership membership{window()};
      EnumThreadWindows(GetThreadId(thread.get()), FindOwnedWindow, reinterpret_cast<LPARAM>(&membership));
      if (membership.found) { owner_thread_ = thread.release(); break; }
    }
    Check(owner_thread_ != nullptr, "No retained host thread owns the exact synthetic HWND");
  }
  HANDLE mapping_ = nullptr, ready_ = nullptr, stop_ = nullptr;
  ConsoleState* state_ = nullptr;
  PROCESS_INFORMATION host_{};
  HANDLE client_ = nullptr, owner_thread_ = nullptr;
};
ComPtr<IUIAutomationElement> ConsoleFocus(ConsoleHostFixture& fixture, IUIAutomation* automation) {
  fixture.Foreground();
  ComPtr<IUIAutomation2> bounded;
  Check(SUCCEEDED(automation->QueryInterface(IID_PPV_ARGS(&bounded))), "Bounded UIA interface unavailable");
  const ULONGLONG deadline = GetTickCount64() + 3000;
  const auto ready = [&] {
    if (GetForegroundWindow() != fixture.window()) return false;
    ULONGLONG now = GetTickCount64();
    if (now >= deadline) return false;
    if (FAILED(bounded->put_ConnectionTimeout(
        static_cast<DWORD>((std::min<ULONGLONG>)(deadline - now, 150))))) return false;
    now = GetTickCount64();
    return now < deadline && GetForegroundWindow() == fixture.window() &&
        SUCCEEDED(bounded->put_TransactionTimeout(
        static_cast<DWORD>((std::min<ULONGLONG>)(deadline - now, 200)))) &&
        GetTickCount64() < deadline && GetForegroundWindow() == fixture.window();
  };
  while (ready()) {
    ComPtr<IUIAutomationElement> focus;
    int provider = 0;
    BOOL has_focus = FALSE;
    if (SUCCEEDED(automation->GetFocusedElement(&focus)) && focus && ready() &&
        SUCCEEDED(focus->get_CurrentProcessId(&provider)) &&
        static_cast<DWORD>(provider) == fixture.provider() && ready() &&
        SUCCEEDED(focus->get_CurrentHasKeyboardFocus(&has_focus)) && has_focus == TRUE && ready()) return focus;
    Sleep(20);
  }
  throw std::runtime_error("Bounded UIA focus metadata did not belong to the owned console host");
}
void RealConsoleChecks(IUIAutomation* automation) {
  bool require_medium_launch = false;
  translation_selection::ConsoleBindingDiagnostics elevated_rejection;
  {
    ConsoleHostFixture inherited;
    inherited.Start(0);
    auto focus = ConsoleFocus(inherited, automation);
    ConsoleBinding binding;
    translation_selection::ConsoleBindingDiagnostics diagnostics;
    const bool accepted = binding.Verify(inherited.window(), inherited.client(), inherited.provider(),
        automation, focus.Get(), [] { return false; }, GetTickCount64() + 3000, &diagnostics);
    std::printf("CONSOLE_BINDING|inheritedTokenProbe|runnerIntegrity=%lu|accepted=%d|stage=%s|hostIntegrity=%lu|clientIntegrity=%lu\n",
        Integrity(GetCurrentProcess()), accepted ? 1 : 0, diagnostics.stage,
        diagnostics.host_integrity, diagnostics.client_integrity);
    require_medium_launch = translation_test_fixture::ConfirmedElevatedRejection(accepted,
        diagnostics.stage, diagnostics.host_integrity, diagnostics.client_integrity);
    if (require_medium_launch) elevated_rejection = diagnostics;
    Check(accepted || require_medium_launch,
        "Inherited-token host failed for a reason other than confirmed elevated-integrity rejection");
    Check(!accepted || inherited.IsMedium(), "Elevated inherited host was unexpectedly accepted");
    // The original elevated rejection remains explicit evidence. It is never
    // hidden by changing the production predicate or retrying a different host.
    if (require_medium_launch)
      std::printf("CONSOLE_BINDING|elevatedInheritedRejection|passed|stage=%s\n", diagnostics.stage);
  }
  ConsoleHostFixture first, second;
  first.Start(1, require_medium_launch ? &elevated_rejection : nullptr);
  second.Start(2, require_medium_launch ? &elevated_rejection : nullptr);
  Check(first.IsMedium() && second.IsMedium(), "Positive host fixtures did not actually run at medium integrity");
  Check(first.window() != second.window() && first.client() != second.client() &&
      first.provider() != second.provider(), "Expected two distinct official console host/client/window sets");
  const auto verified = [&](ConsoleBinding& binding, ConsoleHostFixture& fixture,
                            IUIAutomationElement* focus, const char* phase) {
    translation_selection::ConsoleBindingDiagnostics diagnostics;
    const bool accepted = binding.Verify(fixture.window(), fixture.client(), fixture.provider(),
        automation, focus, [] { return false; }, GetTickCount64() + 3000, &diagnostics);
    std::printf("CONSOLE_BINDING|verifyLive|phase=%s|accepted=%d|stage=%s|hostIntegrity=%lu|clientIntegrity=%lu\n",
        phase, accepted ? 1 : 0, diagnostics.stage, diagnostics.host_integrity, diagnostics.client_integrity);
    return accepted;
  };
  auto focus_first = ConsoleFocus(first, automation);
  ConsoleBinding bound_first;
  Check(verified(bound_first, first, focus_first.Get(), "first"),
      "First real host binding did not positively verify");
  auto focus_second = ConsoleFocus(second, automation);
  ConsoleBinding bound_second;
  Check(verified(bound_second, second, focus_second.Get(), "second"),
      "Second real host binding did not positively verify");
  const auto reject_other = [&](ConsoleHostFixture& source, ConsoleHostFixture& other,
                                 IUIAutomationElement* other_focus) {
    source.Foreground();
    ConsoleBinding wrong_host;
    ULONGLONG deadline = GetTickCount64() + 1500;
    Check(!wrong_host.Verify(source.window(), source.client(), other.provider(), automation,
        other_focus, [] { return false; }, deadline) && GetTickCount64() < deadline &&
        GetForegroundWindow() == source.window() && source.IsLive() && other.IsLive(),
        "A real console HWND was accepted with the other official conhost PID");
    ConsoleBinding wrong_root;
    deadline = GetTickCount64() + 1500;
    Check(!wrong_root.Verify(source.window(), source.client(), source.provider(), automation,
        other_focus, [] { return false; }, deadline) && GetTickCount64() < deadline &&
        GetForegroundWindow() == source.window() && source.IsLive() && other.IsLive(),
        "The other real console's UIA element was accepted for this source root");
  };
  reject_other(first, second, focus_second.Get());
  reject_other(second, first, focus_first.Get());
  first.Foreground();
  Check(verified(bound_first, first, focus_first.Get(), "firstRetained"),
      "Retained first binding failed before host/thread exit");
  Check(!bound_first.Verify(first.window(), first.client(), first.provider(), automation,
      focus_first.Get(), [] { return true; }, GetTickCount64() + 1500),
      "Already-bound console accepted a canceled request");
  Check(!bound_first.Verify(first.window(), first.client(), first.provider(), automation,
      focus_first.Get(), [] { return false; }, GetTickCount64()),
      "Already-bound console accepted an expired deadline");
  Check(verified(bound_first, first, focus_first.Get(), "firstAfterCancellation"),
      "A canceled/expired request corrupted the live bound console");
  first.ExitHostAndThread();
  Check(!bound_first.Verify(first.window(), first.client(), first.provider(), automation,
      focus_first.Get(), [] { return false; }, GetTickCount64() + 1500),
      "Previously verified binding accepted an exited real host and owner thread");
  second.Foreground();
  Check(!bound_first.Verify(second.window(), second.client(), second.provider(), automation,
      focus_second.Get(), [] { return false; }, GetTickCount64() + 1500),
      "Exited retained binding rebound to the other live console");
  Check(verified(bound_second, second, focus_second.Get(), "secondRetained"),
      "Retained second binding failed before client exit");
  second.ExitClient();
  Check(!bound_second.Verify(second.window(), second.client(), second.provider(), automation,
      focus_second.Get(), [] { return false; }, GetTickCount64() + 1500),
      "Previously verified binding accepted an exited real console client");
  std::printf("CONSOLE_BINDING|realOfficialHosts|passed|positivePairs=2|crossHostRejections=2|wrongRootRejections=2|boundHostThreadExit=1|boundClientExit=1\n");
}

void RealWindowChecks() {
  Check(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)), "COM initialization failed");
  {
    ComPtr<IUIAutomation> automation;
    Check(SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&automation))), "UIA creation failed");
    // A genuine non-null element ensures the public API is not rejecting these
    // cases merely because the test supplied a null or invalid COM pointer.
    ComPtr<IUIAutomationElement> desktop;
    Check(SUCCEEDED(automation->GetRootElement(&desktop)) && desktop, "UIA desktop root unavailable");
    FixtureProcess candidate;
    Check(detail::Live(candidate.handle()), "Independent fixture already exited");
    const DWORD client = GetCurrentProcessId();
    Check(candidate.id() != client, "Expected independent candidate provider process");
    const auto rejected = [&](HWND source, DWORD claimed_client, DWORD provider) {
      ConsoleBinding binding;
      return !binding.Verify(source, claimed_client, provider, automation.Get(), desktop.Get(),
          [] { return false; }, GetTickCount64() + 1000);
    };
    {
      FixtureWindow ordinary(L"BaoCodeOrdinaryBindingFixture");
      ordinary.Foreground();
      Check(rejected(ordinary.get(), client, candidate.id()), "Ordinary Win32 window accepted a different provider");
    }
    {
      // A normal process can register this class name. The name alone must
      // never authorize a cross-process provider, even on the foreground HWND.
      FixtureWindow spoof(L"ConsoleWindowClass");
      spoof.Foreground();
      wchar_t cls[64]{};
      Check(GetClassNameW(spoof.get(), cls, 64) && wcscmp(cls, L"ConsoleWindowClass") == 0,
          "Spoof fixture does not have the intended class");
      Check(rejected(spoof.get(), client, candidate.id()), "Spoof console class accepted arbitrary host");
      Check(rejected(spoof.get(), candidate.id(), client), "Wrong nominal client was accepted");
      Check(rejected(spoof.get(), client, client), "Same-process binding was treated as a console exception");
      ConsoleBinding canceled;
      Check(!canceled.Verify(spoof.get(), client, candidate.id(), automation.Get(), desktop.Get(),
          [] { return true; }, GetTickCount64() + 1000), "Canceled public API request accepted");
      ConsoleBinding expired;
      Check(!expired.Verify(spoof.get(), client, candidate.id(), automation.Get(), desktop.Get(),
          [] { return false; }, GetTickCount64()), "Expired public API request accepted");
      ConsoleBinding missing;
      Check(!missing.Verify(spoof.get(), client, candidate.id(), nullptr, desktop.Get(),
          [] { return false; }, GetTickCount64() + 1000), "Null automation accepted");
      Check(!missing.Verify(spoof.get(), client, candidate.id(), automation.Get(), nullptr,
          [] { return false; }, GetTickCount64() + 1000), "Null element accepted");
      HWND password = CreateWindowW(L"EDIT", L"synthetic password only",
          WS_CHILD | WS_VISIBLE | ES_PASSWORD, 10, 10, 240, 40,
          spoof.get(), nullptr, GetModuleHandleW(nullptr), nullptr);
      Check(password != nullptr, "Synthetic password control creation failed");
      Check(rejected(password, client, candidate.id()), "Password child HWND accepted as a console root");
      candidate.Stop();
      Check(WaitForSingleObject(candidate.handle(), 0) == WAIT_OBJECT_0,
          "Synthetic child did not exit");
      Check(!detail::Live(candidate.handle()), "Exited retained process handle is still eligible");
      Check(rejected(spoof.get(), client, candidate.id()), "Exited provider process was accepted");
    }
    Check(!detail::Live(nullptr) && !detail::Live(INVALID_HANDLE_VALUE), "Invalid process handle was eligible");
    RealConsoleChecks(automation.Get());
  }
  CoUninitialize();
  std::printf("CONSOLE_BINDING|realWin32Rejections|passed\n");
}
}  // namespace
int wmain(int argc, wchar_t** argv) {
  if (argc == 2 && std::wstring(argv[1]) == L"--idle") { Sleep(30000); return 0; }
  try {
    if (argc == 3 && std::wstring(argv[1]) == L"--console-fixture") return ConsoleClient(argv[2]);
    DeterministicChecks();
    // Deterministic mode is safe without a foreground desktop. The default
    // suite is deliberately strict: it never silently skips the real fixtures.
    if (argc == 2 && std::wstring(argv[1]) == L"--deterministic") return 0;
    RequireDisposableDesktop();
    RealWindowChecks();
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "CONSOLE_BINDING|failed|%s\n", error.what());
    return 1;
  }
}
