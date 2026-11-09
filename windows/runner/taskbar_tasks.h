#ifndef RUNNER_TASKBAR_TASKS_H_
#define RUNNER_TASKBAR_TASKS_H_

#include <windows.h>
#include <shobjidl.h>

#include <string>

namespace taskbar_tasks {

// Keep this in sync with tool/baocode.iss: all native windows and installed
// shortcuts must belong to the same taskbar group, including pinned ones.
inline constexpr wchar_t kAppId[] = L"BaoCode.Desktop";

// The existing single-instance CLI protocol opens a shared-engine window.
// No files are supplied, so its cwd is only a required protocol placeholder.
inline constexpr wchar_t kNewWindowArguments[] =
    L"--baocode-cli . --new-window";

// Call before creating any windows. Debug builds use a separate identity and
// never replace the installed app's tasks.
void Initialize();

// Rebuild only when the language changes. Failures leave the app usable;
// Windows policy or a shell without a taskbar can prohibit Jump Lists.
void Update(const std::wstring& new_window_label);

// The task itself, separated so native tests can inspect its shell metadata.
HRESULT CreateNewWindowTask(const std::wstring& executable,
                            const std::wstring& label, IShellLinkW** task);

// Commits the Tasks list transactionally; aborts incomplete lists.
HRESULT Publish(const std::wstring& executable, const std::wstring& label);

}  // namespace taskbar_tasks

#endif  // RUNNER_TASKBAR_TASKS_H_
