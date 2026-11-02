# Disposable GitHub runner only: pinned old Setup -> new Setup, per-user.
# Does not change security settings, use real accounts, or test machine UAC.
param(
  [Parameter(Mandatory = $true)][string]$OldInstaller,
  [Parameter(Mandatory = $true)][string]$NewInstaller,
  [Parameter(Mandatory = $true)][string]$NewBundle,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$OldVersion
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP) {
  throw 'This destructive installation smoke test only runs on disposable Actions runners.'
}
if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') { throw 'Expected full numeric app version' }
$expected = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
if ($OldVersion -notmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') { throw 'Expected full numeric baseline version' }
$baseline = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
$root = Join-Path $env:RUNNER_TEMP ('baocode-upgrade-' + [guid]::NewGuid())
$appDir = Join-Path $root 'app'
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:BAOCODE_DATA_DIR = $dataDir
$marker = Join-Path $dataDir 'preserve-me.txt'
Set-Content $marker 'isolated test data'
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
  $p = Start-Process -FilePath $setup -ArgumentList $args -PassThru -Wait
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
  foreach ($relative in @('baocode.exe', 'data\app.so', 'bao_iroh.dll', 'baocode_wer.dll')) {
    $installedHash = (Get-FileHash (Join-Path $appDir $relative) -Algorithm SHA256).Hash
    $builtHash = (Get-FileHash (Join-Path $bundle $relative) -Algorithm SHA256).Hash
    if ($installedHash -ne $builtHash) { throw "Upgrade did not replace $relative with the tested build" }
  }
  if ((Get-Content $marker -Raw).Trim() -ne 'isolated test data') { throw 'Upgrade changed user data' }
  $process = Start-Process -FilePath $exe -PassThru
  Start-Sleep -Seconds 15
  $process.Refresh()
  if ($process.HasExited) { throw "Upgraded app failed startup: $($process.ExitCode)" }
  Write-Host "PASS: $OldVersion -> $Version per-user Setup, executable/AOT hashes, preserved data, startup"
} finally {
  if ($process) {
    $process.Refresh()
    if (!$process.HasExited) {
      Stop-Process -Id $process.Id
      $process.WaitForExit(10000) | Out-Null
    }
  }
  $uninstaller = Join-Path $appDir 'unins000.exe'
  if (Test-Path $uninstaller) {
    Start-Process $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait | Out-Null
  }
  # Keep runner-temp logs for diagnosing failure; the runner is discarded.
}
