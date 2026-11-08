# Real release-app UI integration. Never run on a user's desktop.
param(
  [Parameter(Mandatory = $true)][string]$Executable,
  [string]$OutputDirectory = 'build/translation-window-previews'
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT') {
  throw 'Translation window integration only runs on disposable Windows Actions runners.'
}
$exe = (Resolve-Path -LiteralPath $Executable).Path
$source = Join-Path $PSScriptRoot 'windows_translation_window_smoke.cpp'
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $output | Out-Null
$root = Join-Path $env:RUNNER_TEMP ('translation-window-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $root | Out-Null
$previousDataDir = $env:BAOCODE_DATA_DIR
$app = $null
$test = $null
Push-Location $root
try {
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:translation_window_smoke.exe /link user32.lib gdi32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Translation window harness compilation failed' }
  foreach ($theme in 'Dark', 'Light') {
    $env:BAOCODE_DATA_DIR = Join-Path $root $theme
    $user = Join-Path $env:BAOCODE_DATA_DIR 'User'
    New-Item -ItemType Directory -Force $user | Out-Null
    '{"locale":"zh-cn"}' | Set-Content -LiteralPath (Join-Path $env:BAOCODE_DATA_DIR 'argv.json') -Encoding utf8
    # Empty provider list means no translation network calls or real credentials.
    @{
      'tray.enabled' = $true
      'window.autoDetectColorScheme' = $false
      'workbench.colorTheme' = "Bao $theme"
      'translation.globalHotkey' = 'ctrl+alt+y'
      'translation.selectionAction.enabled' = $true
      'models.providers' = @()
      'update.mode' = 'none'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $user 'settings.json') -Encoding utf8
    $app = Start-Process -FilePath $exe -PassThru
    Start-Sleep -Seconds 15
    $app.Refresh()
    if ($app.HasExited) { throw "Release app startup failed: $($app.ExitCode)" }
    $screenshot = Join-Path $output "bao-$($theme.ToLowerInvariant())-floating-window.bmp"
    $test = Start-Process -FilePath (Join-Path $root 'translation_window_smoke.exe') -ArgumentList @($app.Id, "`"$screenshot`"") -PassThru -NoNewWindow
    if (!$test.WaitForExit(180000)) { throw 'Real-app translation integration timed out' }
    if ($test.ExitCode -ne 0) { throw "Real-app translation integration failed: $($test.ExitCode) ($theme)" }
    $test.Dispose(); $test = $null
    if (!$app.WaitForExit(15000)) { throw 'App did not exit after native quit' }
    if ($app.ExitCode -ne 0) { throw "App crashed at native quit: $($app.ExitCode)" }
    $app.Dispose(); $app = $null
    if (!(Test-Path -LiteralPath $screenshot)) { throw 'Required real-app screenshot missing' }
    Add-Type -AssemblyName System.Drawing
    foreach ($capture in @($screenshot, "$screenshot.mouse.bmp")) {
      if (!(Test-Path -LiteralPath $capture)) { throw "Required real-app screenshot missing: $capture" }
      $bitmap = [System.Drawing.Bitmap]::FromFile($capture)
      $png = [IO.Path]::ChangeExtension($capture, '.png')
      try { $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png) }
      finally { $bitmap.Dispose() }
      Write-Output ('TRANSLATION_WINDOW_PREVIEW|' + [IO.Path]::GetFileNameWithoutExtension($png) + '|' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($png)))
    }
  }
} finally {
  foreach ($process in @($test, $app)) {
    if ($process) {
      $process.Refresh()
      if (!$process.HasExited) { & taskkill /PID $process.Id /T /F | Out-Null }
      $process.Dispose()
    }
  }
  $env:BAOCODE_DATA_DIR = $previousDataDir
  Pop-Location
}
