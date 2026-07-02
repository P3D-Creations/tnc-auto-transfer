<#
================================================================================
  Stores the NAS credential for the TNCWatcher service.

  Prompts for the NAS username/password (the account defined ON THE NAS with
  access to the watch folder share), encrypts it with Windows DPAPI bound to
  THIS machine, and saves it to service\nas-credential.bin readable only by
  SYSTEM and Administrators. The watcher script decrypts it at startup and
  authenticates to the share itself - so the service can run as LocalSystem
  and nothing breaks when Windows passwords change.

  Re-run this only if the NAS account's password changes.

  Also repairs/creates the 3-hour restart task if missing, then restarts the
  service. Launch via Set-NASCredential.cmd (self-elevates).
================================================================================
#>

$ServiceName     = "TNCWatcher"
$Nssm            = Join-Path $PSScriptRoot "nssm.exe"
$CredFile        = Join-Path $PSScriptRoot "nas-credential.bin"
$ProjectDir      = Split-Path -Parent $PSScriptRoot
$RestartTaskName = "TNCWatcher-3h-Restart"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: must be run as Administrator (use Set-NASCredential.cmd)." -ForegroundColor Red
    pause
    exit 1
}

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  TNCWatcher - store NAS credential" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Enter the NAS account (as defined on the NAS itself, e.g. your"
Write-Host "Synology/NAS username) that has access to the watch folder share."
Write-Host ""

$cred = $null
if (Test-Path $CredFile) {
    Write-Host "A stored NAS credential already exists." -ForegroundColor Yellow
    $answer = Read-Host "Enter a new one? (y/N - Enter keeps the existing credential)"
    if ($answer -match '^[Yy]') {
        $cred = Get-Credential -Message "NAS account with access to the watch folder share"
    }
} else {
    $cred = Get-Credential -Message "NAS account with access to the watch folder share"
    if (-not $cred) {
        Write-Host "Cancelled - nothing changed." -ForegroundColor Yellow
        pause
        exit 1
    }
}

if ($cred) {
    # --- Encrypt and save (DPAPI, machine-bound) -------------------------------

    Add-Type -AssemblyName System.Security
    $plain = $cred.UserName + "`n" + $cred.GetNetworkCredential().Password
    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
        [System.Text.Encoding]::UTF8.GetBytes($plain), $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes($CredFile, $encrypted)

    # Lock the file down: only SYSTEM and Administrators can read it
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)   # disable inheritance, drop inherited rules
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")))
    Set-Acl -Path $CredFile -AclObject $acl

    Write-Host "Credential saved (encrypted) to: $CredFile" -ForegroundColor Green
}

# --- Ensure the 3-hour restart task exists ------------------------------------

$task = Get-ScheduledTask -TaskName $RestartTaskName -ErrorAction SilentlyContinue
if (-not $task) {
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
}

# --- Restart the service so it picks up the credential -------------------------

Write-Host ""
Write-Host "Restarting the $ServiceName service..."
& $Nssm stop $ServiceName 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $Nssm start $ServiceName 2>&1 | Out-Null
Start-Sleep -Seconds 10

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
Write-Host ""
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "Service is RUNNING." -ForegroundColor Green
} else {
    Write-Host "Service status: $($svc.Status)" -ForegroundColor Yellow
}

$logFile = Join-Path $ProjectDir "TNCcmd-Watcher.log"
if (Test-Path $logFile) {
    Write-Host ""
    Write-Host "--- Last 12 log lines -----------------------------------------" -ForegroundColor Cyan
    Get-Content $logFile -Tail 12
    Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Look for 'Authenticated to NAS share' followed by 'Waiting for files'." -ForegroundColor Cyan
}
Write-Host ""
pause
