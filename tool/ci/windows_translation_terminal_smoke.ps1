# Run only on a disposable Windows Actions desktop, using installed Windows
# Terminal. No install, shell profile, settings, delegation or account changes.
[CmdletBinding()]
param(
  [string]$OutputDirectory = 'build/translation-terminal-coverage',
  # Exploration may record explicit provider non-support, but never runtime
  # failures. The default is an exact-capture gate, not an availability check.
  [switch]$ObserveOnly
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT' -or $env:BAOCODE_DISPOSABLE_UI_TEST -ne '1') {
  throw 'Windows Terminal coverage requires an explicitly enabled disposable Windows Actions desktop.'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $output | Out-Null
$root = Join-Path $env:RUNNER_TEMP ('baocode-terminal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $root | Out-Null
$fixtureRoot = Join-Path $root 'terminal'
$resultFile = Join-Path $output 'windowsTerminal.json'
# Retained artifacts must all belong to this invocation, never a stale success.
Get-ChildItem -LiteralPath $output -Filter 'windowsTerminal*' -File |
  Remove-Item -Force
$result = [pscustomobject][ordered]@{
  id = 'windowsTerminal'; application = 'Windows Terminal'; availability = 'unknown'
  outcome = 'failed'; captureStatus = 'notRun'; detail = 'Probe did not complete'
  selectionVerified = $false; clipboardUnchanged = $null; copyProof = $false
  nativeCopyFallback = 'forbiddenNotExercised'; sourceImagePath = $null
  version = $null; versionSource = 'unavailable'; packageVersion = $null
}
$test = $null
$package = $null
$terminal = $null
$launcher = $null
$failure = $null

function Get-FileVersion([string]$Path) {
  if (!$Path) { return $null }
  return (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.ProductVersion
}
function Stop-OwnedProbe($Process) {
  if (!$Process) { return }
  try {
    $Process.Refresh()
    if (!$Process.HasExited) { Stop-Process -InputObject $Process -Force -ErrorAction Stop }
  } finally { $Process.Dispose() }
}

Push-Location $root
try {
  # Package registration is required. Do not guess a WindowsApps directory,
  # copy package binaries, install Terminal, or alter app execution aliases.
  $package = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction Stop |
    Sort-Object Version -Descending | Select-Object -First 1
  if (!$package) {
    $result.availability = 'notAvailable'
    $result.outcome = 'notAvailable'
    $result.detail = 'Windows Terminal is not registered on this runner; no install or selection attempt.'
  } else {
    $result.availability = 'installed'
    $result.packageVersion = $package.Version.ToString()
    $terminal = Join-Path $package.InstallLocation 'WindowsTerminal.exe'
    $launcher = Join-Path $package.InstallLocation 'wt.exe'
    if (!(Test-Path -LiteralPath $terminal -PathType Leaf) -or !(Test-Path -LiteralPath $launcher -PathType Leaf)) {
      throw 'The registered Windows Terminal package lacks its documented launcher or host executable.'
    }
    $result | Add-Member -NotePropertyName inventoryImagePath -NotePropertyValue $terminal -Force
    $result | Add-Member -NotePropertyName launcherImagePath -NotePropertyValue $launcher -Force
    $result | Add-Member -NotePropertyName packageFullName -NotePropertyValue $package.PackageFullName -Force
    $source = Join-Path $PSScriptRoot 'windows_translation_terminal_smoke.cpp'
    & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:terminal_smoke.exe /link user32.lib gdi32.lib dwmapi.lib advapi32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
    if ($LASTEXITCODE -ne 0) { throw 'Windows Terminal probe compilation failed' }
    $testExe = Join-Path $root 'terminal_smoke.exe'
    $token = 'BaoCodeSyntheticTerminal-' + [guid]::NewGuid().ToString('N')
    $arguments = @("`"$launcher`"", "`"$terminal`"", $token, "`"$output`"", "`"$fixtureRoot`"")
    $test = Start-Process -FilePath $testExe -ArgumentList $arguments -PassThru -NoNewWindow `
      -RedirectStandardOutput (Join-Path $output 'windowsTerminal.stdout.log') `
      -RedirectStandardError (Join-Path $output 'windowsTerminal.stderr.log')
    $null = $test.Handle
    if (!$test.WaitForExit(70000)) { throw 'Windows Terminal probe timed out' }
    $test.WaitForExit()
    Get-Content -LiteralPath (Join-Path $output 'windowsTerminal.stdout.log') | Write-Host
    Get-Content -LiteralPath (Join-Path $output 'windowsTerminal.stderr.log') | Write-Host
    if (!(Test-Path -LiteralPath $resultFile)) { throw "Terminal probe returned $($test.ExitCode) without a result" }
    $native = Get-Content -Raw -LiteralPath $resultFile | ConvertFrom-Json
    if ($native.id -ne 'windowsTerminal' -or $native.outcome -notin @('exactCaptured', 'safeUnsupported', 'failed')) {
      throw 'Terminal probe returned an invalid application or outcome'
    }
    $expectedExit = switch ($native.outcome) { 'exactCaptured' { 0 } 'safeUnsupported' { 3 } 'failed' { 1 } }
    if ($test.ExitCode -ne $expectedExit) { throw 'Terminal probe exit code contradicts its JSON outcome' }
    if ($native.outcome -in @('exactCaptured', 'safeUnsupported')) {
      if (!$native.selectionVerified -or !$native.clipboardUnchanged -or $native.copyProof -or $native.captureCalls -ne 1) {
        throw 'Terminal outcome lacks exact independent selection, one capture, and clipboard safety evidence'
      }
      if (![string]::Equals($native.sourceImagePath, $terminal, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Captured process executable is not the registered Windows Terminal host'
      }
    }
    $result = $native
    $result | Add-Member -NotePropertyName application -NotePropertyValue 'Windows Terminal' -Force
    $result | Add-Member -NotePropertyName availability -NotePropertyValue 'installed' -Force
    $result | Add-Member -NotePropertyName inventoryImagePath -NotePropertyValue $terminal -Force
    $result | Add-Member -NotePropertyName launcherImagePath -NotePropertyValue $launcher -Force
    $result | Add-Member -NotePropertyName packageFullName -NotePropertyValue $package.PackageFullName -Force
    $result | Add-Member -NotePropertyName packageVersion -NotePropertyValue $package.Version.ToString() -Force
    $version = if ($result.sourceImagePath) { Get-FileVersion $result.sourceImagePath } else { $null }
    $result | Add-Member -NotePropertyName version -NotePropertyValue $version -Force
    $versionSource = if ($version) { 'capturedSourceProcess' } else { 'unavailable' }
    $result | Add-Member -NotePropertyName versionSource -NotePropertyValue $versionSource -Force
  }
} catch {
  $failure = $_.Exception.Message
  $result.outcome = 'failed'
  $result.detail = $failure
  Write-Warning $failure
} finally {
  # Stop is consumed by only the uniquely named compiled fixture. Even if the
  # probe crashes, it never returns control to an interactive shell, and has a
  # fixed 60-second lifetime. Never Stop-Process WindowsTerminal/OpenConsole.
  [IO.File]::WriteAllText(($fixtureRoot + '.stop'), "stop`n")
  if ($test) { Stop-OwnedProbe $test }
  Get-ChildItem -LiteralPath $root -Filter 'terminal.*' -File -ErrorAction SilentlyContinue |
    Copy-Item -Destination $output -Force
  try {
    Add-Type -AssemblyName System.Drawing
    Get-ChildItem -LiteralPath $output -Filter 'windowsTerminal-*.bmp' | ForEach-Object {
      $bitmap = [Drawing.Bitmap]::FromFile($_.FullName)
      try { $bitmap.Save([IO.Path]::ChangeExtension($_.FullName, '.png'), [Drawing.Imaging.ImageFormat]::Png) }
      finally { $bitmap.Dispose() }
    }
  } catch {
    $result.outcome = 'failed'
    $result.detail = 'Synthetic Terminal screenshot conversion failed: ' + $_.Exception.Message
  }
  $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding utf8
  $summary = [ordered]@{
    schemaVersion = 1; observedUtc = [DateTime]::UtcNow.ToString('o')
    commit = $env:GITHUB_SHA; runnerImage = $env:ImageVersion
    capturePath = 'Production read-only UIA Capture, once, after independent pixel selection proof'
    scope = 'Installed Windows Terminal with direct synthetic compiled fixture only; no shell or model request'
    results = @($result)
  }
  $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'terminal-coverage.json') -Encoding utf8
  $lines = @(
    '# Windows Terminal selection observation', '',
    "Outcome: $($result.outcome). Version: $($result.version) ($($result.versionSource)); package: $($result.packageVersion).",
    '', $result.detail, '',
    'Only exactCaptured is selection-capture support for this tested version. safeUnsupported is explicit provider non-support, not a pass. Setup, gesture, focus, timeout and other runtime failures remain failed. No general desktop-support claim is made.'
  )
  $lines | Set-Content -LiteralPath (Join-Path $output 'terminal-coverage.md') -Encoding utf8
  if ($env:GITHUB_STEP_SUMMARY) { $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
  Write-Host "TERMINAL_COVERAGE|$($result.outcome)|$($result.version)|selectionVerified=$($result.selectionVerified)"
  Pop-Location
}
if ($result.outcome -eq 'failed') { throw 'Windows Terminal coverage failed; inspect terminal-coverage.json and fixture evidence.' }
if (!$ObserveOnly -and $result.outcome -ne 'exactCaptured') {
  throw 'Windows Terminal exact-capture gate did not pass. safeUnsupported/notAvailable do not establish support.'
}
$global:LASTEXITCODE = 0
