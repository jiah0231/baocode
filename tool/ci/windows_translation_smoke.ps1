$ErrorActionPreference = 'Stop'
# Run from a VS Developer PowerShell, or a CI job using msvc-dev-cmd.
$source = Join-Path $PSScriptRoot 'windows_translation_smoke.cpp'
$build = Join-Path $env:TEMP ('baocode-translation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $build | Out-Null
try {
  Push-Location $build
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:translation_smoke.exe /link user32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Translation native smoke compilation failed' }
  $test = Start-Process -FilePath (Join-Path $build 'translation_smoke.exe') -PassThru -NoNewWindow
  if (-not $test.WaitForExit(20000)) {
    & taskkill /PID $test.Id /T /F | Out-Null
    throw 'Translation native smoke timed out'
  }
  if ($test.ExitCode -ne 0) { throw "Translation native smoke failed ($($test.ExitCode))" }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $build -ErrorAction SilentlyContinue
}
