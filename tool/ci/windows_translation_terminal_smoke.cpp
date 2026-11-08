// Disposable Windows Actions only. Real Windows Terminal, no shell, settings
// edits, installations, copied text, or model calls. No accessibility warm-up.
#include "../../windows/runner/translation_selection.h"
#include <dwmapi.h>
#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace {
constexpr wchar_t kText[] = L"Terminal selected synthetic Echo";
constexpr int kUnits = static_cast<int>(sizeof(kText)/sizeof(wchar_t))-1;
constexpr int kColumn = 4, kRow = 4;
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
};
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
  const wchar_t value[] = L"BaoCode terminal coverage clipboard decoy";
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(value));
  void* bytes = memory ? GlobalLock(memory) : nullptr;
  if (!bytes) { if (memory) GlobalFree(memory); CloseClipboard(); throw std::runtime_error("Clipboard allocation failed"); }
  memcpy(bytes, value, sizeof(value)); GlobalUnlock(memory);
  const bool emptied = EmptyClipboard() != 0;
  const bool written = emptied && SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
  if (!written) GlobalFree(memory);
  CloseClipboard(); Check(written, "Synthetic clipboard seed failed");
  const DWORD sequence = GetClipboardSequenceNumber();
  Check(sequence != 0, "Clipboard sequence tracking is unavailable"); return sequence;
}

std::wstring Environment(const wchar_t* name) {
  wchar_t value[32768]{};
  const DWORD size = GetEnvironmentVariableW(name, value, 32768);
  return size && size < 32768 ? std::wstring(value, size) : std::wstring{};
}
std::wstring FullPath(const std::wstring& path) {
  wchar_t full[32768]{};
  const DWORD count = GetFullPathNameW(path.c_str(), 32768, full, nullptr);
  Check(count && count < 32768, "Invalid test path");
  return std::wstring(full, count);
}
bool WithinTemp(const std::wstring& path) {
  auto temp = FullPath(Environment(L"RUNNER_TEMP"));
  if (temp.back() != L'\\') temp += L'\\';
  const auto full = FullPath(path);
  return full.size() > temp.size() && _wcsnicmp(full.c_str(), temp.c_str(), temp.size()) == 0;
}
std::wstring ProcessImage(HANDLE process) {
  wchar_t value[32768]{}; DWORD count = 32768;
  return QueryFullProcessImageNameW(process, 0, value, &count) ?
      std::wstring(value, count) : std::wstring{};
}
std::wstring OwnImage() {
  wchar_t value[32768]{};
  const DWORD count = GetModuleFileNameW(nullptr, value, 32768);
  Check(count && count < 32768, "Cannot resolve test executable");
  return std::wstring(value, count);
}
bool SamePath(const std::wstring& first, const std::wstring& second) {
  return !first.empty() && !second.empty() && _wcsicmp(first.c_str(), second.c_str()) == 0;
}
std::wstring WindowImage(HWND window) {
  DWORD pid = 0; GetWindowThreadProcessId(window, &pid);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return {};
  const auto image = ProcessImage(process); CloseHandle(process); return image;
}
struct Windows {
  std::wstring image;
  std::vector<HWND> handles;
  static BOOL CALLBACK Collect(HWND window, LPARAM value) {
    auto& self = *reinterpret_cast<Windows*>(value);
    // Do not read any window title or UIA Name/Value to find our source.
    if (IsWindowVisible(window) && SamePath(WindowImage(window), self.image))
      self.handles.push_back(window);
    return TRUE;
  }
  static std::vector<HWND> Read(const std::wstring& image) {
    Windows self{image, {}};
    Check(EnumWindows(Collect, reinterpret_cast<LPARAM>(&self)) != 0,
          "Cannot enumerate Windows Terminal window metadata");
    return self.handles;
  }
};

// Four solid, uniquely colored fixture cells calibrate the real renderer. No
// text inspection, assumed font size, UIA ranges, or terminal settings are used.
struct Grid {
  LONG left = 0, top = 0, width = 0, height = 0;
};
std::optional<RECT> Marker(const Frame& frame, int red, int green, int blue) {
  RECT rect{frame.width, frame.height, 0, 0}; size_t count = 0;
  for (int y = 0; y < frame.height; ++y) for (int x = 0; x < frame.width; ++x) {
    const auto i = (static_cast<size_t>(y)*frame.width+x)*4;
    if (abs(frame.pixels[i]-blue) <= 2 && abs(frame.pixels[i+1]-green) <= 2 &&
        abs(frame.pixels[i+2]-red) <= 2) {
      rect.left = std::min<LONG>(rect.left, x); rect.top = std::min<LONG>(rect.top, y);
      rect.right = std::max<LONG>(rect.right, x+1); rect.bottom = std::max<LONG>(rect.bottom, y+1); ++count;
    }
  }
  const LONG width = rect.right-rect.left, height = rect.bottom-rect.top;
  if (width < 4 || width > 40 || height < 8 || height > 80 ||
      count < static_cast<size_t>(width*height)*95/100) return std::nullopt;
  return rect;
}
std::optional<Grid> FixtureGrid(const Frame& frame) {
  const auto a = Marker(frame, 255, 0, 255), b = Marker(frame, 0, 255, 255);
  const auto c = Marker(frame, 255, 255, 0), d = Marker(frame, 0, 255, 0);
  if (!a || !b || !c || !d) return std::nullopt;
  const LONG w = a->right-a->left, h = a->bottom-a->top;
  for (const auto& rect : {*b, *c, *d}) {
    if (rect.right-rect.left != w || rect.bottom-rect.top != h) return std::nullopt;
  }
  if (b->left-a->left != (kUnits-1)*w || c->left != a->left || d->left != b->left ||
      a->top != b->top || c->top != d->top || c->top-a->top != 4*h) return std::nullopt;
  const Grid grid{a->left, a->top+2*h, w, h};
  if (grid.left-kColumn*w < 0 || grid.top-kRow*h < 0 ||
      grid.left+(kUnits+2)*w >= frame.width || grid.top+6*h >= frame.height) return std::nullopt;
  return grid;
}
int PixelDifference(const Frame& first, const Frame& second, LONG x, LONG y) {
  const auto i = (static_cast<size_t>(y)*first.width+x)*4;
  return abs(first.pixels[i]-second.pixels[i]) + abs(first.pixels[i+1]-second.pixels[i+1]) +
      abs(first.pixels[i+2]-second.pixels[i+2]);
}
bool ExactVisualSelection(const Frame& before, const Frame& after, const Grid& grid,
                          const std::wstring& proof_path) {
  std::ofstream proof{std::filesystem::path(proof_path)};
  Check(proof.good(), "Cannot write independent selection proof");
  if (!EqualRect(&before.rect, &after.rect) || before.width != after.width || before.height != after.height) {
    proof << "{\"verified\":false,\"reason\":\"frameMoved\"}\n"; return false;
  }
  bool selected = true;
  proof << "{\n  \"method\":\"exactFixtureCellPixelDifference\",\n  \"row\":" << kRow
        << ",\n  \"firstColumn\":" << kColumn << ",\n  \"lastColumn\":" << kColumn+kUnits-1
        << ",\n  \"cellWidth\":" << grid.width << ",\n  \"cellHeight\":" << grid.height
        << ",\n  \"selectedCells\":[";
  for (int cell = 0; cell < kUnits; ++cell) {
    size_t background = 0, changed = 0;
    for (LONG y = grid.top; y < grid.top+grid.height; ++y)
      for (LONG x = grid.left+cell*grid.width; x < grid.left+(cell+1)*grid.width; ++x) {
        const auto i = (static_cast<size_t>(y)*before.width+x)*4;
        if (abs(before.pixels[i]-24) <= 2 && abs(before.pixels[i+1]-16) <= 2 && abs(before.pixels[i+2]-8) <= 2) {
          ++background;
          if (PixelDifference(before, after, x, y) >= 45) ++changed;
        }
      }
    const bool highlighted = background >= static_cast<size_t>(grid.width*grid.height)/3 &&
        changed >= background*95/100;
    selected = selected && highlighted;
    if (cell) proof << ',';
    proof << "{\"backgroundPixels\":" << background << ",\"changedPixels\":" << changed
          << ",\"highlighted\":" << (highlighted ? "true" : "false") << '}';
  }
  // Check the complete nearby fixture, including prefix/suffix cells, marker
  // rows, and all decoy characters. An overlong, wrong-row, or multi-row drag
  // must fail before production Capture. The cursor is hidden by the fixture.
  size_t outside_changed = 0;
  for (LONG y = grid.top-kRow*grid.height; y < grid.top+6*grid.height; ++y)
    for (LONG x = grid.left-kColumn*grid.width; x < grid.left+(kUnits+2)*grid.width; ++x) {
      if (y >= grid.top && y < grid.top+grid.height && x >= grid.left && x < grid.left+kUnits*grid.width) continue;
      if (PixelDifference(before, after, x, y) >= 45) ++outside_changed;
    }
  selected = selected && outside_changed == 0;
  proof << "],\n  \"outsideChangedPixels\":" << outside_changed
        << ",\n  \"verified\":" << (selected ? "true" : "false") << "\n}\n";
  proof.close(); Check(!proof.fail(), "Selection proof was not saved"); return selected;
}

void VisualProofSelfTest(const std::wstring& root) {
  Frame before; before.width = 400; before.height = 200; before.rect = RECT{0, 0, 400, 200};
  before.pixels.resize(static_cast<size_t>(before.width)*before.height*4);
  const auto paint = [](Frame& frame, RECT area, int red, int green, int blue) {
    for (LONG y = area.top; y < area.bottom; ++y) for (LONG x = area.left; x < area.right; ++x) {
      const auto i = (static_cast<size_t>(y)*frame.width+x)*4;
      frame.pixels[i] = static_cast<unsigned char>(blue);
      frame.pixels[i+1] = static_cast<unsigned char>(green);
      frame.pixels[i+2] = static_cast<unsigned char>(red);
    }
  };
  paint(before, before.rect, 8, 16, 24);
  constexpr LONG x = 40, y = 32, w = 8, h = 16;
  paint(before, RECT{x, y, x+w, y+h}, 255, 0, 255);
  paint(before, RECT{x+(kUnits-1)*w, y, x+kUnits*w, y+h}, 0, 255, 255);
  paint(before, RECT{x, y+4*h, x+w, y+5*h}, 255, 255, 0);
  paint(before, RECT{x+(kUnits-1)*w, y+4*h, x+kUnits*w, y+5*h}, 0, 255, 0);
  const auto grid = FixtureGrid(before);
  Check(grid.has_value(), "Visual self-test failed: valid marker grid rejected");
  const RECT expected{x, y+2*h, x+kUnits*w, y+3*h};
  Frame exact = before; paint(exact, expected, 255, 255, 255);
  const auto verify = [&](const Frame& frame, const wchar_t* name) {
    return ExactVisualSelection(before, frame, *grid, root+L".visual-"+name+L".json");
  };
  Check(verify(exact, L"exact"), "Visual self-test failed: exact selection rejected");
  Check(!verify(before, L"none"), "Visual self-test failed: no selection accepted");
  Frame missing = exact; paint(missing, RECT{x, expected.top, x+w, expected.bottom}, 8, 16, 24);
  Check(!verify(missing, L"missing-cell"), "Visual self-test failed: missing selected cell accepted");
  Frame extra = exact; paint(extra, RECT{expected.right, expected.top, expected.right+w, expected.bottom}, 255, 255, 255);
  Check(!verify(extra, L"extra-cell"), "Visual self-test failed: extra selected cell accepted");
  Frame wrong = before; paint(wrong, RECT{x, expected.top+h, expected.right, expected.bottom+h}, 255, 255, 255);
  Check(!verify(wrong, L"wrong-row"), "Visual self-test failed: wrong selected row accepted");
  Frame decoy = exact; paint(decoy, RECT{x, expected.top+4*h, expected.right, expected.bottom+4*h}, 255, 255, 255);
  Check(!verify(decoy, L"decoy"), "Visual self-test failed: selected decoy accepted");
  Frame moved = exact; ++moved.rect.left;
  Check(!verify(moved, L"moved"), "Visual self-test failed: moved source accepted");
  Frame bad_marker = before; paint(bad_marker, RECT{x, y, x+w, y+h}, 8, 16, 24);
  Check(!FixtureGrid(bad_marker).has_value(), "Visual self-test failed: missing marker accepted");
  std::printf("TERMINAL_VISUAL_PROOF_SELF_TEST|8 passed\n");
}

int Fixture(const std::wstring& root) {
  std::ofstream trace((root+L".fixture.log").c_str());
  try {
    Check(WithinTemp(root), "Fixture files must be inside RUNNER_TEMP");
    const auto session = Environment(L"WT_SESSION");
    Check(!session.empty(), "Fixture was not launched in a Windows Terminal session");
    DWORD attached[8]{};
    const DWORD count = GetConsoleProcessList(attached, 8);
    Check(count == 1 && attached[0] == GetCurrentProcessId(), "Fixture console is not exclusive; refusing to write");
    const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    Check(GetConsoleMode(output, &mode) && SetConsoleMode(output, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING),
          "Fixture virtual terminal output unavailable");
    CONSOLE_SCREEN_BUFFER_INFO screen{};
    Check(GetConsoleScreenBufferInfo(output, &screen) != 0, "Fixture viewport unavailable");
    const int columns = screen.srWindow.Right-screen.srWindow.Left+1;
    const int rows = screen.srWindow.Bottom-screen.srWindow.Top+1;
    Check(columns >= 70 && rows >= 14, "Fixture viewport too small");
    // Only this direct child writes output; no prompt, shell, input reader, or
    // selection API. Coordinates below are 1-based ANSI equivalents of Grid.
    const std::wstring reset = L"\x1b[38;2;240;240;240m\x1b[48;2;8;16;24m";
    const std::wstring right = std::to_wstring(kColumn+kUnits);
    std::wstring screen_text = reset+L"\x1b[2J\x1b[H\x1b[?25l";
    screen_text += L"\x1b[3;5H\x1b[48;2;255;0;255m ";
    screen_text += L"\x1b[3;"+right+L"H\x1b[48;2;0;255;255m ";
    screen_text += L"\x1b[7;5H\x1b[48;2;255;255;0m ";
    screen_text += L"\x1b[7;"+right+L"H\x1b[48;2;0;255;0m ";
    screen_text += reset+L"\x1b[5;5H"+kText;
    screen_text += L"\x1b[9;5HUnselected terminal decoy\x1b[12;1H";
    DWORD written = 0;
    Check(WriteConsoleW(output, screen_text.data(), static_cast<DWORD>(screen_text.size()), &written, nullptr) &&
          written == screen_text.size(), "Fixture output incomplete");
    FILETIME created{}, exited{}, kernel{}, user{};
    Check(GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user) != 0, "Fixture process timestamp unavailable");
    trace << "fixturePid=" << GetCurrentProcessId() << " exclusiveConsoleProcesses=" << count
          << " columns=" << columns << " rows=" << rows << " terminalSession=" << Quote(session) << std::endl;
    {
      std::ofstream ready((root+L".ready").c_str());
      ready << GetCurrentProcessId() << ' ' << created.dwHighDateTime << ' ' << created.dwLowDateTime << ' '
            << columns << ' ' << rows << '\n';
      Check(ready.good(), "Fixture readiness write failed");
    }
    const auto end = GetTickCount64()+60000;
    while (GetTickCount64() < end && GetFileAttributesW((root+L".stop").c_str()) == INVALID_FILE_ATTRIBUTES) Sleep(40);
    trace << "cleanExit=1\n"; return 0;
  } catch (const std::exception& error) {
    trace << "failed=" << error.what() << std::endl; return 1;
  }
}

struct Session {
  std::wstring root, source_image;
  PROCESS_INFORMATION launcher{};
  HANDLE fixture = nullptr, source_process = nullptr;
  HWND source = nullptr;
  bool identity_verified = false;
  ~Session() {
    // Never kill a WindowsTerminal process: it can own unrelated windows.
    // The stop file and verified fixture handle affect only our direct client.
    if (!root.empty()) { std::ofstream stop((root+L".stop").c_str()); stop << "stop\n"; }
    if (fixture) {
      if (WaitForSingleObject(fixture, 2500) == WAIT_TIMEOUT) {
        TerminateProcess(fixture, 1); WaitForSingleObject(fixture, 1000);
      }
      CloseHandle(fixture);
    }
    if (source_process) {
      DWORD pid = 0; GetWindowThreadProcessId(source, &pid);
      if (identity_verified && WaitForSingleObject(source_process, 0) == WAIT_TIMEOUT &&
          pid == GetProcessId(source_process) && SamePath(WindowImage(source), source_image))
        PostMessageW(source, WM_CLOSE, 0, 0);
      CloseHandle(source_process);
    }
    if (launcher.hProcess) { CloseHandle(launcher.hProcess); CloseHandle(launcher.hThread); }
  }
  void BindFixture() {
    DWORD pid = 0, high = 0, low = 0; int columns = 0, rows = 0;
    for (int i = 0; i < 200; ++i) {
      std::ifstream ready((root+L".ready").c_str());
      if (ready >> pid >> high >> low >> columns >> rows) break;
      pid = 0; Sleep(100);
    }
    Check(pid && columns >= 70 && rows >= 14, "Terminal fixture did not become ready");
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | PROCESS_TERMINATE, FALSE, pid);
    Check(process != nullptr, "Cannot retain owned terminal fixture process");
    FILETIME created{}, exited{}, kernel{}, user{};
    const bool owned = SamePath(ProcessImage(process), OwnImage()) &&
        GetProcessTimes(process, &created, &exited, &kernel, &user) &&
        created.dwHighDateTime == high && created.dwLowDateTime == low &&
        WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    if (!owned) CloseHandle(process);
    Check(owned, "Fixture PID/image/creation identity mismatch"); fixture = process;
  }
};

struct Result {
  std::string outcome = "failed", status = "notRun", detail;
  std::wstring source_image;
  bool selected = false, clipboard = false, proof = false;
  DWORD source_pid = 0, fixture_pid = 0;
  size_t units = 0;
  ULONGLONG elapsed = 0;
  translation_selection::CaptureDiagnostics diagnostics;
  void Save(const std::wstring& path) const {
    std::ofstream file(path.c_str()); Check(file.good(), "Cannot save terminal result");
    file << "{\n  \"id\":\"windowsTerminal\",\n  \"outcome\":" << Quote(outcome)
         << ",\n  \"captureStatus\":" << Quote(status) << ",\n  \"detail\":" << Quote(detail)
         << ",\n  \"sourceImagePath\":" << Quote(source_image) << ",\n  \"sourcePid\":" << source_pid
         << ",\n  \"fixturePid\":" << fixture_pid << ",\n  \"selectionVerified\":" << (selected ? "true" : "false")
         << ",\n  \"clipboardUnchanged\":" << (clipboard ? "true" : "false")
         << ",\n  \"copyProof\":" << (proof ? "true" : "false")
         << ",\n  \"nativeCopyFallback\":\"forbiddenNotExercised\",\n  \"captureCalls\":" << (status == "notRun" ? 0 : 1)
         << ",\n  \"units\":" << units << ",\n  \"elapsedMs\":" << elapsed
         << ",\n  \"failureStage\":" << Quote(diagnostics.last_failure_stage)
         << ",\n  \"hresult\":" << static_cast<unsigned long>(diagnostics.last_failure)
         << ",\n  \"attempts\":" << diagnostics.attempts << ",\n  \"finalAttempts\":" << diagnostics.final_attempts << "\n}\n";
    file.close(); Check(!file.fail(), "Terminal result write incomplete");
  }
};

void Foreground(HWND window) {
  ShowWindow(window, SW_RESTORE); SetForegroundWindow(window); Sleep(500);
  Check(GetForegroundWindow() == window, "Cannot obtain isolated terminal foreground");
  RECT frame{}; MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
  Check(GetWindowRect(window, &frame) && GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor),
        "Cannot verify isolated terminal placement");
  // Move only, without changing the fixture's calibrated text grid or settings.
  Check(frame.right-frame.left <= monitor.rcWork.right-monitor.rcWork.left &&
        frame.bottom-frame.top <= monitor.rcWork.bottom-monitor.rcWork.top, "Terminal window does not fit on disposable display");
  const LONG x = std::clamp(frame.left, monitor.rcWork.left, monitor.rcWork.right-(frame.right-frame.left));
  const LONG y = std::clamp(frame.top, monitor.rcWork.top, monitor.rcWork.bottom-(frame.bottom-frame.top));
  Check(SetWindowPos(window, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) != 0,
        "Cannot place isolated terminal on disposable display");
  Sleep(300);
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (Environment(L"GITHUB_ACTIONS") != L"true" || Environment(L"BAOCODE_DISPOSABLE_UI_TEST") != L"1" ||
      Environment(L"RUNNER_TEMP").empty()) return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (argc == 3 && std::wstring(argv[1]) == L"--terminal-fixture") return Fixture(argv[2]);
  if (argc != 6) return 2;
  const std::wstring launcher = argv[1], source_image = argv[2], token = argv[3], output = argv[4], root = argv[5];
  Result result;
  Session session; session.root = root; session.source_image = source_image;
  try {
    Check(WithinTemp(root) && WithinTemp(OwnImage()), "Terminal test executable and fixture must be inside RUNNER_TEMP");
    VisualProofSelfTest(root);
    const auto old_windows = Windows::Read(source_image);
    // Documented per-invocation overrides, no settings.json or delegation edits:
    // https://learn.microsoft.com/windows/terminal/command-line-arguments
    // -w -1 forces a NEW window. A commandline replaces the profile shell.
    std::wstring command = L"\""+launcher+L"\" -w -1 --size 80,20 --pos 30,30 new-tab --title \""+token+
        L"\" --suppressApplicationTitle -d \""+FullPath(root+L"\\..")+L"\" \""+OwnImage()+L"\" --terminal-fixture \""+root+L"\"";
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    Check(CreateProcessW(launcher.c_str(), command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr,
                         &startup, &session.launcher) != 0, "Installed wt.exe could not launch the isolated session");
    session.BindFixture(); result.fixture_pid = GetProcessId(session.fixture);
    for (int i = 0; i < 100 && !session.source; ++i) {
      std::vector<HWND> fresh;
      for (HWND window : Windows::Read(source_image))
        if (std::find(old_windows.begin(), old_windows.end(), window) == old_windows.end()) fresh.push_back(window);
      Check(fresh.size() <= 1, "Ambiguous new Terminal windows; refusing input or arbitrary cleanup");
      if (fresh.size() == 1) session.source = fresh.front(); else Sleep(100);
    }
    Check(session.source != nullptr, "No new installed Windows Terminal window was found");
    GetWindowThreadProcessId(session.source, &result.source_pid);
    session.source_process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, result.source_pid);
    Check(session.source_process && SamePath(ProcessImage(session.source_process), source_image), "Terminal host process image mismatch");
    result.source_image = ProcessImage(session.source_process);
    Foreground(session.source);
    Frame before; std::optional<Grid> grid;
    for (int i = 0; i < 60 && !grid; ++i) {
      before = Frame::Read(session.source); grid = FixtureGrid(before); if (!grid) Sleep(100);
    }
    Check(grid.has_value(), "Terminal fixture marker grid did not render; no selection or capture attempted");
    session.identity_verified = true;
    before.Save(output+L"\\windowsTerminal-before.bmp");
    const DWORD clipboard = SeedClipboard(session.source);
    const POINT from{before.rect.left+grid->left+grid->width/2, before.rect.top+grid->top+grid->height/2};
    const POINT to{from.x+(kUnits-1)*grid->width, from.y};
    Drag(session.source, from, to);
    Mouse(session.source, POINT{before.rect.left+grid->left, before.rect.top+grid->top+5*grid->height}, 0);
    Sleep(200);
    const auto after = Frame::Read(session.source);
    after.Save(output+L"\\windowsTerminal-selected.bmp");
    result.selected = ExactVisualSelection(before, after, *grid, output+L"\\windowsTerminal-selection-proof.json");
    Check(result.selected, "Pointer gesture did not independently verify every exact source cell and unchanged decoy; no capture attempted");
    Check(GetClipboardSequenceNumber() == clipboard, "Terminal selection changed the clipboard; no capture attempted");
    // The first and ONLY UIA interaction is the real production capture. No
    // alternate provider, metadata warm-up, or second capture can hide failure.
    const auto began = GetTickCount64();
    const auto capture = translation_selection::Capture(session.source, false, nullptr, 0, &result.diagnostics);
    result.elapsed = GetTickCount64()-began; result.status = capture.status;
    result.units = capture.text.size(); result.proof = capture.copy_proof.has_value();
    result.clipboard = GetClipboardSequenceNumber() == clipboard;
    Check(result.clipboard, "Production capture changed the clipboard");
    Check(!capture.self && !result.proof, "Terminal source identity or forbidden copy eligibility failed");
    Check(GetForegroundWindow() == session.source, "Terminal source lost foreground during capture");
    // No whitespace or newline trimming: the gesture selects precisely these
    // cells, not an entire line or an implicitly normalized provider result.
    if (capture.status == "ok" && capture.text == kText) {
      result.outcome = "exactCaptured";
      result.detail = "Exact independently verified Windows Terminal selection captured; decoy excluded and clipboard unchanged";
    } else {
      const std::string stage = result.diagnostics.last_failure_stage;
      const bool explicit_unsupported = (stage == "TextPattern" || stage == "GetSelection") &&
          (result.diagnostics.last_failure == UIA_E_NOTSUPPORTED || result.diagnostics.last_failure == E_NOINTERFACE);
      if (capture.status == "unsupported" && capture.text.empty() && explicit_unsupported) {
        result.outcome = "safeUnsupported";
        result.detail = "Verified exact selection explicitly unsupported by provider; not Windows Terminal translation support";
      } else {
        result.detail = capture.status == "ok" ? "Captured text did not exactly match the selected row" :
            "Capture runtime failure or unproven unsupported result; not classified as support";
      }
    }
    Frame::Read(session.source).Save(output+L"\\windowsTerminal-result.bmp");
  } catch (const std::exception& error) {
    result.outcome = "failed"; result.detail = error.what();
    // Do not screenshot unverified windows or their potentially unrelated text.
    if (session.identity_verified && GetForegroundWindow() == session.source) {
      try { Frame::Read(session.source).Save(output+L"\\windowsTerminal-failed.bmp"); } catch (...) {}
    }
  }
  try { result.Save(output+L"\\windowsTerminal.json"); }
  catch (const std::exception& error) { std::fprintf(stderr, "%s\n", error.what()); return 1; }
  std::printf("TERMINAL_CAPTURE|%s|status=%s|selected=%d|clipboardUnchanged=%d|units=%zu|elapsedMs=%llu|%s\n",
      result.outcome.c_str(), result.status.c_str(), result.selected ? 1 : 0, result.clipboard ? 1 : 0,
      result.units, result.elapsed, result.detail.c_str());
  return result.outcome == "exactCaptured" ? 0 : (result.outcome == "safeUnsupported" ? 3 : 1);
}
