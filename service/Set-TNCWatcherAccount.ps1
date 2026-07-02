<#
================================================================================
  Sets the account the TNCWatcher service runs as, then restarts the service.

  The service account must have access to the NAS watch folder
  (\\P3D_NAS\...). LocalSystem authenticates to the network as the COMPUTER
  account, which most NAS boxes reject - so the service normally needs to run
  as your own user account.

  Re-run this any time your Windows password changes, or the service will
  fail to start.

  Launch via Set-TNCWatcherAccount.cmd (self-elevates).
================================================================================
#>

$ServiceName = "TNCWatcher"
$Nssm        = Join-Path $PSScriptRoot "nssm.exe"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: must be run as Administrator (use Set-TNCWatcherAccount.cmd)." -ForegroundColor Red
    pause
    exit 1
}

Write-Host "Enter the account the TNCWatcher service should run as."
Write-Host "(Must have access to the NAS watch folder.)"
Write-Host ""

$cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Account for the TNCWatcher service (needs NAS access)"
if (-not $cred) {
    Write-Host "Cancelled - service account unchanged." -ForegroundColor Yellow
    pause
    exit 1
}

& $Nssm stop $ServiceName 2>&1 | Out-Null
# NSSM grants the 'Log on as a service' right to the account automatically
& $Nssm set $ServiceName ObjectName $cred.UserName $cred.GetNetworkCredential().Password
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: failed to set the service account." -ForegroundColor Red
    pause
    exit 1
}
& $Nssm start $ServiceName 2>&1 | Out-Null

Start-Sleep -Seconds 8
$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
Write-Host ""
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "SUCCESS: service now runs as $($cred.UserName) and is RUNNING." -ForegroundColor Green
} else {
    Write-Host "Service status: $($svc.Status) - check the log (TNCWatcher-Console.cmd)." -ForegroundColor Yellow
    Write-Host "A wrong password is the most common cause." -ForegroundColor Yellow
}
Write-Host ""
pause
