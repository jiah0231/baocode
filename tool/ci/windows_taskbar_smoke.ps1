param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT') {
  throw 'Taskbar integration only runs on disposable Windows Actions runners.'
}
$exe = (Resolve-Path -LiteralPath $Executable).Path
$source = Join-Path $PSScriptRoot 'windows_taskbar_smoke.cpp'
$implementation = Join-Path $PSScriptRoot '../../windows/runner/taskbar_tasks.cpp'
$build = Join-Path $env:RUNNER_TEMP ('baocode-taskbar-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $build | Out-Null
Push-Location $build
try {
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /wd4100 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source $implementation /Fe:taskbar_smoke.exe /link shell32.lib ole32.lib propsys.lib uuid.lib user32.lib
  if ($LASTEXITCODE -ne 0) { throw 'Taskbar smoke compilation failed' }
  & ./taskbar_smoke.exe $exe
  if ($LASTEXITCODE -ne 0) { throw "Taskbar smoke failed: $LASTEXITCODE" }
} finally { Pop-Location }
