#include "taskbar_tasks.h"

#include <propkey.h>
#include <propvarutil.h>
#include <wrl/client.h>

namespace taskbar_tasks {
namespace {

using Microsoft::WRL::ComPtr;

[[maybe_unused]] std::wstring ExecutablePath() {
  std::wstring path(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) return {};
  path.resize(length);
  return path;
}

}  // namespace

void Initialize() {
#if defined(_DEBUG)
  ::SetCurrentProcessExplicitAppUserModelID(L"BaoCode.Desktop.Dev");
#else
  ::SetCurrentProcessExplicitAppUserModelID(kAppId);
#endif
}

HRESULT CreateNewWindowTask(const std::wstring& executable,
                            const std::wstring& label, IShellLinkW** task) {
  if (task == nullptr) return E_POINTER;
  *task = nullptr;
  if (executable.empty() || label.empty()) return E_INVALIDARG;
  ComPtr<IShellLinkW> link;
  HRESULT result = ::CoCreateInstance(CLSID_ShellLink, nullptr,
                                      CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(&link));
  if (FAILED(result)) return result;
  result = link->SetPath(executable.c_str());
  if (FAILED(result)) return result;
  result = link->SetArguments(kNewWindowArguments);
  if (FAILED(result)) return result;
  const size_t slash = executable.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    result = link->SetWorkingDirectory(executable.substr(0, slash + 1).c_str());
    if (FAILED(result)) return result;
  }
  result = link->SetIconLocation(executable.c_str(), 0);
  if (FAILED(result)) return result;
  result = link->SetDescription(label.c_str());
  if (FAILED(result)) return result;
  result = link->SetShowCmd(SW_SHOWNORMAL);
  if (FAILED(result)) return result;
  ComPtr<IPropertyStore> properties;
  result = link.As(&properties);
  if (FAILED(result)) return result;
  PROPVARIANT title;
  result = ::InitPropVariantFromString(label.c_str(), &title);
  if (FAILED(result)) return result;
  result = properties->SetValue(PKEY_Title, title);
  ::PropVariantClear(&title);
  if (FAILED(result)) return result;
  result = properties->Commit();
  if (FAILED(result)) return result;
  *task = link.Detach();
  return S_OK;
}

HRESULT Publish(const std::wstring& executable, const std::wstring& label) {
  ComPtr<IShellLinkW> task;
  HRESULT result = CreateNewWindowTask(executable, label, &task);
  if (FAILED(result)) return result;
  ComPtr<IObjectCollection> tasks;
  result = ::CoCreateInstance(CLSID_EnumerableObjectCollection, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&tasks));
  if (FAILED(result)) return result;
  result = tasks->AddObject(task.Get());
  if (FAILED(result)) return result;
  ComPtr<ICustomDestinationList> list;
  result = ::CoCreateInstance(CLSID_DestinationList, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list));
  if (FAILED(result)) return result;
  result = list->SetAppID(kAppId);
  if (FAILED(result)) return result;
  UINT slots = 0;
  ComPtr<IObjectArray> removed;
  result = list->BeginList(&slots, IID_PPV_ARGS(&removed));
  if (FAILED(result)) return result;
  // Only a user task, not recent files: no workspace paths are published.
  result = list->AddUserTasks(tasks.Get());
  if (SUCCEEDED(result)) result = list->CommitList();
  if (FAILED(result)) list->AbortList();
  return result;
}

void Update(const std::wstring& new_window_label) {
#if !defined(_DEBUG)
  if (::GetEnvironmentVariableW(L"BAOCODE_PERF_SCENARIOS", nullptr, 0) > 0) {
    return;
  }
  static std::wstring published_label;
  if (new_window_label.empty() || published_label == new_window_label) return;
  if (SUCCEEDED(Publish(ExecutablePath(), new_window_label))) {
    published_label = new_window_label;
  }
#endif
}

}  // namespace taskbar_tasks
