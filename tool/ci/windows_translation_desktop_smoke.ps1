# Real desktop application coverage. No software installation, user files,
# accounts, external pages, clipboard-copy fallback or model requests.
[CmdletBinding()]
param(
  [string]$OutputDirectory = 'build/translation-desktop-coverage',
  # Leave exploratory applications empty until exact capture is established by
  # real CI evidence. A required application must be present AND exactCaptured.
  [string[]]$RequireExactCapture = @()
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT' -or $env:BAOCODE_DISPOSABLE_UI_TEST -ne '1') {
  throw 'Desktop coverage requires an explicitly enabled disposable Windows Actions desktop.'
}
foreach ($required in $RequireExactCapture) {
  if ($required -notin @('notepad', 'edgePdf', 'console')) { throw "Unknown exact-capture gate: $required" }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $output | Out-Null
$root = Join-Path $env:RUNNER_TEMP ('baocode-desktop-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $root | Out-Null
$results = [Collections.Generic.List[object]]::new()
$testExe = Join-Path $root 'desktop_smoke.exe'

function Find-InstalledFile([string[]]$Candidates) {
  foreach ($candidate in $Candidates) {
    if (!$candidate) { continue }
    $item = Get-Item -Path $candidate -ErrorAction SilentlyContinue | Where-Object { !$_.PSIsContainer } | Select-Object -First 1
    if ($item) { return $item.FullName }
  }
  return $null
}
function Get-AppPath([string]$Name) {
  foreach ($hive in @('HKLM:', 'HKCU:')) {
    foreach ($prefix in @('SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')) {
      $key = Get-Item -LiteralPath "$hive\$prefix\$Name" -ErrorAction SilentlyContinue
      if ($key) {
        $value = $key.GetValue('')
        if ($value) {
          $path = [Environment]::ExpandEnvironmentVariables(([string]$value).Trim('"'))
          if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        }
      }
    }
  }
  return $null
}
function Get-FileVersion([string]$Path) {
  if ($Path) {
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.ProductVersion }
    catch { return $null } # Unknown metadata is not a launcher-version substitute.
  }
  return $null
}
function Add-Unrun([string]$Id, [string]$Application, [string]$Path, [string]$Detail) {
  $result = [pscustomobject][ordered]@{
    id = $Id; application = $Application
    availability = $(if ($Path) { 'installed' } else { 'notAvailable' })
    outcome = $(if ($Path) { 'notTested' } else { 'notAvailable' })
    captureStatus = 'notRun'; nativeCopyFallback = 'notTested'; version = Get-FileVersion $Path
    versionSource = 'inventoryExecutable'; sourceImagePath = $null; inventoryImagePath = $Path
    detail = $Detail; selectionVerified = $false; clipboardUnchanged = $null
  }
  $results.Add($result)
  $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output "$Id.json") -Encoding utf8
}
function Write-SyntheticPdf([string]$Path, [string]$Title) {
  # A real one-page PDF with text objects, a visible magenta position marker,
  # and an unselected decoy. No PDF library, download, script or remote asset.
  $stream = "1 0 1 rg 60 696 6 18 re f`n0 0 0 rg`nBT /F1 18 Tf 72 700 Td (PDF selected synthetic Echo) Tj ET`nBT /F1 18 Tf 72 640 Td (Unselected PDF document decoy) Tj ET`n"
  $objects = @(
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>',
    "<< /Length $([Text.Encoding]::ASCII.GetByteCount($stream)) >>`nstream`n${stream}endstream",
    "<< /Title ($Title) /Producer (BaoCode synthetic CI fixture) >>"
  )
  $pdf = [Text.StringBuilder]::new("%PDF-1.4`n")
  $offsets = [Collections.Generic.List[int]]::new()
  for ($i = 0; $i -lt $objects.Count; $i++) {
    $offsets.Add([Text.Encoding]::ASCII.GetByteCount($pdf.ToString()))
    $null = $pdf.Append("$($i + 1) 0 obj`n$($objects[$i])`nendobj`n")
  }
  $xref = [Text.Encoding]::ASCII.GetByteCount($pdf.ToString())
  $null = $pdf.Append("xref`n0 7`n0000000000 65535 f `n")
  foreach ($offset in $offsets) { $null = $pdf.Append(($offset.ToString('D10') + " 00000 n `n")) }
  $null = $pdf.Append("trailer`n<< /Size 7 /Root 1 0 R /Info 6 0 R >>`nstartxref`n$xref`n%%EOF`n")
  [IO.File]::WriteAllBytes($Path, [Text.Encoding]::ASCII.GetBytes($pdf.ToString()))
}
function Stop-OwnedProcess($Process) {
  if (!$Process) { return }
  try {
    $Process.Refresh()
    if (!$Process.HasExited) { Stop-Process -InputObject $Process -Force -ErrorAction Stop }
  } catch {
    $Process.Refresh()
    if (!$Process.HasExited) { throw }
  } finally { $Process.Dispose() }
}
function Stop-IsolatedEdge([string]$Profile) {
  # Only the unique test profile, rechecking identity after acquiring a process
  # handle. Never kill all Edge processes or use taskkill /T on stale PIDs.
  $candidates = @(Get-CimInstance Win32_Process -Filter "name = 'msedge.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($Profile)
  })
  foreach ($candidate in $candidates) {
    $owned = $null
    try {
      $owned = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
      if (!$owned) { continue }
      $null = $owned.Handle
      $current = Get-CimInstance Win32_Process -Filter "ProcessId = $($candidate.ProcessId) AND name = 'msedge.exe'"
      if (!$current -or $current.CreationDate -ne $candidate.CreationDate -or !$current.CommandLine -or !$current.CommandLine.Contains($Profile)) { continue }
      if (!$owned.HasExited) { Stop-Process -InputObject $owned -Force -ErrorAction Stop }
    } catch {
      $remaining = Get-CimInstance Win32_Process -Filter "ProcessId = $($candidate.ProcessId) AND name = 'msedge.exe'"
      if ($remaining -and $remaining.CreationDate -eq $candidate.CreationDate -and $remaining.CommandLine -and $remaining.CommandLine.Contains($Profile)) { throw }
    } finally { if ($owned) { $owned.Dispose() } }
  }
}
function Run-DesktopCase([string]$Id, [string]$Application, [string]$Path, [string]$Token, [string[]]$AppArguments) {
  if (!$Path) {
    Add-Unrun $Id $Application $null 'Application executable not found on this runner; no installation or capture attempt.'
    return
  }
  $app = $null; $test = $null; $caseRoot = Join-Path $root $Id
  $resultFile = Join-Path $output "$Id.json"
  # Do not accept a stale artifact from an earlier invocation in the same job.
  if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile -Force }
  try {
    if ($Id -ne 'console') {
      $app = Start-Process -FilePath $Path -ArgumentList $AppArguments -PassThru
      $null = $app.Handle
    }
    $test = Start-Process -FilePath $testExe -ArgumentList @($Id, $Token, "`"$output`"", "`"$caseRoot`"") -PassThru -NoNewWindow `
      -RedirectStandardOutput (Join-Path $output "$Id.stdout.log") -RedirectStandardError (Join-Path $output "$Id.stderr.log")
    if (!$test.WaitForExit(70000)) { throw "Desktop probe timed out for $Id" }
    $test.WaitForExit()
    Get-Content -LiteralPath (Join-Path $output "$Id.stdout.log") | Write-Host
    Get-Content -LiteralPath (Join-Path $output "$Id.stderr.log") | Write-Host
    if (!(Test-Path -LiteralPath $resultFile)) { throw "Desktop probe returned $($test.ExitCode) without a result for $Id" }
    $result = Get-Content -Raw -LiteralPath $resultFile | ConvertFrom-Json
    if ($result.id -ne $Id -or $result.outcome -notin @('exactCaptured', 'safeUnsupported', 'failed')) {
      throw "Desktop probe returned an invalid result for $Id"
    }
    if ($test.ExitCode -ne 0 -and $result.outcome -ne 'failed') { throw "Desktop probe exit code contradicts $Id result" }
    $result | Add-Member -NotePropertyName application -NotePropertyValue $Application -Force
    $result | Add-Member -NotePropertyName availability -NotePropertyValue 'installed' -Force
    $actualVersion = Get-FileVersion $result.sourceImagePath
    $versionSource = if ($actualVersion) { 'capturedSourceProcess' } else { 'unavailable' }
    $result | Add-Member -NotePropertyName version -NotePropertyValue $actualVersion -Force
    $result | Add-Member -NotePropertyName versionSource -NotePropertyValue $versionSource -Force
    $result | Add-Member -NotePropertyName launcherVersion -NotePropertyValue (Get-FileVersion $Path) -Force
    $results.Add($result)
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding utf8
  } catch {
    $result = [pscustomobject][ordered]@{
      id = $Id; application = $Application; availability = 'installed'; outcome = 'failed'
      captureStatus = 'notCompleted'; nativeCopyFallback = 'notTested'; version = $null
      versionSource = 'unavailable'; sourceImagePath = $null; launcherVersion = Get-FileVersion $Path
      detail = $_.Exception.Message; selectionVerified = $false; clipboardUnchanged = $null
    }
    $results.Add($result)
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding utf8
    Write-Warning $result.detail
  } finally {
    if ($test) { Stop-OwnedProcess $test }
    # These are handles for only the processes this case created. The probe also
    # closes the source HWND after checking its unique title and executable.
    if ($app) { Stop-OwnedProcess $app }
    if ($Id -eq 'console') {
      # Preserve host initialization/selection evidence, including failed setup.
      Get-ChildItem -LiteralPath $root -Filter 'console.*' -File -ErrorAction SilentlyContinue |
        Copy-Item -Destination $output -Force
    }
  }
}

Push-Location $root
try {
  $source = Join-Path $PSScriptRoot 'windows_translation_desktop_smoke.cpp'
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX $source /Fe:desktop_smoke.exe /link user32.lib gdi32.lib dwmapi.lib advapi32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Desktop coverage probe compilation failed' }

  $notepad = Find-InstalledFile @("$env:WINDIR\System32\notepad.exe")
  $notepadToken = 'BaoCodeDesktopNotepad-' + [guid]::NewGuid().ToString('N')
  $textFile = Join-Path $root "$notepadToken.txt"
  [IO.File]::WriteAllText($textFile, "Notepad selected synthetic Echo`r`nUnselected Notepad document decoy`r`n", [Text.UTF8Encoding]::new($false))
  Run-DesktopCase 'notepad' 'Windows Notepad' $notepad $notepadToken @("`"$textFile`"")

  $edge = Find-InstalledFile @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
  $pdfToken = 'BaoCodeDesktopPdf-' + [guid]::NewGuid().ToString('N')
  $pdfFile = Join-Path $root "$pdfToken.pdf"
  Write-SyntheticPdf $pdfFile $pdfToken
  Copy-Item -LiteralPath $pdfFile -Destination (Join-Path $output 'synthetic-selection.pdf')
  $profile = Join-Path $root 'edge-pdf-profile'
  New-Item -ItemType Directory -Force $profile | Out-Null
  $url = ([Uri]$pdfFile).AbsoluteUri + '#zoom=100'
  $edgeArguments = @("--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync', '--disable-component-update', '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>', '--window-size=1100,800', '--window-position=40,40', "--app=`"$url`"")
  try { Run-DesktopCase 'edgePdf' 'Microsoft Edge built-in PDF reader' $edge $pdfToken $edgeArguments }
  finally { if ($edge) { Stop-IsolatedEdge $profile } }

  $conhost = Find-InstalledFile @("$env:WINDIR\System32\conhost.exe")
  Run-DesktopCase 'console' 'Windows Console Host (conhost.exe), not Windows Terminal' $conhost ('BaoCodeDesktopConsole-' + [guid]::NewGuid().ToString('N')) @()

  # Inventory is NOT app coverage. Native RichEdit fixtures are never presented
  # as evidence of Microsoft Word, WPS, a PDF reader, or an Electron editor.
  $word = Get-AppPath 'WINWORD.EXE'
  if (!$word) { $word = Find-InstalledFile @("$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\WINWORD.EXE", "$env:ProgramFiles\Microsoft Office\Office16\WINWORD.EXE") }
  Add-Unrun 'officeWord' 'Microsoft Word' $word 'Inventory only. No Office document opened; native Edit/RichEdit fixture results do not establish Word support.'
  $wps = Get-AppPath 'wps.exe'
  if (!$wps) { $wps = Find-InstalledFile @("$env:ProgramFiles\Kingsoft\WPS Office\*\office6\wps.exe", "${env:ProgramFiles(x86)}\Kingsoft\WPS Office\*\office6\wps.exe", "$env:LOCALAPPDATA\Kingsoft\WPS Office\*\office6\wps.exe") }
  Add-Unrun 'wpsWriter' 'WPS Writer' $wps 'Inventory only. No WPS document opened and no WPS selection-capture claim.'
  $code = Get-AppPath 'Code.exe'
  if (!$code) { $code = Find-InstalledFile @("$env:ProgramFiles\Microsoft VS Code\Code.exe", "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe") }
  Add-Unrun 'vscode' 'Visual Studio Code' $code 'Inventory only. Chromium browser results do not establish Electron/editor support.'
  $adobe = Get-AppPath 'AcroRd32.exe'
  if (!$adobe) { $adobe = Get-AppPath 'Acrobat.exe' }
  Add-Unrun 'adobeReader' 'Adobe Acrobat / Reader' $adobe 'Inventory only. Edge PDF results do not establish Adobe Reader support.'
  $terminal = $null
  if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
    $package = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($package) { $terminal = Find-InstalledFile @((Join-Path $package.InstallLocation 'WindowsTerminal.exe')) }
  }
  if (!$terminal) { $terminal = Find-InstalledFile @("$env:ProgramFiles\WindowsApps\Microsoft.WindowsTerminal_*\WindowsTerminal.exe") }
  Add-Unrun 'windowsTerminal' 'Windows Terminal' $terminal 'Inventory only. Console Host is a different UIA provider and is not evidence of Windows Terminal support.'
} finally {
  $primaryExitCode = $global:LASTEXITCODE
  try {
    Add-Type -AssemblyName System.Drawing
    Get-ChildItem -LiteralPath $output -Filter '*.bmp' | ForEach-Object {
      $bitmap = [Drawing.Bitmap]::FromFile($_.FullName)
      try { $bitmap.Save([IO.Path]::ChangeExtension($_.FullName, '.png'), [Drawing.Imaging.ImageFormat]::Png) }
      finally { $bitmap.Dispose() }
    }
  } catch { Write-Warning "Synthetic desktop screenshot conversion failed: $_" }
  $summary = [ordered]@{
    schemaVersion = 1; observedUtc = [DateTime]::UtcNow.ToString('o')
    commit = $env:GITHUB_SHA; runnerImage = $env:ImageVersion
    capturePath = 'Production read-only UIA Capture; clipboard-copy fallback is not exercised'
    results = @($results.ToArray())
  }
  $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'desktop-coverage.json') -Encoding utf8
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add('# Windows desktop selection observations')
  $lines.Add('')
  $lines.Add('These are per-application observations, not a universal desktop-support claim. safeUnsupported means a verified selection was safely rejected, not passed translation support. Inventory-only applications were not tested.')
  $lines.Add('')
  $lines.Add('| Application | Version (source) | UIA outcome | Native copy fallback | Detail |')
  $lines.Add('| --- | --- | --- | --- | --- |')
  foreach ($result in $results) {
    $detail = ([string]$result.detail).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
    $lines.Add("| $($result.application) | $($result.version) ($($result.versionSource)) | $($result.outcome) | $($result.nativeCopyFallback) | $detail |")
    Write-Host "DESKTOP_COVERAGE|$($result.id)|$($result.outcome)|$($result.version)"
  }
  $lines | Set-Content -LiteralPath (Join-Path $output 'desktop-coverage.md') -Encoding utf8
  if ($env:GITHUB_STEP_SUMMARY) { $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
  Pop-Location
  $global:LASTEXITCODE = $primaryExitCode
}
$failures = @($results | Where-Object { $_.outcome -eq 'failed' })
foreach ($required in $RequireExactCapture) {
  $observed = @($results | Where-Object { $_.id -eq $required })
  if ($observed.Count -ne 1 -or $observed[0].outcome -ne 'exactCaptured') {
    throw "Required desktop exact-capture gate did not pass: $required. See desktop-coverage.json."
  }
}
if ($failures.Count) { throw "Desktop coverage has $($failures.Count) failure(s). See application JSON and synthetic screenshots; do not label these applications supported." }
# An exploration run may complete with safeUnsupported/notAvailable/notTested.
# Individual JSON outcomes, not this process exit code, define product support.
$global:LASTEXITCODE = 0
