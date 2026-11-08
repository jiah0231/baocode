# Default Edge browser selection, disposable runner only. No accounts or remote pages.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT' -or $env:BAOCODE_DISPOSABLE_UI_TEST -ne '1') {
  throw 'Browser selection smoke requires an explicitly enabled disposable Windows Actions desktop.'
}
$edge = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (!$edge) { throw 'Installed Microsoft Edge unavailable; browser coverage cannot be skipped.' }
Write-Host "Default Edge version: $((Get-Item -LiteralPath $edge).VersionInfo.ProductVersion)"
$root = Join-Path $env:RUNNER_TEMP ('baocode-browser-' + [guid]::NewGuid().ToString('N'))
$profile = Join-Path $root 'profile'
$token = 'BaoCodeBrowserFixture-' + [guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Force $profile | Out-Null
$html = Join-Path $root 'selection.html'
@"
<!doctype html>
<html><head><meta charset="utf-8"><title>$token</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; connect-src 'none'">
<style>html,body{margin:0;background:white;color:black;font:24px/24px monospace}p{position:absolute;left:40px;top:80px;margin:0;white-space:pre;user-select:text}#second{top:180px}#decoy{top:280px}</style></head>
<body><p>Browser synthetic selection Echo</p><p id="second">Browser synthetic selection Foxtrot</p><p id="decoy">Unselected browser document decoy</p></body></html>
"@ | Set-Content -LiteralPath $html -Encoding utf8
$source = Join-Path $PSScriptRoot 'windows_translation_browser_smoke.cpp'
$test = $null
$browser = $null
Push-Location $root
try {
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:browser_smoke.exe /link user32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Browser selection harness compilation failed' }
  $url = ([Uri]$html).AbsoluteUri
  # Normal installed Edge, isolated profile and local page. No forced renderer
  # accessibility, UIA feature overrides, CDP, remote debugging, extensions or login.
  # Background networking is disabled, HTTP(S) uses an unused loopback proxy,
  # and the local HTML has a restrictive CSP. No external origin is requested.
  $arguments = @("--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync', '--disable-component-update', '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>', '--window-size=1100,650', '--window-position=40,40', "--app=`"$url`"")
  $browser = Start-Process -FilePath $edge -ArgumentList $arguments -PassThru
  $test = Start-Process -FilePath (Join-Path $root 'browser_smoke.exe') -ArgumentList $token -PassThru -NoNewWindow
  if (!$test.WaitForExit(60000)) { throw 'Default Edge selection smoke timed out' }
  if ($test.ExitCode -ne 0) { throw "Default Edge selection smoke failed: $($test.ExitCode). Do not claim browser support from RichEdit coverage." }
} finally {
  if ($test) {
    $test.Refresh()
    if (!$test.HasExited) { & taskkill /PID $test.Id /T /F | Out-Null }
    $test.Dispose()
  }
  # Only terminate processes bearing this unique disposable profile path.
  Get-CimInstance Win32_Process -Filter "name = 'msedge.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($profile)
  } | ForEach-Object { & taskkill /PID $_.ProcessId /T /F | Out-Null }
  if ($browser) { $browser.Dispose() }
  Pop-Location
}
