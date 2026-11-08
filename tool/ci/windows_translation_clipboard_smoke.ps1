# Actual keyboard injection and clipboard changes: disposable Windows CI only.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT') {
  throw 'Clipboard integration only runs on disposable Windows Actions runners.'
}
$source = Join-Path $PSScriptRoot 'windows_translation_clipboard_smoke.cpp'
$root = Join-Path $env:RUNNER_TEMP ('translation-clipboard-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $root | Out-Null
Push-Location $root
try {
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:translation_clipboard_smoke.exe /link user32.lib advapi32.lib
  if ($LASTEXITCODE -ne 0) { throw 'Clipboard harness compilation failed' }
  $test = Start-Process -FilePath (Join-Path $root 'translation_clipboard_smoke.exe') -PassThru -NoNewWindow
  try {
    if (!$test.WaitForExit(30000)) { & taskkill /PID $test.Id /T /F | Out-Null; throw 'Clipboard harness timed out' }
    if ($test.ExitCode -ne 0) { throw "Clipboard harness failed: $($test.ExitCode)" }
  } finally { $test.Dispose() }
} finally { Pop-Location }
