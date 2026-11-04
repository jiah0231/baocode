# Dedicated no-Chrome disposable GitHub runner only: pinned old Setup -> new Setup, per-user.
# Does not change security settings, use real accounts, or test machine UAC.
param(
  [Parameter(Mandatory = $true)][string]$OldInstaller,
  [Parameter(Mandatory = $true)][string]$NewInstaller,
  [Parameter(Mandatory = $true)][string]$NewBundle,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$OldVersion
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:BAOCODE_CI_RUNNER_KIND -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or !$env:RUNNER_TEMP) {
  throw 'This destructive installation smoke test only runs on disposable Actions runners.'
}
# Fail rather than interfere with any existing browser/app installation.
foreach ($name in @('chrome', 'msedge', 'chromium', 'baocode', 'baocode-browser-host')) {
  if (Get-Process -Name $name -ErrorAction SilentlyContinue) { throw "Unexpected existing process: $name" }
}
$registryKeys = @(
  'HKCU:\Software\Google\Chrome\NativeMessagingHosts\dev.baocode.browser',
  'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\dev.baocode.browser',
  'HKCU:\Software\Chromium\NativeMessagingHosts\dev.baocode.browser',
  'HKCU:\Software\Classes\baocode',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6fdd732b-95c6-4c37-af6f-ff574358deb5}_is1'
)
foreach ($item in @('*', 'Directory', 'Directory\Background')) {
  foreach ($menu in @('BaoCode', 'BaoCodeFastIde')) {
    $registryKeys += "HKCU:\Software\Classes\$item\shell\$menu"
  }
}
foreach ($key in $registryKeys) {
  if (Test-Path -LiteralPath $key) { throw "Unexpected pre-existing BaoCode registration: $key" }
}
if (Test-Path 'HKCU:\Software\BaoCode') { throw 'Unexpected pre-existing BaoCode application key' }
if (Test-Path (Join-Path $env:TEMP 'baocode-browser.port')) { throw 'Unexpected pre-existing browser bridge' }
if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') { throw 'Expected full numeric app version' }
$expected = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
if ($OldVersion -notmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') { throw 'Expected full numeric baseline version' }
$baseline = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
$root = Join-Path $env:RUNNER_TEMP ('baocode-upgrade-' + [guid]::NewGuid())
$appDir = Join-Path $root 'app'
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:BAOCODE_DATA_DIR = $dataDir
$env:BAOCODE_CLAUDE_DATA_PATH = Join-Path $root 'claude'
$originalAppData = $env:APPDATA
$appData = Join-Path $root 'appdata'
New-Item -ItemType Directory -Force $appData | Out-Null
$marker = Join-Path $dataDir 'preserve-me.txt'
Set-Content $marker 'isolated test data'
New-Item -ItemType Directory -Force (Join-Path $dataDir 'User') | Out-Null
Set-Content (Join-Path $dataDir 'User/settings.json') '{"browser.enabled":false}'

$old = (Resolve-Path $OldInstaller).Path
$new = (Resolve-Path $NewInstaller).Path
$bundle = (Resolve-Path $NewBundle).Path
$exe = Join-Path $appDir 'baocode.exe'
$process = $null
function Assert-Version([string]$path, [int[]]$parts) {
  $info = (Get-Item $path).VersionInfo
  $actual = @($info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart, $info.ProductPrivatePart)
  if (($actual -join '.') -ne ($parts -join '.')) {
    throw "Unexpected executable version: $($info.ProductVersion), numeric $($actual -join '.')"
  }
  Write-Host "Verified executable ProductVersion $($info.ProductVersion), numeric $($actual -join '.')"
}
function Install([string]$setup, [string]$log) {
  # Silent skips the default post-install launch. Empty tasks avoid shell/PATH shortcuts.
  $args = @('/CURRENTUSER', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=""', "/DIR=`"$appDir`"", "/LOG=`"$log`"")
  $p = Start-Process -FilePath $setup -ArgumentList $args -PassThru
  if (!$p.WaitForExit(180000)) {
    Stop-Process -Id $p.Id
    throw 'Owned Setup exceeded three-minute limit; no retry'
  }
  $p.Refresh()
  if ($p.ExitCode -ne 0) { throw "Setup failed: $($p.ExitCode); log: $log" }
}
try {
  Install $old (Join-Path $root 'old-install.log')
  Assert-Version $exe $baseline
  if (!(Test-Path (Join-Path $appDir 'unins000.exe'))) { throw 'Missing installation marker' }
  # No running app: exercise same-product same-marketing-version replacement,
  # not forced process closure. WAITPID/quit guards remain unit-tested separately.
  Install $new (Join-Path $root 'upgrade.log')
  Assert-Version $exe $expected
  foreach ($file in Get-ChildItem -LiteralPath $bundle -File -Recurse) {
    $relative = [IO.Path]::GetRelativePath($bundle, $file.FullName)
    $installedHash = (Get-FileHash (Join-Path $appDir $relative) -Algorithm SHA256).Hash
    $builtHash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
    if ($installedHash -ne $builtHash) { throw "Upgrade did not replace $relative with the tested build" }
  }
  foreach ($key in $registryKeys[0..2]) {
    if ((Get-Item -LiteralPath $key).GetValue('') -ne (Join-Path $appDir 'dev.baocode.browser.json')) {
      throw "Native host registration mismatch: $key"
    }
  }
  Write-Host 'Verified every installed bundle file against the exact new build and native-host registrations'
  if ((Get-Content $marker -Raw).Trim() -ne 'isolated test data') { throw 'Upgrade changed user data' }
  # Redirect only the app's native early log fallback; installer retains standard shell folders.
  $env:APPDATA = $appData
  try { $process = Start-Process -FilePath $exe -PassThru }
  finally { $env:APPDATA = $originalAppData }
  Start-Sleep -Seconds 15
  $process.Refresh()
  if ($process.HasExited) { throw "Upgraded app failed startup: $($process.ExitCode)" }
  foreach ($name in @('chrome', 'msedge', 'chromium', 'baocode-browser-host')) {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue) { throw "Unexpected browser/host process: $name" }
  }
  if (Test-Path (Join-Path $env:TEMP 'baocode-browser.port')) { throw 'Browser bridge unexpectedly active' }
  Write-Host "PASS: $OldVersion -> $Version per-user Setup, executable/AOT/native/helper hashes, preserved data, startup"
} finally {
  try {
  if ($process) {
    $process.Refresh()
    if (!$process.HasExited) {
      Stop-Process -Id $process.Id
      $process.WaitForExit(10000) | Out-Null
    }
  }
  $uninstaller = Join-Path $appDir 'unins000.exe'
  if (Test-Path $uninstaller) {
    $u = Start-Process $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru
    if (!$u.WaitForExit(120000)) { Stop-Process -Id $u.Id; throw 'Owned uninstaller timed out' }
    $u.Refresh()
    if ($u.ExitCode -ne 0) { throw "Uninstaller failed: $($u.ExitCode)" }
    foreach ($key in $registryKeys) {
      if (Test-Path -LiteralPath $key) { throw "Registration remained after uninstall: $key" }
    }
    $wer = 'HKCU:\Software\Microsoft\Windows\Windows Error Reporting\RuntimeExceptionHelperModules'
    if ((Test-Path $wer) -and $null -ne (Get-Item $wer).GetValue((Join-Path $appDir 'baocode_wer.dll'), $null)) {
      throw 'WER registration remained after uninstall'
    }
    # This app-owned diagnostic value is not removed by Inno. Only remove our exact temporary path.
    $logKey = 'HKCU:\Software\BaoCode'
    if (Test-Path $logKey) {
      $value = (Get-Item $logKey).GetValue('LogsFolder', $null)
      if ($null -ne $value) {
        if (!$value.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected LogsFolder path; will not remove' }
        Remove-ItemProperty -LiteralPath $logKey -Name LogsFolder
      }
      if ((Get-Item $logKey).ValueCount -eq 0 -and (Get-Item $logKey).SubKeyCount -eq 0) { Remove-Item -LiteralPath $logKey }
    }
    Write-Host 'Verified uninstall and registry cleanup'

  }
  } finally {
  $evidence = Join-Path $env:GITHUB_WORKSPACE 'build/install-evidence'
  New-Item -ItemType Directory -Force $evidence | Out-Null
  Get-ChildItem $root -Filter '*.log' | Copy-Item -Destination $evidence
  # Only disposable fake data and install logs; runner discarded after the job.
}
}
