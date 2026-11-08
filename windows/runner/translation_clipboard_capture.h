#ifndef RUNNER_TRANSLATION_CLIPBOARD_CAPTURE_H_
#define RUNNER_TRANSLATION_CLIPBOARD_CAPTURE_H_
#include <windows.h>
#include <string>
#include <vector>
#include <cstring>
#include <atomic>

// Explicit-shortcut fallback only. This is intentionally conservative: unknown
// custom controls, terminals and clipboard formats require manual entry.
// Copy briefly exposes source text to clipboard managers/history/sync. Restoring
// the local clipboard does not erase copies observed by those services. Windows
// has no copy-operation transaction ID: same-target concurrent copies and a
// provider that responds after timeout cannot be distinguished with certainty.
// Do not describe this fallback as private, lossless, or universally supported.
namespace translation_clipboard {
struct Proof {
  HWND foreground = nullptr;
  HWND focused = nullptr;
  DWORD process = 0;
  DWORD thread = 0;
  bool explicit_shortcut = false;
  bool non_password = false;
  bool safe_text_control = false;
};
struct Result { std::wstring text; std::string status = "unsupported"; };
// A failed restoration is a separate user-visible warning, including when the
// request was canceled or focus changed meanwhile. Keep that warning while
// discarding source text; ordinary stale-result checks must not hide it.
inline void FinalizeCaptureResult(Result& result, bool same_focus,
                                  bool same_input, bool canceled) {
  if (result.status == "clipboardRestoreFailed") {
    result.text.clear();
    return;
  }
  if (!same_focus) { result.text.clear(); result.status = "focusChanged"; }
  else if (!same_input) { result.text.clear(); result.status = "clipboardChanged"; }
  else if (canceled) { result.text.clear(); result.status = "canceled"; }
}

// GetLastInputInfo is session-local and is not a monotonic clock: SendInput
// can supply timestamps and values can wrap. Use exact equality, not ordering.
// Equal-tick input remains indistinguishable, so this is a race guard rather
// than an authenticated copy transaction or a universal preservation guarantee.
inline bool LastInputMatches(DWORD expected) {
  LASTINPUTINFO info{}; info.cbSize = sizeof(info);
  return expected != 0 && GetLastInputInfo(&info) && info.dwTime == expected;
}
inline bool KeysReleased() {
  const int keys[] = {VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN,
                      VK_LBUTTON, VK_RBUTTON, VK_MBUTTON, 'C'};
  for (int key : keys)
    if (GetAsyncKeyState(key) & 0x8000) return false;
  return true;
}
inline bool SameFocus(const Proof& proof) {
  DWORD process = 0;
  if (!proof.foreground || !proof.focused ||
      GetForegroundWindow() != proof.foreground ||
      GetWindowThreadProcessId(proof.foreground, &process) != proof.thread ||
      process != proof.process || GetAncestor(proof.focused, GA_ROOT) != proof.foreground)
    return false;
  GUITHREADINFO info{}; info.cbSize = sizeof(info);
  return GetGUIThreadInfo(proof.thread, &info) && info.hwndFocus == proof.focused;
}
inline bool SafeControl(const Proof& proof) {
  if (!proof.explicit_shortcut || !proof.non_password || !proof.safe_text_control ||
      !SameFocus(proof) || proof.process == GetCurrentProcessId()) return false;
  wchar_t name[64]{};
  if (!GetClassNameW(proof.focused, name, 64)) return false;
  if (_wcsicmp(name, L"Edit") && _wcsicmp(name, L"RichEdit20W") &&
      _wcsicmp(name, L"RichEdit50W") && _wcsicmp(name, L"RICHEDIT")) return false;
  if (GetWindowLongPtrW(proof.focused, GWL_STYLE) & ES_PASSWORD) return false;
  // Do not inject into elevated targets, even when this process is elevated.
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, proof.process);
  HANDLE token = nullptr;
  bool safe = false;
  if (process && OpenProcessToken(process, TOKEN_QUERY, &token)) {
    DWORD bytes = 0;
    GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &bytes);
    std::vector<BYTE> storage(bytes);
    if (bytes && GetTokenInformation(token, TokenIntegrityLevel, storage.data(), bytes, &bytes)) {
      const auto* level = reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(storage.data());
      const DWORD count = *GetSidSubAuthorityCount(level->Label.Sid);
      safe = count && *GetSidSubAuthority(level->Label.Sid, count - 1) <= SECURITY_MANDATORY_MEDIUM_RID;
    }
    CloseHandle(token);
  }
  if (process) CloseHandle(process);
  return safe;
}
inline bool SupportedFormat(UINT format) {
  // Only documented HGLOBAL formats, never bitmap/metafile/palette handles,
  // private registered formats, file-drop data or owner-display data.
  return format == CF_UNICODETEXT || format == CF_TEXT || format == CF_OEMTEXT ||
         format == CF_LOCALE || format == CF_DIB || format == CF_DIBV5;
}
struct SavedFormat { UINT format; HGLOBAL data; };
struct Snapshot {
  std::vector<SavedFormat> formats;
  ~Snapshot() { for (auto& f : formats) if (f.data) GlobalFree(f.data); }
  Snapshot() = default;
  Snapshot(const Snapshot&) = delete;
  Snapshot& operator=(const Snapshot&) = delete;
};
// Caller owns clipboard lock. Allocate every restoration handle before injecting.
inline bool Save(Snapshot& saved) {
  SIZE_T total = 0;
  SetLastError(ERROR_SUCCESS);
  for (UINT format = EnumClipboardFormats(0); format; format = EnumClipboardFormats(format)) {
    if (!SupportedFormat(format) || saved.formats.size() >= 16) return false;
    HANDLE source = GetClipboardData(format);
    const SIZE_T size = source ? GlobalSize(source) : 0;
    if (!size || size > 4 * 1024 * 1024 || total + size > 8 * 1024 * 1024) return false;
    void* bytes = GlobalLock(source);
    if (!bytes) return false;
    HGLOBAL copy = GlobalAlloc(GMEM_MOVEABLE, size);
    void* target = copy ? GlobalLock(copy) : nullptr;
    if (target) { std::memcpy(target, bytes, size); GlobalUnlock(copy); }
    GlobalUnlock(source);
    if (!target) { if (copy) GlobalFree(copy); return false; }
    saved.formats.push_back({format, copy}); total += size;
    SetLastError(ERROR_SUCCESS);
  }
  return GetLastError() == ERROR_SUCCESS;
}
// Caller owns clipboard lock and checked the sequence immediately before this.
inline bool Restore(Snapshot& saved) {
  if (!EmptyClipboard()) return false;
  bool success = true;
  for (auto& f : saved.formats) {
    if (SetClipboardData(f.format, f.data)) f.data = nullptr;
    else success = false;
  }
  return success;
}
inline Result ReadUnicode() {
  Result result;
  HANDLE data = GetClipboardData(CF_UNICODETEXT);
  const SIZE_T bytes = data ? GlobalSize(data) : 0;
  if (!bytes || bytes % sizeof(wchar_t)) return result;
  if (bytes > 16004) { result.status = "tooLong"; return result; }
  const auto* text = static_cast<const wchar_t*>(GlobalLock(data));
  if (!text) return result;
  const SIZE_T units = bytes / sizeof(wchar_t);
  SIZE_T length = 0;
  while (length < units && text[length]) ++length;
  bool valid = length < units;
  // Allocation padding must be zero: reject embedded NUL + hidden suffix.
  for (SIZE_T i = length; valid && i < units; ++i) valid = text[i] == 0;
  if (length > 8000) result.status = "tooLong";
  else if (valid && length) { result.text.assign(text, length); result.status = "ok"; }
  else if (valid) result.status = "noSelection";
  GlobalUnlock(data);
  return result;
}
// Run off the UI thread, once per explicit shortcut. No retry/injection after
// cancellation. Clipboard APIs can invoke another app's delayed renderer, so the
// caller must not launch further capture attempts while this one is pending.
inline Result CopySelection(HWND owner, const Proof& proof,
                            const std::atomic<bool>* canceled = nullptr,
                            ULONGLONG request_deadline = 0) {
  Result result;
  const auto stopped = [&]() {
    return (canceled && canceled->load()) || !IsWindow(owner) ||
           (request_deadline && GetTickCount64() >= request_deadline);
  };
  if (stopped()) return result;
  if (!SafeControl(proof)) return result;
  const ULONGLONG release_deadline = GetTickCount64() + 450;
  while (!KeysReleased()) {
    if (stopped()) return result;
    if (!SameFocus(proof)) { result.status = "focusChanged"; return result; }
    if (GetTickCount64() >= release_deadline) { result.status = "keysHeld"; return result; }
    Sleep(10);
  }
  LASTINPUTINFO previous_input{}; previous_input.cbSize = sizeof(previous_input);
  if (!GetLastInputInfo(&previous_input)) return result;
  if (stopped() || !OpenClipboard(owner)) return result;
  Snapshot saved;
  const bool ready = Save(saved);
  const DWORD before = GetClipboardSequenceNumber();
  CloseClipboard();
  if (!ready) { result.status = "clipboardUnsupported"; return result; }
  if (stopped() || !SafeControl(proof) || !KeysReleased() || GetClipboardSequenceNumber() != before) return result;
  // Standard Edit messages are marshalled by Windows. Never read the value or
  // whole document; only query selection endpoints, with a bounded provider wait.
  DWORD_PTR endpoints = 0;
  if (!SendMessageTimeoutW(proof.focused, EM_GETSEL, 0, 0,
                          SMTO_ABORTIFHUNG | SMTO_BLOCK, 100, &endpoints)) return result;
  if (endpoints != static_cast<DWORD_PTR>(-1) &&
      LOWORD(endpoints) == HIWORD(endpoints)) {
    result.status = "noSelection"; return result;
  }
  if (stopped() || !SafeControl(proof) || !KeysReleased() || GetClipboardSequenceNumber() != before) return result;
  // Use a known, nonzero stamp for every event in our batch. Zero asks Windows
  // to assign a timestamp; avoid it at tick wrap and avoid the preceding input's
  // tick so an unprocessed injection cannot look like a completed one.
  DWORD injected_time = GetTickCount();
  if (!injected_time || injected_time == previous_input.dwTime) {
    Sleep(20);
    injected_time = GetTickCount();
  }
  if (!injected_time || injected_time == previous_input.dwTime ||
      !LastInputMatches(previous_input.dwTime)) return result;
  INPUT input[4]{};
  for (auto& key : input) { key.type = INPUT_KEYBOARD; key.ki.time = injected_time; }
  input[0].ki.wVk = VK_CONTROL; input[1].ki.wVk = 'C';
  input[2].ki.wVk = 'C'; input[2].ki.dwFlags = KEYEVENTF_KEYUP;
  input[3].ki.wVk = VK_CONTROL; input[3].ki.dwFlags = KEYEVENTF_KEYUP;
  if (stopped() || !SameFocus(proof) || !KeysReleased() ||
      !LastInputMatches(previous_input.dwTime) || GetClipboardSequenceNumber() != before) return result;
  const UINT inserted = SendInput(4, input, sizeof(INPUT));
  if (inserted != 4) {
    // Avoid leaving our synthetic Ctrl down if the OS inserted only a prefix.
    if (inserted) SendInput(2, input + 2, sizeof(INPUT));
    return result;
  }
  const ULONGLONG deadline = GetTickCount64() + 500;
  while (GetTickCount64() < deadline) {
    if (!SameFocus(proof)) { result.status = "focusChanged"; return result; }
    if (GetClipboardSequenceNumber() != before) {
      if (!OpenClipboard(owner)) { Sleep(5); continue; }
      const DWORD copied = GetClipboardSequenceNumber();
      DWORD writer = 0;
      const HWND clipboard_owner = GetClipboardOwner();
      GetWindowThreadProcessId(clipboard_owner, &writer);
      // Unknown writers / concurrent copies are never read or overwritten.
      if (copied != before && writer == proof.process && SameFocus(proof) &&
          LastInputMatches(injected_time) &&
          (clipboard_owner == proof.focused || clipboard_owner == proof.foreground)) {
        if (!stopped()) result = ReadUnicode();
        else result.status = "canceled";
        // A delayed renderer may change the sequence during ReadUnicode.
        if (GetClipboardSequenceNumber() == copied && SameFocus(proof) &&
            LastInputMatches(injected_time)) {
          if (!Restore(saved)) { result.text.clear(); result.status = "clipboardRestoreFailed"; }
        } else { result.text.clear(); result.status = "clipboardChanged"; }
      } else result.status = "clipboardChanged";
      CloseClipboard();
      FinalizeCaptureResult(result, SameFocus(proof),
                            LastInputMatches(injected_time), stopped());
      return result;
    }
    if (stopped()) { result.status = "canceled"; return result; }
    Sleep(5);
  }
  result.status = "clipboardTimeout";
  return result;
}
}  // namespace translation_clipboard
#endif
