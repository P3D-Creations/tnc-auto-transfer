# Reproduces posting an NC file WITHOUT STL export while a stale stem-named
# subfolder lingers from an earlier bundle (Processed moves files, not
# folders). The program must ship promptly - a static folder gets at most the
# two free grace extensions - and the emptied folder must be pruned so the
# next post does not stall at all. Network stubbed.
$ErrorActionPreference = 'Stop'
$SD = $PSScriptRoot
$src = Get-Content 'N:\Electronics and Software Projects\tnc-auto-transfer\TNCcmd-FolderWatcher.ps1' -Raw
$src = $src.Substring(0, $src.IndexOf('# MAIN SCRIPT'))
$src = $src -replace '(?m)^\$WatchFolder\s*=\s*".*"', ('$WatchFolder = "' + (Join-Path $SD 'watch4') + '"')
$src = $src -replace '(?m)^\$LogFile\s*=\s*".*"', '$LogFile = "$env:TEMP\standalone.log"'
$src = $src -replace '(?m)^\$EnableLogging\s*=\s*\$true', '$EnableLogging = $false'
$src = $src -replace 'TNCWatcher-Config.json', 'TNCWatcher-Config.HARNESS-IGNORED.json'
$src = $src -replace '(?m)^\$NcSettleDelaySeconds\s*=\s*\d+', '$NcSettleDelaySeconds = 3'
$src = $src -replace '(?m)^\$NcStableSeconds\s*=\s*\d+', '$NcStableSeconds = 2'
Invoke-Expression $src
$StlPrepExe = "N:/Electronics and Software Projects/tnc-auto-transfer/TNCWatcher-StlPrep.exe"

function Send-FileToMachine {
    param([string]$SourceFile,[string]$DestinationPath,[int]$Attempt=1)
    $script:Sent += "$DestinationPath\$([IO.Path]::GetFileName($SourceFile))"
    Write-Host ("    [SEND] {0}" -f "$DestinationPath\$([IO.Path]::GetFileName($SourceFile))") -ForegroundColor Cyan
    return @{ Success = $true; Retryable = $false }
}
function New-RemoteDirectory { param([string]$RemotePath,[string]$BasePath) }
function Remove-RemoteFile { param([string]$RemoteFilePath) return $true }

$script:Sent = @()
$w = Join-Path $SD 'watch4'
Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$parent = Join-Path $w 'UCF'
$stale  = Join-Path $parent 'chuck OP3'      # leftover shell of an earlier bundle
New-Item -ItemType Directory -Path $stale -Force | Out-Null
Set-Content (Join-Path $parent 'chuck OP3.h') "BEGIN PGM OP3 MM`nEND PGM OP3 MM"
$WatchFolder = $w
Initialize-WatchFolder

Write-Host "-> event: 'chuck OP3.h' posted with NO STL export, stale empty subfolder present" -ForegroundColor Yellow
$sw = [Diagnostics.Stopwatch]::StartNew()
Process-SingleFile -FilePath (Join-Path $parent 'chuck OP3.h')
$sw.Stop()
$elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

# With stable 2s + grace 3s + two free extensions (2 x 3s), the worst case is
# ~11s plus polling slack; the OLD behaviour (12 extensions) would be ~41s.
$sentOk  = @($script:Sent | Where-Object { $_ -like '*chuck OP3.h' }).Count -eq 1
$fastOk  = $elapsed -lt 20
$pruned  = -not (Test-Path $stale)

Write-Host "--- everything sent to the control ---" -ForegroundColor Yellow
$i=1; foreach ($s in $script:Sent) { "  $i. $s"; $i++ }
Write-Host ("RESULT: program sent exactly once      = {0}" -f $(if ($sentOk) { 'yes' } else { 'NO (BUG)' })) -ForegroundColor $(if ($sentOk) { 'Green' } else { 'Red' })
Write-Host ("RESULT: sent promptly ({0}s, limit 20s) = {1}" -f $elapsed, $(if ($fastOk) { 'yes' } else { 'NO (BUG)' })) -ForegroundColor $(if ($fastOk) { 'Green' } else { 'Red' })
Write-Host ("RESULT: stale empty subfolder pruned   = {0}" -f $(if ($pruned) { 'yes' } else { 'NO (BUG)' })) -ForegroundColor $(if ($pruned) { 'Green' } else { 'Red' })
