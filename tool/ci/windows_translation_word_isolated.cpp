// Local Word probe: private non-input desktop, fresh /n /a instance, synthetic RTF.
// Never switches desktops, injects input, uses clipboard, or opens user documents.
#include "../../windows/runner/translation_selection.h"
#include <oleacc.h>
#include <tlhelp32.h>
#include <cstdio>
#include <fstream>
#include <vector>
using Microsoft::WRL::ComPtr;
namespace {
std::wstring DesktopName(HDESK desktop) {
  wchar_t name[256]{}; DWORD size = 0;
  return GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &size) ? name : L"";
}
bool PrivateDesktop() {
  HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!input) return false;
  auto actual = DesktopName(GetThreadDesktop(GetCurrentThreadId()));
  auto active = DesktopName(input); CloseDesktop(input);
  return actual.find(L"BaoCodeWordProbe-") == 0 && !active.empty() && actual != active;
}
void Pump(DWORD ms) {
  auto until = GetTickCount64() + ms;
  do { MSG message; while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message); DispatchMessageW(&message);
  } Sleep(10); } while (GetTickCount64() < until);
}
HRESULT Invoke(IDispatch* object, wchar_t* name, WORD kind, VARIANT* result,
               VARIANT* args = nullptr, UINT count = 0) {
  DISPID id; HRESULT hr = object->GetIDsOfNames(IID_NULL, &name, 1, LOCALE_USER_DEFAULT, &id);
  if (FAILED(hr)) return hr;
  DISPPARAMS parameters{args, nullptr, count, 0};
  return object->Invoke(id, IID_NULL, LOCALE_USER_DEFAULT, kind, &parameters, result, nullptr, nullptr);
}
struct Windows { DWORD pid; HWND root = nullptr, document = nullptr; };
BOOL CALLBACK FindDocument(HWND window, LPARAM value) {
  auto* found = reinterpret_cast<Windows*>(value); DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid); wchar_t cls[64]{}; GetClassNameW(window, cls, 64);
  if (pid == found->pid && wcscmp(cls, L"_WwG") == 0) found->document = window;
  return TRUE;
}
BOOL CALLBACK FindRoot(HWND window, LPARAM value) {
  auto* found = reinterpret_cast<Windows*>(value); DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid); wchar_t cls[64]{}; GetClassNameW(window, cls, 64);
  if (pid == found->pid && wcscmp(cls, L"OpusApp") == 0 && IsWindowVisible(window)) {
    found->root = window; EnumChildWindows(window, FindDocument, value);
  }
  return TRUE;
}
int Probe(const wchar_t* word, const wchar_t* fixture) {
  if (!PrivateDesktop()) return 3;
  // The selected first line and unselected decoy are authored by this harness.
  HANDLE file = CreateFileW(fixture, GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return 9;
  const char content[] = "{\\rtf1\\ansi Word selected synthetic Echo\\par Unselected document decoy\\par}";
  DWORD written = 0;
  const bool saved = WriteFile(file, content, sizeof(content) - 1, &written, nullptr) && written == sizeof(content) - 1;
  CloseHandle(file); if (!saved) return 9;
  STARTUPINFOW startup{sizeof(startup)}; PROCESS_INFORMATION process{};
  std::wstring command = L"\"" + std::wstring(word) + L"\" /n /a /q \"" + fixture + L"\"";
  if (!CreateProcessW(word, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process)) return 4;
  CloseHandle(process.hThread);
  Windows windows{process.dwProcessId};
  for (unsigned i = 0; i < 150 && !windows.document; ++i) {
    EnumWindows(FindRoot, reinterpret_cast<LPARAM>(&windows)); Pump(100);
    if (WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) break;
  }
  int outcome = 5;
  std::printf("WORD_PROBE|ownedPid=%lu|root=%d|document=%d|privateDesktop=%d\n", process.dwProcessId,
      windows.root != nullptr, windows.document != nullptr, PrivateDesktop());
  if (windows.document && PrivateDesktop()) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ComPtr<IDispatch> native;
    HRESULT hr = AccessibleObjectFromWindow(windows.document, OBJID_NATIVEOM, IID_IDispatch,
        reinterpret_cast<void**>(native.GetAddressOf()));
    VARIANT selection; VariantInit(&selection);
    if (SUCCEEDED(hr) && native) hr = Invoke(native.Get(), const_cast<wchar_t*>(L"Selection"), DISPATCH_PROPERTYGET, &selection);
    bool selected = false;
    if (SUCCEEDED(hr) && selection.vt == VT_DISPATCH && selection.pdispVal) {
      VARIANT args[2]; for (auto& arg : args) { VariantInit(&arg); arg.vt = VT_I4; }
      args[0].lVal = 28; args[1].lVal = 0; // SetRange(Start, End), reversed COM arguments.
      hr = Invoke(selection.pdispVal, const_cast<wchar_t*>(L"SetRange"), DISPATCH_METHOD, nullptr, args, 2);
      selected = SUCCEEDED(hr);
    }
    VariantClear(&selection); native.Reset(); CoUninitialize();
    std::printf("WORD_PROBE|selectionSet=%d|nativeOmResult=%08lx\n", selected, static_cast<unsigned long>(hr));
    if (selected) {
      SetForegroundWindow(windows.root); Pump(300);
      translation_selection::CaptureDiagnostics diagnostics;
      const auto result = translation_selection::Capture(windows.root, false, nullptr, 0, &diagnostics);
      const bool exact = result.text == L"Word selected synthetic Echo";
      std::printf("WORD_CAPTURE|status=%s|exact=%d|bounds=%d|attempts=%u|stage=%s|hr=%08lx|targetStage=%s|type=%d|hasFocus=%d\n",
          result.status.c_str(), exact, result.bounds.has_value(), diagnostics.attempts,
          diagnostics.last_failure_stage, static_cast<unsigned long>(diagnostics.last_failure),
          diagnostics.target.stage, diagnostics.target.type, diagnostics.target.has_focus);
      // Explicit test-only inspection of the exact synthetic owned document.
      // This is provider coverage, not a bypass of production foreground checks.
      CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      ComPtr<IUIAutomation> automation;
      ComPtr<IUIAutomationElement> element;
      ComPtr<IUIAutomationTextPattern> pattern;
      ComPtr<IUIAutomationTextRangeArray> ranges;
      HRESULT provider = CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation));
      if (SUCCEEDED(provider)) provider = automation->ElementFromHandle(windows.document, &element);
      CONTROLTYPEID type = 0; BOOL password = TRUE, offscreen = TRUE, focus = FALSE;
      int count = -1, difference = 0;
      if (SUCCEEDED(provider) && element) {
        element->get_CurrentControlType(&type); element->get_CurrentIsPassword(&password);
        element->get_CurrentIsOffscreen(&offscreen); element->get_CurrentHasKeyboardFocus(&focus);
        provider = element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern));
      }
      if (SUCCEEDED(provider) && pattern) provider = pattern->GetSelection(&ranges);
      if (SUCCEEDED(provider) && ranges) ranges->get_Length(&count);
      bool bounds = false;
      if (count == 1) {
        ComPtr<IUIAutomationTextRange> range; ranges->GetElement(0, &range);
        if (range) {
          range->CompareEndpoints(TextPatternRangeEndpoint_Start, range.Get(), TextPatternRangeEndpoint_End, &difference);
          bounds = translation_selection::ReadBounds(range.Get(), windows.root).has_value();
        }
      }
      std::printf("WORD_PROVIDER_ONLY|hr=%08lx|type=%d|password=%d|offscreen=%d|focus=%d|ranges=%d|noncollapsed=%d|bounds=%d\n",
          static_cast<unsigned long>(provider), type, password, offscreen, focus, count, difference != 0, bounds);
      ranges.Reset(); pattern.Reset(); element.Reset(); automation.Reset(); CoUninitialize();
      outcome = exact && result.status == "ok" ? 0 : 6;
    }
  }
  // Only the exact newly created process handle, never a process-name kill.
  if (WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT) TerminateProcess(process.hProcess, 0);
  WaitForSingleObject(process.hProcess, 5000); CloseHandle(process.hProcess);
  return outcome;
}
}
int wmain(int argc, wchar_t** argv) {
  if (argc == 4 && std::wstring(argv[1]) == L"--child") return Probe(argv[2], argv[3]);
  if (argc != 3) return 2;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return 10;
  PROCESSENTRY32W entry{sizeof(entry)}; bool existing = false;
  if (Process32FirstW(snapshot, &entry)) do {
    if (_wcsicmp(entry.szExeFile, L"WINWORD.EXE") == 0) existing = true;
  } while (Process32NextW(snapshot, &entry));
  CloseHandle(snapshot); if (existing) return 10;
  HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!input) return 3;
  const auto before = DesktopName(input); CloseDesktop(input);
  auto name = L"BaoCodeWordProbe-" + std::to_wstring(GetCurrentProcessId());
  HDESK desktop = CreateDesktopW(name.c_str(), nullptr, nullptr, 0,
      DESKTOP_CREATEWINDOW | DESKTOP_READOBJECTS | DESKTOP_WRITEOBJECTS | DESKTOP_ENUMERATE, nullptr);
  if (!desktop) return 4;
  wchar_t exe[MAX_PATH]{}; GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring command = L"\"" + std::wstring(exe) + L"\" --child \"" + argv[1] + L"\" \"" + argv[2] + L"\"";
  STARTUPINFOW startup{sizeof(startup)}; startup.lpDesktop = name.data();
  PROCESS_INFORMATION process{}; DWORD result = 7;
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) return 11;
  if (CreateProcessW(exe, command.data(), nullptr, nullptr, TRUE, CREATE_SUSPENDED, nullptr, nullptr, &startup, &process)) {
    if (!AssignProcessToJobObject(job, process.hProcess)) {
      TerminateProcess(process.hProcess, 11); CloseHandle(process.hThread); CloseHandle(process.hProcess); CloseHandle(job); CloseDesktop(desktop); return 11;
    }
    ResumeThread(process.hThread); CloseHandle(process.hThread);
    if (WaitForSingleObject(process.hProcess, 45000) == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &result);
    else TerminateProcess(process.hProcess, 7);
    CloseHandle(process.hProcess);
  }
  CloseHandle(job);
  input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  const bool unchanged = input && DesktopName(input) == before;
  if (input) CloseDesktop(input); CloseDesktop(desktop);
  std::printf("WORD_ISOLATION|inputDesktopUnchanged=%d|probeExit=%lu\n", unchanged, result);
  return unchanged ? static_cast<int>(result) : 8;
}
