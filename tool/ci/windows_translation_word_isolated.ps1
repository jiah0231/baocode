# Optional local provider diagnostic, NOT the disposable-CI mouse-entry gate.
[CmdletBinding()]
param([switch]$AllowLocalIsolatedWord,
      [string]$OutputDirectory = 'build/translation-word-isolated')
$ErrorActionPreference = 'Stop'
if (!$AllowLocalIsolatedWord -or $env:OS -ne 'Windows_NT') {
  throw 'Requires Windows and explicit -AllowLocalIsolatedWord. No existing Word windows are used.'
}
if (Get-Process WINWORD -ErrorAction SilentlyContinue) {
  throw 'Word is already running. Nothing was launched or changed.'
}
$word = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WINWORD.EXE' -ErrorAction Stop).'(default)'
if (!$word -or !(Test-Path -LiteralPath $word -PathType Leaf)) { throw 'Installed Word is unavailable. Nothing was installed.' }
$null = Get-Command cl.exe -ErrorAction Stop
$output = [IO.Path]::GetFullPath((Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $output | Out-Null
$exe = Join-Path $output 'word_probe.exe'
$source = Join-Path $PSScriptRoot 'windows_translation_word_isolated.cpp'
& cl.exe /nologo /std:c++17 /EHsc /DNOMINMAX /DUNICODE /D_UNICODE $source "/Fe:$exe" "/Fo:$(Join-Path $output 'word_probe.obj')" /link user32.lib ole32.lib oleaut32.lib oleacc.lib advapi32.lib
if ($LASTEXITCODE -ne 0) { throw 'Word probe compilation failed.' }
(Get-Item -LiteralPath $word).VersionInfo | Select-Object FileVersion,ProductVersion | ConvertTo-Json | Set-Content (Join-Path $output 'version.json')
& $exe $word (Join-Path $output 'synthetic-word.rtf') 2>&1 | Tee-Object (Join-Path $output 'word-probe.log')
# Nonzero remains nonzero. Provider metadata alone is not end-to-end support.
exit $LASTEXITCODE
