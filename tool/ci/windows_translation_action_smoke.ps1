$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:BAOCODE_DISPOSABLE_UI_TEST -ne '1') {
  throw 'Selection action smoke may only run on an explicitly enabled disposable GitHub Actions desktop.'
}
$source = Join-Path $PSScriptRoot 'windows_translation_action_smoke.cpp'
$implementation = Join-Path $PSScriptRoot '../../windows/runner/translation_selection_action.cpp'
# Metadata-only discovery invariant: even a UIA provider cannot receive text,
# value, or full-document reads from this entry implementation.
$code = Get-Content -Raw $implementation
if ($code -match '->\s*(GetText|GetDocumentRange|get_DocumentRange|GetCurrentPropertyValue)\s*\(' -or
    $code -match '\b(GetClipboardData|OpenClipboard|UIA_ValuePatternId|WH_KEYBOARD_LL)\b') {
  throw 'Automatic selection entry contains a prohibited text/clipboard/keyboard read'
}
$build = Join-Path $env:TEMP ('baocode-action-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $build | Out-Null
try {
  Push-Location $build
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /wd4100 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source $implementation /Fe:action_smoke.exe /link user32.lib advapi32.lib gdi32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Selection action smoke compilation failed' }
  $test = Start-Process -FilePath (Join-Path $build 'action_smoke.exe') -PassThru -NoNewWindow
  if (-not $test.WaitForExit(20000)) {
    & taskkill /PID $test.Id /T /F | Out-Null
    throw 'Selection action smoke timed out'
  }
  if ($test.ExitCode -ne 0) { throw "Selection action smoke failed ($($test.ExitCode))" }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $build -ErrorAction SilentlyContinue
}
