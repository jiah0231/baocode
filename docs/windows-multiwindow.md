# Windows: New Window

Right-click BaoCode's taskbar icon and choose **New Window** (新建窗口 in
Chinese). The same action is available from the app's New Window command
and Ctrl+Shift+N. Each opens a separate native IDE window in the existing
BaoCode process, so it shares settings and account state rather than
starting a second writer to the same data directory.

An explicit New Window action enables `window.ideWindows: "separate"` if
needed. An existing main-window project moves into its own window, with the
usual unsaved-file confirmation first. Canceling leaves it in place and
opens nothing. A cold start from the taskbar task opens only the requested
empty window rather than restoring old projects.

The task follows the app's language and uses the installed executable's
icon. Installer shortcuts and all app windows share the stable
`BaoCode.Desktop` AppUserModelID. If Windows retains a pin created by a much
older installation, unpin it once and pin the updated running app. Windows
policy can suppress Jump Lists; the app command and shortcut remain usable.

## Verification

`.github/workflows/multiwindow-validation.yml` is a non-publishing Windows
validation workflow. It analyzes the complete source, runs window and
launch regression tests, builds the release executable, checks native Jump
List task properties and shell registration, and exercises cold and warm
launches, repeated new windows, closing one window, the hidden main
receiver, and clean last-window shutdown against isolated data.

The native metadata test verifies the Windows shell accepted the task. It
does not claim a screenshot-based check of Explorer's rendered menu on
every supported Windows version.
