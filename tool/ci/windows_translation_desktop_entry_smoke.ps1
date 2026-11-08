# Actual desktop selection-entry tests. Run separately from the cold Capture
# probes. Each case is a new process and Edge uses a new, isolated local profile.
# No installation, credentials, remote pages, Ctrl+C, provider warm-up or models.
[CmdletBinding()]
param([string]$OutputDirectory = 'build/translation-desktop-entry')
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or $env:OS -ne 'Windows_NT' -or $env:BAOCODE_DISPOSABLE_UI_TEST -ne '1') {
  throw 'Desktop entry smoke requires an explicitly enabled disposable Windows Actions desktop.'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $output | Out-Null
$root = Join-Path $env:RUNNER_TEMP ('baocode-desktop-entry-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $root | Out-Null
$results = [Collections.Generic.List[object]]::new()
$testExe = Join-Path $root 'desktop_entry_smoke.exe'
function Find-InstalledFile([string[]]$Candidates) {
  foreach ($candidate in $Candidates) {
    if (!$candidate) { continue }
    $item = Get-Item -Path $candidate -ErrorAction SilentlyContinue | Where-Object { !$_.PSIsContainer } | Select-Object -First 1
    if ($item) { return $item.FullName }
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
function Run-EntryCase([string]$Id, [string]$Application, [string]$Path, [string]$Token, [string[]]$AppArguments) {
  $caseRoot = Join-Path $root $Id
  $resultFile = Join-Path $output "$Id.json"
  $app = $null; $test = $null
  # Never let artifacts left by an earlier invocation satisfy this run's gate.
  Get-ChildItem -LiteralPath $output -File | Where-Object {
    $_.BaseName -eq $Id -or $_.BaseName.StartsWith("$Id-") -or $_.Name.StartsWith("$Id.")
  } | Remove-Item -Force
  try {
    if (!$Path) { throw "Required installed application is unavailable: $Application. Nothing was installed or substituted." }
    if ($Id -eq 'edgePdf') {
      $app = Start-Process -FilePath $Path -ArgumentList $AppArguments -PassThru
      $null = $app.Handle
    }
    $arguments = @($Id, $Token, "`"$output`"", "`"$caseRoot`"", "`"$Path`"")
    $test = Start-Process -FilePath $testExe -ArgumentList $arguments -PassThru -NoNewWindow `
      -RedirectStandardOutput (Join-Path $output "$Id.stdout.log") `
      -RedirectStandardError (Join-Path $output "$Id.stderr.log")
    $null = $test.Handle
    if (!$test.WaitForExit(70000)) { throw "Desktop entry probe timed out: $Id" }
    $test.WaitForExit()
    Get-Content -LiteralPath (Join-Path $output "$Id.stdout.log") | Write-Host
    Get-Content -LiteralPath (Join-Path $output "$Id.stderr.log") | Write-Host
    if (!(Test-Path -LiteralPath $resultFile)) { throw "Desktop entry probe returned $($test.ExitCode) without a $Id result" }
    $result = Get-Content -Raw -LiteralPath $resultFile | ConvertFrom-Json
    if ($result.id -ne $Id -or $result.outcome -notin @('exactEntryCaptured', 'failed')) {
      throw "Invalid desktop entry result for $Id"
    }
    if ($test.ExitCode -ne 0 -and $result.outcome -ne 'failed') { throw "Desktop entry exit code contradicts the $Id result" }
    if ($result.outcome -eq 'exactEntryCaptured') {
      foreach ($field in @('entryVisible', 'entryNonactivating', 'entryHiddenAfterClick',
          'selectionBeforeClick', 'selectionAfterClick', 'sourceForegroundPreserved',
          'noMainWindow', 'clipboardUnchanged', 'exactSelectedText', 'callbackSourceMatches',
          'staleKeyboardTargetChanged', 'staleSelectionRejected', 'requestNotCanceledAtConsumption')) {
        if ($result.$field -ne $true) { throw "Missing positive entry assertion for $Id`: $field" }
      }
      if ($result.callbacksBeforeClick -ne 0 -or $result.callbacksAfterClick -ne 1 -or
          $result.captureCalls -ne 1 -or $result.gestureAttempts -ne 1 -or $result.copyProof -ne $false -or
          $result.firstUiaCaller -ne 'productionSelectionEntry' -or $result.captureStatus -ne 'ok') {
        throw "Incomplete cold-entry/click-only capture assertions for $Id"
      }
      $negativePhases = @('stale-changed', 'stale-rejected')
      if ($Id -eq 'edgePdf') {
        if ($result.mutationKind -eq 'focusedControlChange') {
          if ($result.staleSameSourceWindow -ne $true -or $result.staleChangedFocusType -ne 50004 -or
              $result.staleFocusIdentityChanged -ne $true -or $result.staleFocusMetadataVerified -ne $true -or
              $result.staleOriginalFocusPid -le 0 -or $result.staleOriginalFocusPid -ne $result.staleChangedFocusPid) {
            throw 'PDF keyboard negative did not prove a distinct focused Edit in the same source window'
          }
        } elseif ($result.mutationKind -eq 'sourceForegroundWindowChange') {
          $before = $result.mutationSourceWindow; $after = $result.mutationForegroundWindow
          if ($result.staleSameSourceWindow -ne $false -or $result.mutationSourceIdentityValid -ne $true -or
              $result.mutationForegroundMatchesPinnedSourceProcess -ne $true -or
              $before.hwnd -eq 0 -or $after.hwnd -eq 0 -or $before.hwnd -eq $after.hwnd -or
              $before.pid -le 0 -or $after.pid -ne $before.pid -or $after.root -ne $after.hwnd -or
              $after.visible -ne $true -or $result.noInputAfterForegroundMutation -ne $true -or
              $result.staleEntryClickAttempted -ne $false -or $result.staleCallbacks -ne 0 -or
              $result.staleStatus -ne 'entryDismissed' -or
              $result.negativeScreenshotOmission -ne 'sourceNoLongerForeground') {
            throw 'PDF foreground negative did not prove a known source-process window transition with zero capture/input'
          }
          $observed = @($result.foregroundTimeline | Where-Object {
            $_.tick -ge $result.mutationTick -and $_.window.hwnd -eq $after.hwnd -and $_.window.pid -eq $after.pid
          })
          if ($observed.Count -eq 0) { throw 'Missing timestamped foreground-window mutation proof' }
          # The original source is background and the new widget is not a
          # screenshot target. No background/unknown window pixels are allowed.
          foreach ($phase in $negativePhases) {
            if (Test-Path -LiteralPath (Join-Path $output "$Id-$phase.bmp")) {
              throw 'Foreground-mutation path unexpectedly captured a negative screenshot'
            }
          }
          $negativePhases = @()
        } else { throw 'Unknown PDF negative mutation scope' }
      }
      if ($Id -eq 'console' -and ($result.mutationKind -ne 'selectedRangeEndpointChange' -or
          $result.staleSameSourceWindow -ne $true)) {
        throw 'Console keyboard negative did not prove changed endpoints within the same source window'
      }
      foreach ($phase in (@('before', 'entry', 'after-click', 'stale-before') + $negativePhases)) {
        if (!(Test-Path -LiteralPath (Join-Path $output "$Id-$phase.bmp"))) {
          throw "Missing desktop entry screenshot for $Id`: $phase"
        }
      }
      if ($Id -eq 'console' -and ($result.hostIdentityVerified -ne $true -or
          $result.hostIntegrity -ne 8192 -or $result.sourceIntegrity -ne 8192)) {
        throw 'Console entry result did not verify an actual medium-integrity source and host'
      }
    }
    $result | Add-Member -NotePropertyName application -NotePropertyValue $Application -Force
    $versionPath = if ($Id -eq 'console' -and $result.hostIdentityVerified) { $result.hostImagePath } else { $result.sourceImagePath }
    $result | Add-Member -NotePropertyName version -NotePropertyValue (Get-FileVersion $versionPath) -Force
    $result | Add-Member -NotePropertyName versionSource -NotePropertyValue $(if ($Id -eq 'console') { 'verifiedConsoleHost' } else { 'capturedSourceProcess' }) -Force
    $results.Add($result)
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding utf8
  } catch {
    $result = [pscustomobject][ordered]@{
      id = $Id; application = $Application; outcome = 'failed'; captureStatus = 'notCompleted'
      detail = $_.Exception.Message; version = Get-FileVersion $Path
      versionSource = 'inventoryExecutable'; sourceImagePath = $null
    }
    $results.Add($result)
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding utf8
    Write-Warning $result.detail
  } finally {
    # This unique stop file is also observed if a timeout killed the harness
    # before its C++ identity-bound console-client cleanup could run.
    if ($Id -eq 'console') {
      [IO.File]::WriteAllText("$caseRoot.stop", "stop`n")
      [IO.File]::WriteAllText("$caseRoot.integrity-probe.stop", "stop`n")
      $privateIpc = "$caseRoot-ipc"
      if (Test-Path -LiteralPath $privateIpc -PathType Container) {
        [IO.File]::WriteAllText((Join-Path $privateIpc 'console.stop'), "stop`n")
      }
    }
    if ($test) { Stop-OwnedProcess $test }
    if ($app) { Stop-OwnedProcess $app }
    if ($Id -eq 'console') {
      Get-ChildItem -LiteralPath $root -Filter 'console.*' -File -ErrorAction SilentlyContinue |
        Copy-Item -Destination $output -Force
      if (Test-Path -LiteralPath "$caseRoot-ipc" -PathType Container) {
        Get-ChildItem -LiteralPath "$caseRoot-ipc" -Filter 'console.*' -File |
          Copy-Item -Destination $output -Force
      }
    }
  }
}

Push-Location $root
try {
  $source = Join-Path $PSScriptRoot 'windows_translation_desktop_entry_smoke.cpp'
  $implementation = Join-Path $PSScriptRoot '../../windows/runner/translation_selection_action.cpp'
  # Only the passive SelectionBounds helper and SelectionTarget are metadata-
  # only. The separate explicit-click path now reads its pinned range on the
  # original MTA; rejecting all GetText in the whole action would reject the
  # secure API itself. No fixture may call the old generic HWND Capture path.
  $entryCode = Get-Content -Raw -LiteralPath $implementation
  $targetCode = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../windows/runner/translation_selection_target.h')
  $metadata = [regex]::Match($entryCode, '(?s)std::optional<RECT> SelectionBounds\(.*?\r?\n\}')
  if (!$metadata.Success) { throw 'Cannot locate passive selection-entry metadata helper' }
  if (($metadata.Value + $targetCode) -match '->\s*(GetText|GetDocumentRange|get_DocumentRange|GetCurrentPropertyValue|FindAll|FindFirst)\s*\(' -or
      ($metadata.Value + $targetCode) -match '\b(GetClipboardData|OpenClipboard|UIA_ValuePatternId|UIA_NamePropertyId|WH_KEYBOARD_LL)\b') {
    throw 'Passive entry metadata path contains a prohibited text, tree-scan or clipboard read'
  }
  $probeCode = Get-Content -Raw -LiteralPath $source
  if ($probeCode -match 'translation_selection::Capture\s*\(' -or
      $probeCode -notmatch 'action->CaptureClickedSelection\s*\(') {
    throw 'Desktop entry probe must use only the action-owned pinned-selection capture API'
  }
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /wd4100 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX `
    $source $implementation /Fe:desktop_entry_smoke.exe /link user32.lib gdi32.lib dwmapi.lib advapi32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Desktop entry probe compilation failed' }

  $edge = Find-InstalledFile @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
  $pdfToken = 'BaoCodeDesktopEntryPdf-' + [guid]::NewGuid().ToString('N')
  $pdfFile = Join-Path $root "$pdfToken.pdf"
  Write-SyntheticPdf $pdfFile $pdfToken
  Copy-Item -LiteralPath $pdfFile -Destination (Join-Path $output 'synthetic-entry-selection.pdf')
  $profile = Join-Path $root 'fresh-edge-entry-profile'
  New-Item -ItemType Directory -Force $profile | Out-Null
  $url = ([Uri]$pdfFile).AbsoluteUri + '#zoom=100'
  $edgeArguments = @("--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-sync', '--disable-component-update',
    '--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=<-loopback>',
    '--window-size=1100,800', '--window-position=40,40', "--app=`"$url`"")
  try { Run-EntryCase 'edgePdf' 'Microsoft Edge built-in PDF reader' $edge $pdfToken $edgeArguments }
  finally { if ($edge) { Stop-IsolatedEdge $profile } }

  [IO.File]::WriteAllText((Join-Path $output 'synthetic-entry-console.txt'),
    "Console selected synthetic Echo`r`n`r`nUnselected console output decoy`r`n", [Text.UTF8Encoding]::new($false))
  $conhost = Find-InstalledFile @("$env:WINDIR\System32\conhost.exe")
  Run-EntryCase 'console' 'Windows Console Host, own synthetic client (no shell)' $conhost `
    ('BaoCodeDesktopEntryConsole-' + [guid]::NewGuid().ToString('N')) @()
} finally {
  $primaryExitCode = $global:LASTEXITCODE
  try {
    Add-Type -AssemblyName System.Drawing
    Get-ChildItem -LiteralPath $output -Filter '*.bmp' -File | ForEach-Object {
      $bitmap = [Drawing.Bitmap]::FromFile($_.FullName)
      try { $bitmap.Save([IO.Path]::ChangeExtension($_.FullName, '.png'), [Drawing.Imaging.ImageFormat]::Png) }
      finally { $bitmap.Dispose() }
    }
  } catch { Write-Warning "Desktop entry screenshot conversion failed: $_" }
  $summary = [ordered]@{
    schemaVersion = 1; observedUtc = [DateTime]::UtcNow.ToString('o')
    commit = $env:GITHUB_SHA; runnerImage = $env:ImageVersion
    scope = 'Real desktop cold selection -> production nonactivating entry -> physical click -> pinned-range capture on the original MTA. Then verify rejection after the exact keyboard mutation named by mutationKind: selected endpoints, a same-window focused control, or a different foreground window belonging to the pinned source process. No model request or Flutter popup in this native probe.'
    coldIsolation = 'Separate positive process per application; new Edge PDF profile; no positive-source UIA preflight or accessibility-forcing flags; one cold positive drag, then a warm stale-selection negative phase. Console integrity diagnosis uses a different subprocess and host that exit before the fresh positive source is launched.'
    consoleIntegrity = 'RIDs: 8192=medium, 12288=high. The inherited-token diagnostic preserves elevated production rejection. Only after that exact rejection may the shared test-only launcher create an independent restricted-medium synthetic host; production acceptance and system settings are unchanged.'
    results = @($results.ToArray())
  }
  $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'desktop-entry-coverage.json') -Encoding utf8
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add('# Windows desktop translation entry observations')
  $lines.Add('')
  $lines.Add($summary.scope)
  $lines.Add('')
  $lines.Add('PDF negative: Ctrl+F must prove either a different same-process, visible, non-password Edit in the source HWND, or another foreground HWND belonging to the pinned source process. The latter is source-foreground change, not a same-window control or text-range change; it must hide the old entry with zero capture and no further input. Negative screenshots are deliberately omitted when the original source is background; the HWND/PID/class/owner timeline records that transition without reading captions or pixels. Console negative: Shift+Left must change native selection endpoints in the same HWND. Separate native action tests cover same-window control/range changes.')
  $lines.Add('')
  $lines.Add('These are per-application entry tests, not universal desktop support. Existing cold Capture probes run separately and remain unchanged. An unsupported or unavailable required app fails this entry gate.')
  $lines.Add('')
  foreach ($result in $results) {
    $lines.Add("- $($result.application): $($result.outcome). $($result.detail)")
    Write-Host "DESKTOP_ENTRY_GATE|$($result.id)|$($result.outcome)|$($result.version)"
  }
  $lines | Set-Content -LiteralPath (Join-Path $output 'desktop-entry-coverage.md') -Encoding utf8
  if ($env:GITHUB_STEP_SUMMARY) { $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
  Pop-Location
  $global:LASTEXITCODE = $primaryExitCode
}
foreach ($required in @('edgePdf', 'console')) {
  $observed = @($results | Where-Object { $_.id -eq $required })
  if ($observed.Count -ne 1 -or $observed[0].outcome -ne 'exactEntryCaptured') {
    throw "Required desktop entry gate did not pass: $required. Inspect desktop-entry-coverage.json, logs and synthetic screenshots."
  }
}
$global:LASTEXITCODE = 0
