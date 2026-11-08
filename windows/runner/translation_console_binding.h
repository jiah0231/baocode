#ifndef RUNNER_TRANSLATION_CONSOLE_BINDING_H_
#define RUNNER_TRANSLATION_CONSOLE_BINDING_H_
#include <windows.h>
#include <tlhelp32.h>
#include <UIAutomation.h>
#include <wrl/client.h>
#include <algorithm>
#include <cwchar>
#include <string>
#include <vector>

namespace translation_selection {
namespace console_binding_detail {
// Keep the ancestry algorithm independent of COM so the same fail-closed
// checks can be fault-injected without registering an untrusted UIA provider.
template <typename Tree, typename Ready, typename Alive>
bool VerifyAncestry(Tree& tree, HWND source, DWORD provider,
                    typename Tree::Element focused, const Ready& ready,
                    const Alive& alive) {
  typename Tree::Element root{};
  if (!focused || !ready() || !tree.Root(source, &root) || !root) return false;
  UIA_HWND native{};
  CONTROLTYPEID type = 0;
  if (!ready() || !tree.Native(root, &native) ||
      reinterpret_cast<HWND>(native) != source || !ready() ||
      !tree.Type(root, &type) || type != UIA_WindowControlTypeId) return false;
  const auto safe = [&](const typename Tree::Element& node) {
    int pid = 0;
    BOOL node_password = TRUE, offscreen = TRUE;
    return ready() && tree.Process(node, &pid) && pid > 0 &&
        static_cast<DWORD>(pid) == provider && ready() &&
        tree.Password(node, &node_password) && node_password == FALSE && ready() &&
        tree.Offscreen(node, &offscreen) && offscreen == FALSE;
  };
  // Validate the root even when the supplied focused element never reaches it.
  if (!safe(root) || !ready() || !tree.Walker()) return false;
  auto node = focused;
  for (unsigned depth = 0; depth < 8 && node; ++depth) {
    BOOL same = FALSE;
    if (!safe(node) || !ready() || !tree.Same(node, root, &same)) return false;
    if (same == TRUE) return ready() && alive();
    typename Tree::Element parent{};
    if (!ready() || !tree.Parent(node, &parent)) return false;
    node = parent;
  }
  return false;
}

class UiaTree {
 public:
  using Element = Microsoft::WRL::ComPtr<IUIAutomationElement>;
  explicit UiaTree(IUIAutomation* automation) : automation_(automation) {}
  bool Root(HWND source, Element* root) {
    return SUCCEEDED(automation_->ElementFromHandle(source, root->GetAddressOf()));
  }
  bool Native(const Element& node, UIA_HWND* value) {
    return SUCCEEDED(node->get_CurrentNativeWindowHandle(value));
  }
  bool Type(const Element& node, CONTROLTYPEID* value) {
    return SUCCEEDED(node->get_CurrentControlType(value));
  }
  bool Process(const Element& node, int* value) {
    return SUCCEEDED(node->get_CurrentProcessId(value));
  }
  bool Password(const Element& node, BOOL* value) {
    return SUCCEEDED(node->get_CurrentIsPassword(value));
  }
  bool Offscreen(const Element& node, BOOL* value) {
    return SUCCEEDED(node->get_CurrentIsOffscreen(value));
  }
  bool Walker() {
    return SUCCEEDED(automation_->get_RawViewWalker(walker_.GetAddressOf())) && walker_;
  }
  bool Same(const Element& first, const Element& second, BOOL* same) {
    return SUCCEEDED(automation_->CompareElements(first.Get(), second.Get(), same));
  }
  bool Parent(const Element& node, Element* parent) {
    return SUCCEEDED(walker_->GetParentElement(node.Get(), parent->GetAddressOf()));
  }
 private:
  IUIAutomation* automation_;
  Microsoft::WRL::ComPtr<IUIAutomationTreeWalker> walker_;
};

class Handle {
 public:
  explicit Handle(HANDLE value = nullptr) : value_(value) {}
  ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
  HANDLE release() { HANDLE value = value_; value_ = nullptr; return value; }
 private:
  HANDLE value_;
};
inline bool Live(HANDLE handle) {
  return handle && handle != INVALID_HANDLE_VALUE &&
      WaitForSingleObject(handle, 0) == WAIT_TIMEOUT;
}
}  // namespace console_binding_detail

// Console HWNDs can report the attached client as their nominal owner. Never
// trust a different UIA ProcessId alone: require exact OS thread-window
// membership of a system console host and a safe UIA chain to this HWND's root.
// Handles stay alive across retries to prevent process/thread-ID reuse.
struct ConsoleBindingDiagnostics {
  const char* stage = "none";
  DWORD host_integrity = 0, client_integrity = 0;
};
class ConsoleBinding {
 public:
  ~ConsoleBinding() {
    if (thread_) CloseHandle(thread_);
    if (host_) CloseHandle(host_);
    if (client_process_) CloseHandle(client_process_);
  }
  ConsoleBinding() = default;
  ConsoleBinding(const ConsoleBinding&) = delete;
  ConsoleBinding& operator=(const ConsoleBinding&) = delete;

  template <typename Stopped>
  bool Verify(HWND source, DWORD client, DWORD provider,
              IUIAutomation* automation, IUIAutomationElement* focused,
              const Stopped& stopped, ULONGLONG deadline,
              ConsoleBindingDiagnostics* diagnostics = nullptr) {
    if (diagnostics) *diagnostics = ConsoleBindingDiagnostics{};
    const auto stage = [&](const char* value) { if (diagnostics) diagnostics->stage = value; };
    stage("Console.Precondition");
    const auto request_active = [&] {
      return !stopped() && GetTickCount64() < deadline &&
          GetForegroundWindow() == source;
    };
    if (!source || !client || !provider || provider == client || !automation ||
        !focused || !request_active()) return false;
    stage("Console.WindowClass");
    wchar_t window_class[64]{};
    if (!GetClassNameW(source, window_class, 64) ||
        wcscmp(window_class, L"ConsoleWindowClass") != 0 ||
        GetAncestor(source, GA_ROOT) != source || !IsWindowVisible(source)) return false;
    stage("Console.ClientIdentity");
    DWORD actual_client = 0;
    const DWORD nominal_thread = GetWindowThreadProcessId(source, &actual_client);
    if (actual_client != client || !nominal_thread || !request_active()) return false;
    if (!host_) {
      if (!Bind(source, client, provider, request_active, diagnostics)) return false;
      source_ = source;
      client_ = client;
      nominal_thread_ = nominal_thread;
      provider_ = provider;
    }
    stage("Console.BindingLifetime");
    if (source != source_ || client != client_ || provider != provider_ ||
        nominal_thread != nominal_thread_ || !request_active() || !LiveBinding()) return false;

    stage("Console.AutomationInterface");
    using Microsoft::WRL::ComPtr;
    ComPtr<IUIAutomation2> bounded;
    if (!request_active() || FAILED(automation->QueryInterface(IID_PPV_ARGS(&bounded))) ||
        !bounded || !request_active()) return false;
    // Check cancellation and recompute remaining time before EACH UIA call,
    // including the timeout setters. No call starts after cancellation/deadline.
    const auto ready = [&] {
      if (!request_active()) return false;
      ULONGLONG now = GetTickCount64();
      if (now >= deadline) return false;
      const DWORD connection = static_cast<DWORD>((std::min<ULONGLONG>)(deadline - now, 150));
      if (FAILED(bounded->put_ConnectionTimeout(connection)) || !request_active()) return false;
      now = GetTickCount64();
      if (now >= deadline) return false;
      const DWORD transaction = static_cast<DWORD>((std::min<ULONGLONG>)(deadline - now, 200));
      return SUCCEEDED(bounded->put_TransactionTimeout(transaction)) && request_active();
    };
    console_binding_detail::UiaTree tree(automation);
    stage("Console.AncestryOrDeadline");
    const bool verified = console_binding_detail::VerifyAncestry(
        tree, source, provider, ComPtr<IUIAutomationElement>(focused), ready,
        [&] { return LiveBinding() && request_active(); });
    if (verified) stage("none");
    return verified;
  }

 private:
  struct Search { HWND target; bool found = false; };
  static BOOL CALLBACK FindWindow(HWND window, LPARAM data) {
    auto* search = reinterpret_cast<Search*>(data);
    if (window != search->target) return TRUE;
    search->found = true;
    return FALSE;
  }
  static bool OwnsWindow(DWORD thread, HWND window) {
    Search search{window};
    EnumThreadWindows(thread, FindWindow, reinterpret_cast<LPARAM>(&search));
    return search.found;
  }
  bool LiveBinding() const {
    DWORD client = 0;
    const DWORD nominal = GetWindowThreadProcessId(source_, &client);
    return console_binding_detail::Live(host_) &&
        console_binding_detail::Live(client_process_) &&
        console_binding_detail::Live(thread_) &&
        GetProcessId(host_) == provider_ && GetProcessId(client_process_) == client_ &&
        GetProcessIdOfThread(thread_) == provider_ &&
        client == client_ && nominal == nominal_thread_ &&
        IsWindowVisible(source_) && GetAncestor(source_, GA_ROOT) == source_ &&
        OwnsWindow(GetThreadId(thread_), source_);
  }
  static bool Ordinary(HANDLE process, DWORD* integrity) {
    HANDLE raw_token = nullptr;
    if (!OpenProcessToken(process, TOKEN_QUERY, &raw_token)) return false;
    console_binding_detail::Handle token(raw_token);
    DWORD size = 0;
    GetTokenInformation(token.get(), TokenIntegrityLevel, nullptr, 0, &size);
    if (size < sizeof(TOKEN_MANDATORY_LABEL) || size > 65536) return false;
    std::vector<BYTE> bytes(size);
    if (!GetTokenInformation(token.get(), TokenIntegrityLevel, bytes.data(), size, &size))
      return false;
    const auto* label = reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(bytes.data());
    if (!IsValidSid(label->Label.Sid)) return false;
    const BYTE count = *GetSidSubAuthorityCount(label->Label.Sid);
    const DWORD level = count ? *GetSidSubAuthority(label->Label.Sid, count - 1) : 0;
    if (integrity) *integrity = level;
    return count && level == SECURITY_MANDATORY_MEDIUM_RID;
  }
  template <typename Active>
  bool Bind(HWND source, DWORD client, DWORD provider, const Active& binding_active,
            ConsoleBindingDiagnostics* diagnostics) {
    const auto stage = [&](const char* value) { if (diagnostics) diagnostics->stage = value; };
    stage("Console.Session");
    using console_binding_detail::Handle;
    DWORD host_session = 0, client_session = 0, own_session = 0;
    if (!binding_active() || !ProcessIdToSessionId(provider, &host_session) ||
        !ProcessIdToSessionId(client, &client_session) ||
        !ProcessIdToSessionId(GetCurrentProcessId(), &own_session) ||
        host_session != own_session || client_session != own_session) return false;
    stage("Console.ProcessAccessOrLifetime");
    Handle host(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, provider));
    Handle client_process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, client));
    if (!binding_active() || !console_binding_detail::Live(host.get()) ||
        !console_binding_detail::Live(client_process.get()) ||
        !binding_active()) return false;
    DWORD host_integrity = 0, client_integrity = 0;
    const bool host_ordinary = Ordinary(host.get(), &host_integrity);
    const bool client_ordinary = Ordinary(client_process.get(), &client_integrity);
    if (diagnostics) {
      diagnostics->host_integrity = host_integrity;
      diagnostics->client_integrity = client_integrity;
    }
    stage("Console.HostIntegrity");
    if (!host_ordinary || !binding_active()) return false;
    stage("Console.ClientIntegrity");
    if (!client_ordinary || !binding_active()) return false;
    stage("Console.SystemHostImage");
    wchar_t system[MAX_PATH]{}, image[32768]{};
    DWORD size = 32768;
    const UINT length = GetSystemDirectoryW(system, MAX_PATH);
    if (!length || length >= MAX_PATH ||
        !QueryFullProcessImageNameW(host.get(), 0, image, &size) ||
        _wcsicmp(image, (std::wstring(system) + L"\\conhost.exe").c_str()) != 0 ||
        !binding_active()) return false;
    stage("Console.ThreadWindowMembership");
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0));
    if (snapshot.get() == INVALID_HANDLE_VALUE || !binding_active()) return false;
    THREADENTRY32 entry{};
    entry.dwSize = sizeof(entry);
    unsigned visited = 0, candidates = 0;
    for (BOOL more = Thread32First(snapshot.get(), &entry);
         more && binding_active() && visited++ < 65536;
         more = Thread32Next(snapshot.get(), &entry)) {
      if (entry.th32OwnerProcessID != provider) continue;
      if (++candidates > 128) break;
      Handle thread(OpenThread(THREAD_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                               FALSE, entry.th32ThreadID));
      if (!binding_active()) return false;
      if (console_binding_detail::Live(thread.get()) &&
          GetProcessIdOfThread(thread.get()) == provider &&
          OwnsWindow(GetThreadId(thread.get()), source) && binding_active() &&
          console_binding_detail::Live(host.get()) &&
          console_binding_detail::Live(client_process.get())) {
        host_ = host.release();
        client_process_ = client_process.release();
        thread_ = thread.release();
        return true;
      }
    }
    return false;
  }
  HWND source_ = nullptr;
  DWORD client_ = 0, provider_ = 0, nominal_thread_ = 0;
  HANDLE host_ = nullptr, thread_ = nullptr, client_process_ = nullptr;
};
}  // namespace translation_selection
#endif
