$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:BAOCODE_DISPOSABLE_UI_TEST -ne '1') {
  throw 'Mouse hook smoke may only inject input on an explicitly enabled disposable GitHub Actions desktop.'
}
$source = Join-Path $PSScriptRoot 'windows_translation_mouse_hook_smoke.cpp'
$build = Join-Path $env:TEMP ('baocode-hook-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $build | Out-Null
try {
  Push-Location $build
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:hook_smoke.exe /link user32.lib
  if ($LASTEXITCODE -ne 0) { throw 'Mouse hook smoke compilation failed' }
  $test = Start-Process -FilePath (Join-Path $build 'hook_smoke.exe') -PassThru -NoNewWindow
  if (-not $test.WaitForExit(15000)) {
    & taskkill /PID $test.Id /T /F | Out-Null
    throw 'Mouse hook smoke timed out'
  }
  if ($test.ExitCode -ne 0) { throw "Mouse hook smoke failed ($($test.ExitCode))" }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $build -ErrorAction SilentlyContinue
}
