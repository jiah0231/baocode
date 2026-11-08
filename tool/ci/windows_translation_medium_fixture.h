#ifndef BAOCODE_WINDOWS_TRANSLATION_MEDIUM_FIXTURE_H_
#define BAOCODE_WINDOWS_TRANSLATION_MEDIUM_FIXTURE_H_
// Disposable Windows CI fixtures only. Never include this in the runner app.
#include <windows.h>
#include <sddl.h>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <stdexcept>
#include <string>
#include <vector>

namespace translation_test_fixture {
class Handle {
 public:
  explicit Handle(HANDLE value) : value_(value) {}
  ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
 private:
  HANDLE value_;
};
inline void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
// Capture immediately, before diagnostics or a second Win32 call can overwrite
// the failing operation's last-error value. Exceptions reach both CI logs and
// the desktop-entry result JSON.
inline void RequireWin32(BOOL succeeded, const char* operation) {
  if (succeeded) return;
  const DWORD error = GetLastError();
  std::printf("CONSOLE_BINDING|mediumTokenFailure|operation=%s|win32Error=%lu\n", operation, error);
  throw std::runtime_error(std::string(operation) + " failed (Win32 error " + std::to_string(error) + ")");
}
// CreateRestrictedToken returns a handle with the SAME access rights as its
// source handle. SetTokenInformation(TokenIntegrityLevel) needs ADJUST_DEFAULT
// on that new disposable handle; QUERY/DUPLICATE/ASSIGN_PRIMARY alone cannot set
// its integrity. This handle is never used to modify the running process token.
inline constexpr DWORD kRestrictedFixtureTokenAccess =
    TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT;
// A lowered child cannot write a high-integrity parent's default kernel
// objects. Grant only this same account access to fresh, private medium-label
// IPC objects or newly created fixture directories. This never edits an existing permission.
class FixtureIpcSecurity {
 public:
  FixtureIpcSecurity() {
    HANDLE raw = nullptr;
    Require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw) != FALSE,
        "Cannot obtain own user SID for private fixture IPC");
    Handle token(raw);
    DWORD size = 0;
    GetTokenInformation(token.get(), TokenUser, nullptr, 0, &size);
    Require(size >= sizeof(TOKEN_USER) && size <= 65536, "Invalid own-user token size");
    std::vector<BYTE> buffer(size);
    Require(GetTokenInformation(token.get(), TokenUser, buffer.data(), size, &size) != FALSE,
        "Cannot read own user SID for private fixture IPC");
    const auto* user = reinterpret_cast<const TOKEN_USER*>(buffer.data());
    LPWSTR sid = nullptr;
    Require(ConvertSidToStringSidW(user->User.Sid, &sid) != FALSE,
        "Cannot format own SID for private fixture IPC");
    const std::wstring descriptor = L"D:P(A;;GA;;;" + std::wstring(sid) + L")S:(ML;;NW;;;ME)";
    LocalFree(sid);
    Require(ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor.c_str(), SDDL_REVISION_1,
        &descriptor_, nullptr) != FALSE, "Cannot create same-user medium-label fixture IPC security");
    attributes_.nLength = sizeof(attributes_);
    attributes_.lpSecurityDescriptor = descriptor_;
    attributes_.bInheritHandle = FALSE;
  }
  ~FixtureIpcSecurity() { if (descriptor_) LocalFree(descriptor_); }
  FixtureIpcSecurity(const FixtureIpcSecurity&) = delete;
  FixtureIpcSecurity& operator=(const FixtureIpcSecurity&) = delete;
  SECURITY_ATTRIBUTES* get() { return &attributes_; }
 private:
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
  SECURITY_ATTRIBUTES attributes_{};
};
inline bool ConfirmedElevatedRejection(bool accepted, const char* stage,
                                      DWORD host_integrity, DWORD client_integrity) {
  return !accepted && stage &&
      ((std::strcmp(stage, "Console.HostIntegrity") == 0 &&
        host_integrity > SECURITY_MANDATORY_MEDIUM_RID) ||
       (std::strcmp(stage, "Console.ClientIntegrity") == 0 &&
        client_integrity > SECURITY_MANDATORY_MEDIUM_RID));
}
// Relabeling a SYSTEM/protected/unknown token is not a supported test setup.
// Only ordinary medium/high user tokens and an exact high-integrity rejection
// may enter this narrowly scoped synthetic-launch path.
inline bool SupportedMediumFixtureTransition(DWORD own_integrity, const char* stage,
                                             DWORD host_integrity, DWORD client_integrity) {
  return (own_integrity == SECURITY_MANDATORY_MEDIUM_RID ||
          own_integrity == SECURITY_MANDATORY_HIGH_RID) && stage &&
      ((std::strcmp(stage, "Console.HostIntegrity") == 0 &&
        host_integrity == SECURITY_MANDATORY_HIGH_RID) ||
       (std::strcmp(stage, "Console.ClientIntegrity") == 0 &&
        client_integrity == SECURITY_MANDATORY_HIGH_RID));
}
inline DWORD TokenIntegrity(HANDLE token) {
  DWORD length = 0;
  GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &length);
  if (length < sizeof(TOKEN_MANDATORY_LABEL) || length > 65536) return 0;
  std::vector<BYTE> data(length);
  if (!GetTokenInformation(token, TokenIntegrityLevel, data.data(), length, &length)) return 0;
  const auto* label = reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(data.data());
  if (!IsValidSid(label->Label.Sid)) return 0;
  const BYTE count = *GetSidSubAuthorityCount(label->Label.Sid);
  return count ? *GetSidSubAuthority(label->Label.Sid, count - 1) : 0;
}
inline DWORD Integrity(HANDLE process) {
  HANDLE raw = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &raw)) return 0;
  Handle token(raw);
  return TokenIntegrity(token.get());
}
// Hosted Windows runners can execute as an elevated administrator. Lower ONLY
// these disposable processes. Never change the account, a persistent token,
// desktop permissions, system policy, or the production acceptance rules.
inline void LaunchMediumConsole(const std::wstring& image, const std::wstring& arguments,
                                STARTUPINFOW* startup, PROCESS_INFORMATION* process,
                                const char* rejection_stage, DWORD rejected_host_integrity,
                                DWORD rejected_client_integrity) {
  Require(ConfirmedElevatedRejection(false, rejection_stage, rejected_host_integrity,
      rejected_client_integrity), "A confirmed elevated production rejection is required before lowering a fixture");
  wchar_t guard[16]{}, actions[16]{}, system[MAX_PATH]{}, executable[32768]{};
  GetEnvironmentVariableW(L"BAOCODE_DISPOSABLE_UI_TEST", guard, 16);
  GetEnvironmentVariableW(L"GITHUB_ACTIONS", actions, 16);
  const UINT system_length = GetSystemDirectoryW(system, MAX_PATH);
  const DWORD executable_length = GetModuleFileNameW(nullptr, executable, 32768);
  Require(std::wstring(guard) == L"1" && std::wstring(actions) == L"true" &&
      system_length && system_length < MAX_PATH && executable_length && executable_length < 32768,
      "Medium fixture launch requires a disposable hosted CI desktop and verified executable paths");
  const std::wstring official = std::wstring(system, system_length) + L"\\conhost.exe";
  const std::wstring prefix = L"\"" + official + L"\" \"" + std::wstring(executable) + L"\" --console-fixture ";
  Require(startup && process && !process->hProcess && !process->hThread &&
      _wcsicmp(image.c_str(), official.c_str()) == 0 && arguments.size() > prefix.size() &&
      _wcsnicmp(arguments.c_str(), prefix.c_str(), prefix.size()) == 0,
      "Medium fixture launcher accepts only the official conhost with this test executable's console-fixture mode");
  const DWORD own_integrity = Integrity(GetCurrentProcess());
  Require(SupportedMediumFixtureTransition(own_integrity, rejection_stage,
      rejected_host_integrity, rejected_client_integrity),
      "Only medium/high user tokens and exact high-integrity rejection may use this fixture launcher; SYSTEM and unknown levels are refused");
  std::wstring command = arguments;
  if (own_integrity == SECURITY_MANDATORY_MEDIUM_RID) {
    Require(CreateProcessW(image.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
        nullptr, nullptr, startup, process) != FALSE, "Explicit medium System32 conhost launch failed");
    Require(Integrity(process->hProcess) == SECURITY_MANDATORY_MEDIUM_RID,
        "Synthetic conhost did not actually launch at medium integrity");
    return;
  }
  HANDLE raw_original = nullptr;
  RequireWin32(OpenProcessToken(GetCurrentProcess(), kRestrictedFixtureTokenAccess,
      &raw_original), "OpenProcessToken(fixture source)");
  Handle original(raw_original);
  BYTE admin_sid[SECURITY_MAX_SID_SIZE]{};
  DWORD admin_size = sizeof(admin_sid);
  RequireWin32(CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, admin_sid, &admin_size),
      "CreateWellKnownSid(Administrators)");
  SID_AND_ATTRIBUTES disabled_admin{admin_sid, 0};
  HANDLE raw_restricted = nullptr;
  RequireWin32(CreateRestrictedToken(original.get(), DISABLE_MAX_PRIVILEGE, 1, &disabled_admin,
      0, nullptr, 0, nullptr, &raw_restricted), "CreateRestrictedToken(fixture)");
  Handle restricted(raw_restricted);
  BYTE medium_sid[SECURITY_MAX_SID_SIZE]{};
  DWORD medium_size = sizeof(medium_sid);
  RequireWin32(CreateWellKnownSid(WinMediumLabelSid, nullptr, medium_sid, &medium_size),
      "CreateWellKnownSid(MediumLabel)");
  TOKEN_MANDATORY_LABEL label{};
  label.Label.Sid = medium_sid;
  label.Label.Attributes = SE_GROUP_INTEGRITY;
  const DWORD restricted_before = TokenIntegrity(restricted.get());
  const BOOL lowered = SetTokenInformation(restricted.get(), TokenIntegrityLevel, &label,
      static_cast<DWORD>(sizeof(label)) + GetLengthSid(medium_sid));
  const DWORD lower_error = lowered ? ERROR_SUCCESS : GetLastError();
  const DWORD own_after = Integrity(GetCurrentProcess());
  const DWORD restricted_after = TokenIntegrity(restricted.get());
  std::printf("CONSOLE_BINDING|mediumToken|operation=SetTokenInformation(TokenIntegrityLevel)|ok=%d|win32Error=%lu|requestedAccess=%lu|runnerBefore=%lu|runnerAfter=%lu|restrictedBefore=%lu|restrictedAfter=%lu\n",
      lowered ? 1 : 0, lower_error, kRestrictedFixtureTokenAccess,
      own_integrity, own_after, restricted_before, restricted_after);
  if (!lowered) throw std::runtime_error("SetTokenInformation(TokenIntegrityLevel) failed (Win32 error " +
      std::to_string(lower_error) + ")");
  Require(own_after == own_integrity, "Running process integrity changed during disposable-token setup");
  Require(restricted_after == SECURITY_MANDATORY_MEDIUM_RID,
      "Disposable token did not actually reach medium integrity");
  BOOL created = CreateProcessAsUserW(restricted.get(), image.c_str(), command.data(),
      nullptr, nullptr, FALSE, 0, nullptr, nullptr, startup, process);
  const DWORD primary_error = created ? ERROR_SUCCESS : GetLastError();
  if (!created) {
    Require(!process->hProcess && !process->hThread, "Failed fixture launch returned uncertain process handles");
    command = arguments;
    created = CreateProcessWithTokenW(restricted.get(), 0, image.c_str(), command.data(),
        0, nullptr, nullptr, startup, process);
  }
  const DWORD fallback_error = created ? ERROR_SUCCESS : GetLastError();
  std::printf("CONSOLE_BINDING|mediumLaunch|runnerIntegrity=%lu|created=%d|asUserError=%lu|withTokenError=%lu\n",
      own_integrity, created ? 1 : 0, primary_error, fallback_error);
  Require(created != FALSE, "Cannot launch medium-integrity synthetic host; production elevated-host rejection remains unchanged");
  Require(Integrity(process->hProcess) == SECURITY_MANDATORY_MEDIUM_RID &&
      Integrity(GetCurrentProcess()) == own_integrity,
      "Fixture launch did not preserve runner integrity and give only the synthetic host medium integrity");
}

}  // namespace translation_test_fixture
#endif
