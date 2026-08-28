# Replays the post's real behaviour against the size-stability gate:
#   t0..6   the parent-level NC file GROWS (engine still posting) - the gate
#           must never send a growing file (this is the partial-upload bug)
#   t7      onClose creates the stem-named subfolder (meshes about to copy)
#   t17     meshes + sidecar land in the subfolder
#   t18     onTerminate moves (or with NOMOVE=1, leaves) the parent copy
# Then a rescan sweep re-finds any leftover. Asserts the stray is never sent
# and that the bundle also deletes the parent-level stray ON THE CONTROL.
# Network stubbed.
$ErrorActionPreference='Stop'; $SD=$PSScriptRoot
Set-Location 'N:/Electronics and Software Projects/tnc-auto-transfer'
$src = Get-Content 'TNCcmd-FolderWatcher.ps1' -Raw
$src = $src.Substring(0,$src.IndexOf('# MAIN SCRIPT'))
$src = $src -replace '(?m)^\$WatchFolder\s*=\s*".*"', ('$WatchFolder = "'+(Join-Path $SD 'watch5')+'"')
$src = $src -replace '(?m)^\$LogFile\s*=\s*".*"','$LogFile = "$env:TEMP\timing.log"'
$src = $src -replace '(?m)^\$EnableLogging\s*=\s*\$true','$EnableLogging = $false'
$src = $src -replace 'TNCWatcher-Config.json', 'TNCWatcher-Config.HARNESS-IGNORED.json'
$src = $src -replace '(?m)^\$NcSettleDelaySeconds\s*=\s*\d+', '$NcSettleDelaySeconds = 3'
$src = $src -replace '(?m)^\$NcStableSeconds\s*=\s*\d+', '$NcStableSeconds = 2'
Invoke-Expression $src
$StlPrepExe = 'N:/Electronics and Software Projects/tnc-auto-transfer/TNCWatcher-StlPrep.exe'
function Send-FileToMachine { param($SourceFile,$DestinationPath,$Attempt=1)
  $script:Sent += "$DestinationPath\$([IO.Path]::GetFileName($SourceFile))"
  Write-Host "    [SEND] $DestinationPath\$([IO.Path]::GetFileName($SourceFile))" -ForegroundColor Cyan
  return @{Success=$true;Retryable=$false} }
function New-RemoteDirectory { param($RemotePath,$BasePath) }
function Remove-RemoteFile { param([string]$RemoteFilePath)
  $script:Deleted += $RemoteFilePath
  Write-Host "    [DEL ] $RemoteFilePath" -ForegroundColor DarkYellow
  return $true }
$script:Deleted = @()
$script:Sent=@()
$w=Join-Path $SD 'watch5'; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$parent=Join-Path $w 'Archer\Prop Hub'; $sub=Join-Path $parent 'Prop Hub Roughing'
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$WatchFolder=$w; Initialize-WatchFolder
$bundle='N:\Electronics and Software Projects\tnc-auto-transfer\Reference Docs\STL Export\STL Export Test'
Set-Content (Join-Path $parent 'Prop Hub Roughing.h') "BEGIN PGM MM"

# post: keep WRITING the parent file for 6s, mkdir the subfolder at 7s,
# land meshes+sidecar at 17s, move (or leave) the parent copy at 18s
$job = Start-Job -ScriptBlock {
  param($p,$s,$b)
  $nc = Join-Path $p 'Prop Hub Roughing.h'
  for ($i = 0; $i -lt 6; $i++) { Start-Sleep -Seconds 1; Add-Content $nc ("L X{0} Y{0} F5000" -f $i) }
  Start-Sleep -Seconds 1
  New-Item -ItemType Directory -Path $s -Force | Out-Null
  Start-Sleep -Seconds 10
  Copy-Item (Join-Path $b 'STOCK.stl') $s -Force
  Copy-Item (Join-Path $b 'PART.stl') $s -Force
  Copy-Item (Join-Path $b 'FIXTURE.stl') $s -Force
  $m = Get-Content (Join-Path $b 'FIXTURE.json') -Raw | ConvertFrom-Json
  $m.program.ncFile='Prop Hub Roughing.h'
  $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $s 'FIXTURE.json')
  Add-Content $nc "END PGM MM"
  Start-Sleep -Seconds 1
  if ($env:NOMOVE) { Copy-Item (Join-Path $p 'Prop Hub Roughing.h') (Join-Path $s 'Prop Hub Roughing.h') -Force }
  else { Move-Item (Join-Path $p 'Prop Hub Roughing.h') (Join-Path $s 'Prop Hub Roughing.h') -Force }
} -ArgumentList $parent,$sub,$bundle

Write-Host "-> event: transient .h at PARENT (still being written; post finishes at ~18s)" -ForegroundColor Yellow
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
$remoteDel=@($script:Deleted | Where-Object { $_ -eq 'TNC:\nc_prog\Archer\Prop Hub\Prop Hub Roughing.h' })
Write-Host ("RESULT: remote stray DEL attempted = {0}" -f $(if($remoteDel.Count){'yes'}else{'NO (BUG)'})) -ForegroundColor $(if($remoteDel.Count){'Green'}else{'Red'})
