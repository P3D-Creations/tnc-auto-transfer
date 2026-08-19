# Replays the REAL observed timing: transient NC at parent, sidecar+meshes
# appear 19s later, post moves the NC in at 19s. Then a later rescan re-finds
# any leftover. Network stubbed.
$ErrorActionPreference='Stop'; $SD=$PSScriptRoot
Set-Location 'N:/Electronics and Software Projects/tnc-auto-transfer'
$src = Get-Content 'TNCcmd-FolderWatcher.ps1' -Raw
$src = $src.Substring(0,$src.IndexOf('# MAIN SCRIPT'))
$src = $src -replace '(?m)^\$WatchFolder\s*=\s*".*"', ('$WatchFolder = "'+(Join-Path $SD 'watch5')+'"')
$src = $src -replace '(?m)^\$LogFile\s*=\s*".*"','$LogFile = "$env:TEMP\timing.log"'
$src = $src -replace '(?m)^\$EnableLogging\s*=\s*\$true','$EnableLogging = $false'
Invoke-Expression $src
$StlPrepExe = 'N:/Electronics and Software Projects/tnc-auto-transfer/TNCWatcher-StlPrep.exe'
function Send-FileToMachine { param($SourceFile,$DestinationPath,$Attempt=1)
  $script:Sent += "$DestinationPath\$([IO.Path]::GetFileName($SourceFile))"
  Write-Host "    [SEND] $DestinationPath\$([IO.Path]::GetFileName($SourceFile))" -ForegroundColor Cyan
  return @{Success=$true;Retryable=$false} }
function New-RemoteDirectory { param($RemotePath,$BasePath) }
$script:Sent=@()
$w=Join-Path $SD 'watch5'; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$parent=Join-Path $w 'Archer\Prop Hub'; $sub=Join-Path $parent 'Prop Hub Roughing'
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$WatchFolder=$w; Initialize-WatchFolder
$bundle='N:\Electronics and Software Projects\tnc-auto-transfer\Reference Docs\STL Export\STL Export Test'
Set-Content (Join-Path $parent 'Prop Hub Roughing.h') "BEGIN PGM MM`nEND PGM MM"

# post: 19s later create the subfolder, write meshes + sidecar, then move the NC in
$job = Start-Job -ScriptBlock {
  param($p,$s,$b)
  Start-Sleep -Seconds 19
  New-Item -ItemType Directory -Path $s -Force | Out-Null
  Copy-Item (Join-Path $b 'STOCK.stl') $s -Force
  Copy-Item (Join-Path $b 'PART.stl') $s -Force
  Copy-Item (Join-Path $b 'FIXTURE.stl') $s -Force
  $m = Get-Content (Join-Path $b 'FIXTURE.json') -Raw | ConvertFrom-Json
  $m.program.ncFile='Prop Hub Roughing.h'
  $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $s 'FIXTURE.json')
  if ($env:NOMOVE) { Copy-Item (Join-Path $p 'Prop Hub Roughing.h') (Join-Path $s 'Prop Hub Roughing.h') -Force }
  else { Move-Item (Join-Path $p 'Prop Hub Roughing.h') (Join-Path $s 'Prop Hub Roughing.h') -Force }
} -ArgumentList $parent,$sub,$bundle

Write-Host "-> event: transient .h at PARENT (post finishes 19s later)" -ForegroundColor Yellow
Process-SingleFile -FilePath (Join-Path $parent 'Prop Hub Roughing.h')
Wait-Job $job | Out-Null; Remove-Job $job
foreach ($n in 'STOCK.stl','PART.stl','FIXTURE.stl','FIXTURE.json','Prop Hub Roughing.h') {
  Process-SingleFile -FilePath (Join-Path $sub $n)
}
Write-Host "-> simulating the 5-min rescan finding anything left over" -ForegroundColor Yellow
foreach ($f in @(Get-ChildItem $parent -File -Recurse -ErrorAction SilentlyContinue)) {
  if ($f.FullName -notmatch '\(Processed|Failed)\') { Process-SingleFile -FilePath $f.FullName }
}
Write-Host "--- sent to control ---" -ForegroundColor Yellow
$i=1; foreach($x in $script:Sent){"  $i. $x";$i++}
$stray=@($script:Sent | Where-Object { $_ -eq 'TNC:\nc_prog\Archer\Prop Hub\Prop Hub Roughing.h' })
Write-Host ("RESULT: stray parent-level copy sent = {0}" -f $(if($stray.Count){'YES (BUG)'}else{'no'})) -ForegroundColor $(if($stray.Count){'Red'}else{'Green'})
