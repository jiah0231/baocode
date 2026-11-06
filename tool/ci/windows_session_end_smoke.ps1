# Disposable GitHub runner only. Send lifecycle messages to owned app windows;
# never broadcast, call ExitWindowsEx, or end the runner's actual session.
param(
  [Parameter(Mandatory = $true)][string]$Executable
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT') {
  throw 'Session-end regression only runs on disposable Windows Actions runners.'
}
$exe = (Resolve-Path -LiteralPath $Executable).Path
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BaoCodeSessionEnd {
  [DllImport("user32.dll", SetLastError = true)]
  public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message,
    IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
  [DllImport("user32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@
$previousDataDir = $env:BAOCODE_DATA_DIR
function Start-TestApp {
  $app = Start-Process -FilePath $exe -PassThru
  try {
    Start-Sleep -Seconds 15
    $app.Refresh()
    if ($app.HasExited) { throw "App exited during startup: $($app.ExitCode)" }
    if ($app.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Missing owned app window' }
    return $app
  } catch {
    if (!$app.HasExited) { Stop-Process -Id $app.Id }
    $app.Dispose()
    throw
  }
}
function Send-LifecycleMessage($app, [uint32]$message, [int]$accepted, [int]$reason) {
  $result = [UIntPtr]::Zero
  # SMTO_ABORTIFHUNG keeps a stalled app from hanging this CI step.
  $sent = [BaoCodeSessionEnd]::SendMessageTimeout($app.MainWindowHandle,
    $message, [IntPtr]$accepted, [IntPtr]$reason, 2, 10000, [ref]$result)
  if ($sent -eq [IntPtr]::Zero) { throw "Lifecycle message $message failed or timed out" }
  return $result.ToUInt64()
}
try {
  # 0 = system session end; 1 = Restart Manager ENDSESSION_CLOSEAPP.
  foreach ($reason in 0, 1) {
    $env:BAOCODE_DATA_DIR = Join-Path $env:RUNNER_TEMP ('baocode-session-end-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force $env:BAOCODE_DATA_DIR | Out-Null
    $marker = Join-Path $env:BAOCODE_DATA_DIR 'preserve-session-end.txt'
    Set-Content -LiteralPath $marker 'isolated session-end data'
    $markerHash = (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash
    $app = $null
    try {
      $app = Start-TestApp
      if ((Send-LifecycleMessage $app 0x0011 0 $reason) -eq 0) {
        throw "App refused WM_QUERYENDSESSION, reason $reason"
      }
      # A canceled shutdown must leave the app usable and alive.
      $null = Send-LifecycleMessage $app 0x0016 0 $reason
      Start-Sleep -Seconds 1
      $app.Refresh()
      if ($app.HasExited) { throw 'Canceled session end closed the app' }
      if ((Send-LifecycleMessage $app 0x0011 0 $reason) -eq 0) {
        throw 'App refused repeated WM_QUERYENDSESSION'
      }
      # Async: the native handler intentionally terminates its own process.
      if (![BaoCodeSessionEnd]::PostMessage($app.MainWindowHandle, 0x0016, [IntPtr]1, [IntPtr]$reason)) {
        throw 'Could not post WM_ENDSESSION to owned app window'
      }
      if (!$app.WaitForExit(30000)) { throw 'App did not exit after WM_ENDSESSION' }
      if ($app.ExitCode -ne 0) { throw "Native shutdown crashed: $($app.ExitCode), reason $reason" }
      $app.Dispose()
      $app = $null
      $app = Start-TestApp
      if ((Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash -ne $markerHash) {
        throw 'Session end or relaunch changed existing test data'
      }
      Write-Host "PASS: accepted query, canceled query, WM_ENDSESSION reason $reason, exit 0, relaunch and data hash"
    } finally {
      if ($app) {
        $app.Refresh()
        if (!$app.HasExited) {
          Stop-Process -Id $app.Id
          if (!$app.WaitForExit(10000)) { throw 'Test app cleanup timed out' }
        }
        $app.Dispose()
      }
    }
  }
} finally {
  $env:BAOCODE_DATA_DIR = $previousDataDir
}
