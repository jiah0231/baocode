# Default Edge browser selection, disposable runner only. No accounts or remote pages.
param([string]$OutputDirectory = 'build/translation-browser-previews')
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT' -or $env:BAOCODE_DISPOSABLE_UI_TEST -ne '1') {
  throw 'Browser selection smoke requires an explicitly enabled disposable Windows Actions desktop.'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $output | Out-Null
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
<style>html,body{margin:0;background:white;color:black;font:24px/24px monospace}p{position:absolute;left:40px;top:80px;margin:0;padding-left:32px;width:900px;box-sizing:border-box;white-space:pre;user-select:text}#second{top:180px}#decoy{top:280px}</style></head>
<body><p>Browser synthetic selection Echo</p><p id="second">Browser synthetic selection Foxtrot</p><p id="decoy">Unselected browser document decoy</p></body></html>
"@ | Set-Content -LiteralPath $html -Encoding utf8
$source = Join-Path $PSScriptRoot 'windows_translation_browser_smoke.cpp'
$test = $null
$browser = $null
$testSucceeded = $false
Push-Location $root
try {
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:browser_smoke.exe /link user32.lib advapi32.lib gdi32.lib dwmapi.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Browser selection harness compilation failed' }
  $url = ([Uri]$html).AbsoluteUri
  # Normal installed Edge, isolated profile and local page. No forced renderer
  # accessibility, UIA feature overrides, CDP, remote debugging, extensions or login.
  # Background networking is disabled, HTTP(S) uses an unused loopback proxy,
  # and the local HTML has a restrictive CSP. No external origin is requested.
  $arguments = @("--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync', '--disable-component-update', '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>', '--window-size=1100,650', '--window-position=40,40', "--app=`"$url`"")
  $browser = Start-Process -FilePath $edge -ArgumentList $arguments -PassThru
  $test = Start-Process -FilePath (Join-Path $root 'browser_smoke.exe') -ArgumentList @($token, "`"$output`"") -PassThru -NoNewWindow
  if (!$test.WaitForExit(60000)) { throw 'Default Edge selection smoke timed out' }
  if ($test.ExitCode -ne 0) { throw "Default Edge selection smoke failed: $($test.ExitCode). Do not claim browser support from RichEdit coverage." }
  $testSucceeded = $true
} finally {
  $primaryExitCode = $global:LASTEXITCODE
  # Preserve synthetic failure diagnostics even when the strict assertion fails.
  try {
    Add-Type -AssemblyName System.Drawing
    Get-ChildItem -LiteralPath $output -Filter '*-mismatch.bmp' | ForEach-Object {
      $bitmap = [System.Drawing.Bitmap]::FromFile($_.FullName)
      $png = [IO.Path]::ChangeExtension($_.FullName, '.png')
      try { $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png) }
      finally { $bitmap.Dispose() }
      Write-Output ('TRANSLATION_BROWSER_PREVIEW|' + [IO.Path]::GetFileNameWithoutExtension($png) + '|' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($png)))
    }
  } catch {
    Write-Warning "Synthetic browser screenshot export failed: $_"
  }
  try {
    if ($test) {
      $test.Refresh()
      if (!$test.HasExited) {
        try { Stop-Process -InputObject $test -Force -ErrorAction Stop }
        catch { $test.Refresh(); if (!$test.HasExited) { throw } }
      }
    }
    # Revalidate each PID immediately before killing it. Closing the browser
    # can already have ended renderer children from the original CIM snapshot.
    # Do not use taskkill /T on that stale list or affect unrelated Edge profiles.
    $candidates = @(Get-CimInstance Win32_Process -Filter "name = 'msedge.exe'" | Where-Object {
      $_.CommandLine -and $_.CommandLine.Contains($profile)
    })
    foreach ($candidate in $candidates) {
      $owned = $null
      try {
        $owned = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
        if (!$owned) { continue }
        # Cache a handle before rechecking identity, so subsequent termination
        # uses this process instance rather than an eventually reused PID.
        $null = $owned.Handle
        $current = Get-CimInstance Win32_Process -Filter "ProcessId = $($candidate.ProcessId) AND name = 'msedge.exe'"
        if (!$current -or $current.CreationDate -ne $candidate.CreationDate -or
            !$current.CommandLine -or !$current.CommandLine.Contains($profile)) { continue }
        if (!$owned.HasExited) { Stop-Process -InputObject $owned -Force -ErrorAction Stop }
      } catch {
        # Already gone is success. A still-running matching instance means a
        # real cleanup error, not an excuse to broaden the process kill scope.
        $remaining = Get-CimInstance Win32_Process -Filter "ProcessId = $($candidate.ProcessId) AND name = 'msedge.exe'"
        if ($remaining -and $remaining.CreationDate -eq $candidate.CreationDate -and
            $remaining.CommandLine -and $remaining.CommandLine.Contains($profile)) { throw }
      } finally {
        if ($owned) { $owned.Dispose() }
      }
    }
  } catch {
    if ($testSucceeded) { throw }
    Write-Warning "Browser cleanup also failed; preserving the primary test failure: $_"
  } finally {
    if ($test) { $test.Dispose() }
    if ($browser) { $browser.Dispose() }
    Pop-Location
    # Cleanup must not overwrite the compiler/test status. Test failures above
    # remain terminating exceptions; this never converts a failed test to pass.
    $global:LASTEXITCODE = $primaryExitCode
  }
}
