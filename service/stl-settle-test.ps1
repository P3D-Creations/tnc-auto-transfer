# Reproduces the post's real sequence: NC file appears at the PARENT level
# during posting, sidecar+meshes land in the subfolder, then onTerminate moves
# the NC file in. Network stubbed.
$ErrorActionPreference = 'Stop'
$SD = $PSScriptRoot
$src = Get-Content 'N:\Electronics and Software Projects\tnc-auto-transfer\TNCcmd-FolderWatcher.ps1' -Raw
$src = $src.Substring(0, $src.IndexOf('# MAIN SCRIPT'))
$src = $src -replace '(?m)^\$WatchFolder\s*=\s*".*"', ('$WatchFolder = "' + (Join-Path $SD 'watch2') + '"')
$src = $src -replace '(?m)^\$LogFile\s*=\s*".*"', '$LogFile = "$env:TEMP\settle.log"'
$src = $src -replace '(?m)^\$EnableLogging\s*=\s*\$true', '$EnableLogging = $false'
$src = $src -replace 'TNCWatcher-Config.json', 'TNCWatcher-Config.HARNESS-IGNORED.json'
$src = $src -replace '(?m)^\$NcSettleDelaySeconds\s*=\s*\d+', '$NcSettleDelaySeconds = 3'
$src = $src -replace '(?m)^\$NcStableSeconds\s*=\s*\d+', '$NcStableSeconds = 2'
$src = $src -replace '(?m)^\$NcSettleDelaySeconds\s*=\s*15', '$NcSettleDelaySeconds = 3'   # keep the test quick
Invoke-Expression $src
$StlPrepExe = "N:/Electronics and Software Projects/tnc-auto-transfer/TNCWatcher-StlPrep.exe"

function Send-FileToMachine {
    param([string]$SourceFile,[string]$DestinationPath,[int]$Attempt=1)
    $script:Sent += "$DestinationPath\$([IO.Path]::GetFileName($SourceFile))"
    Write-Host ("    [SEND] {0}" -f "$DestinationPath\$([IO.Path]::GetFileName($SourceFile))") -ForegroundColor Cyan
    return @{ Success = $true; Retryable = $false }
}
function New-RemoteDirectory { param([string]$RemotePath,[string]$BasePath) }
function Remove-RemoteFile { param([string]$RemoteFilePath)
  $script:Deleted += $RemoteFilePath
  Write-Host "    [DEL ] $RemoteFilePath" -ForegroundColor DarkYellow
  return $true }
$script:Deleted = @()

$script:Sent = @()
$w = Join-Path $SD 'watch2'
Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$parent = Join-Path $w 'Archer\Prop Hub'
$sub    = Join-Path $parent 'Prop Hub OP1'
New-Item -ItemType Directory -Path $sub -Force | Out-Null
$bundle = 'N:\Electronics and Software Projects\tnc-auto-transfer\Reference Docs\STL Export\STL Export Test'
Copy-Item (Join-Path $bundle 'STOCK.stl')   $sub -Force
Copy-Item (Join-Path $bundle 'PART.stl')    $sub -Force
Copy-Item (Join-Path $bundle 'FIXTURE.stl') $sub -Force
# sidecar rewritten to name the NC file used here
$m = Get-Content (Join-Path $bundle 'FIXTURE.json') -Raw | ConvertFrom-Json
$m.program.ncFile = 'Prop Hub OP1.h'
$m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $sub 'FIXTURE.json')
# the transient NC copy, at the PARENT level, as the post leaves it while posting
Set-Content (Join-Path $parent 'Prop Hub OP1.h') "BEGIN PGM OP1 MM`nEND PGM OP1 MM"
$WatchFolder = $w
Initialize-WatchFolder

# Background: emulate onTerminate moving the NC file into the subfolder,
# partway through the watcher's settle delay.
$mover = $null
if (-not $env:NOMOVE) {
  $mover = Start-Job -ScriptBlock {
      param($p,$s)
      Start-Sleep -Milliseconds 1500
      Move-Item (Join-Path $p 'Prop Hub OP1.h') (Join-Path $s 'Prop Hub OP1.h') -Force
  } -ArgumentList $parent,$sub
} else {
  Copy-Item (Join-Path $parent 'Prop Hub OP1.h') (Join-Path $sub 'Prop Hub OP1.h') -Force
}

Write-Host "-> event: transient 'Prop Hub OP1.h' at PARENT level" -ForegroundColor Yellow
Process-SingleFile -FilePath (Join-Path $parent 'Prop Hub OP1.h')
if ($mover) { Wait-Job $mover | Out-Null; Remove-Job $mover }

foreach ($n in 'STOCK.stl','PART.stl','FIXTURE.stl','FIXTURE.json','Prop Hub OP1.h') {
    Write-Host "-> event: $n (in subfolder)" -ForegroundColor Yellow
    Process-SingleFile -FilePath (Join-Path $sub $n)
}

Write-Host "--- everything sent to the control ---" -ForegroundColor Yellow
$i=1; foreach ($s in $script:Sent) { "  $i. $s"; $i++ }
$stray = @($script:Sent | Where-Object { $_ -eq 'TNC:\nc_prog\Archer\Prop Hub\Prop Hub OP1.h' })
Write-Host ("RESULT: stray parent-level copy sent = {0}" -f $(if ($stray.Count) { 'YES (BUG)' } else { 'no' })) -ForegroundColor $(if ($stray.Count) { 'Red' } else { 'Green' })
