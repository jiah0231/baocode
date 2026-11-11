[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Repository,
  [string]$Pdf,
  [string]$Output = (Join-Path $PSScriptRoot 'artifacts'),
  [int]$FromX=0, [int]$FromY=0, [int]$ToX=0, [int]$ToY=0,
  [int]$Zoom=100, [int]$ScrollY=450, [int]$ExpectedDpi=0,
  [switch]$Warm, [switch]$CalibrateOnly, [switch]$IA2, [switch]$ChromiumBoundIA2, [switch]$SelectedEmbeddedIA2
)
$ErrorActionPreference='Stop'
if ($SelectedEmbeddedIA2 -and !$ChromiumBoundIA2) { throw 'Selected object mode requires explicit -ChromiumBoundIA2' }
if ($ChromiumBoundIA2 -and !$IA2) { throw 'Chromium identity comparison requires explicit -IA2' }
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
  $extraCompile=@()
  if ($IA2) {
    $vendor=Join-Path $PSScriptRoot 'ia2_vendor'
    $pins=@{
      'AccessibleHypertext.idl'='1ec84a2927419eda602a73c5a852944eec799f40aaac35be05245d4e71966747'
      'AccessibleHyperlink.idl'='04e29b9ba7a62b0af559259ef6ffd6358c7896602668465e19ed38359f067809'
      'AccessibleAction.idl'='09f8cd3ad0b4b96738286a9316548f915c77f4c79509673f798edbdd7814bf5a'
      'AccessibleText.idl'='0f86b12a904044a7f9f0bc103cc25181bdec18b962c07a9fca13fd2b53ffb0a3'
      'IA2CommonTypes.idl'='84451f99df2a73a3e9e6548c5a079745c92c35ab51642081911ee53064cd3a94'
      'Accessible2.idl'='e3d6a3fa6f72a1e630c746abba9376508cf327a4ae7648fcd176cff8c90317f6'
      'AccessibleRelation.idl'='651febf3ccc1ceb76e8523ed3b6c1746ca578ead337d12b8bc20b6dde81636b0'
      'AccessibleStates.idl'='51124be3bd0f41de60a6120a7d50b693b88545de6634b888c4262b87aa2d1306'
    }
    foreach($name in $pins.Keys) {
      # Normalize only Windows checkout line endings; verify all source content.
      $idlText=[System.IO.File]::ReadAllText((Join-Path $vendor $name)).Replace("`r`n","`n")
      $hasher=[System.Security.Cryptography.SHA256]::Create()
      try { $actual=[System.BitConverter]::ToString($hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($idlText))).Replace('-','').ToLowerInvariant() } finally { $hasher.Dispose() }
      if ($actual -ne $pins[$name]) { throw "Official IA2 IDL pin mismatch: $name" }
    }
    & midl.exe /nologo /env x64 "/I$vendor" /out $run /h IA2CommonTypes.h (Join-Path $vendor 'IA2CommonTypes.idl')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned official IA2 common types generation failed' }
    foreach($name in @('AccessibleRelation','AccessibleStates')) {
      & midl.exe /nologo /env x64 "/I$vendor" /out $run /h ($name+'.h') (Join-Path $vendor ($name+'.idl'))
      if ($LASTEXITCODE -ne 0) { throw "Pinned official IA2 dependency generation failed: $name" }
    }
    & midl.exe /nologo /env x64 "/I$vendor" /out $run /h ia2_core_generated.h (Join-Path $vendor 'Accessible2.idl')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned official IA2 core generation failed' }
    & midl.exe /nologo /env x64 "/I$vendor" /out $run /h ia2_text_generated.h /iid ia2_text_i.c (Join-Path $vendor 'AccessibleText.idl')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned official IA2 IDL header generation failed' }
    if ($SelectedEmbeddedIA2) {
      Copy-Item (Join-Path $run 'ia2_text_generated.h') (Join-Path $run 'AccessibleText.h')
      foreach($name in @('AccessibleAction','AccessibleHyperlink','AccessibleHypertext')) {
        & midl.exe /nologo /env x64 "/I$vendor" /out $run /h ($name+'.h') (Join-Path $vendor ($name+'.idl'))
        if ($LASTEXITCODE -ne 0) { throw "Pinned selected-object IA2 header generation failed: $name" }
      }
    }
    $extraCompile=@('/DBAOCODE_PUBLIC_PDF_IA2_DIAGNOSTIC',"/I$run")
    if ($ChromiumBoundIA2) { $extraCompile += '/DBAOCODE_CHROMIUM_BOUND_IA2_DIAGNOSTIC' }
    if ($SelectedEmbeddedIA2) { $extraCompile += '/DBAOCODE_SELECTED_EMBEDDED_IA2_DIAGNOSTIC' }
  }
  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /wd4100 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX /DBAOCODE_TRANSLATION_ACTION_DIAGNOSTICS "/I$include" @extraCompile $source $impl /Fe:edge_pdf_probe.exe /link user32.lib advapi32.lib gdi32.lib dwmapi.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib oleacc.lib
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
    expectedDpi=$ExpectedDpi; ia2Diagnostic=$IA2.IsPresent; note='PDF fragment zoom/scroll is a request, verify screenshot. Not cold-start acceptance evidence. PrintWindow may render blank GPU content.'
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
