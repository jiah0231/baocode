// Metadata and real-shell registration checks, on a disposable CI desktop.
#include <windows.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <iostream>
#include <string>

#include "../../windows/runner/taskbar_tasks.h"

using Microsoft::WRL::ComPtr;

int wmain(int argc, wchar_t** argv) {
  if (::GetEnvironmentVariableW(L"GITHUB_ACTIONS", nullptr, 0) == 0) return 2;
  if (argc != 2) return 3;
  if (FAILED(::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 4;
  taskbar_tasks::Initialize();
  PWSTR app_id = nullptr;
  if (FAILED(::GetCurrentProcessExplicitAppUserModelID(&app_id))) return 5;
  const bool identity = std::wstring(app_id) == taskbar_tasks::kAppId;
  ::CoTaskMemFree(app_id);
  if (!identity) return 6;
  const std::wstring executable = argv[1];
  for (const std::wstring label : {L"新建窗口", L"New Window"}) {
    ComPtr<IShellLinkW> task;
    if (FAILED(taskbar_tasks::CreateNewWindowTask(executable, label, &task))) return 7;
    wchar_t text[32768] = {};
    if (FAILED(task->GetPath(text, 32768, nullptr, SLGP_RAWPATH)) ||
        std::wstring(text) != executable) return 8;
    if (FAILED(task->GetArguments(text, 32768)) ||
        std::wstring(text) != taskbar_tasks::kNewWindowArguments) return 9;
    if (FAILED(task->GetWorkingDirectory(text, 32768)) ||
        std::wstring(text) != executable.substr(0, executable.find_last_of(L"\\/") + 1)) return 10;
    int icon = -1;
    if (FAILED(task->GetIconLocation(text, 32768, &icon)) ||
        std::wstring(text) != executable || icon != 0) return 11;
    ComPtr<IPropertyStore> properties;
    if (FAILED(task.As(&properties))) return 12;
    PROPVARIANT title;
    ::PropVariantInit(&title);
    if (FAILED(properties->GetValue(PKEY_Title, &title))) return 13;
    const bool titled = title.vt == VT_LPWSTR && title.pwszVal != nullptr &&
                        std::wstring(title.pwszVal) == label;
    ::PropVariantClear(&title);
    if (!titled) return 14;
    const HRESULT published = taskbar_tasks::Publish(executable, label);
    if (FAILED(published)) {
      std::cerr << "Jump List registration failed: " << std::hex << published << '\n';
      return 15;
    }
  }
  if (taskbar_tasks::CreateNewWindowTask(executable, L"", nullptr) != E_POINTER) return 16;
  std::cout << "PASS: app identity, Unicode/English titles, executable, arguments, cwd, icon and committed Jump List\n";
  ::CoUninitialize();
  return 0;
}
