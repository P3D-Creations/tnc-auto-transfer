# Loads the watcher's functions without starting it, stubs the transfer, and
# drives Process-SingleFile over a synthetic bundle. Machine stays untouched.
$ErrorActionPreference = 'Stop'
$SD = $PSScriptRoot
$src = Get-Content 'N:\Electronics and Software Projects\tnc-auto-transfer\TNCcmd-FolderWatcher.ps1' -Raw
# Cut everything from the MAIN SCRIPT banner so nothing runs.
$cut = $src.IndexOf('# MAIN SCRIPT')
$src = $src.Substring(0, $cut)
$src = $src -replace '(?m)^\$WatchFolder\s*=\s*".*"', ('$WatchFolder = "' + (Join-Path $SD 'watch') + '"')
$src = $src -replace '(?m)^\$LogFile\s*=\s*".*"',     '$LogFile = "$env:TEMP\harness.log"'
$src = $src -replace '(?m)^\$EnableLogging\s*=\s*\$true', '$EnableLogging = $false'
$src = $src -replace 'TNCWatcher-Config.json', 'TNCWatcher-Config.HARNESS-IGNORED.json'
$src = $src -replace '(?m)^\$NcSettleDelaySeconds\s*=\s*\d+', '$NcSettleDelaySeconds = 3'
$src = $src -replace '(?m)^\$NcStableSeconds\s*=\s*\d+', '$NcStableSeconds = 2'
Invoke-Expression $src
$StlPrepExe = "N:/Electronics and Software Projects/tnc-auto-transfer/TNCWatcher-StlPrep.exe"

# Stub the network so nothing touches the control.
function Send-FileToMachine {
    param([string]$SourceFile, [string]$DestinationPath, [int]$Attempt = 1)
    $script:Sent += [PSCustomObject]@{ File = [IO.Path]::GetFileName($SourceFile); Dest = $DestinationPath }
    Write-Host ("    [SEND] {0,-14} -> {1}" -f [IO.Path]::GetFileName($SourceFile), $DestinationPath) -ForegroundColor Cyan
    return @{ Success = $true; Retryable = $false }
}
function New-RemoteDirectory { param([string]$RemotePath, [string]$BasePath) }
function Remove-RemoteFile { param([string]$RemoteFilePath)
  $script:Deleted += $RemoteFilePath
  Write-Host "    [DEL ] $RemoteFilePath" -ForegroundColor DarkYellow
  return $true }
$script:Deleted = @()

$script:Sent = @()
$w = Join-Path $SD 'watch'
Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $w 'OP1') -Force | Out-Null
Copy-Item (Join-Path $SD 'bundle\*') (Join-Path $w 'OP1') -Force
$WatchFolder = $w
Initialize-WatchFolder

$mode = if ($args.Count -gt 0) { $args[0] } else { 'layoutA' }
$f = Join-Path $w 'OP1'
Write-Host "=== $mode ===" -ForegroundColor Yellow
if ($mode -eq 'layoutA') {
    # subfolder layout: meshes, then sidecar, then the NC file last
    foreach ($n in 'STOCK.stl','PART.stl','FIXTURE.stl','FIXTURE.json','OP1.h') {
        Write-Host "  -> event: $n"
        Process-SingleFile -FilePath (Join-Path $f $n)
    }
} else {
    # flat layout: NC file first, then meshes, sidecar last
    foreach ($n in 'OP1.h','STOCK.stl','PART.stl','FIXTURE.stl','FIXTURE.json') {
        Write-Host "  -> event: $n"
        Process-SingleFile -FilePath (Join-Path $f $n)
    }
}
Write-Host "--- send order ---" -ForegroundColor Yellow
$i=1; foreach ($s in $script:Sent) { "  $i. $($s.File)"; $i++ }
Write-Host "--- leftovers in watch folder (should be empty) ---" -ForegroundColor Yellow
Get-ChildItem $f -File | ForEach-Object { "  LEFT: $($_.Name)" }
