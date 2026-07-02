<#
================================================================================
  TNCWatcher Service Installer
  Installs TNCcmd-FolderWatcher.ps1 as a Windows service named "TNCWatcher"
  using NSSM, so it starts at boot with no user login required.

  Also creates a scheduled task that restarts the service every 3 hours as a
  safety net against hangs.

  MUST be run as Administrator (use Install-TNCWatcher-Service.cmd, which
  self-elevates).
================================================================================
#>

$ErrorActionPreference = "Continue"

$ServiceName   = "TNCWatcher"
$ServiceDir    = $PSScriptRoot
$ProjectDir    = Split-Path -Parent $PSScriptRoot
$WatcherScript = Join-Path $ProjectDir "TNCcmd-FolderWatcher.ps1"
$Nssm          = Join-Path $ServiceDir "nssm.exe"
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$RestartTaskName = "TNCWatcher-3h-Restart"

# --- Sanity checks -----------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click Install-TNCWatcher-Service.cmd and choose 'Run as administrator'." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Nssm))          { Write-Host "ERROR: nssm.exe not found at $Nssm" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $WatcherScript)) { Write-Host "ERROR: watcher script not found at $WatcherScript" -ForegroundColor Red; exit 1 }

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Installing service: $ServiceName" -ForegroundColor Cyan
Write-Host "  Script: $WatcherScript" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

# --- Service account choice --------------------------------------------------
# The watch folder is on a NAS (UNC path). The account the service runs under
# must be able to reach that share. LocalSystem authenticates to the network
# as the COMPUTER account, which many NAS boxes reject.

Write-Host "The watch folder is a network share on your NAS." -ForegroundColor Yellow
Write-Host "Which account should the service run as?" -ForegroundColor Yellow
Write-Host "  [1] LocalSystem (default) - works if the NAS share allows guest/everyone access"
Write-Host "  [2] Your user account     - required if the NAS needs your credentials"
$choice = Read-Host "Choose 1 or 2 (Enter = 1)"

# --- Remove any previous install --------------------------------------------

$existing = Get-Service $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing $ServiceName service..." -ForegroundColor Yellow
    & $Nssm stop $ServiceName 2>&1 | Out-Null
    & $Nssm remove $ServiceName confirm 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

# --- Install and configure ----------------------------------------------------

& $Nssm install $ServiceName $PowerShellExe
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: nssm install failed" -ForegroundColor Red; exit 1 }

# Set the arguments via the registry - PowerShell 5.1 mangles embedded quotes
# when passing them to native exes, which breaks paths containing spaces
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters" -Name AppParameters -Value "-NoProfile -NoLogo -ExecutionPolicy Bypass -File `"$WatcherScript`""

& $Nssm set $ServiceName AppDirectory $ProjectDir
& $Nssm set $ServiceName DisplayName "TNCcmd Folder Watcher"
& $Nssm set $ServiceName Description "Auto-transfers NC programs from the watch folder to the Heidenhain CNC via TNCcmd. Log: $ProjectDir\TNCcmd-Watcher.log"

# Start automatically at boot, delayed so the network/NAS is up first
& $Nssm set $ServiceName Start SERVICE_DELAYED_AUTO_START

# Capture the script's console output (catches fatal PowerShell errors that
# never make it into the script's own log file)
& $Nssm set $ServiceName AppStdout "$ServiceDir\service-console.log"
& $Nssm set $ServiceName AppStderr "$ServiceDir\service-console.log"
& $Nssm set $ServiceName AppStdoutCreationDisposition 4
& $Nssm set $ServiceName AppStderrCreationDisposition 4
& $Nssm set $ServiceName AppRotateFiles 1
& $Nssm set $ServiceName AppRotateOnline 1
& $Nssm set $ServiceName AppRotateBytes 10485760

# Auto-restart if the script ever crashes/exits, with a 10s delay;
# throttle so a boot-loop can't spin the CPU
& $Nssm set $ServiceName AppExit Default Restart
& $Nssm set $ServiceName AppRestartDelay 10000
& $Nssm set $ServiceName AppThrottle 15000

# Give the script 5s to shut down cleanly on stop before being killed
& $Nssm set $ServiceName AppStopMethodConsole 5000

if ($choice -eq "2") {
    $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Account the TNCWatcher service will run as (needs NAS access)"
    if ($cred) {
        # NSSM grants the 'Log on as a service' right automatically
        & $Nssm set $ServiceName ObjectName $cred.UserName $cred.GetNetworkCredential().Password
        Write-Host "Service will run as $($cred.UserName)" -ForegroundColor Green
    } else {
        Write-Host "No credential entered - keeping LocalSystem" -ForegroundColor Yellow
    }
}

# --- Scheduled 3-hour restart (safety net against hangs) ----------------------

Write-Host ""
Write-Host "Creating scheduled task '$RestartTaskName' (restarts the service every 3 hours)..."
# Import from XML (UTF-16) - the PowerShell scheduled-task cmdlets proved
# unreliable for a SYSTEM task here; schtasks /XML is battle-tested.
$taskXml = Join-Path $PSScriptRoot "TNCWatcher-3h-Restart.xml"
schtasks /Create /F /TN $RestartTaskName /XML $taskXml 2>&1 | Out-Null
if (Get-ScheduledTask -TaskName $RestartTaskName -ErrorAction SilentlyContinue) {
    Write-Host "Scheduled restart task created." -ForegroundColor Green
} else {
    Write-Host "WARNING: could not create the scheduled restart task from $taskXml" -ForegroundColor Yellow
}

# --- Start and verify ----------------------------------------------------------

Write-Host ""
Write-Host "Starting service..."
& $Nssm start $ServiceName | Out-Null
Start-Sleep -Seconds 5

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
Write-Host ""
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "SUCCESS: $ServiceName is installed and RUNNING." -ForegroundColor Green
} else {
    Write-Host "Service installed but status is '$($svc.Status)'. Check the logs:" -ForegroundColor Yellow
    Write-Host "  $ProjectDir\TNCcmd-Watcher.log"
    Write-Host "  $ServiceDir\service-console.log"
}

$logFile = Join-Path $ProjectDir "TNCcmd-Watcher.log"
if (Test-Path $logFile) {
    Write-Host ""
    Write-Host "--- Last 15 log lines -----------------------------------------" -ForegroundColor Cyan
    Get-Content $logFile -Tail 15
    Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "If you see errors about the watch folder being unreachable, re-run" -ForegroundColor Yellow
    Write-Host "this installer and choose option [2] (your user account)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "To watch the live log at any time, double-click TNCWatcher-Console.cmd" -ForegroundColor Cyan
Write-Host "in the project folder." -ForegroundColor Cyan
