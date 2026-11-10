[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Repository,
  [string]$Pdf,
  [string]$Output = (Join-Path $PSScriptRoot 'artifacts'),
  [int]$FromX=0, [int]$FromY=0, [int]$ToX=0, [int]$ToY=0,
  [int]$Zoom=100, [int]$ScrollY=450, [int]$ExpectedDpi=0,
  [switch]$Warm, [switch]$CalibrateOnly
)
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:OS -cne 'Windows_NT' -or $env:BAOCODE_DISPOSABLE_UI_TEST -cne '1') { throw 'Requires explicitly enabled disposable Windows GitHub Actions desktop' }
$expected='d159155dffad685a388562d1d2a4e0f869a5473be90c6c06381ab68a381451dc'
if (!$Pdf) {
  $Pdf=Join-Path $env:TEMP ('baocode-public-2608.11260-'+[guid]::NewGuid().ToString('N')+'.pdf')
  Invoke-WebRequest -Uri 'https://arxiv.org/pdf/2608.11260' -OutFile $Pdf
}
if ((Get-FileHash -LiteralPath $Pdf -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Source is not the exact approved public arXiv PDF' }
if ($Zoom -lt 25 -or $Zoom -gt 500 -or $ScrollY -lt 0) { throw 'Invalid viewport parameters' }
$Repository=(Resolve-Path $Repository).Path
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$Output=(Resolve-Path $Output).Path
$run=Join-Path $env:TEMP ('baocode-pdf-probe-'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $run 'profile'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$fixture=Join-Path $run '2608.11260.pdf'
Copy-Item -LiteralPath $Pdf -Destination $fixture
$edge=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (!$edge) { throw 'Edge unavailable' }
$impl=Join-Path $Repository 'windows/runner/translation_selection_action.cpp'
$include=Join-Path $Repository 'windows/runner'
$source=Join-Path $PSScriptRoot 'edge_pdf_probe.cpp'
$uri=([uri]$fixture).AbsoluteUri + "#page=1&zoom=$Zoom,0,$ScrollY"
$prefix=Join-Path $Output ('zoom'+$Zoom+'-scroll'+$ScrollY+'-dpi'+$ExpectedDpi+'-warm'+[int]$Warm.IsPresent+'-'+[guid]::NewGuid().ToString('N'))
$pushed=$false
$ownedProcess=$null
if (-not ('BaoCodePdfProbeCleanup' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BaoCodePdfProbeCleanup {
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr handle, uint exitCode);
 [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
}
'@
}

try {
  Push-Location $run; $pushed=$true
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /wd4100 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX /DBAOCODE_TRANSLATION_ACTION_DIAGNOSTICS "/I$include" $source $impl /Fe:edge_pdf_probe.exe /link user32.lib advapi32.lib gdi32.lib dwmapi.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib
  if ($LASTEXITCODE -ne 0) { throw 'Probe compilation failed' }
  # Unique fresh profile, app window containing ONLY the fixed local public PDF.
  # No force-renderer-accessibility, debugging port, CDP, extension, clipboard or OCR.
  $edgeArgs=@("--user-data-dir=`"$profile`"",'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-sync','--disable-component-update','--proxy-server=http://127.0.0.1:9','--proxy-bypass-list=<-loopback>',"--app=`"$uri`"")
  $started=Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru
  $owner=$null
  for($i=0;$i -lt 100;$i++) {
    $matches=@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) -and $_.CommandLine.Contains($uri) -and $_.CommandLine -notmatch '--type=' })
    if($matches.Count -eq 1){$owner=$matches[0];break}
    Start-Sleep -Milliseconds 100
  }
  if (!$owner) { throw 'Could not verify unique Edge owner with exact profile and document URI' }
  $ownedProcess=[System.Diagnostics.Process]::GetProcessById([int]$owner.ProcessId)
  $ownedHandle=$ownedProcess.Handle
  $ownedCreation=$ownedProcess.StartTime.ToUniversalTime()
  if ($ownedProcess.MainModule.FileName -ine $edge) { throw 'Owner executable mismatch' }
  Start-Sleep -Seconds 8
  $mode=if($CalibrateOnly){-1}elseif($Warm){1}else{0}
  @{
    source='https://arxiv.org/pdf/2608.11260'; sha256=$expected;
    browserExecutable=$edge; browserVersion=(Get-Item $edge).VersionInfo.FileVersion;
    ownerPid=$owner.ProcessId; profile=$profile; uri=$uri; zoomRequested=$Zoom; scrollRequested=$ScrollY;
    coordinates='physical pixels relative to GetWindowRect top-left, NOT document points';
    from=@($FromX,$FromY); to=@($ToX,$ToY); warm=$Warm.IsPresent; calibrationOnly=$CalibrateOnly.IsPresent;
    expectedDpi=$ExpectedDpi; note='PDF fragment zoom/scroll is a request, verify screenshot. Not cold-start acceptance evidence. PrintWindow may render blank GPU content.'
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ($prefix+'-manifest.json') -Encoding utf8
  $args=@($owner.ProcessId,$FromX,$FromY,$ToX,$ToY,"`"$prefix`"",$mode,$ExpectedDpi,"`"$edge`"")
  $probe=Start-Process -FilePath (Join-Path $run 'edge_pdf_probe.exe') -ArgumentList $args -PassThru -RedirectStandardOutput ($prefix+'-stdout.log') -RedirectStandardError ($prefix+'-stderr.log')
  if (!$probe.WaitForExit(60000)) { [BaoCodePdfProbeCleanup]::TerminateProcess($probe.Handle,2) | Out-Null; throw 'Probe timeout; diagnostic incomplete, not pass' }
  $probe.Refresh()
  Get-Content -LiteralPath ($prefix+'-stdout.log')
  if ($probe.ExitCode -ne 0) { throw "Probe returned $($probe.ExitCode); preserved logs/screenshots at $prefix" }
} finally {
  # Retained OS handle prevents PID reuse. Revalidate exact profile, URI and path.
  if ($ownedProcess -and [BaoCodePdfProbeCleanup]::WaitForSingleObject($ownedHandle,0) -eq 258) {
    $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($ownedProcess.Id)"
    if ($current -and $current.CommandLine.Contains($profile) -and $current.CommandLine.Contains($uri) -and $current.ExecutablePath -ieq $edge -and $ownedProcess.StartTime.ToUniversalTime() -eq $ownedCreation) {
      [BaoCodePdfProbeCleanup]::TerminateProcess($ownedHandle,0) | Out-Null
    } else { Write-Warning 'Cleanup identity check failed; refusing process termination' }
  }
  if ($ownedProcess) { $ownedProcess.Dispose() }
  if($pushed){Pop-Location}
  Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}
