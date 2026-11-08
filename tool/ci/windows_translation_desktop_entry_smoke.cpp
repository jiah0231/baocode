// Disposable Windows Actions desktop only. Separate cold Edge PDF profile and
// real ConsoleHost client. The production entry is the first UIA caller; only
// a physical entry click requests capture of its pinned selection. No model/network.
#include "../../windows/runner/translation_selection_action.h"
#include "../../windows/runner/translation_selection.h"
#include "windows_translation_medium_fixture.h"
#include <dwmapi.h>
#include <tlhelp32.h>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cwctype>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

namespace {
constexpr wchar_t kPdfText[] = L"PDF selected synthetic Echo";
constexpr wchar_t kConsoleText[] = L"Console selected synthetic Echo";
constexpr wchar_t kClipboard[] = L"BaoCode desktop entry clipboard decoy";
constexpr wchar_t kEntryClass[] = L"BaoCodeTranslationSelectionAction";
void Check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
std::string Quote(const std::string& value) {
  std::ostringstream out; out << '"';
  for (char raw : value) {
    const auto c = static_cast<unsigned char>(raw);
    if (c == '"' || c == '\\') out << '\\' << c;
    else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
    else out << c;
  }
  return out.str() + '"';
}
// JSON escapes preserve the actual Unicode executable path, including valid
// UTF-16 surrogate pairs, without relying on the runner console code page.
std::string Quote(const std::wstring& value) {
  std::ostringstream out; out << '"';
  for (wchar_t raw : value) {
    const auto c = static_cast<unsigned short>(raw);
    if (c >= 32 && c <= 126) {
      if (c == '"' || c == '\\') out << '\\';
      out << static_cast<char>(c);
    } else out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << c;
  }
  return out.str() + '"';
}
// Window metadata only. Never read captions or pixels from an unverified
// foreground window; the timeline explains source-focus changes without them.
struct WindowState {
  HWND window = nullptr, root = nullptr, owner = nullptr, root_owner = nullptr;
  DWORD pid = 0;
  bool visible = false;
  std::wstring cls;
  static WindowState Read(HWND value) {
    WindowState state; state.window = value;
    if (!value) return state;
    GetWindowThreadProcessId(value, &state.pid);
    state.root = GetAncestor(value, GA_ROOT);
    state.owner = GetWindow(value, GW_OWNER);
    state.root_owner = GetAncestor(value, GA_ROOTOWNER);
    state.visible = IsWindowVisible(value) != 0;
    wchar_t cls[128]{};
    if (GetClassNameW(value, cls, 128)) state.cls = cls;
    return state;
  }
  std::string Json() const {
    std::ostringstream out;
    out << "{\"hwnd\":" << reinterpret_cast<uintptr_t>(window)
        << ",\"pid\":" << pid << ",\"class\":" << Quote(cls)
        << ",\"root\":" << reinterpret_cast<uintptr_t>(root)
        << ",\"owner\":" << reinterpret_cast<uintptr_t>(owner)
        << ",\"rootOwner\":" << reinterpret_cast<uintptr_t>(root_owner)
        << ",\"visible\":" << (visible ? "true" : "false") << '}';
    return out.str();
  }
};
struct ForegroundEvent { ULONGLONG tick; WindowState state; };
std::vector<ForegroundEvent> foreground_events;
struct Result {
  std::string id, outcome = "failed", detail, status = "notRun";
  std::string first_uia_caller = "productionSelectionEntry";
  std::wstring source_image_path, host_image_path;
  bool host_identity_verified = false;
  DWORD runner_integrity = 0, source_integrity = 0, host_integrity = 0;
  DWORD inherited_source_integrity = 0, inherited_host_integrity = 0;
  bool lowered_fixture = false;
  std::string inherited_rejection = "notApplicable";
  bool selection_before_click = false, selection_after_click = false;
  bool entry_visible = false, entry_nonactivating = false, entry_hidden = false;
  bool foreground_preserved = false, no_main_window = false;
  bool clipboard = false, exact = false, proof = false, callback_source = false;
  bool request_not_canceled = false;
  bool stale_changed = false, stale_click_attempted = false, stale_rejected = false;
  bool stale_same_source = false, stale_focus_identity_changed = false, stale_focus_metadata_safe = false;
  DWORD stale_original_focus_pid = 0, stale_changed_focus_pid = 0;
  int stale_original_type = 0, stale_changed_type = 0;
  std::string stale_mutation = "notRun";
  WindowState stale_source_window, stale_changed_window;
  bool stale_foreground_known_source = false, stale_source_identity_valid = false;
  bool stale_no_post_mutation_input = true;
  ULONGLONG stale_mutation_tick = 0;
  std::string stale_screenshot_omission = "none";
  unsigned stale_callbacks = 0;
  std::string stale_status = "notRun";
  unsigned callbacks_before_click = 0, callbacks = 0, capture_calls = 0;
  unsigned gesture_attempts = 0;
  size_t units = 0;
  unsigned long long entry_ms = 0, capture_ms = 0;
  void Save(const std::wstring& path) const {
    std::ofstream file(path.c_str());
    Check(file.good(), "Cannot write desktop entry JSON");
    file << "{\n  \"id\":" << Quote(id) << ",\n  \"outcome\":" << Quote(outcome)
         << ",\n  \"detail\":" << Quote(detail)
         << ",\n  \"sourceImagePath\":" << Quote(source_image_path)
         << ",\n  \"hostImagePath\":" << Quote(host_image_path)
         << ",\n  \"hostIdentityVerified\":" << (host_identity_verified ? "true" : "false")
         << ",\n  \"runnerIntegrity\":" << runner_integrity
         << ",\n  \"sourceIntegrity\":" << source_integrity
         << ",\n  \"hostIntegrity\":" << host_integrity
         << ",\n  \"inheritedSourceIntegrity\":" << inherited_source_integrity
         << ",\n  \"inheritedHostIntegrity\":" << inherited_host_integrity
         << ",\n  \"inheritedRejectionStage\":" << Quote(inherited_rejection)
         << ",\n  \"loweredSyntheticFixture\":" << (lowered_fixture ? "true" : "false")
         << ",\n  \"captureStatus\":" << Quote(status)
         << ",\n  \"firstUiaCaller\":" << Quote(first_uia_caller)
         << ",\n  \"gestureAttempts\":" << gesture_attempts
         << ",\n  \"selectionBeforeClick\":" << (selection_before_click ? "true" : "false")
         << ",\n  \"selectionAfterClick\":" << (selection_after_click ? "true" : "false")
         << ",\n  \"entryVisible\":" << (entry_visible ? "true" : "false")
         << ",\n  \"entryNonactivating\":" << (entry_nonactivating ? "true" : "false")
         << ",\n  \"entryHiddenAfterClick\":" << (entry_hidden ? "true" : "false")
         << ",\n  \"sourceForegroundPreserved\":" << (foreground_preserved ? "true" : "false")
         << ",\n  \"noMainWindow\":" << (no_main_window ? "true" : "false")
         << ",\n  \"clipboardUnchanged\":" << (clipboard ? "true" : "false")
         << ",\n  \"exactSelectedText\":" << (exact ? "true" : "false")
         << ",\n  \"copyProof\":" << (proof ? "true" : "false")
         << ",\n  \"callbackSourceMatches\":" << (callback_source ? "true" : "false")
         << ",\n  \"requestNotCanceledAtConsumption\":" << (request_not_canceled ? "true" : "false")
         << ",\n  \"callbacksBeforeClick\":" << callbacks_before_click
         << ",\n  \"callbacksAfterClick\":" << callbacks
         << ",\n  \"captureCalls\":" << capture_calls
         << ",\n  \"entryWaitMs\":" << entry_ms << ",\n  \"captureMs\":" << capture_ms
         << ",\n  \"selectedUnits\":" << units
         << ",\n  \"staleKeyboardTargetChanged\":" << (stale_changed ? "true" : "false")
         << ",\n  \"mutationKind\":" << Quote(stale_mutation)
         << ",\n  \"staleFocusIdentityChanged\":" << (stale_focus_identity_changed ? "true" : "false")
         << ",\n  \"staleFocusMetadataVerified\":" << (stale_focus_metadata_safe ? "true" : "false")
         << ",\n  \"staleOriginalFocusPid\":" << stale_original_focus_pid
         << ",\n  \"staleChangedFocusPid\":" << stale_changed_focus_pid
         << ",\n  \"staleSameSourceWindow\":" << (stale_same_source ? "true" : "false")
         << ",\n  \"mutationSourceWindow\":" << stale_source_window.Json()
         << ",\n  \"mutationForegroundWindow\":" << stale_changed_window.Json()
         << ",\n  \"mutationTick\":" << stale_mutation_tick
         << ",\n  \"mutationForegroundMatchesPinnedSourceProcess\":" << (stale_foreground_known_source ? "true" : "false")
         << ",\n  \"mutationSourceIdentityValid\":" << (stale_source_identity_valid ? "true" : "false")
         << ",\n  \"noInputAfterForegroundMutation\":" << (stale_no_post_mutation_input ? "true" : "false")
         << ",\n  \"negativeScreenshotOmission\":" << Quote(stale_screenshot_omission)
         << ",\n  \"staleOriginalFocusType\":" << stale_original_type
         << ",\n  \"staleChangedFocusType\":" << stale_changed_type
         << ",\n  \"staleEntryClickAttempted\":" << (stale_click_attempted ? "true" : "false")
         << ",\n  \"staleSelectionRejected\":" << (stale_rejected ? "true" : "false")
         << ",\n  \"staleCallbacks\":" << stale_callbacks
         << ",\n  \"staleStatus\":" << Quote(stale_status)
         << ",\n  \"foregroundTimeline\":[";
    for (size_t i = 0; i < foreground_events.size(); ++i) {
      if (i) file << ',';
      file << "{\"tick\":" << foreground_events[i].tick
           << ",\"window\":" << foreground_events[i].state.Json() << '}';
    }
    file << "]\n}\n";
    file.close(); Check(!file.fail(), "Cannot finish desktop entry JSON");
  }
};
std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(towlower(c));
  });
  return value;
}
DWORD ParentProcessId(DWORD pid) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return 0;
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry); DWORD parent = 0;
  if (Process32FirstW(snapshot, &entry)) do {
    if (entry.th32ProcessID == pid) { parent = entry.th32ParentProcessID; break; }
  } while (Process32NextW(snapshot, &entry));
  CloseHandle(snapshot); return parent;
}
std::wstring ProcessImagePath(HANDLE process) {
  wchar_t path[32768]{}; DWORD length = 32768;
  return QueryFullProcessImageNameW(process, 0, path, &length) ? std::wstring(path, length) : std::wstring{};
}
std::wstring ImagePath(HWND window) {
  DWORD pid = 0; GetWindowThreadProcessId(window, &pid);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return {};
  wchar_t path[32768]{}; DWORD length = 32768;
  const bool queried = QueryFullProcessImageNameW(process, 0, path, &length) != 0;
  CloseHandle(process);
  return queried ? std::wstring(path, length) : std::wstring{};
}
bool HasImage(HWND window, const wchar_t* executable) {
  const std::wstring image = Lower(ImagePath(window)), suffix = L"\\" + Lower(executable);
  return image.size() >= suffix.size() && image.compare(image.size()-suffix.size(), suffix.size(), suffix) == 0;
}
struct WindowSearch { std::wstring token; const wchar_t* image; HWND found = nullptr; };
BOOL CALLBACK FindSource(HWND window, LPARAM data) {
  auto& search = *reinterpret_cast<WindowSearch*>(data);
  wchar_t title[512]{}; GetWindowTextW(window, title, 512);
  if (IsWindowVisible(window) && std::wstring(title).find(search.token) != std::wstring::npos &&
      HasImage(window, search.image)) search.found = window;
  return TRUE;
}
HWND WaitForSource(const std::wstring& token, const wchar_t* image) {
  WindowSearch search{token, image, nullptr};
  for (int i = 0; i < 200 && !search.found; ++i) { EnumWindows(FindSource, reinterpret_cast<LPARAM>(&search)); Sleep(100); }
  Check(search.found != nullptr, "Installed application did not open the isolated synthetic document");
  return search.found;
}
void Foreground(HWND window) {
  ShowWindow(window, SW_RESTORE); SetForegroundWindow(window); Sleep(500);
  Check(GetForegroundWindow() == window, "Cannot obtain verified synthetic foreground window");
  MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor); RECT rect{};
  Check(GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor) &&
        GetWindowRect(window, &rect), "Synthetic source monitor bounds unavailable");
  const RECT work = monitor.rcWork;
  if (rect.left < work.left || rect.top < work.top || rect.right > work.right || rect.bottom > work.bottom) {
    const LONG width = std::min(rect.right-rect.left, work.right-work.left-16);
    const LONG height = std::min(rect.bottom-rect.top, work.bottom-work.top-16);
    Check(SetWindowPos(window, nullptr, work.left+8, work.top+8, width, height,
        SWP_NOZORDER | SWP_NOACTIVATE) != 0, "Cannot fit synthetic source inside the visible work area");
    Sleep(300);
  }
}
struct SourceIdentity {
  HWND window = nullptr; DWORD pid = 0; HANDLE process = nullptr;
  ~SourceIdentity() { if (process) CloseHandle(process); }
  void Bind(HWND source, const std::wstring& expected_image) {
    window = source;
    GetWindowThreadProcessId(source, &pid);
    Check(pid && pid != GetCurrentProcessId(), "Source must be an independent desktop process");
    process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
    Check(process && Lower(ProcessImagePath(process)) == Lower(expected_image), "Source executable identity mismatch");
    Check(Valid(), "Source process changed while pinning identity");
  }
  bool Valid() const {
    DWORD current = 0; GetWindowThreadProcessId(window, &current);
    return process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT &&
        current == pid && IsWindow(window) && IsWindowVisible(window) &&
        GetAncestor(window, GA_ROOT) == window;
  }
};
SourceIdentity* monitored_source = nullptr;
bool foreground_lost = false;
void ObserveForeground() {
  if (!monitored_source) return;
  const HWND foreground = GetForegroundWindow();
  if (foreground_events.empty() || foreground_events.back().state.window != foreground) {
    foreground_events.push_back(ForegroundEvent{GetTickCount64(), WindowState::Read(foreground)});
    std::printf("DESKTOP_ENTRY_FOREGROUND|tick=%llu|source=%llu|window=%s\n",
        static_cast<unsigned long long>(foreground_events.back().tick),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(monitored_source->window)),
        foreground_events.back().state.Json().c_str());
  }
  if (!monitored_source->Valid() || foreground != monitored_source->window) foreground_lost = true;
}
void Pump(DWORD duration) {
  const ULONGLONG end = GetTickCount64()+duration;
  do {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      ObserveForeground(); TranslateMessage(&message); DispatchMessageW(&message);
    }
    ObserveForeground(); Sleep(5);
  } while (GetTickCount64() < end);
}
void Mouse(HWND window, POINT point, DWORD flags) {
  Check(monitored_source && monitored_source->Valid() && !foreground_lost &&
      GetForegroundWindow() == window, "Refusing mouse input after verified source lost identity or foreground");
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  Check(width > 1 && height > 1, "Interactive desktop unavailable");
  INPUT input{}; input.type = INPUT_MOUSE;
  input.mi.dx = MulDiv(point.x-GetSystemMetrics(SM_XVIRTUALSCREEN), 65535, width-1);
  input.mi.dy = MulDiv(point.y-GetSystemMetrics(SM_YVIRTUALSCREEN), 65535, height-1);
  input.mi.dwFlags = flags | MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  Check(SendInput(1, &input, sizeof(INPUT)) == 1, "Synthetic selection mouse input failed");
  Pump(5);
}
void Drag(HWND window, POINT from, POINT to) {
  Mouse(window, from, 0); Pump(60); Mouse(window, from, MOUSEEVENTF_LEFTDOWN);
  for (int i = 1; i <= 24; ++i) {
    Mouse(window, POINT{from.x+(to.x-from.x)*i/24, from.y+(to.y-from.y)*i/24}, 0); Pump(20);
  }
  Mouse(window, to, MOUSEEVENTF_LEFTUP); Pump(25);
}
DWORD SeedClipboard(HWND window) {
  Check(OpenClipboard(window) != 0, "Cannot seed synthetic clipboard");
  const auto& value = kClipboard;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(value));
  void* bytes = memory ? GlobalLock(memory) : nullptr;
  if (!bytes) { if (memory) GlobalFree(memory); CloseClipboard(); throw std::runtime_error("Clipboard allocation failed"); }
  memcpy(bytes, value, sizeof(value)); GlobalUnlock(memory);
  const bool emptied = EmptyClipboard() != 0;
  const bool written = emptied && SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
  if (!written) GlobalFree(memory);
  CloseClipboard(); Check(written, "Synthetic clipboard seed failed");
  return GetClipboardSequenceNumber();
}
// Screenshot only the verified foreground source's DWM visible frame. No full
// desktop screenshot and no GetWindowRect fallback with invisible border strips.
struct Frame {
  RECT rect{}; int width = 0, height = 0; std::vector<unsigned char> pixels;
  static Frame Read(HWND window) {
    Check(GetForegroundWindow() == window, "Refusing screenshot of background source");
    Frame frame;
    Check(SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &frame.rect, sizeof(frame.rect))), "Visible frame bounds unavailable");
    frame.width = frame.rect.right-frame.rect.left; frame.height = frame.rect.bottom-frame.rect.top;
    Check(frame.width > 0 && frame.height > 0 && frame.width <= 4096 && frame.height <= 4096, "Invalid synthetic screenshot dimensions");
    HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
    BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = frame.width; info.bmiHeader.biHeight = -frame.height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
    void* pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap || !pixels || !dc) {
      if (bitmap) DeleteObject(bitmap); if (dc) DeleteDC(dc); if (screen) ReleaseDC(nullptr, screen);
      throw std::runtime_error("Screenshot allocation failed");
    }
    const auto old = SelectObject(dc, bitmap);
    const bool copied = BitBlt(dc, 0, 0, frame.width, frame.height, screen, frame.rect.left, frame.rect.top, SRCCOPY) != 0;
    GdiFlush();
    if (copied) {
      const auto* begin = static_cast<const unsigned char*>(pixels);
      frame.pixels.assign(begin, begin+static_cast<size_t>(frame.width)*frame.height*4);
    }
    SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(nullptr, screen);
    Check(copied, "Synthetic screenshot failed");
    return frame;
  }
  void Save(const std::wstring& path) const {
    BITMAPFILEHEADER header{}; header.bfType = 0x4d42;
    header.bfOffBits = sizeof(header)+sizeof(BITMAPINFOHEADER);
    header.bfSize = header.bfOffBits+static_cast<DWORD>(pixels.size());
    BITMAPINFOHEADER info{}; info.biSize = sizeof(info); info.biWidth = width; info.biHeight = -height;
    info.biPlanes = 1; info.biBitCount = 32;
    FILE* file = nullptr; _wfopen_s(&file, path.c_str(), L"wb"); Check(file != nullptr, "Screenshot output unavailable");
    const bool saved = fwrite(&header, sizeof(header), 1, file) == 1 && fwrite(&info, sizeof(info), 1, file) == 1 &&
        fwrite(pixels.data(), pixels.size(), 1, file) == 1;
    fclose(file); Check(saved, "Screenshot output incomplete");
  }
  std::optional<RECT> PdfMarker() const {
    RECT marker{width, height, 0, 0}; size_t count = 0;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
      const auto i = (static_cast<size_t>(y)*width+x)*4;
      if (pixels[i] > 225 && pixels[i+1] < 35 && pixels[i+2] > 225) {
        marker.left = std::min<LONG>(marker.left, x); marker.top = std::min<LONG>(marker.top, y);
        marker.right = std::max<LONG>(marker.right, x+1); marker.bottom = std::max<LONG>(marker.bottom, y+1); ++count;
      }
    }
    // Only one tiny magenta rectangle exists in the synthetic PDF. Reject UI
    // adornments, unrendered pages, or a marker larger than the fixture permits.
    const LONG w = marker.right-marker.left, h = marker.bottom-marker.top;
    if (count < 12 || w < 2 || w > 32 || h < 6 || h > 96 || count < static_cast<size_t>(w*h/2)) return std::nullopt;
    return marker;
  }
};
bool VisiblePdfSelection(const Frame& before, const Frame& after, RECT area) {
  if (!EqualRect(&before.rect, &after.rect) || before.width != after.width || before.height != after.height) return false;
  area.left = std::max<LONG>(0, area.left); area.top = std::max<LONG>(0, area.top);
  area.right = std::min<LONG>(before.width, area.right); area.bottom = std::min<LONG>(before.height, area.bottom);
  size_t white = 0, highlighted = 0;
  for (LONG y = area.top; y < area.bottom; ++y) for (LONG x = area.left; x < area.right; ++x) {
    const auto i = (static_cast<size_t>(y)*before.width+x)*4;
    if (before.pixels[i] > 240 && before.pixels[i+1] > 240 && before.pixels[i+2] > 240) {
      ++white;
      const int b = after.pixels[i], g = after.pixels[i+1], r = after.pixels[i+2];
      if (b > 90 && g > 90 && r > 70 && (static_cast<int>(before.pixels[i])-b)+(static_cast<int>(before.pixels[i+1])-g)+(static_cast<int>(before.pixels[i+2])-r) >= 35) ++highlighted;
    }
  }
  return white >= 200 && highlighted >= white/8;
}
// A broad highlight can still omit the final character. Require substantial
// background highlight in BOTH edge cells and no highlight in the decoy row.
bool CompletePdfSelection(const Frame& before, const Frame& after, RECT line, double scale) {
  if (!VisiblePdfSelection(before, after, line)) return false;
  const LONG cell = std::max<LONG>(1, static_cast<LONG>(10.8*scale));
  const auto fraction = [&](RECT area) {
    size_t white = 0, highlighted = 0;
    for (LONG y = area.top; y < area.bottom; ++y) for (LONG x = area.left; x < area.right; ++x) {
      if (x < 0 || y < 0 || x >= before.width || y >= before.height) continue;
      const auto i = (static_cast<size_t>(y)*before.width+x)*4;
      if (before.pixels[i] > 240 && before.pixels[i+1] > 240 && before.pixels[i+2] > 240) {
        ++white; const int b = after.pixels[i], g = after.pixels[i+1], r = after.pixels[i+2];
        if (b > 90 && g > 90 && r > 70 && (static_cast<int>(before.pixels[i])-b)+(static_cast<int>(before.pixels[i+1])-g)+(static_cast<int>(before.pixels[i+2])-r) >= 35) ++highlighted;
      }
    }
    return std::pair<size_t, size_t>{white, highlighted};
  };
  const auto first = fraction(RECT{line.left, line.top, line.left+cell, line.bottom});
  const auto last = fraction(RECT{line.right-cell, line.top, line.right, line.bottom});
  const LONG dy = static_cast<LONG>(60*scale);
  const auto decoy = fraction(RECT{line.left, line.top+dy, line.right, line.bottom+dy});
  std::printf("DESKTOP_PDF_HIGHLIGHT|first=%zu/%zu|last=%zu/%zu|decoy=%zu/%zu\n",
      first.second, first.first, last.second, last.first, decoy.second, decoy.first);
  return first.first >= 40 && last.first >= 40 && first.second*5 >= first.first*3 &&
      last.second*5 >= last.first*3 && decoy.first >= 200 && decoy.second == 0;
}
// Find an actual dark pixel in the leading half of the first Courier glyph.
// PDF viewers can ignore a drag starting in the font's left side-bearing even
// though the same coordinate is a valid caret position in an HTML paragraph.
POINT PdfGlyphAnchor(const Frame& frame, RECT marker, double scale, int row_offset) {
  const LONG left = marker.left+static_cast<LONG>(12*scale);
  const LONG middle = marker.top+static_cast<LONG>(9*scale)+row_offset;
  const LONG half_cell = std::max<LONG>(3, static_cast<LONG>(5.4*scale));
  for (LONG distance = 0; distance <= 4; ++distance) {
    for (LONG direction : {1L, -1L}) {
      const LONG y = middle+distance*direction;
      if (y <= marker.top || y >= marker.bottom || y < 0 || y >= frame.height) continue;
      for (LONG x = left+1; x < left+half_cell && x < frame.width; ++x) {
        if (x < 0) continue;
        const auto i = (static_cast<size_t>(y)*frame.width+x)*4;
        if (frame.pixels[i] < 100 && frame.pixels[i+1] < 100 && frame.pixels[i+2] < 100)
          return POINT{frame.rect.left+x, frame.rect.top+y};
      }
    }
  }
  throw std::runtime_error("PDF first glyph could not be visually identified; refusing a guessed drag");
}
int ConsoleFixture(const std::wstring& token, const std::wstring& root) {
  std::ofstream trace((root+L".startup.log").c_str());
  HWND window = GetConsoleWindow();
  trace << "fixturePid=" << GetCurrentProcessId() << " initialWindow=" << reinterpret_cast<uintptr_t>(window)
        << " initialVisible=" << (window && IsWindowVisible(window) ? 1 : 0) << std::endl;
  // The first HWND can precede its visible host. A pseudo-console HWND never
  // becomes visible, which must be reported rather than treated as capture.
  for (int i = 0; i < 200 && (!window || !IsWindowVisible(window)); ++i) {
    Sleep(50); window = GetConsoleWindow();
  }
  DWORD attached[8]{};
  const DWORD attached_count = GetConsoleProcessList(attached, 8);
  trace << "window=" << reinterpret_cast<uintptr_t>(window)
        << " visible=" << (window && IsWindowVisible(window) ? 1 : 0)
        << " sourceImagePath=" << Quote(ImagePath(window))
        << " attachedProcessCount=" << attached_count << std::endl;
  if (!window || !IsWindowVisible(window)) { trace << "exit=3 invisibleConsoleWindow" << std::endl; return 3; }
  // Never write fixture output into an inherited CI shell's console.
  if (attached_count != 1 || attached[0] != GetCurrentProcessId()) {
    trace << "exit=6 consoleNotExclusiveToFixture" << std::endl; return 6;
  }
  DWORD expected_host = 0;
  for (int i = 0; i < 60 && !expected_host; ++i) {
    std::ifstream expected((root+L".expected-host").c_str()); expected >> expected_host;
    if (!expected_host) Sleep(50);
  }
  const DWORD parent = ParentProcessId(GetCurrentProcessId());
  DWORD owner = 0; GetWindowThreadProcessId(window, &owner);
  wchar_t cls[128]{}; GetClassNameW(window, cls, 128);
  const bool host_proof = expected_host && parent == expected_host && GetAncestor(window, GA_ROOT) == window &&
      _wcsicmp(cls, L"ConsoleWindowClass") == 0 && (owner == expected_host || owner == GetCurrentProcessId());
  trace << "expectedHost=" << expected_host << " parentPid=" << parent << " windowOwner=" << owner
        << " windowClass=" << Quote(std::wstring(cls)) << " hostIdentityVerified=" << host_proof << std::endl;
  if (!host_proof) { trace << "exit=7 consoleHostIdentityMismatch" << std::endl; return 7; }
  SetConsoleTitleW(token.c_str());
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE), input = GetStdHandle(STD_INPUT_HANDLE);
  CONSOLE_FONT_INFOEX font{}; font.cbSize = sizeof(font); font.dwFontSize.Y = 20;
  font.FontFamily = FF_DONTCARE; font.FontWeight = FW_NORMAL; wcscpy_s(font.FaceName, L"Consolas");
  const BOOL set_font = SetCurrentConsoleFontEx(output, FALSE, &font);
  SMALL_RECT visible{0, 0, 79, 19}; const BOOL set_window = SetConsoleWindowInfo(output, TRUE, &visible);
  const BOOL set_buffer = SetConsoleScreenBufferSize(output, COORD{80, 20});
  trace << "setFont=" << set_font << " setWindow=" << set_window << " setBuffer=" << set_buffer << std::endl;
  DWORD mode = 0;
  if (!GetConsoleMode(input, &mode) || !SetConsoleMode(input, (mode | ENABLE_EXTENDED_FLAGS | ENABLE_QUICK_EDIT_MODE) & ~ENABLE_MOUSE_INPUT)) {
    trace << "exit=4 consoleInputMode error=" << GetLastError() << std::endl; return 4;
  }
  CONSOLE_CURSOR_INFO cursor{25, FALSE}; SetConsoleCursorInfo(output, &cursor);
  DWORD written = 0; FillConsoleOutputCharacterW(output, L' ', 1600, COORD{0, 0}, &written);
  SetConsoleCursorPosition(output, COORD{4, 2}); WriteConsoleW(output, kConsoleText, static_cast<DWORD>(wcslen(kConsoleText)), &written, nullptr);
  const wchar_t decoy[] = L"Unselected console output decoy";
  SetConsoleCursorPosition(output, COORD{4, 4}); WriteConsoleW(output, decoy, static_cast<DWORD>(wcslen(decoy)), &written, nullptr);
  CONSOLE_FONT_INFO current{};
  if (!GetCurrentConsoleFont(output, FALSE, &current)) {
    trace << "exit=5 consoleFont error=" << GetLastError() << std::endl; return 5;
  }
  const COORD size = GetConsoleFontSize(output, current.nFont);
  trace << "ready cell=" << size.X << ',' << size.Y << std::endl;
  {
    std::ofstream ready((root+L".ready").c_str());
    ready << reinterpret_cast<uintptr_t>(window) << ' ' << size.X << ' ' << size.Y << ' ' << GetCurrentProcessId() << '\n';
  }
  const auto end = GetTickCount64()+60000;
  unsigned published = 0, publish_failures = 0;
  ULONGLONG last_published = 0;
  while (GetTickCount64() < end && GetFileAttributesW((root+L".stop").c_str()) == INVALID_FILE_ATTRIBUTES) {
    CONSOLE_SELECTION_INFO selection{};
    if (GetConsoleSelectionInfo(&selection)) {
      const auto sample = GetTickCount64();
      std::ofstream proof((root+L".selection.tmp").c_str());
      proof << sample << ' ' << selection.dwFlags << ' ' << selection.srSelection.Left << ' ' << selection.srSelection.Top << ' '
            << selection.srSelection.Right << ' ' << selection.srSelection.Bottom << '\n';
      proof.close();
      if (!proof.fail() && MoveFileExW((root+L".selection.tmp").c_str(),
          (root+L".selection").c_str(), MOVEFILE_REPLACE_EXISTING)) {
        ++published; last_published = sample;
      } else {
        const DWORD error = proof.fail() ? ERROR_WRITE_FAULT : GetLastError();
        ++publish_failures;
        trace << "selectionPublishFailure tick=" << sample << " error=" << error
              << " count=" << publish_failures << std::endl;
      }
    }
    Sleep(40);
  }
  trace << "selectionPublisherSummary published=" << published << " failures=" << publish_failures
        << " lastPublishedTick=" << last_published << std::endl;
  return 0;
}
struct Child {
  PROCESS_INFORMATION value{}; std::wstring root; HANDLE fixture = nullptr;
  ~Child() {
    if (value.hProcess) {
      if (!root.empty()) { std::ofstream stop((root+L".stop").c_str()); stop << "stop\n"; }
      if (fixture) {
        if (WaitForSingleObject(fixture, 2000) == WAIT_TIMEOUT) {
          TerminateProcess(fixture, 1); WaitForSingleObject(fixture, 1000);
        }
        CloseHandle(fixture);
      }
      if (WaitForSingleObject(value.hProcess, 2000) == WAIT_TIMEOUT) {
        // This handle belongs only to the explicit conhost process launched
        // for our synthetic fixture. Its child also observes the stop file.
        TerminateProcess(value.hProcess, 1); WaitForSingleObject(value.hProcess, 1000);
      }
      CloseHandle(value.hProcess); CloseHandle(value.hThread);
    }
  }
};
struct IntegrityEvidence {
  std::string stage = "notRun";
  DWORD host = 0, client = 0;
  bool rejected = false;
};
HWND ConsoleSource(const std::wstring& token, const std::wstring& root, Child& child,
                   int& cell_x, int& cell_y, Result& result,
                   const IntegrityEvidence* evidence = nullptr) {
  wchar_t executable[32768]{}; Check(GetModuleFileNameW(nullptr, executable, 32768) != 0, "Cannot locate console fixture executable");
  wchar_t system[32768]{};
  const UINT length = GetSystemDirectoryW(system, 32768);
  Check(length > 0 && length < 32768, "Cannot locate the official system Console Host");
  const std::wstring host = std::wstring(system, length)+L"\\conhost.exe";
  // Microsoft documents direct conhost.exe <client> as a per-launch host choice
  // even when Windows Terminal is the default. Do not change delegation settings.
  std::wstring command = L"\""+host+L"\" \""+std::wstring(executable)+L"\" --console-fixture \""+token+L"\" \""+root+L"\"";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup); child.root = root;
  startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_SHOWNORMAL;
  BOOL created = FALSE;
  if (evidence && evidence->rejected) {
    translation_test_fixture::LaunchMediumConsole(host, command, &startup, &child.value,
        evidence->stage.c_str(), evidence->host, evidence->client);
    created = TRUE;
    result.lowered_fixture = true;
  } else created = CreateProcessW(host.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
      nullptr, nullptr, &startup, &child.value);
  const DWORD create_error = created ? ERROR_SUCCESS : GetLastError();
  std::printf("DESKTOP_ENTRY_CONSOLE_LAUNCH|explicitSystemConhost=1|created=%d|error=%lu|hostPid=%lu\n",
      created ? 1 : 0, create_error, child.value.dwProcessId);
  Check(created != 0, "Cannot launch the official system conhost.exe with the synthetic client");
  result.host_image_path = ProcessImagePath(child.value.hProcess);
  Check(Lower(result.host_image_path) == Lower(host), "Launched host process identity does not match the official system conhost path");
  { std::ofstream expected((root+L".expected-host").c_str()); expected << child.value.dwProcessId << '\n'; }
  uintptr_t handle = 0; DWORD fixture_pid = 0; int fixture_exit = -1;
  for (int i = 0; i < 150 && !handle; ++i) {
    std::ifstream ready((root+L".ready").c_str());
    uintptr_t candidate = 0; int x = 0, y = 0; DWORD pid = 0;
    if (ready >> candidate >> x >> y >> pid) { handle = candidate; cell_x = x; cell_y = y; fixture_pid = pid; }
    // A launcher exit is not evidence that its client failed. Wait for the
    // fixture's own ready/exit protocol instead of racing the conhost launcher.
    std::ifstream exited((root+L".exit").c_str());
    if (!handle && (exited >> fixture_exit)) break;
    if (!handle) Sleep(100);
  }
  DWORD exit_code = STILL_ACTIVE; GetExitCodeProcess(child.value.hProcess, &exit_code);
  std::printf("DESKTOP_ENTRY_CONSOLE_READY|window=%llu|cell=%d,%d|hostExit=%lu|fixturePid=%lu|fixtureExit=%d\n",
      static_cast<unsigned long long>(handle), cell_x, cell_y, exit_code, fixture_pid, fixture_exit);
  HWND window = reinterpret_cast<HWND>(handle);
  Check(window && IsWindowVisible(window) && cell_x > 0 && cell_y > 0, "Classic console host unavailable or fixture initialization failed; Windows Terminal is not substituted");
  wchar_t cls[128]{}; GetClassNameW(window, cls, 128);
  DWORD owner = 0; GetWindowThreadProcessId(window, &owner);
  Check(fixture_pid && ParentProcessId(fixture_pid) == child.value.dwProcessId &&
      _wcsicmp(cls, L"ConsoleWindowClass") == 0 && GetAncestor(window, GA_ROOT) == window &&
      (owner == fixture_pid || owner == child.value.dwProcessId), "Visible console host/client provenance does not match the explicit launch");
  child.fixture = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | PROCESS_TERMINATE, FALSE, fixture_pid);
  Check(child.fixture != nullptr, "Cannot pin the known synthetic console client process");
  if (Lower(ProcessImagePath(child.fixture)) != Lower(executable)) {
    CloseHandle(child.fixture); child.fixture = nullptr;
    throw std::runtime_error("Console client executable does not match the synthetic fixture");
  }
  result.host_identity_verified = true;
  result.host_integrity = translation_test_fixture::Integrity(child.value.hProcess);
  result.source_integrity = translation_test_fixture::Integrity(child.fixture);
  wchar_t title[512]{}; GetWindowTextW(window, title, 512);
  Check(std::wstring(title).find(token) != std::wstring::npos, "Console title identity mismatch");
  return window;
}
int ConsoleIntegrityProbe(const std::wstring& token, const std::wstring& output,
                          const std::wstring& root) {
  Result observed; observed.id = "consoleIntegrity";
  observed.first_uia_caller = "separateInheritedIntegrityDiagnostic";
  observed.runner_integrity = translation_test_fixture::Integrity(GetCurrentProcess());
  IntegrityEvidence evidence;
  int result = 1;
  try {
    Child inherited; int x = 0, y = 0;
    const HWND window = ConsoleSource(token, root, inherited, x, y, observed);
    Foreground(window);
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    Check(SUCCEEDED(initialized), "Cannot initialize isolated integrity probe COM");
    {
      Microsoft::WRL::ComPtr<IUIAutomation> automation;
      Microsoft::WRL::ComPtr<IUIAutomation2> bounded;
      Microsoft::WRL::ComPtr<IUIAutomationElement> focus;
      Check(SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
          IID_PPV_ARGS(&automation))) && SUCCEEDED(automation.As(&bounded)), "Cannot create bounded integrity probe UIA");
      const auto deadline = GetTickCount64()+3000;
      const auto ready = [&] {
        auto now = GetTickCount64();
        if (now >= deadline || GetForegroundWindow() != window) return false;
        if (FAILED(bounded->put_ConnectionTimeout(static_cast<DWORD>(
            std::min<ULONGLONG>(150, deadline-now))))) return false;
        now = GetTickCount64();
        return now < deadline && GetForegroundWindow() == window &&
            SUCCEEDED(bounded->put_TransactionTimeout(static_cast<DWORD>(
                std::min<ULONGLONG>(200, deadline-now)))) &&
            GetTickCount64() < deadline && GetForegroundWindow() == window;
      };
      bool matched = false;
      while (!matched && ready()) {
        focus.Reset(); int pid = 0; BOOL has_focus = FALSE;
        matched = SUCCEEDED(automation->GetFocusedElement(&focus)) && focus && ready() &&
            SUCCEEDED(focus->get_CurrentProcessId(&pid)) &&
            static_cast<DWORD>(pid) == inherited.value.dwProcessId && ready() &&
            SUCCEEDED(focus->get_CurrentHasKeyboardFocus(&has_focus)) && has_focus && ready();
        if (!matched) Sleep(30);
      }
      Check(matched, "Isolated inherited console focus did not bind to its known host");
      translation_selection::ConsoleBinding binding;
      translation_selection::ConsoleBindingDiagnostics diagnostics;
      const bool accepted = binding.Verify(window, GetProcessId(inherited.fixture),
          inherited.value.dwProcessId, automation.Get(), focus.Get(), [] { return false; },
          GetTickCount64()+3000, &diagnostics);
      evidence.stage = diagnostics.stage;
      evidence.host = diagnostics.host_integrity;
      evidence.client = diagnostics.client_integrity;
      evidence.rejected = translation_test_fixture::ConfirmedElevatedRejection(
          accepted, diagnostics.stage, evidence.host, evidence.client);
      observed.inherited_rejection = diagnostics.stage;
      Check(evidence.rejected || (accepted && observed.host_integrity == SECURITY_MANDATORY_MEDIUM_RID &&
          observed.source_integrity == SECURITY_MANDATORY_MEDIUM_RID),
          "Inherited console failed for a reason other than confirmed elevated-integrity rejection");
    }
    CoUninitialize();
    observed.outcome = evidence.rejected ? "elevatedRejected" : "mediumAccepted";
    observed.detail = "Separate diagnostic process and host; never reused by the cold positive entry case.";
    result = 0;
  } catch (const std::exception& error) { observed.detail = error.what(); }
  observed.Save(output+L"\\console-integrity.json");
  if (!result) {
    std::ofstream proof((root+L".evidence").c_str());
    proof << evidence.rejected << ' ' << evidence.stage << ' ' << evidence.host << ' ' << evidence.client
          << ' ' << observed.host_integrity << ' ' << observed.source_integrity << '\n';
    Check(proof.good(), "Cannot write owned integrity rejection evidence");
  }
  return result;
}
IntegrityEvidence ProbeIntegritySeparately(const std::wstring& token,
                                          const std::wstring& output,
                                          const std::wstring& root, Result& result) {
  wchar_t self[32768]{};
  Check(GetModuleFileNameW(nullptr, self, 32768) != 0, "Cannot resolve integrity probe executable");
  Child probe; probe.root = root+L".integrity-probe";
  std::wstring command = L"\""+std::wstring(self)+L"\" --console-integrity-probe \""+
      token+L"-integrity\" \""+output+L"\" \""+probe.root+L"\"";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup);
  Check(CreateProcessW(self, command.data(), nullptr, nullptr, FALSE, 0,
      nullptr, nullptr, &startup, &probe.value) != 0, "Cannot start separate console integrity probe");
  Check(WaitForSingleObject(probe.value.hProcess, 30000) == WAIT_OBJECT_0,
      "Separate inherited console integrity probe timed out");
  DWORD code = 1; GetExitCodeProcess(probe.value.hProcess, &code);
  Check(code == 0, "Separate inherited console failed its precise integrity gate; see console-integrity.json");
  IntegrityEvidence evidence;
  std::ifstream proof((probe.root+L".evidence").c_str());
  proof >> evidence.rejected >> evidence.stage >> evidence.host >> evidence.client >>
      result.inherited_host_integrity >> result.inherited_source_integrity;
  Check(!proof.fail(), "Invalid inherited console integrity evidence");
  result.inherited_rejection = evidence.stage;
  Check(evidence.rejected || (result.inherited_host_integrity == SECURITY_MANDATORY_MEDIUM_RID &&
      result.inherited_source_integrity == SECURITY_MANDATORY_MEDIUM_RID), "Inherited source integrity evidence is not medium");
  Check(!evidence.rejected || translation_test_fixture::ConfirmedElevatedRejection(
      false, evidence.stage.c_str(), evidence.host, evidence.client), "Invalid elevated rejection proof");
  return evidence;
}
// File-only regression check for the old IPC race, before any positive-source
// UIA access. Keep the legacy reader open to observe its replacement behavior,
// then prove a delete-shared reader allows the publisher's atomic replacement.
void CheckConsoleProofSharing(const std::wstring& root) {
  const std::wstring path = root+L".io-check", temporary = root+L".io-check.tmp";
  const auto write = [](const std::wstring& target, const char* value) {
    std::ofstream stream(target.c_str()); stream << value; stream.close();
    Check(!stream.fail(), "Cannot write owned console proof I/O check");
  };
  write(path, "old"); write(temporary, "legacy replacement");
  bool legacy_blocked = false; DWORD legacy_error = ERROR_SUCCESS;
  {
    std::ifstream legacy(path.c_str());
    Check(legacy.good(), "Cannot open legacy-reader control");
    legacy_blocked = MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) == FALSE;
    if (legacy_blocked) legacy_error = GetLastError();
  }
  write(temporary, "shared replacement");
  HANDLE shared = CreateFileW(path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  Check(shared != INVALID_HANDLE_VALUE, "Cannot open delete-shared reader control");
  const bool replaced = MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) != FALSE;
  const DWORD shared_error = replaced ? ERROR_SUCCESS : GetLastError();
  CloseHandle(shared);
  std::printf("CONSOLE_PROOF_IO_CHECK|legacyRenameBlocked=%d|legacyError=%lu|deleteSharedRename=%d|sharedError=%lu\n",
      legacy_blocked ? 1 : 0, legacy_error, replaced ? 1 : 0, shared_error);
  Check(replaced, "Delete-shared console proof reader blocked atomic publication");
  Check(DeleteFileW(path.c_str()) != FALSE, "Cannot clean owned proof-sharing check");
}
bool ConsoleSelection(const std::wstring& root, ULONGLONG since, int right_delta = 0,
                      const char* phase = "unspecified") {
  const auto began = GetTickCount64();
  ULONGLONG sample = 0; DWORD flags = 0, read_error = ERROR_SUCCESS;
  int left = -1, top = -1, right = -1, bottom = -1;
  bool matched = false; unsigned attempts = 0;
  for (; attempts < 40; ++attempts) {
    char bytes[256]{}; DWORD length = 0;
    bool read = false;
    // Close BEFORE parsing or pumping. FILE_SHARE_DELETE also permits an atomic
    // replacement during the read; this handle sees one complete old snapshot.
    {
      HANDLE file = CreateFileW((root+L".selection").c_str(), GENERIC_READ,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file != INVALID_HANDLE_VALUE) {
        read = ReadFile(file, bytes, static_cast<DWORD>(sizeof(bytes)-1), &length, nullptr) != FALSE;
        read_error = read ? ERROR_SUCCESS : GetLastError();
        CloseHandle(file);
      } else read_error = GetLastError();
    }
    std::istringstream proof(read ? std::string(bytes, length) : std::string{});
    proof >> sample >> flags >> left >> top >> right >> bottom;
    matched = proof && sample >= since && (flags & CONSOLE_SELECTION_NOT_EMPTY) &&
        left == 4 && top == 2 && right == 4+static_cast<int>(wcslen(kConsoleText))-1+right_delta && bottom == 2;
    if (matched) { ++attempts; break; }
    Pump(25);
  }
  std::printf("CONSOLE_SELECTION_PROOF|phase=%s|ok=%d|since=%llu|lastSample=%llu|finished=%llu|waitMs=%llu|attempts=%u|flags=%lu|rect=%d,%d,%d,%d|expectedRight=%d|readError=%lu\n",
      phase, matched ? 1 : 0, static_cast<unsigned long long>(since),
      static_cast<unsigned long long>(sample), static_cast<unsigned long long>(GetTickCount64()),
      static_cast<unsigned long long>(GetTickCount64()-began), attempts, flags, left, top, right, bottom,
      4+static_cast<int>(wcslen(kConsoleText))-1+right_delta, read_error);
  return matched;
}
bool ClipboardUnchanged(DWORD sequence) {
  if (GetClipboardSequenceNumber() != sequence || !OpenClipboard(nullptr)) return false;
  HGLOBAL memory = GetClipboardData(CF_UNICODETEXT);
  const auto* value = memory ? static_cast<const wchar_t*>(GlobalLock(memory)) : nullptr;
  const bool same = value && GlobalSize(memory) >= sizeof(kClipboard) &&
      memcmp(value, kClipboard, sizeof(kClipboard)) == 0;
  if (value) GlobalUnlock(memory);
  CloseClipboard();
  return same && GetClipboardSequenceNumber() == sequence;
}
HWND OwnedEntry() {
  HWND found = FindWindowW(kEntryClass, nullptr); DWORD pid = 0;
  if (found) GetWindowThreadProcessId(found, &pid);
  return pid == GetCurrentProcessId() ? found : nullptr;
}
bool EntryVisible() {
  const HWND entry = OwnedEntry(); return entry && IsWindowVisible(entry);
}
BOOL CALLBACK OnlyEntryWindow(HWND window, LPARAM result) {
  DWORD pid = 0; GetWindowThreadProcessId(window, &pid);
  if (pid == GetCurrentProcessId() && IsWindowVisible(window) && window != OwnedEntry())
    *reinterpret_cast<bool*>(result) = false;
  return TRUE;
}
bool NoMainWindow() {
  bool safe = true; EnumWindows(OnlyEntryWindow, reinterpret_cast<LPARAM>(&safe)); return safe;
}
struct Captured {
  std::atomic<bool> done{false}, canceled{false};
  translation_selection::Selection selection;
  unsigned long long elapsed = 0;
  unsigned accepted_generation = 0;
  bool foreground_before = false, foreground_after = false;
};
struct Driver {
  HWND dispatcher = nullptr, source = nullptr;
  std::unique_ptr<TranslationSelectionAction> action;
  std::shared_ptr<Captured> captured = std::make_shared<Captured>();
  unsigned callbacks = 0, capture_calls = 0;
  bool correct_source = true, hidden_at_callback = true, capture_requested = false;
  std::string callback_error;
  ~Driver() {
    captured->canceled.store(true);
    action.reset();
    if (dispatcher) DestroyWindow(dispatcher);
  }
  void ResetRequest() {
    captured->canceled.store(true);
    captured = std::make_shared<Captured>();
    callbacks = 0; capture_calls = 0;
    correct_source = true; hidden_at_callback = true; capture_requested = false;
    callback_error.clear();
  }
  void Click(HWND callback_source) noexcept {
    ++callbacks;
    correct_source = correct_source && callback_source == source;
    hidden_at_callback = hidden_at_callback && !EntryVisible();
    // No text/capture work is possible before this exact production callback.
    // Reject duplicate callbacks instead of accidentally translating twice.
    if (callbacks != 1 || !correct_source || GetForegroundWindow() != source) return;
    ++capture_calls;
    // Register this request synchronously inside the real click callback. The
    // native action's original MTA owns the pinned focus, target and endpoints;
    // this harness never calls generic Capture or reacquires a current range.
    const auto target = captured;
    const auto began = GetTickCount64();
    target->foreground_before = GetForegroundWindow() == callback_source;
    try {
      capture_requested = action->CaptureClickedSelection(
          callback_source, began+1500,
          [target] { return target->canceled.load(); },
          [target, callback_source, began](translation_selection::Selection selection) {
            target->selection = std::move(selection);
            target->elapsed = GetTickCount64()-began;
            target->foreground_after = GetForegroundWindow() == callback_source;
            target->done.store(true, std::memory_order_release);
          },
          [target] { target->canceled.store(true); }, &target->accepted_generation);
      if (!capture_requested) {
        target->selection.status = "requestRejected";
        target->done.store(true, std::memory_order_release);
      }
    } catch (const std::exception& error) { callback_error = error.what(); }
  }
};
Driver* current_driver = nullptr;
LRESULT CALLBACK Dispatch(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  LRESULT result = 0;
  if (current_driver && current_driver->action &&
      current_driver->action->HandleMessage(message, wparam, lparam, &result)) return result;
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
void Arm(Driver& driver, HWND source) {
  Check(!FindWindowW(kEntryClass, nullptr), "Another translation entry exists on the disposable desktop");
  WNDCLASSW cls{}; cls.lpfnWndProc = Dispatch; cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"BaoCodeDesktopEntryDispatch";
  Check(RegisterClassW(&cls) != 0, "Cannot register isolated action dispatcher");
  driver.source = source; current_driver = &driver;
  driver.dispatcher = CreateWindowW(cls.lpszClassName, L"", 0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, cls.hInstance, nullptr);
  Check(driver.dispatcher != nullptr, "Cannot create message-only action dispatcher");
  driver.action = std::make_unique<TranslationSelectionAction>(
      driver.dispatcher, [&driver](HWND clicked_source) { driver.Click(clicked_source); });
  Check(driver.action->Configure(true, false), "Cannot enable the production selection action");
  Check(NoMainWindow(), "Action arming opened an unexpected main window");
}
void ChangeTargetWithKeyboard(HWND window, bool pdf) {
  Check(monitored_source && monitored_source->Valid() && !foreground_lost &&
      GetForegroundWindow() == window, "Refusing keyboard input outside the synthetic source");
  INPUT input[4]{};
  const WORD modifier = static_cast<WORD>(pdf ? VK_CONTROL : VK_SHIFT);
  const WORD key = pdf ? static_cast<WORD>('F') : static_cast<WORD>(VK_LEFT);
  const WORD keys[] = {modifier, key, key, modifier};
  for (int i = 0; i < 4; ++i) {
    input[i].type = INPUT_KEYBOARD; input[i].ki.wVk = keys[i];
    input[i].ki.dwFlags = i >= 2 ? KEYEVENTF_KEYUP : 0;
  }
  Check(SendInput(4, input, sizeof(INPUT)) == 4, "Synthetic keyboard target mutation failed");
  Pump(40);
}
// Used ONLY after the real cold entry and its explicit-click capture passed.
// Ctrl+A is a no-op in some Edge PDF versions. Ctrl+F can focus an in-window
// Edit or a separate Edge widget. This helper proves ONLY the in-window Edit
// identity transition; a foreground-window transition is checked separately using metadata
// only; never use a name, value, text, document range, child scan or fresh Capture.
class KeyboardFocusProof {
 public:
  explicit KeyboardFocusProof(HWND source) : source_(source) {
    GetWindowThreadProcessId(source_, &pid_);
    initialized_ = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    Check(SUCCEEDED(initialized_), "Cannot initialize post-positive keyboard-focus proof");
    Check(SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&automation_))) && SUCCEEDED(automation_.As(&bounded_)),
        "Cannot create post-positive metadata-only focus verifier");
    deadline_ = GetTickCount64()+1500;
    Check(Ready() && SUCCEEDED(automation_->GetFocusedElement(&original_)) && original_ &&
        SafeFocus(original_.Get(), &original_type_), "Original entry focus is not a verified source control");
  }
  ~KeyboardFocusProof() {
    original_.Reset(); bounded_.Reset(); automation_.Reset();
    if (SUCCEEDED(initialized_)) CoUninitialize();
  }
  int OriginalType() const { return original_type_; }
  DWORD SourcePid() const { return pid_; }
  bool WaitForChangedEdit(int* changed_type, bool* identity_changed, DWORD* changed_pid) {
    deadline_ = GetTickCount64()+1500;
    while (Ready()) {
      Microsoft::WRL::ComPtr<IUIAutomationElement> current;
      int type = 0; BOOL same = TRUE;
      if (SUCCEEDED(automation_->GetFocusedElement(&current)) && current &&
          SafeFocus(current.Get(), &type) && Ready() &&
          SUCCEEDED(automation_->CompareElements(original_.Get(), current.Get(), &same)) && Ready()) {
        *changed_type = type;
        *changed_pid = pid_;  // SafeFocus verified this exact process ID.
        *identity_changed = same == FALSE;
        if (*identity_changed && type == UIA_EditControlTypeId) return true;
      }
      Pump(25);
    }
    return false;
  }
 private:
  bool Ready() {
    auto now = GetTickCount64();
    if (!bounded_ || now >= deadline_ || !monitored_source ||
        !monitored_source->Valid() || foreground_lost || GetForegroundWindow() != source_) return false;
    if (FAILED(bounded_->put_ConnectionTimeout(static_cast<DWORD>(
        std::min<ULONGLONG>(150, deadline_-now))))) return false;
    now = GetTickCount64();
    return now < deadline_ && GetForegroundWindow() == source_ &&
        SUCCEEDED(bounded_->put_TransactionTimeout(static_cast<DWORD>(
            std::min<ULONGLONG>(200, deadline_-now)))) &&
        GetTickCount64() < deadline_ && GetForegroundWindow() == source_;
  }
  bool SafeFocus(IUIAutomationElement* focus, int* type) {
    int owner = 0; BOOL password = TRUE, has_focus = FALSE, offscreen = TRUE;
    return Ready() && SUCCEEDED(focus->get_CurrentProcessId(&owner)) &&
        static_cast<DWORD>(owner) == pid_ && Ready() &&
        SUCCEEDED(focus->get_CurrentIsPassword(&password)) && password == FALSE && Ready() &&
        SUCCEEDED(focus->get_CurrentHasKeyboardFocus(&has_focus)) && has_focus == TRUE && Ready() &&
        SUCCEEDED(focus->get_CurrentIsOffscreen(&offscreen)) && offscreen == FALSE && Ready() &&
        SUCCEEDED(focus->get_CurrentControlType(type)) && Ready();
  }
  HWND source_ = nullptr;
  DWORD pid_ = 0;
  HRESULT initialized_ = E_FAIL;
  ULONGLONG deadline_ = 0;
  int original_type_ = 0;
  Microsoft::WRL::ComPtr<IUIAutomation> automation_;
  Microsoft::WRL::ComPtr<IUIAutomation2> bounded_;
  Microsoft::WRL::ComPtr<IUIAutomationElement> original_;
};
void RejectChangedTarget(HWND window, Driver& driver, Result& result,
                            const std::wstring& mode, const std::wstring& root,
                            const std::wstring& output, const Frame& baseline,
                            RECT text_area, double scale, POINT from, POINT to,
                            DWORD clipboard) {
  // This phase runs only after the independent first cold entry has passed.
  // A changed range/control in the source HWND, or a verified source-process
  // foreground-window change, must invalidate the original bound marker.
  driver.ResetRequest();
  Pump(GetDoubleClickTime()+100);
  Mouse(window, from, 0); Mouse(window, from, MOUSEEVENTF_LEFTDOWN);
  Mouse(window, from, MOUSEEVENTF_LEFTUP); Pump(GetDoubleClickTime()+100);
  Drag(window, from, to);
  const auto released = GetTickCount64();
  Mouse(window, POINT{(from.x+to.x)/2, from.y}, 0);
  while (!EntryVisible() && GetTickCount64()-released < 2200) Pump(10);
  Check(EntryVisible() && driver.callbacks == 0, "Cannot establish the stale-selection negative precondition");
  const auto before_change = Frame::Read(window);
  Check(mode == L"edgePdf" ? CompletePdfSelection(baseline, before_change, text_area, scale) :
      ConsoleSelection(root, released, 0, "negativeBeforeMutation"), "Negative precondition did not recreate the original exact selection");
  before_change.Save(output+L"\\"+mode+L"-stale-before.bmp");
  const HWND entry = OwnedEntry(); RECT button{};
  Check(GetWindowRect(entry, &button) != 0, "Stale entry bounds unavailable");
  const POINT center{(button.left+button.right)/2, (button.top+button.bottom)/2};
  std::unique_ptr<KeyboardFocusProof> focus_proof;
  if (mode == L"edgePdf") {
    focus_proof = std::make_unique<KeyboardFocusProof>(window);
    result.stale_original_type = focus_proof->OriginalType();
    result.stale_original_focus_pid = focus_proof->SourcePid();
    result.stale_mutation = "focusedControlChange";
  } else result.stale_mutation = "selectedRangeEndpointChange";
  const auto changed = GetTickCount64();
  result.stale_mutation_tick = changed;
  result.stale_source_window = WindowState::Read(window);
  ChangeTargetWithKeyboard(window, mode == L"edgePdf");
  result.stale_changed = mode == L"edgePdf" ?
      focus_proof->WaitForChangedEdit(&result.stale_changed_type, &result.stale_focus_identity_changed,
          &result.stale_changed_focus_pid) : ConsoleSelection(root, changed, -1, "negativeAfterKeyboard");
  result.stale_focus_metadata_safe = mode == L"edgePdf" && result.stale_changed;
  ObserveForeground();
  result.stale_changed_window = WindowState::Read(GetForegroundWindow());
  result.stale_source_identity_valid = monitored_source && monitored_source->Valid();
  result.stale_same_source = result.stale_changed_window.window == window && !foreground_lost &&
      result.stale_source_identity_valid;
  if (mode == L"edgePdf" && result.stale_changed_window.window &&
      result.stale_changed_window.window != window) {
    // An Edge PDF version may put Find in another top-level widget. This is
    // explicitly a SOURCE-FOREGROUND change, never claimed as same-HWND focus
    // or text-range mutation. Do not query its UIA, send input, or screenshot it.
    result.stale_mutation = "sourceForegroundWindowChange";
    result.stale_focus_metadata_safe = false;
    result.stale_focus_identity_changed = false;
    result.stale_changed_focus_pid = 0;
    result.stale_changed_type = 0;
    result.stale_foreground_known_source = result.stale_source_identity_valid &&
        result.stale_changed_window.pid == monitored_source->pid &&
        result.stale_changed_window.visible &&
        result.stale_changed_window.root == result.stale_changed_window.window;
    result.stale_changed = result.stale_foreground_known_source;
    result.stale_screenshot_omission = "sourceNoLongerForeground";
  }
  const bool source_window_changed = result.stale_mutation == "sourceForegroundWindowChange";
  // Preserve the screenshot guard exactly: never capture a background source
  // or the new/unknown foreground. Metadata replaces those two negative images.
  if (!source_window_changed && GetForegroundWindow() == window)
    Frame::Read(window).Save(output+L"\\"+mode+L"-stale-changed.bmp");
  std::printf("DESKTOP_ENTRY_KEYBOARD_MUTATION|%s|method=%s|changed=%d|sameSource=%d|beforeType=%d|afterType=%d|before=%s|after=%s\n",
      result.id.c_str(), result.stale_mutation.c_str(), result.stale_changed ? 1 : 0,
      result.stale_same_source ? 1 : 0, result.stale_original_type, result.stale_changed_type,
      result.stale_source_window.Json().c_str(), result.stale_changed_window.Json().c_str());
  Check(result.stale_changed, "Keyboard mutation did not prove a changed range, focused Edit, or verified source-process foreground window");
  Check(source_window_changed ? result.stale_foreground_known_source : result.stale_same_source,
      "Keyboard mutation moved to an unverified foreground or lost the same-window identity");
  // The regular metadata poll may already have dismissed the stale entry.
  // If still present, use a real click, never a fabricated window message.
  if (!source_window_changed && EntryVisible() && WindowFromPoint(center) == entry) {
    result.stale_no_post_mutation_input = false;
    Mouse(window, center, 0);
    if (EntryVisible() && WindowFromPoint(center) == entry) {
      result.stale_click_attempted = true;
      Mouse(window, center, MOUSEEVENTF_LEFTDOWN);
      Mouse(window, center, MOUSEEVENTF_LEFTUP);
    }
  }
  const auto deadline = GetTickCount64()+2500;
  while (GetTickCount64() < deadline &&
      ((driver.callbacks > 0 && !driver.captured->done.load(std::memory_order_acquire)) || EntryVisible())) Pump(10);
  result.stale_callbacks = driver.callbacks;
  if (driver.callbacks == 0) {
    result.stale_status = "entryDismissed";
    result.stale_rejected = !EntryVisible() && driver.capture_calls == 0;
  } else if (driver.captured->done.load(std::memory_order_acquire) && driver.captured->canceled.load()) {
    // Mirror the real channel consumer: a finished-but-invalidated request is
    // discarded without consuming its text. A done flag is not authorization.
    result.stale_status = "canceledBeforeConsumption";
    result.stale_rejected = driver.callbacks == 1 && driver.capture_calls == 1;
  } else if (driver.captured->done.load(std::memory_order_acquire)) {
    const auto& selection = driver.captured->selection;
    result.stale_status = selection.status;
    result.stale_rejected = driver.callbacks == 1 && driver.capture_calls == 1 &&
        selection.status != "ok" && selection.text.empty() && !selection.copy_proof;
  }
  Check(result.stale_rejected, "Old entry returned text after its verified source target or foreground changed");
  Check(driver.correct_source && NoMainWindow() && ClipboardUnchanged(clipboard) &&
      (source_window_changed ? (result.stale_no_post_mutation_input && driver.callbacks == 0 &&
          driver.capture_calls == 0 && !EntryVisible()) : !foreground_lost),
      "Stale-target rejection captured text, changed clipboard or violated the foreground boundary");
  if (!source_window_changed)
    Frame::Read(window).Save(output+L"\\"+mode+L"-stale-rejected.bmp");
}
std::wstring Environment(const wchar_t* name) {
  const DWORD count = GetEnvironmentVariableW(name, nullptr, 0);
  if (count == 0 || count > 32768) return {};
  std::vector<wchar_t> value(count);
  const DWORD copied = GetEnvironmentVariableW(name, value.data(), count);
  return copied && copied < count ? std::wstring(value.data(), copied) : std::wstring{};
}
bool UnderRunnerTemp(const std::wstring& value) {
  wchar_t path[32768]{}, parent[32768]{};
  const auto temp = Environment(L"RUNNER_TEMP");
  if (temp.empty()) return false;
  const DWORD size = GetFullPathNameW(value.c_str(), 32768, path, nullptr);
  const DWORD parent_size = GetFullPathNameW(temp.c_str(), 32768, parent, nullptr);
  if (!size || size >= 32768 || !parent_size || parent_size >= 32768) return false;
  std::wstring base = Lower(parent);
  if (base.back() != L'\\') base += L'\\';
  const std::wstring full = Lower(path);
  return full.size() > base.size() && full.compare(0, base.size(), base) == 0;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  // The executable checks independently of the wrapper, including fixture mode.
  // A user desktop or arbitrary executable location is never an input target.
  wchar_t self[32768]{};
  if (Environment(L"GITHUB_ACTIONS") != L"true" ||
      Environment(L"BAOCODE_DISPOSABLE_UI_TEST") != L"1" ||
      Environment(L"OS") != L"Windows_NT" ||
      !GetModuleFileNameW(nullptr, self, 32768) || !UnderRunnerTemp(self)) return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (argc == 4 && std::wstring(argv[1]) == L"--console-fixture") {
    if (!UnderRunnerTemp(argv[3])) return 2;
    const int code = ConsoleFixture(argv[2], argv[3]);
    std::ofstream exited((std::wstring(argv[3])+L".exit").c_str()); exited << code << '\n';
    return code;
  }
  if (argc == 5 && std::wstring(argv[1]) == L"--console-integrity-probe") {
    if (!UnderRunnerTemp(argv[4])) return 2;
    return ConsoleIntegrityProbe(argv[2], argv[3], argv[4]);
  }
  if (argc != 6 || !UnderRunnerTemp(argv[4])) return 2;
  const std::wstring mode = argv[1], token = argv[2], output = argv[3], app_image = argv[5];
  std::wstring root = argv[4];
  Result result; result.id = mode == L"edgePdf" ? "edgePdf" : "console";
  HWND window = nullptr; Child console; SourceIdentity identity;
  Driver driver;
  DWORD clipboard = 0;
  try {
    Check(mode == L"edgePdf" || mode == L"console", "Unknown desktop entry case");
    result.runner_integrity = translation_test_fixture::Integrity(GetCurrentProcess());
    Check(result.runner_integrity != 0, "Cannot read runner integrity");
    IntegrityEvidence evidence;
    if (mode == L"console") {
      evidence = ProbeIntegritySeparately(token, output, root, result);
      // Only this newly-created synthetic IPC directory receives explicit
      // same-user medium access. Never modify an existing directory or policy.
      const std::wstring ipc = root+L"-ipc";
      translation_test_fixture::FixtureIpcSecurity security;
      Check(CreateDirectoryW(ipc.c_str(), security.get()) != 0,
          "Cannot create a fresh private medium-label console fixture directory");
      root = ipc+L"\\console";
      CheckConsoleProofSharing(root);
    }
    int cell_x = 0, cell_y = 0;
    window = mode == L"console" ? ConsoleSource(token, root, console, cell_x, cell_y, result, &evidence) :
        WaitForSource(token, L"msedge.exe");
    if (mode == L"console") Check(result.source_integrity == SECURITY_MANDATORY_MEDIUM_RID &&
        result.host_integrity == SECURITY_MANDATORY_MEDIUM_RID,
        "Positive console source and host must actually be medium integrity");
    identity.Bind(window, mode == L"console" ? std::wstring(self) : app_image);
    result.source_image_path = ProcessImagePath(identity.process);
    result.source_integrity = translation_test_fixture::Integrity(identity.process);
    Foreground(window);
    monitored_source = &identity;
    clipboard = SeedClipboard(window);
    Frame before;
    RECT text_area{};
    double pdf_scale = 1;
    POINT from{}, to{};
    if (mode == L"edgePdf") {
      std::optional<RECT> marker;
      for (int i = 0; i < 80 && !marker; ++i) {
        before = Frame::Read(window); marker = before.PdfMarker(); if (!marker) Pump(150);
      }
      Check(marker.has_value(), "Local synthetic PDF did not visibly render its marker");
      pdf_scale = static_cast<double>(marker->bottom-marker->top)/18.0;
      // This is the single exact gesture established by the separate desktop
      // capture probe. Never retry a failed entry after warming accessibility.
      from = PdfGlyphAnchor(before, *marker, pdf_scale, -2);
      const LONG left = marker->left+static_cast<LONG>(12*pdf_scale);
      const LONG width = static_cast<LONG>(static_cast<double>(wcslen(kPdfText))*10.8*pdf_scale);
      to = POINT{before.rect.left+left+width-2, from.y};
      text_area = RECT{left, marker->top, left+width, marker->bottom};
      Check(to.x < before.rect.right-10, "PDF viewport too narrow for the verified gesture");
      // This ordinary click only focuses the synthetic page. No accessibility
      // or production action has been initialized at this point.
      const POINT focus{from.x+static_cast<LONG>(30*pdf_scale), from.y};
      Mouse(window, focus, 0); Mouse(window, focus, MOUSEEVENTF_LEFTDOWN);
      Mouse(window, focus, MOUSEEVENTF_LEFTUP); Pump(GetDoubleClickTime()+100);
    } else {
      POINT origin{}; Check(ClientToScreen(window, &origin) != 0, "Console grid unavailable");
      from = POINT{origin.x+4*cell_x+cell_x/2, origin.y+2*cell_y+cell_y/2};
      to = POINT{from.x+(static_cast<LONG>(wcslen(kConsoleText))-1)*cell_x, from.y};
    }
    before = Frame::Read(window);
    before.Save(output+L"\\"+mode+L"-before.bmp");
    Arm(driver, window);
    Pump(250);
    Check(!EntryVisible() && driver.callbacks == 0 && driver.capture_calls == 0,
        "Enabling the action captured source or showed an entry without a selection");
    result.gesture_attempts = 1;
    const auto began = GetTickCount64();
    Drag(window, from, to);
    const auto released = GetTickCount64();
    // Keep the real pointer on selected source text until entry readiness. The
    // production action, not this harness, makes the first provider/UIA call.
    Mouse(window, POINT{(from.x+to.x)/2, from.y}, 0);
    while (!EntryVisible() && GetTickCount64()-released < 2200) Pump(10);
    result.entry_ms = GetTickCount64()-released;
    result.entry_visible = EntryVisible();
    result.callbacks_before_click = driver.callbacks;
    result.no_main_window = NoMainWindow();
    const Frame selected = Frame::Read(window);
    selected.Save(output+L"\\"+mode+L"-entry.bmp");
    result.selection_before_click = mode == L"edgePdf" ?
        CompletePdfSelection(before, selected, text_area, pdf_scale) : ConsoleSelection(root, released, 0, "positiveBeforeClick");
    Check(result.selection_before_click, "The single cold gesture did not retain the exact synthetic selection");
    Check(result.entry_visible, "Cold desktop selection did not show the production translation entry");
    Check(result.callbacks_before_click == 0 && driver.capture_calls == 0,
        "Mouse release captured/transmitted text before the explicit entry click");
    Check(result.no_main_window && !foreground_lost && identity.Valid(),
        "Entry creation opened a main window or took source foreground");
    const HWND entry = OwnedEntry(); RECT button{};
    const auto style = GetWindowLongPtrW(entry, GWL_EXSTYLE);
    result.entry_nonactivating = (style & WS_EX_NOACTIVATE) && (style & WS_EX_TOOLWINDOW);
    Check(result.entry_nonactivating, "Production entry lacks nonactivating tool-window styles");
    Check(GetWindowRect(entry, &button) != 0 &&
        button.left >= selected.rect.left && button.top >= selected.rect.top &&
        button.right <= selected.rect.right && button.bottom <= selected.rect.bottom,
        "Entry screenshot does not include the entire production entry");
    const POINT center{(button.left+button.right)/2, (button.top+button.bottom)/2};
    Check(WindowFromPoint(center) == entry, "Entry is obscured; refusing an unverified mouse click");
    Check(ClipboardUnchanged(clipboard), "Selection/entry discovery changed the clipboard");
    Mouse(window, center, 0); Mouse(window, center, MOUSEEVENTF_LEFTDOWN);
    Pump(40);
    Check(driver.callbacks == 0 && !foreground_lost, "Entry mouse-down captured text or activated a window");
    Mouse(window, center, MOUSEEVENTF_LEFTUP);
    Check(driver.callbacks == 1 && driver.capture_calls == 1 && driver.capture_requested,
        "Physical entry click did not request pinned-selection capture exactly once");
    Check(driver.callback_error.empty(), "Pinned-selection capture request failed");
    const auto clicked = GetTickCount64();
    while (!driver.captured->done.load(std::memory_order_acquire) && GetTickCount64()-clicked < 6000) Pump(10);
    Check(driver.captured->done.load(std::memory_order_acquire), "Entry capture did not finish within its bound");
    result.request_not_canceled = !driver.captured->canceled.load();
    Check(result.request_not_canceled, "Finished entry request was invalidated before UI consumption");
    const auto& captured = *driver.captured;
    result.capture_ms = captured.elapsed; result.status = captured.selection.status;
    result.units = captured.selection.text.size();
    result.proof = captured.selection.copy_proof.has_value();
    result.exact = captured.selection.text == (mode == L"edgePdf" ? kPdfText : kConsoleText);
    result.callback_source = driver.correct_source && captured.foreground_before && captured.foreground_after;
    result.entry_hidden = driver.hidden_at_callback && !EntryVisible();
    result.callbacks = driver.callbacks; result.capture_calls = driver.capture_calls;
    Pump(300);
    const auto after_time = GetTickCount64();
    const Frame after = Frame::Read(window);
    after.Save(output+L"\\"+mode+L"-after-click.bmp");
    result.selection_after_click = mode == L"edgePdf" ?
        CompletePdfSelection(before, after, text_area, pdf_scale) : ConsoleSelection(root, after_time, 0, "positiveAfterClick");
    result.clipboard = ClipboardUnchanged(clipboard);
    result.foreground_preserved = !foreground_lost && identity.Valid() && GetForegroundWindow() == window;
    result.no_main_window = result.no_main_window && NoMainWindow();
    std::printf("DESKTOP_ENTRY_TEXT|%s|actual=%s|elapsedSinceDragMs=%llu\n", result.id.c_str(),
        Quote(captured.selection.text).c_str(), static_cast<unsigned long long>(GetTickCount64()-began));
    Check(result.status == "ok" && result.exact && !captured.selection.self && !result.proof,
        "Entry capture did not return exactly the selected synthetic text, or incorrectly enabled copy fallback");
    Check(result.callback_source && result.entry_hidden && driver.callbacks == 1 && driver.capture_calls == 1,
        "Entry click targeted another source, left the entry open, or captured more than once");
    Check(result.selection_after_click,
        "Post-click selection proof failed freshness/exact-selection requirements; see CONSOLE_SELECTION_PROOF or PDF highlight logs");
    Check(result.clipboard, "Entry click changed the synthetic clipboard");
    Check(result.foreground_preserved, "Entry click lost the verified source foreground");
    Check(result.no_main_window, "Entry click opened an unexpected main window");
    result.request_not_canceled = !captured.canceled.load();
    Check(result.request_not_canceled, "Finished request was canceled before acceptance");
    driver.action->ReleaseClickedSelection(captured.accepted_generation);
    RejectChangedTarget(window, driver, result, mode, root, output,
        before, text_area, pdf_scale, from, to, clipboard);
    result.outcome = "exactEntryCaptured";
    result.detail = "Single cold drag showed a nonactivating entry; only its physical click captured exact selected text, excluding decoy, with selection/foreground/clipboard preserved. A later independently verified keyboard target/foreground change invalidated the stale entry; mutationKind records its exact scope. Native pinned-entry selection only; Flutter popup/model routing is separate coverage.";
  } catch (const std::exception& error) {
    result.detail = error.what();
    if (!result.exact) { result.callbacks = driver.callbacks; result.capture_calls = driver.capture_calls; }
    if (clipboard) result.clipboard = ClipboardUnchanged(clipboard);
    if (window && identity.Valid() && GetForegroundWindow() == window) {
      try { Frame::Read(window).Save(output+L"\\"+mode+L"-failed.bmp"); } catch (...) {}
    }
  }
  driver.captured->canceled.store(true);
  driver.action.reset(); current_driver = nullptr; monitored_source = nullptr;
  try { result.Save(output+L"\\"+mode+L".json"); }
  catch (const std::exception& error) { std::fprintf(stderr, "Result write failed: %s\n", error.what()); return 1; }
  std::printf("DESKTOP_ENTRY|%s|%s|status=%s|callbacks=%u|clipboardUnchanged=%d|%s\n",
      result.id.c_str(), result.outcome.c_str(), result.status.c_str(), result.callbacks,
      result.clipboard ? 1 : 0, result.detail.c_str());
  // Close only the pinned synthetic browser HWND, never a stale HWND/PID.
  if (mode == L"edgePdf" && identity.Valid()) {
    wchar_t title[512]{}; GetWindowTextW(window, title, 512);
    if (std::wstring(title).find(token) != std::wstring::npos) PostMessageW(window, WM_CLOSE, 0, 0);
  }
  return result.outcome == "exactEntryCaptured" ? 0 : 1;
}
