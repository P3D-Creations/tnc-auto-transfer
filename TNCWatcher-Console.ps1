<#
================================================================================
  TNCWatcher Live Console
  Read-only live view of the TNCWatcher service log. Open as many of these as
  you like, on any account - closing it never affects the service.
  Launch via TNCWatcher-Console.cmd (double-click).
================================================================================
#>

$ServiceName = "TNCWatcher"
$LogFile     = Join-Path $PSScriptRoot "TNCcmd-Watcher.log"

$Host.UI.RawUI.WindowTitle = "TNCWatcher Live Console (read-only viewer)"

try { Clear-Host } catch {}

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
$status = if ($svc) { $svc.Status } else { "NOT INSTALLED" }
$statusColor = if ("$status" -eq "Running") { "Green" } else { "Red" }

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  TNCWatcher Live Console" -ForegroundColor Cyan
Write-Host -NoNewline "  Service status: "
Write-Host "$status" -ForegroundColor $statusColor
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host "  Close this window or press Ctrl+C to exit." -ForegroundColor DarkGray
Write-Host "  (The service keeps running - this is only a viewer.)" -ForegroundColor DarkGray
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $LogFile)) {
    Write-Host "Log file not found yet - waiting for the service to create it..." -ForegroundColor Yellow
    while (-not (Test-Path $LogFile)) { Start-Sleep -Seconds 2 }
}

# Tail the log forever, colorized like the original console output
Get-Content $LogFile -Tail 40 -Wait | ForEach-Object {
    switch -Regex ($_) {
        '\[ERROR\]'   { Write-Host $_ -ForegroundColor Red }
        '\[WARNING\]' { Write-Host $_ -ForegroundColor Yellow }
        '\[SUCCESS\]' { Write-Host $_ -ForegroundColor Green }
        '\[DEBUG\]'   { Write-Host $_ -ForegroundColor DarkGray }
        default       { Write-Host $_ }
    }
}
