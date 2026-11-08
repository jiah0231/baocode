// Disposable Windows CI only. Real installed desktop applications, synthetic
// documents, production read-only selection capture. Never injects Ctrl+C.
#include "../../windows/runner/translation_selection.h"
#include <dwmapi.h>
#include <algorithm>
#include <cstdio>
#include <cwctype>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <vector>

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
  std::wstring source_image_path;
  bool selected = false, clipboard = false, proof = false;
  unsigned long long elapsed = 0;
  size_t units = 0;
  translation_selection::CaptureDiagnostics diagnostics;
  void Save(const std::wstring& path) const {
    std::ofstream file(path.c_str());
    Check(file.good(), "Cannot write desktop result JSON");
    file << "{\n  \"id\":" << Quote(id) << ",\n  \"outcome\":" << Quote(outcome)
         << ",\n  \"sourceImagePath\":" << Quote(source_image_path)
         << ",\n  \"captureStatus\":" << Quote(status) << ",\n  \"detail\":" << Quote(detail)
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
      if (b > 90 && g > 90 && r > 70 && (255-b)+(255-g)+(255-r) >= 35) ++highlighted;
    }
  }
  return white >= 200 && highlighted >= white/8;
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
translation_selection::Selection Capture(HWND window, Result& result) {
  const ULONGLONG began = GetTickCount64();
  auto capture = translation_selection::Capture(window, true, nullptr, 0, &result.diagnostics);
  result.elapsed = GetTickCount64()-began; result.status = capture.status;
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
  const HWND window = GetConsoleWindow();
  if (!window || !IsWindowVisible(window)) return 3;
  SetConsoleTitleW(token.c_str());
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE), input = GetStdHandle(STD_INPUT_HANDLE);
  CONSOLE_FONT_INFOEX font{}; font.cbSize = sizeof(font); font.dwFontSize.Y = 20;
  font.FontFamily = FF_DONTCARE; font.FontWeight = FW_NORMAL; wcscpy_s(font.FaceName, L"Consolas");
  SetCurrentConsoleFontEx(output, FALSE, &font);
  SMALL_RECT visible{0, 0, 79, 19}; SetConsoleWindowInfo(output, TRUE, &visible);
  SetConsoleScreenBufferSize(output, COORD{80, 20});
  DWORD mode = 0;
  if (!GetConsoleMode(input, &mode) || !SetConsoleMode(input, (mode | ENABLE_EXTENDED_FLAGS | ENABLE_QUICK_EDIT_MODE) & ~ENABLE_MOUSE_INPUT)) return 4;
  CONSOLE_CURSOR_INFO cursor{25, FALSE}; SetConsoleCursorInfo(output, &cursor);
  DWORD written = 0; FillConsoleOutputCharacterW(output, L' ', 1600, COORD{0, 0}, &written);
  SetConsoleCursorPosition(output, COORD{4, 2}); WriteConsoleW(output, kConsoleText, static_cast<DWORD>(wcslen(kConsoleText)), &written, nullptr);
  const wchar_t decoy[] = L"Unselected console output decoy";
  SetConsoleCursorPosition(output, COORD{4, 4}); WriteConsoleW(output, decoy, static_cast<DWORD>(wcslen(decoy)), &written, nullptr);
  CONSOLE_FONT_INFO current{};
  if (!GetCurrentConsoleFont(output, FALSE, &current)) return 5;
  const COORD size = GetConsoleFontSize(output, current.nFont);
  {
    std::ofstream ready((root+L".ready").c_str());
    ready << reinterpret_cast<uintptr_t>(window) << ' ' << size.X << ' ' << size.Y << '\n';
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
  PROCESS_INFORMATION value{}; std::wstring root;
  ~Child() {
    if (value.hProcess) {
      if (!root.empty()) { std::ofstream stop((root+L".stop").c_str()); stop << "stop\n"; }
      if (WaitForSingleObject(value.hProcess, 2000) == WAIT_TIMEOUT) {
        // This is the handle returned when creating our synthetic fixture only.
        TerminateProcess(value.hProcess, 1); WaitForSingleObject(value.hProcess, 1000);
      }
      CloseHandle(value.hProcess); CloseHandle(value.hThread);
    }
  }
};
HWND ConsoleSource(const std::wstring& token, const std::wstring& root, Child& child, int& cell_x, int& cell_y) {
  wchar_t executable[32768]{}; Check(GetModuleFileNameW(nullptr, executable, 32768) != 0, "Cannot locate console fixture executable");
  std::wstring command = L"\""+std::wstring(executable)+L"\" --console-fixture \""+token+L"\" \""+root+L"\"";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup); child.root = root;
  Check(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, CREATE_NEW_CONSOLE, nullptr, nullptr, &startup, &child.value) != 0, "Cannot start isolated native console host");
  uintptr_t handle = 0;
  for (int i = 0; i < 100 && !handle; ++i) {
    std::ifstream ready((root+L".ready").c_str()); ready >> handle >> cell_x >> cell_y; Sleep(100);
    if (WaitForSingleObject(child.value.hProcess, 0) == WAIT_OBJECT_0 && !handle) break;
  }
  HWND window = reinterpret_cast<HWND>(handle);
  Check(window && IsWindowVisible(window) && cell_x > 0 && cell_y > 0, "Classic console host unavailable or fixture initialization failed; Windows Terminal is not substituted");
  Check(HasImage(window, L"conhost.exe"), "Console fixture window is not the real Windows conhost.exe");
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
  if (argc == 4 && std::wstring(argv[1]) == L"--console-fixture") return ConsoleFixture(argv[2], argv[3]);
  if (argc != 5) return 2;
  const std::wstring mode = argv[1], token = argv[2], output = argv[3], root = argv[4];
  Result result; result.id = mode == L"notepad" ? "notepad" : (mode == L"edgePdf" ? "edgePdf" : "console");
  HWND window = nullptr; Child console;
  try {
    Check(mode == L"notepad" || mode == L"edgePdf" || mode == L"console", "Unknown desktop coverage case");
    int cell_x = 0, cell_y = 0;
    window = mode == L"console" ? ConsoleSource(token, root, console, cell_x, cell_y) :
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
      // PDF marker is x=60, y=696, width=6, height=18 points. Text starts x=72
      // on baseline y=700. Derive page scale from pixels, not browser toolbar size.
      const double scale = static_cast<double>(marker->bottom-marker->top)/18.0;
      const POINT from{before.rect.left+marker->left+static_cast<LONG>(12*scale),
                       before.rect.top+marker->top+static_cast<LONG>(9*scale)};
      const POINT to{from.x+static_cast<LONG>(360*scale), from.y};
      Check(to.x < before.rect.right-10, "PDF viewport too small for synthetic drag");
      const POINT focus{from.x+static_cast<LONG>(30*scale), from.y};
      Mouse(window, focus, 0); Mouse(window, focus, MOUSEEVENTF_LEFTDOWN); Mouse(window, focus, MOUSEEVENTF_LEFTUP);
      Sleep(GetDoubleClickTime()+100); before = Frame::Read(window);
      Drag(window, from, to);
      Mouse(window, POINT{before.rect.left+20, before.rect.bottom-20}, 0); Sleep(300);
      const auto after = Frame::Read(window);
      const RECT text_area{from.x-before.rect.left, marker->top,
          from.x-before.rect.left+static_cast<LONG>(static_cast<double>(wcslen(kPdfText))*10.8*scale), marker->bottom};
      result.selected = VisiblePdfSelection(before, after, text_area);
      after.Save(output+L"\\edgePdf-selected.bmp");
      const auto capture = Capture(window, result);
      Classify(result, capture, kPdfText, true, clipboard);
    } else {
      POINT origin{}; Check(ClientToScreen(window, &origin) != 0, "Console text grid unavailable");
      const POINT from{origin.x+4*cell_x+cell_x/2, origin.y+2*cell_y+cell_y/2};
      const POINT to{from.x+(static_cast<LONG>(wcslen(kConsoleText))-1)*cell_x, from.y};
      Drag(window, from, to);
      result.selected = ConsoleSelection(root);
      const auto capture = Capture(window, result);
      Classify(result, capture, kConsoleText, true, clipboard);
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
