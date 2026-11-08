// Disposable Windows CI only. Real installed desktop applications, synthetic
// documents, production read-only selection capture. Never injects Ctrl+C.
#include "../../windows/runner/translation_selection.h"
#include <dwmapi.h>
#include <tlhelp32.h>
#include <algorithm>
#include <cstdio>
#include <cwctype>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <vector>
#include <utility>

namespace {
constexpr wchar_t kNotepadText[] = L"Notepad selected synthetic Echo";
constexpr wchar_t kPdfText[] = L"PDF selected synthetic Echo";
constexpr wchar_t kConsoleText[] = L"Console selected synthetic Echo";
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
struct Result {
  std::string id, outcome = "failed", status = "notRun", detail;
  std::string fallback = "notEligible";
  std::wstring source_image_path, host_image_path;
  bool host_identity_verified = false;
  bool selected = false, clipboard = false, proof = false;
  unsigned long long elapsed = 0;
  ULONGLONG capture_finished = 0;
  size_t units = 0;
  unsigned gesture_attempts = 0;
  translation_selection::CaptureDiagnostics diagnostics;
  void Save(const std::wstring& path) const {
    std::ofstream file(path.c_str());
    Check(file.good(), "Cannot write desktop result JSON");
    file << "{\n  \"id\":" << Quote(id) << ",\n  \"outcome\":" << Quote(outcome)
         << ",\n  \"sourceImagePath\":" << Quote(source_image_path)
         << ",\n  \"hostImagePath\":" << Quote(host_image_path)
         << ",\n  \"hostIdentityVerified\":" << (host_identity_verified ? "true" : "false")
         << ",\n  \"captureStatus\":" << Quote(status) << ",\n  \"detail\":" << Quote(detail)
         << ",\n  \"gestureAttempts\":" << gesture_attempts
         << ",\n  \"selectionVerified\":" << (selected ? "true" : "false")
         << ",\n  \"clipboardUnchanged\":" << (clipboard ? "true" : "false")
         << ",\n  \"copyProof\":" << (proof ? "true" : "false")
         << ",\n  \"nativeCopyFallback\":" << Quote(fallback)
         << ",\n  \"elapsedMs\":" << elapsed << ",\n  \"units\":" << units
         << ",\n  \"failureStage\":" << Quote(diagnostics.last_failure_stage)
         << ",\n  \"hresult\":" << static_cast<unsigned long>(diagnostics.last_failure)
         << ",\n  \"attempts\":" << diagnostics.attempts
         << ",\n  \"finalAttempts\":" << diagnostics.final_attempts << "\n}\n";
    file.close(); Check(!file.fail(), "Cannot finish desktop result JSON");
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
void Key(HWND window, WORD key, bool control = false, bool shift = false) {
  Check(GetForegroundWindow() == window, "Refusing input after synthetic source lost foreground");
  INPUT input[6]{}; UINT count = 0;
  const auto add = [&](WORD code, DWORD flags) {
    input[count].type = INPUT_KEYBOARD; input[count].ki.wVk = code;
    input[count].ki.dwFlags = flags; ++count;
  };
  if (control) add(VK_CONTROL, 0);
  if (shift) add(VK_SHIFT, 0);
  add(key, 0); add(key, KEYEVENTF_KEYUP);
  if (shift) add(VK_SHIFT, KEYEVENTF_KEYUP);
  if (control) add(VK_CONTROL, KEYEVENTF_KEYUP);
  Check(SendInput(count, input, sizeof(INPUT)) == count, "Synthetic selection keyboard input failed");
  Sleep(120);
}
void Mouse(HWND window, POINT point, DWORD flags) {
  Check(GetForegroundWindow() == window, "Refusing mouse input after synthetic source lost foreground");
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  Check(width > 1 && height > 1, "Interactive desktop unavailable");
  INPUT input{}; input.type = INPUT_MOUSE;
  input.mi.dx = MulDiv(point.x-GetSystemMetrics(SM_XVIRTUALSCREEN), 65535, width-1);
  input.mi.dy = MulDiv(point.y-GetSystemMetrics(SM_YVIRTUALSCREEN), 65535, height-1);
  input.mi.dwFlags = flags | MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  Check(SendInput(1, &input, sizeof(INPUT)) == 1, "Synthetic selection mouse input failed");
}
void Drag(HWND window, POINT from, POINT to) {
  Mouse(window, from, 0); Sleep(60); Mouse(window, from, MOUSEEVENTF_LEFTDOWN);
  for (int i = 1; i <= 24; ++i) {
    Mouse(window, POINT{from.x+(to.x-from.x)*i/24, from.y+(to.y-from.y)*i/24}, 0); Sleep(20);
  }
  Mouse(window, to, MOUSEEVENTF_LEFTUP); Sleep(250);
}
DWORD SeedClipboard(HWND window) {
  Check(OpenClipboard(window) != 0, "Cannot seed synthetic clipboard");
  const wchar_t value[] = L"BaoCode desktop coverage clipboard decoy";
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
bool NotepadSelectionMetadata(HWND window, size_t units) {
  DWORD pid = 0; const DWORD thread = GetWindowThreadProcessId(window, &pid);
  GUITHREADINFO info{}; info.cbSize = sizeof(info);
  if (GetGUIThreadInfo(thread, &info) && info.hwndFocus && GetAncestor(info.hwndFocus, GA_ROOT) == window) {
    wchar_t cls[128]{}; GetClassNameW(info.hwndFocus, cls, 128);
    const auto name = Lower(cls);
    if (name == L"edit" || name == L"richedit20w" || name == L"richedit50w" || name == L"richeditd2dpt") {
      DWORD start = 0, end = 0; DWORD_PTR ignored = 0;
      if (SendMessageTimeoutW(info.hwndFocus, EM_GETSEL, reinterpret_cast<WPARAM>(&start),
          reinterpret_cast<LPARAM>(&end), SMTO_ABORTIFHUNG, 500, &ignored) && start == 0 && end == units) return true;
    }
  }
  // After the production call only: metadata verification may warm accessibility,
  // but is never used to produce the source or rerun a failed capture.
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return false;
  bool selected = false;
  {
    Microsoft::WRL::ComPtr<IUIAutomation> uia;
    Microsoft::WRL::ComPtr<IUIAutomationElement> focus;
    Microsoft::WRL::ComPtr<IUIAutomationTextPattern> pattern;
    Microsoft::WRL::ComPtr<IUIAutomationTextRangeArray> ranges;
    if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)))) {
      Microsoft::WRL::ComPtr<IUIAutomation2> bounded;
      if (SUCCEEDED(uia.As(&bounded))) { bounded->put_ConnectionTimeout(200); bounded->put_TransactionTimeout(300); }
      int owner = 0; BOOL focused = FALSE, password = TRUE;
      if (SUCCEEDED(uia->GetFocusedElement(&focus)) && focus && SUCCEEDED(focus->get_CurrentProcessId(&owner)) &&
          static_cast<DWORD>(owner) == pid && SUCCEEDED(focus->get_CurrentHasKeyboardFocus(&focused)) && focused &&
          SUCCEEDED(focus->get_CurrentIsPassword(&password)) && !password &&
          SUCCEEDED(focus->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern))) && pattern &&
          SUCCEEDED(pattern->GetSelection(&ranges)) && ranges) {
        int count = 0;
        if (SUCCEEDED(ranges->get_Length(&count)) && count == 1) {
          Microsoft::WRL::ComPtr<IUIAutomationTextRange> range; int difference = 0;
          selected = SUCCEEDED(ranges->GetElement(0, &range)) && range &&
              SUCCEEDED(range->CompareEndpoints(TextPatternRangeEndpoint_Start, range.Get(), TextPatternRangeEndpoint_End, &difference)) && difference != 0;
        }
      }
    }
  }
  CoUninitialize(); return selected;
}
void PointParentMetadata(std::ofstream& out, IUIAutomation* uia,
                         IUIAutomationElement* original_focus, HWND source,
                         DWORD source_pid, bool original_focus_safe,
                         IUIAutomationElement* current_focus = nullptr,
                         IUIAutomationElement* starting_element = nullptr) {
  POINT point{}; const bool have_point = GetCursorPos(&point) != 0;
  out << ",\n  \"pointer\":[" << point.x << ',' << point.y << ']'
      << ",\n  \"pointerAvailable\":" << (have_point ? "true" : "false");
  Microsoft::WRL::ComPtr<IUIAutomationElement> hit;
  HRESULT hit_hr = E_ABORT;
  if (GetForegroundWindow() == source) {
    if (starting_element) { hit = starting_element; hit_hr = S_OK; }
    else if (have_point) hit_hr = uia->ElementFromPoint(point, &hit);
  }
  out << ",\n  \"chainOrigin\":" << Quote(starting_element ? std::string("providedElement") : std::string("currentPointer"))
      << ",\n  \"startingElementHRESULT\":" << static_cast<unsigned long>(hit_hr);
  if (!starting_element) out << ",\n  \"pointHRESULT\":" << static_cast<unsigned long>(hit_hr);
  if (FAILED(hit_hr) || !hit) return;
  for (int view = 0; view < 2; ++view) {
    Microsoft::WRL::ComPtr<IUIAutomationTreeWalker> walker;
    const HRESULT walker_hr = view ? uia->get_ControlViewWalker(&walker) : uia->get_RawViewWalker(&walker);
    out << (view ? ",\n  \"controlParentChain\":[" : ",\n  \"rawParentChain\":[");
    Microsoft::WRL::ComPtr<IUIAutomationElement> element = hit;
    const ULONGLONG deadline = GetTickCount64()+4000;
    for (int depth = 0; SUCCEEDED(walker_hr) && walker && element && depth < 8 &&
        GetTickCount64() < deadline && GetForegroundWindow() == source; ++depth) {
      int pid = 0; CONTROLTYPEID type = 0; BOOL has_focus = FALSE, password = TRUE, same = FALSE;
      const HRESULT pid_hr = element->get_CurrentProcessId(&pid);
      const HRESULT type_hr = element->get_CurrentControlType(&type);
      const HRESULT focus_hr = element->get_CurrentHasKeyboardFocus(&has_focus);
      const HRESULT password_hr = element->get_CurrentIsPassword(&password);
      const HRESULT same_hr = uia->CompareElements(original_focus, element.Get(), &same);
      BSTR cls = nullptr, framework = nullptr;
      const HRESULT class_hr = element->get_CurrentClassName(&cls);
      const HRESULT framework_hr = element->get_CurrentFrameworkId(&framework);
      if (depth) out << ',';
      out << "{\"depth\":" << depth << ",\"pid\":" << pid
          << ",\"pidHRESULT\":" << static_cast<unsigned long>(pid_hr)
          << ",\"controlType\":" << type << ",\"typeHRESULT\":" << static_cast<unsigned long>(type_hr)
          << ",\"hasKeyboardFocus\":" << (has_focus ? "true" : "false")
          << ",\"focusHRESULT\":" << static_cast<unsigned long>(focus_hr)
          << ",\"isPassword\":" << (password ? "true" : "false")
          << ",\"passwordHRESULT\":" << static_cast<unsigned long>(password_hr)
          << ",\"sameAsOriginalFocus\":" << (same ? "true" : "false")
          << ",\"compareFocusHRESULT\":" << static_cast<unsigned long>(same_hr)
          << ",\"className\":" << Quote(cls ? std::wstring(cls, SysStringLen(cls)) : std::wstring{})
          << ",\"classHRESULT\":" << static_cast<unsigned long>(class_hr)
          << ",\"frameworkId\":" << Quote(framework ? std::wstring(framework, SysStringLen(framework)) : std::wstring{})
          << ",\"frameworkHRESULT\":" << static_cast<unsigned long>(framework_hr);
      SysFreeString(cls); SysFreeString(framework);
      if (current_focus) {
        BOOL current_same = FALSE;
        const HRESULT current_hr = uia->CompareElements(current_focus, element.Get(), &current_same);
        out << ",\"sameAsCurrentFocus\":" << (current_same ? "true" : "false")
            << ",\"compareCurrentFocusHRESULT\":" << static_cast<unsigned long>(current_hr);
      }
      int count = -1, noncollapsed = 0;
      const bool metadata_safe = original_focus_safe && SUCCEEDED(pid_hr) && static_cast<DWORD>(pid) == source_pid &&
          SUCCEEDED(password_hr) && !password && GetForegroundWindow() == source;
      // Children need not own keyboard focus. These are endpoint/count metadata
      // diagnostics only, never authority to read text from a child or its tree.
      if (metadata_safe) {
        Microsoft::WRL::ComPtr<IUIAutomationTextPattern> pattern;
        const HRESULT pattern_hr = element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern));
        out << ",\"patternHRESULT\":" << static_cast<unsigned long>(pattern_hr);
        if (SUCCEEDED(pattern_hr) && pattern) {
          Microsoft::WRL::ComPtr<IUIAutomationTextRangeArray> ranges;
          const HRESULT selection_hr = pattern->GetSelection(&ranges);
          const HRESULT count_hr = ranges ? ranges->get_Length(&count) : E_POINTER;
          out << ",\"selectionHRESULT\":" << static_cast<unsigned long>(selection_hr)
              << ",\"selectionCountHRESULT\":" << static_cast<unsigned long>(count_hr);
          for (int i = 0; SUCCEEDED(selection_hr) && SUCCEEDED(count_hr) && count <= 16 && i < count; ++i) {
            Microsoft::WRL::ComPtr<IUIAutomationTextRange> range; int difference = 0;
            if (SUCCEEDED(ranges->GetElement(i, &range)) && range &&
                SUCCEEDED(range->CompareEndpoints(TextPatternRangeEndpoint_Start, range.Get(), TextPatternRangeEndpoint_End, &difference)) && difference != 0) ++noncollapsed;
          }
        }
      }
      out << ",\"selectionCount\":" << count << ",\"nonCollapsedRanges\":" << noncollapsed;
      std::printf("DESKTOP_POST_CAPTURE_POINT|view=%s|depth=%d|pid=%d|type=%d|hasFocus=%d|password=%d|sameFocus=%d|ranges=%d|nonCollapsed=%d\n",
          view ? "control" : "raw", depth, pid, type, has_focus, password, same, count, noncollapsed);
      if ((SUCCEEDED(same_hr) && same) || FAILED(pid_hr) || static_cast<DWORD>(pid) != source_pid ||
          FAILED(password_hr) || password) { out << '}'; break; }
      Microsoft::WRL::ComPtr<IUIAutomationElement> parent;
      const HRESULT parent_hr = walker->GetParentElement(element.Get(), &parent);
      out << ",\"parentHRESULT\":" << static_cast<unsigned long>(parent_hr) << '}';
      if (FAILED(parent_hr) || !parent) break;
      element = parent;
    }
    out << ']';
  }
}
void DelayedFocusMetadata(std::ofstream& out, IUIAutomation* uia,
                          IUIAutomationElement* initial_focus, HWND source,
                          DWORD initial_pid, bool initial_safe, ULONGLONG capture_finished) {
  out << ",\n  \"delayedObservations\":[";
  const DWORD delays[] = {200, 500, 1000, 2000};
  for (size_t index = 0; index < sizeof(delays)/sizeof(delays[0]); ++index) {
    const ULONGLONG target = capture_finished+delays[index];
    while (GetTickCount64() < target && GetForegroundWindow() == source) Sleep(5);
    const bool foreground = GetForegroundWindow() == source;
    const auto observed = static_cast<unsigned long long>(GetTickCount64()-capture_finished);
    if (index) out << ',';
    out << "{\"scheduledAfterCaptureMs\":" << delays[index] << ",\"observedAfterCaptureMs\":" << observed
        << ",\"foregroundMatches\":" << (foreground ? "true" : "false");
    Microsoft::WRL::ComPtr<IUIAutomationElement> focus;
    const HRESULT focus_hr = foreground ? uia->GetFocusedElement(&focus) : E_ABORT;
    out << ",\"focusHRESULT\":" << static_cast<unsigned long>(focus_hr);
    if (SUCCEEDED(focus_hr) && focus) {
      BOOL same = FALSE, has_focus = FALSE, password = TRUE; int pid = 0; CONTROLTYPEID type = 0;
      const HRESULT same_hr = uia->CompareElements(initial_focus, focus.Get(), &same);
      const HRESULT pid_hr = focus->get_CurrentProcessId(&pid);
      const HRESULT type_hr = focus->get_CurrentControlType(&type);
      const HRESULT has_focus_hr = focus->get_CurrentHasKeyboardFocus(&has_focus);
      const HRESULT password_hr = focus->get_CurrentIsPassword(&password);
      out << ",\"sameAsInitialDiagnosticFocus\":" << (same ? "true" : "false")
          << ",\"compareIdentityHRESULT\":" << static_cast<unsigned long>(same_hr)
          << ",\"pid\":" << pid << ",\"pidHRESULT\":" << static_cast<unsigned long>(pid_hr)
          << ",\"controlType\":" << type << ",\"typeHRESULT\":" << static_cast<unsigned long>(type_hr)
          << ",\"hasKeyboardFocus\":" << (has_focus ? "true" : "false")
          << ",\"hasFocusHRESULT\":" << static_cast<unsigned long>(has_focus_hr)
          << ",\"isPassword\":" << (password ? "true" : "false")
          << ",\"passwordHRESULT\":" << static_cast<unsigned long>(password_hr);
      const bool safe = initial_safe && SUCCEEDED(same_hr) && same && SUCCEEDED(pid_hr) &&
          static_cast<DWORD>(pid) == initial_pid && SUCCEEDED(has_focus_hr) && has_focus &&
          SUCCEEDED(password_hr) && !password && GetForegroundWindow() == source;
      out << ",\"selectionMetadataEligible\":" << (safe ? "true" : "false");
      int count = -1, noncollapsed = 0;
      if (safe) {
        Microsoft::WRL::ComPtr<IUIAutomationTextPattern> pattern;
        const HRESULT pattern_hr = focus->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern));
        out << ",\"patternHRESULT\":" << static_cast<unsigned long>(pattern_hr);
        if (SUCCEEDED(pattern_hr) && pattern) {
          Microsoft::WRL::ComPtr<IUIAutomationTextRangeArray> ranges;
          const HRESULT selected_hr = pattern->GetSelection(&ranges);
          const HRESULT count_hr = ranges ? ranges->get_Length(&count) : E_POINTER;
          out << ",\"getSelectionHRESULT\":" << static_cast<unsigned long>(selected_hr)
              << ",\"selectionCountHRESULT\":" << static_cast<unsigned long>(count_hr);
          for (int i = 0; SUCCEEDED(selected_hr) && SUCCEEDED(count_hr) && count <= 16 && i < count; ++i) {
            Microsoft::WRL::ComPtr<IUIAutomationTextRange> range; int difference = 0;
            if (SUCCEEDED(ranges->GetElement(i, &range)) && range &&
                SUCCEEDED(range->CompareEndpoints(TextPatternRangeEndpoint_Start, range.Get(), TextPatternRangeEndpoint_End, &difference)) && difference != 0) ++noncollapsed;
          }
        }
      }
      out << ",\"selectionCount\":" << count << ",\"nonCollapsedRanges\":" << noncollapsed;
      std::printf("DESKTOP_DELAYED_UIA|scheduledMs=%lu|observedMs=%llu|sameIdentity=%d|pid=%d|type=%d|hasFocus=%d|password=%d|ranges=%d|nonCollapsed=%d\n",
          delays[index], observed, same, pid, type, has_focus, password, count, noncollapsed);
      // A single test-only transition snapshot at 500 ms distinguishes a new
      // focused Group from replacement of the initial Document's UIA object.
      // The held original reference is never rebound. Counts/endpoint metadata
      // may be inspected without HasFocus, but only for same-PID, non-password
      // elements while the synthetic source remains foreground.
      const bool transition_safe = initial_safe && SUCCEEDED(pid_hr) && static_cast<DWORD>(pid) == initial_pid &&
          SUCCEEDED(has_focus_hr) && has_focus && SUCCEEDED(password_hr) && !password && GetForegroundWindow() == source;
      if (delays[index] == 500 && transition_safe) {
        out << ",\"transitionSnapshot\":{\"focusReference\":\"heldInitialPostCaptureDocument\"";
        out << ",\"pinnedOriginal\":{\"reference\":\"unchangedOriginalObject\"";
        PointParentMetadata(out, uia, initial_focus, source, initial_pid, initial_safe, focus.Get(), initial_focus);
        out << "},\"newFocusAncestors\":{\"reference\":\"current500msFocus\"";
        PointParentMetadata(out, uia, initial_focus, source, initial_pid, initial_safe, focus.Get(), focus.Get());
        out << "},\"pointerAncestors\":{\"reference\":\"currentPointer\"";
        PointParentMetadata(out, uia, initial_focus, source, initial_pid, initial_safe, focus.Get());
        out << "}}";
      }
    }
    out << ",\"completedAfterCaptureMs\":" << static_cast<unsigned long long>(GetTickCount64()-capture_finished) << '}';
    if (!foreground || GetForegroundWindow() != source) break;
  }
  out << ']';
}
struct HostWindowMembership {
  HWND source = nullptr; DWORD current_thread = 0, matching_thread = 0;
  unsigned window_count = 0; bool found = false;
};
BOOL CALLBACK MatchExactHostWindow(HWND window, LPARAM parameter) {
  auto& evidence = *reinterpret_cast<HostWindowMembership*>(parameter);
  ++evidence.window_count;
  if (window == evidence.source) { evidence.found = true; evidence.matching_thread = evidence.current_thread; }
  return TRUE; // Compare handles only. Never read window contents or captions.
}
void ConsoleKernelOwnershipMetadata(std::ofstream& out, HWND source,
                                    DWORD reported_thread, DWORD verified_host_pid) {
  DWORD owner = 0, open_error = ERROR_SUCCESS, owner_error = ERROR_SUCCESS;
  HANDLE thread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, reported_thread);
  if (thread) {
    owner = GetProcessIdOfThread(thread);
    if (!owner) owner_error = GetLastError();
    CloseHandle(thread);
  } else open_error = GetLastError();
  std::wstring image; DWORD process_open_error = ERROR_SUCCESS, image_error = ERROR_SUCCESS;
  if (owner) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, owner);
    if (process) {
      image = ProcessImagePath(process);
      if (image.empty()) image_error = GetLastError();
      CloseHandle(process);
    } else process_open_error = GetLastError();
  }
  HostWindowMembership evidence; evidence.source = source;
  DWORD snapshot_error = ERROR_SUCCESS, first_error = ERROR_SUCCESS, enumeration_error = ERROR_SUCCESS;
  unsigned host_threads = 0; bool capped = false;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if (snapshot == INVALID_HANDLE_VALUE) snapshot_error = GetLastError();
  else {
    THREADENTRY32 entry{}; entry.dwSize = sizeof(entry);
    if (Thread32First(snapshot, &entry)) do {
      // No window enumeration for any other process. The target PID was pinned
      // and verified during this test's explicit system-conhost launch.
      if (entry.th32OwnerProcessID != verified_host_pid) continue;
      if (host_threads >= 128) { capped = true; break; }
      ++host_threads; evidence.current_thread = entry.th32ThreadID;
      SetLastError(ERROR_SUCCESS);
      if (!EnumThreadWindows(entry.th32ThreadID, MatchExactHostWindow, reinterpret_cast<LPARAM>(&evidence))) {
        const DWORD error = GetLastError(); if (error) enumeration_error = error;
      }
    } while (Thread32Next(snapshot, &entry));
    else first_error = GetLastError();
    CloseHandle(snapshot);
  }
  out << ",\n  \"consoleKernelOwnership\":{\"reportedThreadId\":" << reported_thread
      << ",\"openThreadError\":" << open_error << ",\"kernelThreadOwnerPid\":" << owner
      << ",\"getProcessIdOfThreadError\":" << owner_error
      << ",\"kernelThreadOwnerImagePath\":" << Quote(image)
      << ",\"openOwnerProcessError\":" << process_open_error << ",\"ownerImageQueryError\":" << image_error
      << ",\"kernelOwnerMatchesVerifiedHost\":" << (owner && owner == verified_host_pid ? "true" : "false")
      << ",\"hostThreadSnapshotError\":" << snapshot_error << ",\"hostThreadFirstError\":" << first_error
      << ",\"enumThreadWindowsError\":" << enumeration_error << ",\"hostThreadsEnumerated\":" << host_threads
      << ",\"hostThreadLimitReached\":" << (capped ? "true" : "false")
      << ",\"hostWindowsCompared\":" << evidence.window_count
      << ",\"membershipFound\":" << (evidence.found ? "true" : "false")
      << ",\"matchingThreadId\":" << evidence.matching_thread << '}';
  std::printf("DESKTOP_CONSOLE_KERNEL|reportedTid=%lu|kernelOwnerPid=%lu|verifiedHostPid=%lu|membershipFound=%d|matchingTid=%lu|threads=%u|windows=%u\n",
      reported_thread, owner, verified_host_pid, evidence.found ? 1 : 0, evidence.matching_thread, host_threads, evidence.window_count);
}
void ConsoleRootMetadata(std::ofstream& out, IUIAutomation* uia,
                         IUIAutomationElement* focus, HWND source,
                         DWORD provider_pid, bool focus_safe) {
  Microsoft::WRL::ComPtr<IUIAutomationElement> root;
  const HRESULT root_hr = GetForegroundWindow() == source ? uia->ElementFromHandle(source, &root) : E_ABORT;
  out << ",\n  \"consoleSourceRoot\":{\"elementFromHandleHRESULT\":" << static_cast<unsigned long>(root_hr);
  if (SUCCEEDED(root_hr) && root) {
    int pid = 0; CONTROLTYPEID type = 0; UIA_HWND native = {};
    BOOL password = TRUE, offscreen = TRUE;
    const HRESULT pid_hr = root->get_CurrentProcessId(&pid);
    const HRESULT native_hr = root->get_CurrentNativeWindowHandle(&native);
    const HRESULT type_hr = root->get_CurrentControlType(&type);
    const HRESULT password_hr = root->get_CurrentIsPassword(&password);
    const HRESULT offscreen_hr = root->get_CurrentIsOffscreen(&offscreen);
    out << ",\"pid\":" << pid << ",\"pidHRESULT\":" << static_cast<unsigned long>(pid_hr)
        << ",\"nativeHandle\":" << reinterpret_cast<uintptr_t>(reinterpret_cast<HWND>(native))
        << ",\"nativeHandleHRESULT\":" << static_cast<unsigned long>(native_hr)
        << ",\"nativeHandleMatchesSource\":" << (reinterpret_cast<HWND>(native) == source ? "true" : "false")
        << ",\"controlType\":" << type << ",\"typeHRESULT\":" << static_cast<unsigned long>(type_hr)
        << ",\"isPassword\":" << (password ? "true" : "false")
        << ",\"passwordHRESULT\":" << static_cast<unsigned long>(password_hr)
        << ",\"isOffscreen\":" << (offscreen ? "true" : "false")
        << ",\"offscreenHRESULT\":" << static_cast<unsigned long>(offscreen_hr)
        << ",\"focusedAncestorsToRoot\":{\"originalComparisonReference\":\"elementFromSourceHwnd\"";
    PointParentMetadata(out, uia, root.Get(), source, provider_pid, focus_safe, focus, focus);
    out << '}';
  }
  out << '}';
}
// Post-capture diagnostics only: never call before the measured production
// capture, never read Name/Value/DocumentRange/GetText, and never change focus.
void SourceSelectionMetadata(HWND source, const std::wstring& path,
                             ULONGLONG capture_finished = 0, bool observe_delayed = false,
                             DWORD verified_console_host_pid = 0) {
  std::ofstream out(path.c_str());
  if (!out) return;
  DWORD source_pid = 0; const DWORD source_thread = GetWindowThreadProcessId(source, &source_pid);
  out << "{\n  \"phase\":\"afterOnlyProductionCapture\",\n  \"focusReference\":\"postCaptureGetFocusedElement\",\n  \"sourcePid\":" << source_pid
      << ",\n  \"foregroundMatches\":" << (GetForegroundWindow() == source ? "true" : "false")
      << ",\n  \"sourceThreadId\":" << source_thread
      << ",\n  \"verifiedConsoleHostPid\":" << verified_console_host_pid;
  if (verified_console_host_pid) ConsoleKernelOwnershipMetadata(out, source, source_thread, verified_console_host_pid);
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  out << ",\n  \"initializeHRESULT\":" << static_cast<unsigned long>(initialized);
  if (SUCCEEDED(initialized)) {
    {
      Microsoft::WRL::ComPtr<IUIAutomation> uia;
      const HRESULT created = CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia));
      out << ",\n  \"automationHRESULT\":" << static_cast<unsigned long>(created);
      if (SUCCEEDED(created) && uia && GetForegroundWindow() == source) {
        Microsoft::WRL::ComPtr<IUIAutomation2> bounded;
        if (SUCCEEDED(uia.As(&bounded))) { bounded->put_ConnectionTimeout(200); bounded->put_TransactionTimeout(300); }
        Microsoft::WRL::ComPtr<IUIAutomationElement> focus;
        const HRESULT focused = uia->GetFocusedElement(&focus);
        out << ",\n  \"focusHRESULT\":" << static_cast<unsigned long>(focused);
        if (SUCCEEDED(focused) && focus) {
          int pid = 0; CONTROLTYPEID type = 0; BOOL has_focus = FALSE, password = TRUE;
          UIA_HWND native = {}; RECT rect{};
          const HRESULT pid_hr = focus->get_CurrentProcessId(&pid);
          const HRESULT type_hr = focus->get_CurrentControlType(&type);
          const HRESULT focus_hr = focus->get_CurrentHasKeyboardFocus(&has_focus);
          const HRESULT password_hr = focus->get_CurrentIsPassword(&password);
          const HRESULT native_hr = focus->get_CurrentNativeWindowHandle(&native);
          const HRESULT bounds_hr = focus->get_CurrentBoundingRectangle(&rect);
          BSTR cls = nullptr, framework = nullptr;
          const HRESULT class_hr = focus->get_CurrentClassName(&cls);
          const HRESULT framework_hr = focus->get_CurrentFrameworkId(&framework);
          out << ",\n  \"focusedPid\":" << pid << ",\n  \"pidHRESULT\":" << static_cast<unsigned long>(pid_hr)
              << ",\n  \"controlType\":" << type << ",\n  \"typeHRESULT\":" << static_cast<unsigned long>(type_hr)
              << ",\n  \"hasKeyboardFocus\":" << (has_focus ? "true" : "false")
              << ",\n  \"focusPropertyHRESULT\":" << static_cast<unsigned long>(focus_hr)
              << ",\n  \"isPassword\":" << (password ? "true" : "false")
              << ",\n  \"passwordHRESULT\":" << static_cast<unsigned long>(password_hr)
              << ",\n  \"nativeHandle\":" << reinterpret_cast<uintptr_t>(reinterpret_cast<HWND>(native))
              << ",\n  \"nativeHandleHRESULT\":" << static_cast<unsigned long>(native_hr)
              << ",\n  \"bounds\":[" << rect.left << ',' << rect.top << ',' << rect.right << ',' << rect.bottom << ']'
              << ",\n  \"boundsHRESULT\":" << static_cast<unsigned long>(bounds_hr)
              << ",\n  \"className\":" << Quote(cls ? std::wstring(cls, SysStringLen(cls)) : std::wstring{})
              << ",\n  \"classHRESULT\":" << static_cast<unsigned long>(class_hr)
              << ",\n  \"frameworkId\":" << Quote(framework ? std::wstring(framework, SysStringLen(framework)) : std::wstring{})
              << ",\n  \"frameworkHRESULT\":" << static_cast<unsigned long>(framework_hr);
          SysFreeString(cls); SysFreeString(framework);
          // Test-only console metadata may come from its separately verified
          // host process. This does not change production's same-PID policy.
          const bool known_provider = static_cast<DWORD>(pid) == source_pid ||
              (verified_console_host_pid && static_cast<DWORD>(pid) == verified_console_host_pid);
          const bool safe = SUCCEEDED(pid_hr) && known_provider &&
              SUCCEEDED(focus_hr) && has_focus && SUCCEEDED(password_hr) && !password && GetForegroundWindow() == source;
          out << ",\n  \"selectionMetadataEligible\":" << (safe ? "true" : "false");
          if (safe) {
            Microsoft::WRL::ComPtr<IUIAutomationTextPattern> pattern;
            const HRESULT pattern_hr = focus->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern));
            out << ",\n  \"textPatternHRESULT\":" << static_cast<unsigned long>(pattern_hr)
                << ",\n  \"textPatternPresent\":" << (pattern ? "true" : "false");
            if (SUCCEEDED(pattern_hr) && pattern) {
              SupportedTextSelection supported = SupportedTextSelection_None;
              const HRESULT support_hr = pattern->get_SupportedTextSelection(&supported);
              Microsoft::WRL::ComPtr<IUIAutomationTextRangeArray> ranges;
              const HRESULT selection_hr = pattern->GetSelection(&ranges);
              int count = -1, noncollapsed = 0;
              const HRESULT count_hr = ranges ? ranges->get_Length(&count) : E_POINTER;
              out << ",\n  \"supportedTextSelection\":" << static_cast<int>(supported)
                  << ",\n  \"supportedSelectionHRESULT\":" << static_cast<unsigned long>(support_hr)
                  << ",\n  \"getSelectionHRESULT\":" << static_cast<unsigned long>(selection_hr)
                  << ",\n  \"selectionCount\":" << count
                  << ",\n  \"selectionCountHRESULT\":" << static_cast<unsigned long>(count_hr)
                  << ",\n  \"ranges\":[";
              for (int i = 0; SUCCEEDED(selection_hr) && SUCCEEDED(count_hr) && count <= 16 && i < count; ++i) {
                Microsoft::WRL::ComPtr<IUIAutomationTextRange> range; int difference = 0;
                const HRESULT range_hr = ranges->GetElement(i, &range);
                const HRESULT compare_hr = SUCCEEDED(range_hr) && range ?
                    range->CompareEndpoints(TextPatternRangeEndpoint_Start, range.Get(), TextPatternRangeEndpoint_End, &difference) : E_POINTER;
                if (SUCCEEDED(compare_hr) && difference != 0) ++noncollapsed;
                if (i) out << ',';
                out << "{\"elementHRESULT\":" << static_cast<unsigned long>(range_hr)
                    << ",\"compareHRESULT\":" << static_cast<unsigned long>(compare_hr)
                    << ",\"endpointDifference\":" << difference << '}';
              }
              out << "],\n  \"nonCollapsedRanges\":" << noncollapsed;
              std::printf("DESKTOP_POST_CAPTURE_UIA|pid=%d|type=%d|hasFocus=%d|password=%d|patternHRESULT=0x%08lX|selectionHRESULT=0x%08lX|ranges=%d|nonCollapsed=%d\n",
                  pid, type, has_focus, password, static_cast<unsigned long>(pattern_hr), static_cast<unsigned long>(selection_hr), count, noncollapsed);
            }
          }
          PointParentMetadata(out, uia.Get(), focus.Get(), source,
              known_provider ? static_cast<DWORD>(pid) : source_pid, safe);
          if (verified_console_host_pid) ConsoleRootMetadata(out, uia.Get(), focus.Get(), source,
              known_provider ? static_cast<DWORD>(pid) : source_pid, safe);
          if (observe_delayed && capture_finished) {
            DelayedFocusMetadata(out, uia.Get(), focus.Get(), source, static_cast<DWORD>(pid), safe, capture_finished);
          }
        }
      }
    }
    CoUninitialize();
  }
  out << "\n}\n";
}
translation_selection::Selection Capture(HWND window, Result& result) {
  const ULONGLONG began = GetTickCount64();
  auto capture = translation_selection::Capture(window, true, nullptr, 0, &result.diagnostics);
  result.capture_finished = GetTickCount64();
  result.elapsed = result.capture_finished-began; result.status = capture.status;
  result.units = capture.text.size(); result.proof = capture.copy_proof.has_value();
  if (capture.copy_proof) result.fallback = translation_clipboard::SafeControl(*capture.copy_proof) ?
      "eligibleButNotExercised" : "proofRejectedBySafetyChecks";
  return capture;
}
void Classify(Result& result, const translation_selection::Selection& capture,
              const wchar_t* expected, bool forbid_copy_proof, DWORD clipboard) {
  result.clipboard = GetClipboardSequenceNumber() == clipboard;
  std::wstring actual = capture.text;
  // A provider may include a line delimiter. Never trim spaces or arbitrary text.
  while (!actual.empty() && (actual.back() == L'\r' || actual.back() == L'\n')) actual.pop_back();
  if (!result.clipboard) result.detail = "Capture or application unexpectedly changed the clipboard";
  else if (forbid_copy_proof && result.proof) result.detail = "Unsafe copy eligibility was returned for PDF or console";
  else if (capture.self) result.detail = "Source was not an independent desktop application";
  else if (capture.status == "ok" && actual == expected) {
    result.outcome = "exactCaptured"; result.selected = true;
    result.detail = "Production UIA capture returned exactly the selected synthetic line; unselected decoy excluded";
  } else if (capture.status == "unsupported" && capture.text.empty() && result.selected) {
    result.outcome = "safeUnsupported";
    result.detail = result.proof ? "Verified selection unavailable through read-only UIA; native-copy fallback eligibility reported but fallback not exercised" :
        "Verified selection safely rejected by production capture; no source returned and no Ctrl+C injected";
  } else if (capture.status == "ok") result.detail = "Captured source did not exactly match the selected synthetic line";
  else if (!result.selected) result.detail = "Selection could not be independently verified; not counted as safeUnsupported";
  else result.detail = "Capture returned a runtime failure or noSelection for a verified synthetic selection";
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
  while (GetTickCount64() < end && GetFileAttributesW((root+L".stop").c_str()) == INVALID_FILE_ATTRIBUTES) {
    CONSOLE_SELECTION_INFO selection{};
    if (GetConsoleSelectionInfo(&selection)) {
      std::ofstream proof((root+L".selection").c_str());
      proof << selection.dwFlags << ' ' << selection.srSelection.Left << ' ' << selection.srSelection.Top << ' '
            << selection.srSelection.Right << ' ' << selection.srSelection.Bottom << '\n';
    }
    Sleep(40);
  }
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
HWND ConsoleSource(const std::wstring& token, const std::wstring& root, Child& child, int& cell_x, int& cell_y, Result& result) {
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
  const BOOL created = CreateProcessW(host.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
      nullptr, nullptr, &startup, &child.value);
  const DWORD create_error = created ? ERROR_SUCCESS : GetLastError();
  std::printf("DESKTOP_CONSOLE_LAUNCH|explicitSystemConhost=1|created=%d|error=%lu|hostPid=%lu\n",
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
  std::printf("DESKTOP_CONSOLE_READY|window=%llu|cell=%d,%d|hostExit=%lu|fixturePid=%lu|fixtureExit=%d\n",
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
  wchar_t title[512]{}; GetWindowTextW(window, title, 512);
  Check(std::wstring(title).find(token) != std::wstring::npos, "Console title identity mismatch");
  return window;
}
bool ConsoleSelection(const std::wstring& root) {
  for (int i = 0; i < 30; ++i) {
    DWORD flags = 0; int left = -1, top = -1, right = -1, bottom = -1;
    std::ifstream proof((root+L".selection").c_str()); proof >> flags >> left >> top >> right >> bottom;
    if (proof && (flags & CONSOLE_SELECTION_NOT_EMPTY) && left == 4 && top == 2 &&
        right == 4+static_cast<int>(wcslen(kConsoleText))-1 && bottom == 2) return true;
    Sleep(50);
  }
  return false;
}
}

int wmain(int argc, wchar_t** argv) {
  wchar_t guard[16]{}, actions[16]{};
  GetEnvironmentVariableW(L"BAOCODE_DISPOSABLE_UI_TEST", guard, 16);
  GetEnvironmentVariableW(L"GITHUB_ACTIONS", actions, 16);
  if (std::wstring(guard) != L"1" || std::wstring(actions) != L"true") return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (argc == 4 && std::wstring(argv[1]) == L"--console-fixture") {
    const int code = ConsoleFixture(argv[2], argv[3]);
    std::ofstream exited((std::wstring(argv[3])+L".exit").c_str()); exited << code << '\n';
    return code;
  }
  if (argc != 5) return 2;
  const std::wstring mode = argv[1], token = argv[2], output = argv[3], root = argv[4];
  Result result; result.id = mode == L"notepad" ? "notepad" : (mode == L"edgePdf" ? "edgePdf" : "console");
  HWND window = nullptr; Child console;
  try {
    Check(mode == L"notepad" || mode == L"edgePdf" || mode == L"console", "Unknown desktop coverage case");
    int cell_x = 0, cell_y = 0;
    window = mode == L"console" ? ConsoleSource(token, root, console, cell_x, cell_y, result) :
        WaitForSource(token, mode == L"notepad" ? L"notepad.exe" : L"msedge.exe");
    result.source_image_path = ImagePath(window);
    Check(!result.source_image_path.empty(), "Captured source executable path could not be verified");
    Foreground(window);
    const DWORD clipboard = SeedClipboard(window);
    if (mode == L"notepad") {
      Key(window, VK_HOME, true); Key(window, VK_END, false, true);
      const auto capture = Capture(window, result);
      result.selected = NotepadSelectionMetadata(window, wcslen(kNotepadText));
      Classify(result, capture, kNotepadText, false, clipboard);
    } else if (mode == L"edgePdf") {
      Frame before; std::optional<RECT> marker;
      for (int i = 0; i < 80 && !marker; ++i) { before = Frame::Read(window); marker = before.PdfMarker(); if (!marker) Sleep(150); }
      Check(marker.has_value(), "Local PDF page did not visibly render its unique fixture marker");
      // At most three real gestures may establish the test precondition. No
      // UIA call is made during this phase. Once Capture starts, there is no
      // recapture or gesture retry that could conceal a product failure.
      for (unsigned attempt = 0; attempt < 3 && !result.selected; ++attempt) {
        result.gesture_attempts = attempt+1;
        before = Frame::Read(window); marker = before.PdfMarker();
        Check(marker.has_value(), "PDF marker disappeared before the selection gesture");
        const double scale = static_cast<double>(marker->bottom-marker->top)/18.0;
        POINT from = PdfGlyphAnchor(before, *marker, scale, attempt == 1 ? -2 : 0);
        const LONG text_left = marker->left+static_cast<LONG>(12*scale);
        const LONG text_width = static_cast<LONG>(static_cast<double>(wcslen(kPdfText))*10.8*scale);
        // Extend beyond the line and slightly below its last glyph, still well
        // above the decoy row. This includes the trailing glyph rather than
        // stopping at its leading boundary in the PDF hit-test implementation.
        POINT to{before.rect.left+text_left+text_width+static_cast<LONG>(48*scale),
                 from.y+static_cast<LONG>(14*scale)};
        Check(to.x < before.rect.right-10, "PDF viewport too small for synthetic drag");
        // Clear any prior gesture selection and give the PDF real pointer focus.
        // The wait prevents the following mouse-down from becoming a double-click.
        Sleep(GetDoubleClickTime()+80);
        const POINT focus{from.x+static_cast<LONG>(30*scale), from.y};
        Mouse(window, focus, 0); Mouse(window, focus, MOUSEEVENTF_LEFTDOWN); Mouse(window, focus, MOUSEEVENTF_LEFTUP);
        Sleep(GetDoubleClickTime()+100); before = Frame::Read(window);
        if (attempt == 1) {
          to = POINT{before.rect.left+text_left+text_width-2, from.y};
        } else if (attempt == 2) {
          // The next line's leading boundary extends through the first line's
          // trailing glyph. The proof below rejects ANY decoy-row highlight.
          to = POINT{before.rect.left+text_left, from.y+static_cast<LONG>(60*scale)};
        }
        before.Save(output+L"\\edgePdf-before-gesture"+std::to_wstring(attempt+1)+L".bmp");
        Drag(window, from, to);
        // Leave the real pointer over the selected PDF text, without clicking.
        // Post-capture point/parent metadata can then describe this exact point.
        Mouse(window, POINT{before.rect.left+text_left+text_width/2, from.y}, 0); Sleep(300);
        const auto after = Frame::Read(window);
        const RECT text_area{text_left, marker->top, text_left+text_width, marker->bottom};
        result.selected = CompletePdfSelection(before, after, text_area, scale);
        std::printf("DESKTOP_PDF_GESTURE|attempt=%u|from=%ld,%ld|to=%ld,%ld|scale=%.3f|selectionVerified=%d\n",
            attempt+1, from.x, from.y, to.x, to.y, scale, result.selected ? 1 : 0);
        after.Save(output+L"\\edgePdf-gesture"+std::to_wstring(attempt+1)+L".bmp");
        after.Save(output+L"\\edgePdf-selected.bmp");
      }
      Check(result.selected, "PDF gesture did not create a verifiable visible selection; production capture was not attempted");
      const auto capture = Capture(window, result);
      Classify(result, capture, kPdfText, true, clipboard);
      SourceSelectionMetadata(window, output+L"\\edgePdf-uia-metadata.json", result.capture_finished, true);
    } else {
      POINT origin{}; Check(ClientToScreen(window, &origin) != 0, "Console text grid unavailable");
      const POINT from{origin.x+4*cell_x+cell_x/2, origin.y+2*cell_y+cell_y/2};
      const POINT to{from.x+(static_cast<LONG>(wcslen(kConsoleText))-1)*cell_x, from.y};
      result.gesture_attempts = 1;
      Drag(window, from, to);
      result.selected = ConsoleSelection(root);
      Check(result.selected, "Console gesture did not select the exact synthetic rectangle; production capture was not attempted");
      const auto capture = Capture(window, result);
      Classify(result, capture, kConsoleText, true, clipboard);
      SourceSelectionMetadata(window, output+L"\\console-uia-metadata.json", result.capture_finished, false,
          result.host_identity_verified ? console.value.dwProcessId : 0);
    }
    Check(GetForegroundWindow() == window, "Synthetic source lost foreground during capture");
    Frame::Read(window).Save(output+L"\\"+mode+L"-result.bmp");
  } catch (const std::exception& error) {
    result.outcome = "failed"; result.detail = error.what();
    if (window && GetForegroundWindow() == window) {
      try { Frame::Read(window).Save(output+L"\\"+mode+L"-failed.bmp"); } catch (...) {}
    }
  }
  try { result.Save(output+L"\\"+mode+L".json"); }
  catch (const std::exception& error) { std::fprintf(stderr, "Cannot save coverage result: %s\n", error.what()); return 1; }
  std::printf("DESKTOP_CAPTURE|%s|%s|status=%s|selectionVerified=%d|clipboardUnchanged=%d|copyProof=%d|elapsedMs=%llu|%s\n",
      result.id.c_str(), result.outcome.c_str(), result.status.c_str(), result.selected ? 1 : 0,
      result.clipboard ? 1 : 0, result.proof ? 1 : 0, result.elapsed, result.detail.c_str());
  if (window && mode != L"console") PostMessageW(window, WM_CLOSE, 0, 0);
  return result.outcome == "failed" ? 1 : 0;
}
