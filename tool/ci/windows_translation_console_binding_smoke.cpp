// Deterministic production ancestry checks plus real Win32 rejection fixtures.
// Run only on a disposable Windows CI desktop. No clipboard access, input
// injection, text reading, settings changes, or existing-app inspection.
#include "../../windows/runner/translation_console_binding.h"
#include <array>
#include <cstdio>
#include <stdexcept>

namespace {
using translation_selection::ConsoleBinding;
namespace detail = translation_selection::console_binding_detail;
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
  }
  CoUninitialize();
  std::printf("CONSOLE_BINDING|realWin32Rejections|passed\n");
}
}  // namespace
int wmain(int argc, wchar_t** argv) {
  if (argc == 2 && std::wstring(argv[1]) == L"--idle") { Sleep(30000); return 0; }
  try {
    DeterministicChecks();
    // Deterministic mode is safe without a foreground desktop. The default
    // suite is deliberately strict: it never silently skips the real fixtures.
    if (argc == 2 && std::wstring(argv[1]) == L"--deterministic") return 0;
    wchar_t guard[16]{};
    Check(GetEnvironmentVariableW(L"BAOCODE_DISPOSABLE_UI_TEST", guard, 16) &&
        std::wstring(guard) == L"1", "Requires BAOCODE_DISPOSABLE_UI_TEST=1 on a disposable CI desktop");
    RealWindowChecks();
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "CONSOLE_BINDING|failed|%s\n", error.what());
    return 1;
  }
}
