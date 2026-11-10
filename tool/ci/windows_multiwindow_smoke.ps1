# Real release-app integration, restricted to disposable Windows Actions runners.
# Enumerate and close only windows belonging to processes this test started.
param(
  [Parameter(Mandatory = $true)][string]$Executable,
  [string]$DiagnosticsDirectory = (Join-Path $env:RUNNER_TEMP 'baocode-multiwindow-diagnostics')
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
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
  public static string Title(IntPtr hwnd) {
    var text = new StringBuilder(512); GetWindowText(hwnd, text, text.Capacity); return text.ToString();
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr hwnd, string name);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
  [StructLayout(LayoutKind.Sequential)] private struct INPUT { public uint type; public INPUT_DATA data; }
  [StructLayout(LayoutKind.Explicit)] private struct INPUT_DATA {
    [FieldOffset(0)] public KEYBDINPUT keyboard;
    [FieldOffset(0)] public MOUSEINPUT mouse;
  }
  [StructLayout(LayoutKind.Sequential)] private struct KEYBDINPUT {
    public ushort vk, scan; public uint flags, time; public UIntPtr extra;
  }
  [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT {
    public int x, y; public uint data, flags, time; public UIntPtr extra;
  }
  private static void Key(IntPtr window, ushort key, bool up, bool unicode = false) {
    if (GetForegroundWindow() != window) throw new Exception("Refusing input outside the owned foreground window");
    var input = new INPUT { type = 1 };
    input.data.keyboard = new KEYBDINPUT {
      vk = unicode ? (ushort)0 : key, scan = unicode ? key : (ushort)0,
      flags = (up ? 2u : 0u) | (unicode ? 4u : 0u)
    };
    if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1) throw new Exception("Synthetic key input failed");
  }
  // Release only keys this helper pressed, even if foreground was lost mid-gesture.
  private static void Release(ushort key) {
    var input = new INPUT { type = 1 };
    input.data.keyboard = new KEYBDINPUT { vk = key, flags = 2 };
    if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1) throw new Exception("Synthetic key release failed");
  }
  private static void Chord(IntPtr window, params ushort[] keys) {
    int pressed = 0;
    try {
      foreach (var key in keys) { Key(window, key, false); pressed++; }
    } finally {
      for (int index = pressed - 1; index >= 0; index--) Release(keys[index]);
    }
  }
  public static void ChatEditor(IntPtr window) { Chord(window, 0x11, 0x12, 0x49); }
  public static void NewChat(IntPtr window) { Chord(window, 0x11, 0x4e); }
  public static void Type(IntPtr window, string text) {
    foreach (var character in text) { Key(window, character, false, true); Key(window, character, true, true); }
  }
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
  $previous = -1
  do {
    $app.Refresh()
    if ($app.HasExited) { throw "Owner exited waiting for $expected windows: $($app.ExitCode)" }
    $windows = @([BaoCodeMultiwindow]::Windows($app.Id, $true))
    if ($windows.Count -ne $previous) {
      $previous = $windows.Count
      Write-Host "WINDOW_COUNT pid=$($app.Id) expected=$expected actual=$previous"
      foreach ($window in [BaoCodeMultiwindow]::Windows($app.Id, $false)) {
        Write-Host "WINDOW hwnd=$window visible=$([BaoCodeMultiwindow]::IsWindowVisible($window)) receiver=$($window -eq [BaoCodeMultiwindow]::Receiver($app.Id)) title=$([BaoCodeMultiwindow]::Title($window))"
      }
    }
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
function Focus-OwnedWindow($app, [IntPtr]$window) {
  if (@([BaoCodeMultiwindow]::Windows($app.Id, $true)) -notcontains $window) {
    throw 'Refusing input to an unowned window'
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    [BaoCodeMultiwindow]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Milliseconds 100
    if ([BaoCodeMultiwindow]::GetForegroundWindow() -eq $window) { return }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'Owned window did not receive foreground for the navigation test'
}
function Read-ChatState([int]$count) {
  $file = Join-Path $env:BAOCODE_DATA_DIR 'state/windows.json'
  $deadline = [DateTime]::UtcNow.AddSeconds(12)
  do {
    if (Test-Path -LiteralPath $file) {
      $state = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
      if (@($state.windows | Where-Object { $_.chatMode }).Count -eq $count) { return $state }
    }
    Start-Sleep -Milliseconds 150
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Expected $count windows in their own chat mode"
}
function Assert-Draft([string]$key, [string]$text) {
  $file = Join-Path $env:BAOCODE_DATA_DIR 'state/drafts.json'
  $deadline = [DateTime]::UtcNow.AddSeconds(12)
  do {
    if (Test-Path -LiteralPath $file) {
      $drafts = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
      if ($drafts[$key].text -like "*$text*") { return }
    }
    Start-Sleep -Milliseconds 150
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "The isolated $key draft was not retained"
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

  # The user's exact regression: return from B's IDE to B's own chat, never A.
  $env:BAOCODE_DATA_DIR = Join-Path $root 'chat-navigation'
  $user = Join-Path $env:BAOCODE_DATA_DIR 'User'
  New-Item -ItemType Directory -Force $user | Out-Null
  @{
    'tray.enabled' = $false
    'window.confirmBeforeClose' = 'never'
    'terminal.integrated.confirmOnExit' = 'never'
    'models.providers' = @()
    'update.mode' = 'none'
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $user 'settings.json') -Encoding utf8
  # The input scenario models an existing user's windows, not first-run setup.
  # An empty provider list otherwise opens the real model welcome modal and
  # intentionally prevents typing into the composer behind it. Keep providers
  # empty (no external requests), but mark that onboarding as already seen.
  $stateDirectory = Join-Path $env:BAOCODE_DATA_DIR 'state'
  New-Item -ItemType Directory -Force $stateDirectory | Out-Null
  @{ 'models.welcomed' = $true } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $stateDirectory 'storage.json') -Encoding utf8
  $app = Start-NewWindow
  Wait-WindowCount $app 1
  $a = @([BaoCodeMultiwindow]::Windows($app.Id, $true))[0]
  Forward-NewWindow $app 2
  $b = @([BaoCodeMultiwindow]::Windows($app.Id, $true) | Where-Object { $_ -ne $a })[0]
  Focus-OwnedWindow $app $a
  [BaoCodeMultiwindow]::ChatEditor($a)
  $state = Read-ChatState 1
  if ([BaoCodeMultiwindow]::GetForegroundWindow() -ne $a) { throw 'A returned into another native window' }
  $aKey = $state.windows[0].conversation.draftKey
  if (!$aKey.StartsWith('window:')) { throw 'A did not receive an independent draft identity' }
  Start-Sleep -Milliseconds 600
  [BaoCodeMultiwindow]::Type($a, 'synthetic draft only A')
  Assert-Draft $aKey 'synthetic draft only A'
  Focus-OwnedWindow $app $b
  [BaoCodeMultiwindow]::ChatEditor($b)
  $state = Read-ChatState 2
  if ([BaoCodeMultiwindow]::GetForegroundWindow() -ne $b) { throw 'B returned into A or the main chat' }
  $bKey = $state.windows[0].conversation.draftKey
  if (!$bKey.StartsWith('window:') -or $aKey -eq $bKey) { throw 'A and B share a new-chat draft identity' }
  Start-Sleep -Milliseconds 600
  [BaoCodeMultiwindow]::Type($b, 'synthetic draft only B')
  Assert-Draft $bKey 'synthetic draft only B'
  Assert-Draft $aKey 'synthetic draft only A'
  [BaoCodeMultiwindow]::NewChat($b)
  Start-Sleep -Milliseconds 700
  $state = Read-ChatState 2
  $freshKey = $state.windows[0].conversation.draftKey
  if ($freshKey -eq $bKey -or $freshKey -eq $aKey) { throw 'New Chat reused another unsent conversation' }
  Assert-Draft $bKey 'synthetic draft only B'
  [BaoCodeMultiwindow]::ChatEditor($b)
  $null = Read-ChatState 1
  if ([BaoCodeMultiwindow]::GetForegroundWindow() -ne $b) { throw 'B opened its editor in another native window' }
  Start-Sleep -Milliseconds 600
  [BaoCodeMultiwindow]::ChatEditor($b)
  $state = Read-ChatState 2
  if ($state.windows[0].conversation.draftKey -ne $freshKey) { throw 'B lost its own selected chat on return' }
  Wait-WindowCount $app 2
  Assert-HiddenReceiver $app
  Assert-Draft $aKey 'synthetic draft only A'
  Assert-Draft $bKey 'synthetic draft only B'
  Close-OwnedWindow $app $a
  Wait-WindowCount $app 1
  Close-OwnedWindow $app $b
  if (!$app.WaitForExit(30000) -or $app.ExitCode -ne 0) { throw 'Chat navigation scenario did not exit cleanly' }
  Assert-Draft $aKey 'synthetic draft only A'
  Assert-Draft $bKey 'synthetic draft only B'
  Write-Host 'PASS: A/B return in place, independent drafts, local New Chat, editor/chat round-trip, preserved drafts after close'

} catch {
  Write-Host "ISOLATED_DATA $env:BAOCODE_DATA_DIR"
  New-Item -ItemType Directory -Force $DiagnosticsDirectory | Out-Null
  # Capture only the synthetic test app's owned foreground window, never the desktop.
  try {
    $foreground = [BaoCodeMultiwindow]::GetForegroundWindow()
    $owned = @($processes | ForEach-Object {
      if (!$_.HasExited) { [BaoCodeMultiwindow]::Windows($_.Id, $true) }
    })
    if ($owned -contains $foreground) {
      Add-Type -AssemblyName System.Drawing
      $rect = [BaoCodeMultiwindow+RECT]::new()
      if ([BaoCodeMultiwindow]::GetWindowRect($foreground, [ref]$rect)) {
        $bitmap = [Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
          $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
          $bitmap.Save((Join-Path $DiagnosticsDirectory 'owned-window.png'), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
      }
      try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $element = [Windows.Automation.AutomationElement]::FromHandle($foreground)
        $elements = $element.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt [Math]::Min($elements.Count, 300); $i++) {
          $current = $elements[$i].Current
          Write-Host "OWNED_UIA type=$($current.ControlType.ProgrammaticName) focused=$($current.HasKeyboardFocus) enabled=$($current.IsEnabled) name=$($current.Name)"
        }
      } catch { Write-Host "OWNED_UIA unavailable: $_" }
    } else { Write-Host "OWNED_SCREENSHOT omitted: foreground $foreground is not owned" }
  } catch { Write-Host "OWNED_DIAGNOSTIC unavailable: $_" }
  Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object {
    $_.Name -in @('settings.json', 'windows.json', 'drafts.json', 'storage.json', 'events.log', 'errors.log')
  } | ForEach-Object {
    Write-Host "DIAGNOSTIC_FILE $($_.FullName)"
    Get-Content -LiteralPath $_.FullName -Tail 100
    $relative = [IO.Path]::GetRelativePath($root, $_.FullName)
    $copy = Join-Path $DiagnosticsDirectory $relative
    New-Item -ItemType Directory -Force (Split-Path $copy) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $copy
  }
  Get-ItemProperty 'HKCU:\Software\BaoCode' | Select-Object MainShownAtLaunch | Format-List
  throw
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
