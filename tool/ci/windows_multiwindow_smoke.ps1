# Real release-app integration, restricted to disposable Windows Actions runners.
# Enumerate and close only windows belonging to processes this test started.
param(
  [Parameter(Mandatory = $true)][string]$Executable
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT') {
  throw 'Multiwindow integration only runs on disposable Windows Actions runners.'
}
$exe = (Resolve-Path -LiteralPath $Executable).Path
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class BaoCodeMultiwindow {
  private delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr data);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr hwnd, string name);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  public static IntPtr[] Windows(int process, bool visibleOnly) {
    var windows = new List<IntPtr>();
    EnumWindows((hwnd, data) => {
      uint owner;
      GetWindowThreadProcessId(hwnd, out owner);
      if (owner != (uint)process) return true;
      var name = new StringBuilder(256);
      GetClassName(hwnd, name, name.Capacity);
      if (name.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW" &&
          (!visibleOnly || IsWindowVisible(hwnd))) windows.Add(hwnd);
      return true;
    }, IntPtr.Zero);
    return windows.ToArray();
  }
  public static IntPtr Receiver(int process) {
    foreach (var hwnd in Windows(process, false)) {
      if (GetProp(hwnd, "BaoCode.OpenRequests") != IntPtr.Zero) return hwnd;
    }
    return IntPtr.Zero;
  }
}
'@
$previousDataDir = $env:BAOCODE_DATA_DIR
$root = Join-Path $env:RUNNER_TEMP ('baocode-multiwindow-' + [guid]::NewGuid())
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
New-Item -ItemType Directory -Force $root | Out-Null
function Start-NewWindow {
  # Match the installed Jump List task exactly. No paths are opened.
  $process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) `
    -ArgumentList @('--baocode-cli', '.', '--new-window') -PassThru
  $processes.Add($process)
  return $process
}
function Wait-WindowCount($app, [int]$expected) {
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  $stable = 0
  do {
    $app.Refresh()
    if ($app.HasExited) { throw "Owner exited waiting for $expected windows: $($app.ExitCode)" }
    $windows = @([BaoCodeMultiwindow]::Windows($app.Id, $true))
    if ($windows.Count -eq $expected) { $stable++ } else { $stable = 0 }
    if ($stable -ge 5) { return }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Expected $expected owned visible windows; found $($windows.Count), PID $($app.Id)"
}
function Assert-HiddenReceiver($app) {
  $receiver = [BaoCodeMultiwindow]::Receiver($app.Id)
  if ($receiver -eq [IntPtr]::Zero) { throw 'Missing single-instance receiver in owner process' }
  if ([BaoCodeMultiwindow]::IsWindowVisible($receiver)) { throw 'Cold CLI launch unexpectedly shows main chat window' }
}
function Forward-NewWindow($app, [int]$expected, [bool]$hiddenReceiver = $true) {
  $forwarder = Start-NewWindow
  if (!$forwarder.WaitForExit(15000)) { throw 'Second launch did not forward and exit; possible second persistent engine' }
  if ($forwarder.ExitCode -ne 0) { throw "Forwarding process failed: $($forwarder.ExitCode)" }
  Wait-WindowCount $app $expected
  if ($hiddenReceiver) { Assert-HiddenReceiver $app }
}
function Close-OwnedWindow($app, [IntPtr]$window) {
  if (@([BaoCodeMultiwindow]::Windows($app.Id, $true)) -notcontains $window) {
    throw 'Refusing to close a window not currently visible and owned by the test app'
  }
  if (![BaoCodeMultiwindow]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
    throw 'Could not post WM_CLOSE to owned window'
  }
}
try {
  $env:BAOCODE_DATA_DIR = Join-Path $root 'data'
  $user = Join-Path $env:BAOCODE_DATA_DIR 'User'
  New-Item -ItemType Directory -Force $user | Out-Null
  @{
    'tray.enabled' = $false
    'window.confirmBeforeClose' = 'never'
    'terminal.integrated.confirmOnExit' = 'never'
    'models.providers' = @()
    'update.mode' = 'none'
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $user 'settings.json') -Encoding utf8
  # First round starts with default window settings; the second checks persisted
  # separate-window mode and clean relaunch against the same isolated data.
  foreach ($round in 1, 2) {
    $app = Start-NewWindow
    Wait-WindowCount $app 1
    Assert-HiddenReceiver $app
    $first = @([BaoCodeMultiwindow]::Windows($app.Id, $true))[0]
    Forward-NewWindow $app 2
    Forward-NewWindow $app 3
    if (@([BaoCodeMultiwindow]::Windows($app.Id, $true)) -notcontains $first) {
      throw 'New Window replaced the original native window'
    }
    Close-OwnedWindow $app $first
    Wait-WindowCount $app 2
    # The receiver is the hidden main window, not the visible window just closed.
    Forward-NewWindow $app 3
    foreach ($remaining in 2, 1) {
      $window = @([BaoCodeMultiwindow]::Windows($app.Id, $true))[0]
      Close-OwnedWindow $app $window
      Wait-WindowCount $app $remaining
    }
    $last = @([BaoCodeMultiwindow]::Windows($app.Id, $true))[0]
    Close-OwnedWindow $app $last
    if (!$app.WaitForExit(30000)) { throw 'Closing the last visible window failed to quit without a tray' }
    if ($app.ExitCode -ne 0) { throw "Last-window shutdown crashed: $($app.ExitCode)" }
    $saved = Get-Content -LiteralPath (Join-Path $user 'settings.json') -Raw | ConvertFrom-Json
    if ($saved.'window.ideWindows' -ne 'separate') { throw 'Explicit New Window did not persist separate-window mode' }
    Write-Host "PASS round ${round}: cold launch, repeated forwarding to PID $($app.Id), independent close, hidden receiver, last-window exit 0"
  }
  # A separate clean profile tests a warm request after an ordinary default launch.
  $env:BAOCODE_DATA_DIR = Join-Path $root 'warm-default'
  $user = Join-Path $env:BAOCODE_DATA_DIR 'User'
  New-Item -ItemType Directory -Force $user | Out-Null
  @{
    'tray.enabled' = $false
    'window.confirmBeforeClose' = 'never'
    'terminal.integrated.confirmOnExit' = 'never'
    'models.providers' = @()
    'update.mode' = 'none'
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $user 'settings.json') -Encoding utf8
  $app = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru
  $processes.Add($app)
  Wait-WindowCount $app 1
  $main = [BaoCodeMultiwindow]::Receiver($app.Id)
  if ($main -eq [IntPtr]::Zero -or ![BaoCodeMultiwindow]::IsWindowVisible($main)) {
    throw 'Default ordinary launch did not show its main window'
  }
  Forward-NewWindow $app 2 $false
  Forward-NewWindow $app 3 $false
  Close-OwnedWindow $app $main
  Wait-WindowCount $app 2
  Assert-HiddenReceiver $app
  Forward-NewWindow $app 3
  foreach ($remaining in 2, 1) {
    $window = @([BaoCodeMultiwindow]::Windows($app.Id, $true))[0]
    Close-OwnedWindow $app $window
    Wait-WindowCount $app $remaining
  }
  $last = @([BaoCodeMultiwindow]::Windows($app.Id, $true))[0]
  Close-OwnedWindow $app $last
  if (!$app.WaitForExit(30000)) { throw 'Warm-default app did not quit after its last window closed' }
  if ($app.ExitCode -ne 0) { throw "Warm-default app crashed: $($app.ExitCode)" }
  Write-Host 'PASS: ordinary default launch, warm promotion, repeated windows, hide main, forward again, clean exit'

} finally {
  foreach ($process in $processes) {
    try {
      $process.Refresh()
      if (!$process.HasExited) {
        Stop-Process -Id $process.Id -Force
        if (!$process.WaitForExit(10000)) { Write-Warning "Cleanup timed out for owned PID $($process.Id)" }
      }
    } finally { $process.Dispose() }
  }
  $env:BAOCODE_DATA_DIR = $previousDataDir
}
