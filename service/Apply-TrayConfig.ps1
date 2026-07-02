<#
================================================================================
  Applies configuration saved by the tray app's Settings dialog.
  Launched elevated (UAC) by TNCWatcher-Tray.exe when the user clicks
  "Save & Restart Service". Can also be run standalone as admin.

  Steps:
    1. If service\nas-credential.staged.bin exists (written DPAPI-encrypted by
       the tray app), move it into place as nas-credential.bin and lock its
       ACL to SYSTEM + Administrators.
    2. Ensure the 3-hour restart scheduled task exists.
    3. Restart the TNCWatcher service so it picks up config + credential.
  Shows a message box with the result.
================================================================================
#>

$ServiceName     = "TNCWatcher"
$Nssm            = Join-Path $PSScriptRoot "nssm.exe"
$CredFile        = Join-Path $PSScriptRoot "nas-credential.bin"
$StagedCredFile  = Join-Path $PSScriptRoot "nas-credential.staged.bin"
$RestartTaskName = "TNCWatcher-3h-Restart"
$ProjectDir      = Split-Path -Parent $PSScriptRoot

Add-Type -AssemblyName System.Windows.Forms

function Show-Result([string]$Message, [bool]$IsError) {
    $icon = if ($IsError) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [System.Windows.Forms.MessageBox]::Show($Message, "TNCWatcher configuration", [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Show-Result "This helper must run elevated. Right-click and run as administrator." $true
    exit 1
}

$problems = @()

# --- 1. Install staged NAS credential -----------------------------------------

if (Test-Path $StagedCredFile) {
    try {
        Move-Item $StagedCredFile $CredFile -Force -ErrorAction Stop

        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")))
        Set-Acl -Path $CredFile -AclObject $acl
    }
    catch {
        $problems += "Could not install the NAS credential: $_"
    }
}

# --- 2. Ensure the 3-hour restart task ----------------------------------------

$task = Get-ScheduledTask -TaskName $RestartTaskName -ErrorAction SilentlyContinue
if (-not $task) {
    # Import from XML (UTF-16) - the PowerShell scheduled-task cmdlets proved
    # unreliable for a SYSTEM task here; schtasks /XML is battle-tested.
    $taskXml = Join-Path $PSScriptRoot "TNCWatcher-3h-Restart.xml"
    schtasks /Create /F /TN $RestartTaskName /XML $taskXml 2>&1 | Out-Null
    if (-not (Get-ScheduledTask -TaskName $RestartTaskName -ErrorAction SilentlyContinue)) {
        $problems += "Could not create the 3-hour restart task from $taskXml"
    }
}

# --- 3. Restart the service ----------------------------------------------------

try {
    if (Test-Path $Nssm) {
        & $Nssm stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & $Nssm start $ServiceName 2>&1 | Out-Null
    } else {
        Restart-Service $ServiceName -Force -ErrorAction Stop
    }
    Start-Sleep -Seconds 8
}
catch {
    $problems += "Could not restart the service: $_"
}

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
$status = if ($svc) { $svc.Status } else { "not installed" }

if ($problems.Count -eq 0 -and "$status" -eq "Running") {
    Show-Result "Configuration applied. Service is running.`n`nCheck the tray icon / live log to confirm the watcher connected to the watch folder." $false
}
else {
    $msg = "Service status: $status"
    if ($problems.Count -gt 0) { $msg += "`n`n" + ($problems -join "`n") }
    $msg += "`n`nSee the live log (tray icon) for details."
    Show-Result $msg $true
}
