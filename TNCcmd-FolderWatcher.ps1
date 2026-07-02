#Requires -Version 5.1
<#
================================================================================
  TNCcmd Folder Watcher
  Version: 1.6.0
  Date:    2026-07-02
  Author:  Xander Luciano
  Docs:    https://notes.xanderluciano.com/heidenhain-tnccmd-auto-transfer
================================================================================

.SYNOPSIS
    Watches a folder for new files and automatically sends them to a Heidenhain CNC machine using TNCcmd.

.DESCRIPTION
    This script monitors a specified folder for newly created files and automatically
    transfers them to a Heidenhain CNC controller over the network using the TNCcmd
    command-line tool (part of TNCremo software package).
    
    Two watching modes are available:
    - Synchronous (WaitForChanged): Simple, reliable, blocks during file processing
    - Asynchronous (Event Queue): Non-blocking, handles rapid file creation

.PREREQUISITES
    1. TNCremo must be installed on this PC
       - Download free from: https://www.heidenhain.com/products/cnc-controls/software/tncremo
       - During installation, TNCcmd.exe is included automatically
       
    2. Network connectivity to the CNC machine
       - Machine must be on the same network or reachable via IP
       - Default port is 19000 (LSV2 protocol)
       
    3. CNC controller must have network/DNC option enabled
       - Check with machine manufacturer or Heidenhain support

.NOTES
    Author: Generated for Heidenhain TNC controllers
    Compatible Controllers: TNC 320, TNC 620, TNC 640, iTNC 530, TNC 426/430, and others
    Protocol: LSV2 (over TCP/IP)
    
.EXAMPLE
    .\TNCcmd-FolderWatcher.ps1
    
    Runs the folder watcher with default settings. Press Ctrl+C to stop.
#>

# ============================================================================
# CONFIGURATION - Edit these variables to match your setup
# ============================================================================

# ------------------------------
# WATCHER MODE
# ------------------------------
# Choose how the script monitors for file changes:
#
# "Synchronous"  - Uses WaitForChanged() in a loop
#                  + Simple and reliable
#                  + No scope/variable issues
#                  - Blocks during file transfer (can't detect new files while transferring)
#                  Best for: Infrequent file drops, simple setups
#
# "Asynchronous" - Uses event-based monitoring with a queue
#                  + Non-blocking (continues detecting files during transfers)
#                  + Handles rapid file creation
#                  - Slightly more complex
#                  Best for: Frequent file drops, production environments

$WatcherMode = "Asynchronous"  # Options: "Synchronous" or "Asynchronous"

# ------------------------------
# MACHINE CONNECTION
# ------------------------------

# Machine IP address - Change this to your CNC machine's IP
$MachineIP = "192.168.2.27"

# Destination folder on the CNC machine
# - TNC:\ is the root of the machine's storage
# - Common paths: TNC:\nc_prog\, TNC:\Programs\, TNC:\
$DestinationFolder = "TNC:\nc_prog\"

# Connection timeout in seconds (quick operations: DEL, MKDIR, connection tests)
$ConnectionTimeout = 30

# Transfer timeout in seconds (PUT/GET). LSV2 is slow (~100-200 KB/s on older
# controllers), so large NC programs need generous time. If TNCcmd is still
# running after this long it is killed and the transfer is retried.
$TransferTimeoutSeconds = 600

# ------------------------------
# FOLDER SETTINGS
# ------------------------------

# Watch folder path
# - Use ".\WatchFolder" for a subfolder next to this script
# - Use $PSScriptRoot for the same folder as the script
# - Or specify a full path like "C:\NCPrograms\ToMachine" or a UNC path like "\\Server\Share\Folder"
$WatchFolder = "\\P3D_NAS\Machines\Kern\nc_prog\WatchFolder"

# File filter - which files to watch for
# - "*.h" for Heidenhain NC programs only
# - "*.H" for uppercase extension
# - "*.*" for all files
$FileFilter = "*.*"

# Include subdirectories - watch for files in subfolders recursively
# - $true:  Monitors all subfolders, preserving folder structure on CNC destination
# - $false: Only monitors files placed directly in the watch folder
$IncludeSubdirectories = $true

# NAS credential file (optional). If this file exists, the script decrypts it
# (DPAPI, machine-bound) and authenticates to the watch folder's SMB share
# with those credentials before watching. This lets the service run as
# LocalSystem and still reach a NAS that requires a login.
# Create/update the file with: service\Set-NASCredential.cmd
$NASCredentialFile = ".\service\nas-credential.bin"

# ------------------------------
# TRANSFER OPTIONS
# ------------------------------

$UseBinaryMode = $true           # Use /b flag for binary transfer (recommended)
$ConvertNCPrograms = $false      # Use /c flag to convert .H/.I files during transfer
$DeleteBeforeTransfer = $true    # DEL existing file on controller before PUT (ensures clean overwrite)
                                 # NOTE: Overwriting files that are OPEN on the controller requires
                                 #       TNCcmdPlus (purchased USB dongle + Option #18 HEIDENHAIN DNC).
                                 #       With TNCcmd Essential, open files will retry until closed.
                                 #
$DeleteAfterTransfer = $false    # Delete source file after successful transfer
$MoveToProcessedFolder = $true   # Move files to "Processed" subfolder after transfer
$MoveToFailedFolder = $true      # Move files to "Failed" subfolder after max retries

# ------------------------------
# TOOL TABLE ROUTING
# ------------------------------

# Files listed here (case-insensitive) are routed to $ToolTableDestination instead
# of $DestinationFolder, and receive special handling (backup + merge/overwrite).
$ToolTableFiles       = @("tool.t")    # Filenames that trigger tool-table handling
$ToolTableDestination = "TNC:\\table\\" # Destination folder on CNC for tool tables

# Controls how an incoming tool table is applied to the controller.
#
#   "Merge"     - Run PUT /m. Requires TNCcmdPlus + Option #18 HEIDENHAIN DNC.
#                 If the merge fails for ANY reason (including timeout, which is
#                 what TNCcmd Essential does when /m is not supported), the
#                 transfer FAILS with an error message. The remote file is NEVER
#                 deleted or modified. Incoming file moves to the Failed folder.
#
#   "Overwrite" - DEL the remote file then PUT the new one (clean replace).
#                 The remote file is explicitly deleted before upload.
#                 Use only when a full replacement is intentionally desired.
#                 NOTE: a backup is always taken before the delete (see below).
#
$ToolTableTransferMode = "Merge"   # "Merge" | "Overwrite"

# Before any merge or overwrite, the current remote tool table is downloaded and
# saved locally as a timestamped backup. Older backups are pruned automatically.
$ToolTableBackupFolder = ".\ToolTableBackups"   # Relative to script or absolute path
$ToolTableBackupCount  = 20                      # Max number of backups to keep

# ------------------------------
# RETRY SETTINGS
# ------------------------------

# For locked files on controller (file open in editor, etc.)
$MaxRetries = 150                # Maximum retry attempts
$RetryDelaySeconds = 30          # Seconds between retries

# ------------------------------
# LOGGING
# ------------------------------

$EnableLogging = $true
$LogFile = ".\TNCcmd-Watcher.log"

# ------------------------------
# TNCcmd PATH
# ------------------------------

# TNCcmd.exe path (usually auto-detected)
$TNCcmdPath = "C:\Program Files (x86)\HEIDENHAIN\TNCremo\TNCcmd.exe"

# ============================================================================
# END OF CONFIGURATION
# ============================================================================

# Resolve paths to absolute paths
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

# ----------------------------------------------------------------------------
# OPTIONAL CONFIG FILE OVERRIDES
# If TNCWatcher-Config.json exists next to this script (written by the tray
# app's Settings dialog), values in it override the defaults above. Delete the
# file to fall back to the script defaults.
# ----------------------------------------------------------------------------
$ConfigFile = Join-Path $ScriptDir "TNCWatcher-Config.json"
$ConfigOverridesActive = $false
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.MachineIP)              { $MachineIP              = [string]$cfg.MachineIP }
        if ($cfg.DestinationFolder)      { $DestinationFolder      = [string]$cfg.DestinationFolder }
        if ($cfg.WatchFolder)            { $WatchFolder            = [string]$cfg.WatchFolder }
        if ($cfg.FileFilter)             { $FileFilter             = [string]$cfg.FileFilter }
        if ($null -ne $cfg.IncludeSubdirectories) { $IncludeSubdirectories = [bool]$cfg.IncludeSubdirectories }
        if ($cfg.MaxRetries)             { $MaxRetries             = [int]$cfg.MaxRetries }
        if ($cfg.RetryDelaySeconds)      { $RetryDelaySeconds      = [int]$cfg.RetryDelaySeconds }
        if ($cfg.ConnectionTimeout)      { $ConnectionTimeout      = [int]$cfg.ConnectionTimeout }
        if ($cfg.TransferTimeoutSeconds) { $TransferTimeoutSeconds = [int]$cfg.TransferTimeoutSeconds }
        $ConfigOverridesActive = $true
    }
    catch {
        # Malformed config file - ignore and use script defaults
    }
}
$WatchFolder = if ([System.IO.Path]::IsPathRooted($WatchFolder)) { $WatchFolder } else { Join-Path $ScriptDir $WatchFolder }
$LogFile = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }
$NASCredentialFile = if ([System.IO.Path]::IsPathRooted($NASCredentialFile)) { $NASCredentialFile } else { Join-Path $ScriptDir $NASCredentialFile }

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "DEBUG"   { Write-Host $logMessage -ForegroundColor DarkGray }
        default   { Write-Host $logMessage }
    }
    
    # File logging (with simple 10 MB rotation so the log can't grow unbounded)
    if ($EnableLogging) {
        try {
            if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 10MB)) {
                Move-Item $LogFile "$LogFile.old" -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
    }
}

function Test-TNCcmd {
    # Check if TNCcmd.exe exists
    if (-not (Test-Path $TNCcmdPath)) {
        # Try alternate locations
        $alternatePaths = @(
            "C:\Program Files\HEIDENHAIN\TNCremo\TNCcmd.exe",
            "C:\Program Files (x86)\HEIDENHAIN\TNCremoNT\TNCcmd.exe",
            "${env:ProgramFiles}\HEIDENHAIN\TNCremo\TNCcmd.exe",
            "${env:ProgramFiles(x86)}\HEIDENHAIN\TNCremo\TNCcmd.exe"
        )
        
        foreach ($path in $alternatePaths) {
            if (Test-Path $path) {
                $script:TNCcmdPath = $path
                Write-Log "Found TNCcmd at: $path"
                return $true
            }
        }
        
        Write-Log "TNCcmd.exe not found! Please install TNCremo from Heidenhain." "ERROR"
        Write-Log "Download from: https://www.heidenhain.com/products/cnc-controls/software/tncremo" "ERROR"
        return $false
    }
    
    Write-Log "TNCcmd found at: $TNCcmdPath"
    return $true
}

function Invoke-TNCcmd {
    <#
    .SYNOPSIS
        Runs TNCcmd.exe with the given arguments and a hard timeout.

        stdout/stderr are read asynchronously and stdin is closed immediately,
        so a stalled TNCcmd can never deadlock this script (synchronous
        ReadToEnd() before WaitForExit() was the cause of indefinite hangs when
        the machine was unreachable). If the process is still running when the
        timeout expires it is killed and TimedOut is reported to the caller.
    .OUTPUTS
        Hashtable: @{ ExitCode; StdOut; StdErr; TimedOut }
    #>
    param(
        [string]$Arguments,
        [int]$TimeoutSeconds = $ConnectionTimeout
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $TNCcmdPath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.CreateNoWindow         = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        # Close stdin so TNCcmd gets EOF instead of blocking on a prompt
        $process.StandardInput.Close()

        # Async reads: drain both pipes without blocking, avoiding the
        # stdout-full/stderr-full pipe deadlock
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()

        $timedOut = $false
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill() } catch {}
            $process.WaitForExit(5000) | Out-Null
        }

        $stdout = ""
        $stderr = ""
        try { if ($outTask.Wait(5000)) { $stdout = $outTask.Result } } catch {}
        try { if ($errTask.Wait(5000)) { $stderr = $errTask.Result } } catch {}

        $exitCode = -1
        if (-not $timedOut) { $exitCode = $process.ExitCode }

        return @{
            ExitCode = $exitCode
            StdOut   = $stdout
            StdErr   = $stderr
            TimedOut = $timedOut
        }
    }
    finally {
        $process.Dispose()
    }
}

function Connect-NASShare {
    <#
    .SYNOPSIS
        Authenticates to the watch folder's SMB share using credentials stored
        in the DPAPI-encrypted credential file (created by
        service\Set-NASCredential.cmd). No-op when the watch folder is not a
        UNC path, the credential file doesn't exist, or the share is already
        accessible. Safe to call repeatedly. Never logs the password.
    #>

    # Only applies to UNC watch folders
    if ($WatchFolder -notmatch '^\\\\([^\\]+)\\([^\\]+)') { return }
    $shareRoot = "\\" + $Matches[1] + "\" + $Matches[2]

    if (-not (Test-Path $NASCredentialFile)) { return }

    # Already accessible - nothing to do
    if (Test-Path $WatchFolder) { return }

    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $encrypted = [System.IO.File]::ReadAllBytes($NASCredentialFile)
        $plain = [System.Text.Encoding]::UTF8.GetString(
            [System.Security.Cryptography.ProtectedData]::Unprotect(
                $encrypted, $null,
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine))
        $parts = $plain -split "`n", 2
        if ($parts.Count -ne 2) {
            Write-Log "NAS credential file is malformed - recreate it with Set-NASCredential.cmd" "WARNING"
            return
        }

        # net.exe works reliably under LocalSystem; New-SmbMapping does not
        # ("A specified logon session does not exist" in service context)
        $netExe = "$env:SystemRoot\System32\net.exe"
        $output = & $netExe use $shareRoot $parts[1] "/user:$($parts[0])" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Authenticated to NAS share $shareRoot as '$($parts[0])'" "SUCCESS"
            return
        }

        $text = ($output | Out-String)
        if ($text -match "1219") {
            # A session with different credentials already exists - replace it
            & $netExe use $shareRoot /delete /y 2>&1 | Out-Null
            $output = & $netExe use $shareRoot $parts[1] "/user:$($parts[0])" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Authenticated to NAS share $shareRoot as '$($parts[0])' (replaced stale session)" "SUCCESS"
                return
            }
            $text = ($output | Out-String)
        }

        if (Test-Path $WatchFolder) { return }  # accessible anyway - good enough
        Write-Log "Could not authenticate to NAS share ${shareRoot}: $($text.Trim())" "WARNING"
    }
    catch {
        if (Test-Path $WatchFolder) {
            # A session already existed - connection works, ignore the error
            return
        }
        Write-Log "Could not authenticate to NAS share ${shareRoot}: $($_.Exception.Message)" "WARNING"
    }
}

function Test-MachineConnection {
    param([string]$IP)
    
    Write-Log "Testing connection to machine at $IP..."
    
    # First do a simple ping test
    $ping = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $ping) {
        Write-Log "Cannot ping machine at $IP - check network connection" "WARNING"
        # Continue anyway - some machines block ping but allow LSV2
    }
    
    # Try a TNCcmd connection test
    $cmdFile = [System.IO.Path]::GetTempFileName()
    try {
        @"
CONNECT -I $IP
EXIT
"@ | Set-Content $cmdFile -Encoding ASCII
        
        $result = cmd.exe /c "`"$TNCcmdPath`" < `"$cmdFile`"" 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0 -or $result -notmatch "error|failed|timeout") {
            Write-Log "Connection test successful!" "SUCCESS"
            return $true
        } else {
            Write-Log "Connection test failed: $result" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Connection test error: $_" "ERROR"
        return $false
    }
    finally {
        Remove-Item $cmdFile -ErrorAction SilentlyContinue
    }
}

function Test-RetryableError {
    param([string]$ErrorOutput)
    
    # Patterns that indicate the file is temporarily locked/busy (should retry)
    # Includes Heidenhain LSV2 error codes from TNCcmd
    $retryPatterns = @(
        "locked",
        "in use",
        "access denied",
        "busy",
        "cannot access",
        "being used",
        "sharing violation",
        "file is open",
        "write protected",
        "protection",
        "timeout",
        "timed out",
        "connection lost",
        "connection reset",
        "connection failed",
        "connection error",
        "could not connect",
        "cannot connect",
        "connect failed",
        "failed to connect",
        "no connection",
        "not connected",
        "unreachable",
        "could not establish",          # "Could not establish connection to the control"
        "connection setup",             # "Connection setup canceled"
        "e20001508",                    # Connection setup canceled (machine off/unreachable)
        "10060",           # Winsock WSAETIMEDOUT
        "10061",           # Winsock WSAECONNREFUSED
        "10064",           # Winsock WSAEHOSTDOWN
        "10065",           # Winsock WSAEHOSTUNREACH
        "e20001721",       # File cannot be opened (file open on controller)
        "e20001724",       # File cannot be deleted (write-protected or open)
        "e2000172d",       # File access not possible
        "e2000173b",       # No write-access
        "e2000173c",       # NC still active: Function cannot be executed
        "e2000175a"        # Transmission still active
    )
    
    foreach ($pattern in $retryPatterns) {
        if ($ErrorOutput -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-ConnectionError {
    <#
    .SYNOPSIS
        Returns $true when a retryable error is a CONNECTION problem (machine
        off / unreachable / LSV2 not responding) as opposed to the file being
        locked or in use on a reachable controller. Used only to choose the
        wording of the retry log line so the tray monitor can notify
        appropriately: unreachable = notify once per file; locked = periodic.
    #>
    param([string]$ErrorOutput)

    $connectionPatterns = @(
        "could not establish",   # "Could not establish connection to the control"
        "connection setup",      # "Connection setup canceled"
        "e20001508",             # Connection setup canceled (machine off/unreachable)
        "connection lost",
        "connection reset",
        "connection failed",
        "connection error",
        "could not connect",
        "cannot connect",
        "connect failed",
        "failed to connect",
        "no connection",
        "not connected",
        "unreachable",
        "timeout",
        "timed out",
        "10060",                 # Winsock WSAETIMEDOUT
        "10061",                 # Winsock WSAECONNREFUSED
        "10064",                 # Winsock WSAEHOSTDOWN
        "10065"                  # Winsock WSAEHOSTUNREACH
    )

    foreach ($pattern in $connectionPatterns) {
        if ($ErrorOutput -match $pattern) {
            return $true
        }
    }
    return $false
}

function Wait-FileReady {
    <#
    .SYNOPSIS
        Waits for a file to be fully written and released by other processes.
    #>
    param(
        [string]$FilePath,
        [int]$TimeoutSeconds = 30
    )
    
    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        try {
            # Try to open file with exclusive access
            $stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
            $stream.Close()
            $stream.Dispose()
            return $true
        }
        catch {
            Start-Sleep -Seconds 1
            $waited++
        }
    }
    return $false
}

function Remove-RemoteFile {
    <#
    .SYNOPSIS
        Attempts to delete a file on the CNC controller via TNCcmd DEL command.
        Used before PUT to ensure a clean overwrite. Failures are non-fatal.
    .OUTPUTS
        $true if DEL succeeded or file didn't exist, $false if file is locked/open.
    #>
    param(
        [string]$RemoteFilePath
    )
    
    $arguments = "DEL `"$RemoteFilePath`" -I $MachineIP"

    try {
        $result = Invoke-TNCcmd -Arguments $arguments -TimeoutSeconds $ConnectionTimeout
        $stdout = $result.StdOut
        $stderr = $result.StdErr

        $combinedOutput = "$stdout $stderr".ToLower()

        if ($result.TimedOut) {
            Write-Log "DEL timed out after ${ConnectionTimeout}s (proceeding with PUT): $RemoteFilePath" "WARNING"
            return $true
        }

        if ($result.ExitCode -eq 0 -and $stderr -eq "") {
            Write-Log "DEL succeeded: $RemoteFilePath" "DEBUG"
            return $true
        }
        
        # File doesn't exist - that's fine, PUT will create it
        if ($combinedOutput -match "e20001720|does not exist") {
            Write-Log "File does not exist on controller (will be created): $RemoteFilePath" "DEBUG"
            return $true
        }
        
        # File is locked/open on controller - DEL can't help, PUT will also fail
        if ($combinedOutput -match "e20001724|cannot be deleted|e20001721|cannot be opened") {
            Write-Log "File is open/locked on controller, cannot delete before overwrite: $RemoteFilePath" "WARNING"
            return $false
        }
        
        # Other error - log but continue with PUT anyway
        Write-Log "DEL returned unexpected result (proceeding with PUT): $combinedOutput" "WARNING"
        return $true
    }
    catch {
        Write-Log "DEL exception (proceeding with PUT): $_" "WARNING"
        return $true
    }
}

function Send-FileToMachine {
    <#
    .SYNOPSIS
        Transfers a file to the CNC machine with retry logic.
    .OUTPUTS
        Hashtable with Success (bool) and Retryable (bool) properties.
    #>
    param(
        [string]$SourceFile,
        [string]$DestinationPath,
        [int]$Attempt = 1
    )
    
    $fileName = [System.IO.Path]::GetFileName($SourceFile)
    $destFile = $DestinationPath.TrimEnd('\', '/') + '\' + $fileName
    
    if ($Attempt -eq 1) {
        Write-Log "Transferring: $fileName -> $destFile"
    } else {
        Write-Log "Retry attempt $Attempt/$MaxRetries for: $fileName"
    }
    
    # Build the PUT command with options
    $putOptions = ""
    if ($UseBinaryMode) { $putOptions += " /b" }
    if ($ConvertNCPrograms) { $putOptions += " /c" }
    
    # Delete existing file before PUT to ensure clean overwrite
    if ($DeleteBeforeTransfer -and $Attempt -eq 1) {
        $delResult = Remove-RemoteFile -RemoteFilePath $destFile
        if (-not $delResult) {
            Write-Log "File is locked on controller - will attempt PUT anyway (retry logic will handle)" "WARNING"
        }
    }
    
    # Direct command-line execution
    $arguments = @(
        "PUT"
        "`"$SourceFile`""
        "`"$destFile`""
        $putOptions.Trim()
        "-I"
        $MachineIP
    ) -join " "
    
    try {
        $result = Invoke-TNCcmd -Arguments $arguments -TimeoutSeconds $TransferTimeoutSeconds
        $stdout = $result.StdOut
        $stderr = $result.StdErr

        $exitCode = $result.ExitCode
        $combinedOutput = "$stdout $stderr".ToLower()

        if ($result.TimedOut) {
            Write-Log "TNCcmd stalled and was killed after ${TransferTimeoutSeconds}s (machine unreachable?): $fileName" "WARNING"
        }

        # Success case
        if (-not $result.TimedOut -and $exitCode -eq 0 -and $stderr -eq "") {
            if ($Attempt -gt 1) {
                Write-Log "Transfer successful after $Attempt attempts: $fileName" "SUCCESS"
            } else {
                Write-Log "Transfer successful: $fileName" "SUCCESS"
            }
            return @{ Success = $true; Retryable = $false }
        }

        # Check if this is a retryable error (file locked, stalled connection, etc.)
        $isRetryable = $result.TimedOut -or (Test-RetryableError -ErrorOutput $combinedOutput)
        $isConnError = $result.TimedOut -or (Test-ConnectionError -ErrorOutput $combinedOutput)

        if ($isRetryable -and $Attempt -lt $MaxRetries) {
            if ($isConnError) {
                Write-Log "Machine unreachable. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
            } else {
                Write-Log "File locked on controller. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
            }
            if ($stdout) { Write-Log "Output: $stdout" "WARNING" }
            if ($stderr) { Write-Log "Error: $stderr" "WARNING" }

            Start-Sleep -Seconds $RetryDelaySeconds
            return Send-FileToMachine -SourceFile $SourceFile -DestinationPath $DestinationPath -Attempt ($Attempt + 1)
        }
        elseif ($isRetryable) {
            # Max retries reached for a retryable error
            Write-Log "Transfer failed after $MaxRetries attempts (file locked): $fileName" "ERROR"
            if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
            if ($stderr) { Write-Log "Error: $stderr" "ERROR" }
            return @{ Success = $false; Retryable = $true }
        }
        else {
            # Non-retryable error (bad path, permission issue, etc.)
            Write-Log "Transfer failed for $fileName (Exit: $exitCode) - non-retryable error" "ERROR"
            if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
            if ($stderr) { Write-Log "Error: $stderr" "ERROR" }
            return @{ Success = $false; Retryable = $false }
        }
    }
    catch {
        Write-Log "Transfer exception for ${fileName}: $_" "ERROR"
        
        # Treat exceptions as potentially retryable (network issues, etc.)
        if ($Attempt -lt $MaxRetries) {
            Write-Log "Retrying after exception... Waiting ${RetryDelaySeconds}s (attempt $Attempt/$MaxRetries)" "WARNING"
            Start-Sleep -Seconds $RetryDelaySeconds
            return Send-FileToMachine -SourceFile $SourceFile -DestinationPath $DestinationPath -Attempt ($Attempt + 1)
        }
        return @{ Success = $false; Retryable = $true }
    }
}

function Move-ProcessedFile {
    <#
    .SYNOPSIS
        Handles post-transfer file movement (delete, move to processed, or move to failed).
    #>
    param(
        [string]$FilePath,
        [bool]$Success
    )
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    
    # Compute relative path from watch folder for subfolder structure preservation
    $watchBase = $WatchFolder.TrimEnd('\', '/')
    $relativePath = $FilePath.Substring($watchBase.Length + 1)
    $relativeDir = [System.IO.Path]::GetDirectoryName($relativePath)
    
    if ($Success) {
        if ($DeleteAfterTransfer) {
            Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted source file: $fileName"
        }
        elseif ($MoveToProcessedFolder) {
            # Preserve subfolder structure inside Processed folder
            $processedBase = Join-Path $WatchFolder "Processed"
            if ($relativeDir) {
                $processedBase = Join-Path $processedBase $relativeDir
                if (-not (Test-Path $processedBase)) {
                    New-Item -Path $processedBase -ItemType Directory -Force | Out-Null
                }
            }
            $processedPath = Join-Path $processedBase $fileName
            
            # Handle duplicate filenames
            if (Test-Path $processedPath) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $extension = [System.IO.Path]::GetExtension($fileName)
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $processedPath = Join-Path $processedBase "${baseName}_${timestamp}${extension}"
            }
            
            Move-Item $FilePath $processedPath -Force -ErrorAction SilentlyContinue
            Write-Log "Moved to Processed: $relativePath"
        }
    }
    else {
        if ($MoveToFailedFolder) {
            # Preserve subfolder structure inside Failed folder
            $failedBase = Join-Path $WatchFolder "Failed"
            if ($relativeDir) {
                $failedBase = Join-Path $failedBase $relativeDir
                if (-not (Test-Path $failedBase)) {
                    New-Item -Path $failedBase -ItemType Directory -Force | Out-Null
                }
            }
            $failedPath = Join-Path $failedBase $fileName
            
            # Handle duplicate filenames
            if (Test-Path $failedPath) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $extension = [System.IO.Path]::GetExtension($fileName)
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $failedPath = Join-Path $failedBase "${baseName}_${timestamp}${extension}"
            }
            
            Move-Item $FilePath $failedPath -Force -ErrorAction SilentlyContinue
            Write-Log "Moved to Failed folder: $relativePath" "ERROR"
        }
    }
}

function New-RemoteDirectory {
    <#
    .SYNOPSIS
        Creates a directory tree on the CNC machine using TNCcmd MKDIR.
        Creates each intermediate directory level so parent folders are
        guaranteed to exist before children. Silently succeeds if a
        directory already exists.
    .PARAMETER RemotePath
        Full remote path, e.g. "TNC:\nc_prog\Outpost\Hinge Stop"
    .PARAMETER BasePath
        The portion of the path that already exists on the controller,
        e.g. "TNC:\nc_prog". Only directories below this are created.
    #>
    param(
        [string]$RemotePath,
        [string]$BasePath = $DestinationFolder
    )
    
    # Normalise separators and trim trailing slashes
    $base = $BasePath.TrimEnd('\', '/').Replace('/', '\')
    $full = $RemotePath.TrimEnd('\', '/').Replace('/', '\')
    
    # Nothing to create if the path equals the base
    if ($full -eq $base) { return }
    
    # Get the relative portion (e.g. "Outpost\Hinge Stop")
    $relative = $full.Substring($base.Length + 1)
    $parts = $relative -split '\\'
    
    # Create each directory level using direct command-line execution
    # (same approach as Send-FileToMachine for maximum compatibility)
    $current = $base
    foreach ($part in $parts) {
        $current = "$current\$part"
        
        $arguments = "MKDIR `"$current`" -I $MachineIP"

        try {
            $result = Invoke-TNCcmd -Arguments $arguments -TimeoutSeconds $ConnectionTimeout

            if ($result.TimedOut) {
                Write-Log "MKDIR '$current' timed out after ${ConnectionTimeout}s (machine unreachable?)" "WARNING"
            }
            elseif ($result.ExitCode -eq 0) {
                Write-Log "Created remote directory: $current" "SUCCESS"
            } else {
                # MKDIR returns an error if directory already exists - that's OK
                Write-Log "MKDIR '$current' returned exit $($result.ExitCode) (may already exist)" "WARNING"
                if ($result.StdErr) { Write-Log "  MKDIR stderr: $($result.StdErr)" "WARNING" }
            }
        }
        catch {
            Write-Log "MKDIR exception for '$current': $_" "WARNING"
        }
    }
}

function Backup-RemoteToolTable {
    <#
    .SYNOPSIS
        Downloads the current remote tool table to a local timestamped backup file.
        Keeps only the most recent $ToolTableBackupCount backups; older ones are pruned.
        Returns $true on success, $false if the GET failed (non-fatal — caller decides).
    #>
    param(
        [string]$RemoteFilePath   # e.g. TNC:\table\tool.t
    )

    $fileName = [System.IO.Path]::GetFileName($RemoteFilePath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $ext      = [System.IO.Path]::GetExtension($fileName)

    # Resolve backup folder relative to script location
    $backupRoot = if ([System.IO.Path]::IsPathRooted($ToolTableBackupFolder)) {
        $ToolTableBackupFolder
    } else {
        Join-Path $PSScriptRoot $ToolTableBackupFolder
    }

    try {
        if (-not (Test-Path $backupRoot)) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            Write-Log "Created backup folder: $backupRoot" "DEBUG"
        }
    }
    catch {
        Write-Log "Could not create backup folder '$backupRoot': $_" "WARNING"
        return $false
    }

    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $backupRoot "${baseName}_${timestamp}${ext}"

    $getArgs = "GET `"$RemoteFilePath`" `"$backupFile`" /b -I $MachineIP"

    try {
        $result = Invoke-TNCcmd -Arguments $getArgs -TimeoutSeconds $TransferTimeoutSeconds
        $stdout  = $result.StdOut
        $stderr  = $result.StdErr

        if ($result.TimedOut) {
            Write-Log "Backup GET timed out after ${TransferTimeoutSeconds}s: $RemoteFilePath" "WARNING"
            return $false
        }

        if ($result.ExitCode -eq 0 -and $stderr -eq "") {
            Write-Log "Backup saved: $backupFile" "SUCCESS"

            # Prune oldest backups beyond $ToolTableBackupCount
            $all = Get-ChildItem -Path $backupRoot -Filter "${baseName}_*${ext}" |
                   Sort-Object LastWriteTime -Descending
            if ($all.Count -gt $ToolTableBackupCount) {
                $toDelete = $all | Select-Object -Skip $ToolTableBackupCount
                foreach ($old in $toDelete) {
                    Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
                    Write-Log "Pruned old backup: $($old.Name)" "DEBUG"
                }
            }
            return $true
        }
        else {
            Write-Log "Backup GET failed (exit $($result.ExitCode)): $stderr" "WARNING"
            if ($stdout) { Write-Log "Output: $stdout" "WARNING" }
            return $false
        }
    }
    catch {
        Write-Log "Backup GET exception for '$RemoteFilePath': $_" "WARNING"
        return $false
    }
}

function Send-ToolTableFile {
    <#
    .SYNOPSIS
        Transfers a tool table file (e.g. tool.t) to TNC:\table\ using the mode
        specified by $ToolTableTransferMode.

        Before any transfer a backup of the current remote file is taken.

        Merge   - Runs PUT /m. If the command times out or returns a non-zero exit
                  code the transfer FAILS immediately. The remote file is never
                  deleted or modified on failure.
        Overwrite - DEL then PUT. Explicit full replacement. Backup is taken first.
    .OUTPUTS
        Hashtable: @{ Success = [bool]; Retryable = [bool] }
    #>
    param(
        [string]$SourceFile,
        [string]$DestinationPath,
        [int]$Attempt = 1
    )

    $fileName = [System.IO.Path]::GetFileName($SourceFile)
    $destFile = $DestinationPath.TrimEnd('\', '/') + '\' + $fileName

    if ($Attempt -eq 1) {
        Write-Log "Tool table transfer ($ToolTableTransferMode): $fileName -> $destFile"

        # Always take a backup of the remote file before touching it
        Write-Log "Taking backup of remote $fileName before transfer..." "DEBUG"
        $backupOk = Backup-RemoteToolTable -RemoteFilePath $destFile
        if (-not $backupOk) {
            Write-Log "WARNING: Could not back up remote $fileName. Proceeding anyway — check backup folder." "WARNING"
        }
    }
    else {
        Write-Log "Retry attempt $Attempt/$MaxRetries for tool table: $fileName"
    }

    # ──────────────────────────────────────────────────────────────────────────
    # MERGE mode  (PUT /m)
    # ──────────────────────────────────────────────────────────────────────────
    if ($ToolTableTransferMode -eq "Merge") {
        Write-Log "Running PUT /m (merge) — requires TNCcmdPlus + Option 18" "DEBUG"

        $mergeArgs = "PUT `"$SourceFile`" `"$destFile`" /m /b -I $MachineIP"

        try {
            $result = Invoke-TNCcmd -Arguments $mergeArgs -TimeoutSeconds $ConnectionTimeout

            if ($result.TimedOut) {
                # TNCcmd Essential hangs indefinitely on /m — treat as hard failure
                Write-Log "PUT /m timed out. TNCcmdPlus is required for Merge mode." "ERROR"
                Write-Log "The remote $fileName has NOT been modified." "ERROR"
                Write-Log "Set `$ToolTableTransferMode = `"Overwrite`" to use DEL+PUT instead." "ERROR"
                return @{ Success = $false; Retryable = $false }
            }

            $stdout  = $result.StdOut
            $stderr  = $result.StdErr
            $exitCode = $result.ExitCode
            $combinedOutput = "$stdout $stderr".ToLower()

            if ($exitCode -eq 0 -and $stderr -eq "") {
                Write-Log "Tool table merged successfully (PUT /m): $fileName" "SUCCESS"
                return @{ Success = $true; Retryable = $false }
            }

            # Check whether the table is locked/open on the controller (retryable)
            $isRetryable = Test-RetryableError -ErrorOutput $combinedOutput
            $isConnError = Test-ConnectionError -ErrorOutput $combinedOutput
            if ($isRetryable -and $Attempt -lt $MaxRetries) {
                if ($isConnError) {
                    Write-Log "Machine unreachable. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
                } else {
                    Write-Log "Tool table locked on controller. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
                }
                if ($stdout) { Write-Log "Output: $stdout" "WARNING" }
                if ($stderr) { Write-Log "Error:  $stderr" "WARNING" }
                Start-Sleep -Seconds $RetryDelaySeconds
                return Send-ToolTableFile -SourceFile $SourceFile -DestinationPath $DestinationPath -Attempt ($Attempt + 1)
            }
            elseif ($isRetryable) {
                Write-Log "Tool table merge failed after $MaxRetries attempts (table locked): $fileName" "ERROR"
                if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
                if ($stderr) { Write-Log "Error:  $stderr" "ERROR" }
                Write-Log "The remote $fileName has NOT been modified." "ERROR"
                return @{ Success = $false; Retryable = $true }
            }
            else {
                Write-Log "PUT /m failed (exit $exitCode) for $fileName" "ERROR"
                if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
                if ($stderr) { Write-Log "Error:  $stderr" "ERROR" }
                Write-Log "The remote $fileName has NOT been modified." "ERROR"
                return @{ Success = $false; Retryable = $false }
            }
        }
        catch {
            Write-Log "PUT /m exception for ${fileName}: $_" "ERROR"
            Write-Log "The remote $fileName has NOT been modified." "ERROR"
            return @{ Success = $false; Retryable = $false }
        }
    }

    # ──────────────────────────────────────────────────────────────────────────
    # OVERWRITE mode  (DEL + PUT)
    # ──────────────────────────────────────────────────────────────────────────
    Write-Log "Transferring tool table (DEL+PUT overwrite): $fileName -> $destFile" "DEBUG"

    if ($Attempt -eq 1) {
        $delResult = Remove-RemoteFile -RemoteFilePath $destFile
        if (-not $delResult) {
            Write-Log "Tool table is open/locked on controller, cannot delete — aborting overwrite to prevent data loss." "ERROR"
            Write-Log "Close $fileName on the controller then retry, or check the Failed folder." "ERROR"
            return @{ Success = $false; Retryable = $false }
        }
    }

    $putOptions = if ($UseBinaryMode) { "/b" } else { "" }
    $arguments  = "PUT `"$SourceFile`" `"$destFile`" $putOptions -I $MachineIP".Trim()

    try {
        $result = Invoke-TNCcmd -Arguments $arguments -TimeoutSeconds $TransferTimeoutSeconds
        $stdout  = $result.StdOut
        $stderr  = $result.StdErr

        $exitCode       = $result.ExitCode
        $combinedOutput = "$stdout $stderr".ToLower()

        if ($result.TimedOut) {
            Write-Log "Tool table PUT stalled and was killed after ${TransferTimeoutSeconds}s: $fileName" "WARNING"
        }

        if (-not $result.TimedOut -and $exitCode -eq 0 -and $stderr -eq "") {
            if ($Attempt -gt 1) {
                Write-Log "Tool table overwrite successful after $Attempt attempts: $fileName" "SUCCESS"
            } else {
                Write-Log "Tool table overwrite successful: $fileName" "SUCCESS"
            }
            return @{ Success = $true; Retryable = $false }
        }

        $isRetryable = $result.TimedOut -or (Test-RetryableError -ErrorOutput $combinedOutput)
        $isConnError = $result.TimedOut -or (Test-ConnectionError -ErrorOutput $combinedOutput)
        if ($isRetryable -and $Attempt -lt $MaxRetries) {
            if ($isConnError) {
                Write-Log "Machine unreachable. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
            } else {
                Write-Log "Tool table locked on controller. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
            }
            if ($stdout) { Write-Log "Output: $stdout" "WARNING" }
            if ($stderr) { Write-Log "Error:  $stderr" "WARNING" }
            Start-Sleep -Seconds $RetryDelaySeconds
            return Send-ToolTableFile -SourceFile $SourceFile -DestinationPath $DestinationPath -Attempt ($Attempt + 1)
        }
        elseif ($isRetryable) {
            Write-Log "Tool table overwrite failed after $MaxRetries attempts (locked): $fileName" "ERROR"
            if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
            if ($stderr) { Write-Log "Error:  $stderr" "ERROR" }
            return @{ Success = $false; Retryable = $true }
        }
        else {
            Write-Log "Tool table overwrite failed for $fileName (exit $exitCode)" "ERROR"
            if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
            if ($stderr) { Write-Log "Error:  $stderr" "ERROR" }
            return @{ Success = $false; Retryable = $false }
        }
    }
    catch {
        Write-Log "Tool table overwrite exception for ${fileName}: $_" "ERROR"
        if ($Attempt -lt $MaxRetries) {
            Start-Sleep -Seconds $RetryDelaySeconds
            return Send-ToolTableFile -SourceFile $SourceFile -DestinationPath $DestinationPath -Attempt ($Attempt + 1)
        }
        return @{ Success = $false; Retryable = $true }
    }
}

function Process-SingleFile {
    <#
    .SYNOPSIS
        Processes a single file: wait for ready, transfer, move to appropriate folder.
        Supports subfolder structure - preserves relative paths on CNC destination.
        Tool table files (e.g. tool.t) are routed to $ToolTableDestination with
        merge semantics via Send-ToolTableFile.
    #>
    param([string]$FilePath)
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    
    # Verify file still exists
    if (-not (Test-Path $FilePath)) {
        Write-Log "File no longer exists, skipping: $fileName" "WARNING"
        return
    }
    
    # Wait for file to be fully written
    Write-Log "Waiting for file to be ready: $fileName"
    $ready = Wait-FileReady -FilePath $FilePath -TimeoutSeconds 30
    
    if (-not $ready) {
        Write-Log "File still locked after 30s, skipping: $fileName" "WARNING"
        return
    }
    
    # Check if this is a tool table file that needs special routing
    $isToolTable = $ToolTableFiles | Where-Object { $_ -ieq $fileName }
    if ($isToolTable) {
        Write-Log "Tool table file detected: $fileName -> $ToolTableDestination (mode: $ToolTableTransferMode)"
        $result = Send-ToolTableFile -SourceFile $FilePath -DestinationPath $ToolTableDestination
        Move-ProcessedFile -FilePath $FilePath -Success $result.Success
        return
    }

    # Compute destination path, preserving subfolder structure
    $watchBase = $WatchFolder.TrimEnd('\', '/')
    $relativePath = $FilePath.Substring($watchBase.Length + 1)
    $relativeDir = [System.IO.Path]::GetDirectoryName($relativePath)
    
    if ($relativeDir) {
        # File is in a subfolder - mirror the structure on the CNC
        $destPath = $DestinationFolder.TrimEnd('\', '/') + '\' + $relativeDir.Replace('/', '\')
        Write-Log "Creating remote directory: $destPath"
        New-RemoteDirectory -RemotePath $destPath
    } else {
        $destPath = $DestinationFolder
    }
    
    # Transfer the file
    $result = Send-FileToMachine -SourceFile $FilePath -DestinationPath $destPath
    
    # Handle post-transfer file movement
    Move-ProcessedFile -FilePath $FilePath -Success $result.Success
}

function Initialize-WatchFolder {
    <#
    .SYNOPSIS
        Creates watch folder and subfolders if they don't exist.
    #>
    
    # Wait for the watch folder to be reachable. On a NAS share this can fail
    # temporarily (NAS boots slower than this PC) or permanently (service
    # account has no access to the share) - keep retrying instead of crashing
    # so the service recovers on its own once the share is available.
    # Authenticate to the NAS share first if a stored credential exists
    Connect-NASShare

    $warned = $false
    while (-not (Test-Path $WatchFolder)) {
        try {
            New-Item -Path $WatchFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {}

        # Verify with Test-Path rather than trusting New-Item: on an
        # inaccessible share New-Item -Force can return without error while
        # the folder is still not actually visible to this account.
        if (Test-Path $WatchFolder) { break }

        if (-not $warned) {
            Write-Log "Watch folder unreachable: $WatchFolder" "WARNING"
            Write-Log "Waiting for it to come online (NAS still booting? service account lacks share access?). Retrying every 30s..." "WARNING"
            $warned = $true
        }
        Start-Sleep -Seconds 30
        Connect-NASShare
    }
    if ($warned) {
        Write-Log "Watch folder is now reachable: $WatchFolder" "SUCCESS"
    }
    
    # Create processed folder if needed
    if ($MoveToProcessedFolder) {
        $processedFolder = Join-Path $WatchFolder "Processed"
        if (-not (Test-Path $processedFolder)) {
            New-Item -Path $processedFolder -ItemType Directory -Force | Out-Null
        }
    }
    
    # Create failed folder if needed
    if ($MoveToFailedFolder) {
        $failedFolder = Join-Path $WatchFolder "Failed"
        if (-not (Test-Path $failedFolder)) {
            New-Item -Path $failedFolder -ItemType Directory -Force | Out-Null
        }
    }
}

function Process-ExistingFiles {
    <#
    .SYNOPSIS
        Processes any files that already exist in the watch folder on startup.
    #>
    
    $gciParams = @{
        Path        = $WatchFolder
        Filter      = $FileFilter
        File        = $true
        ErrorAction = 'SilentlyContinue'
    }
    if ($IncludeSubdirectories) { $gciParams['Recurse'] = $true }
    
    # Exclude files already in Processed or Failed folders
    $existingFiles = Get-ChildItem @gciParams | Where-Object {
        $rel = $_.FullName.Substring($WatchFolder.TrimEnd('\', '/').Length + 1)
        $rel -notmatch '^(Processed|Failed)(\\|/)'
    }
    
    if ($existingFiles.Count -gt 0) {
        Write-Log "Found $($existingFiles.Count) existing file(s) in watch folder"
        foreach ($file in $existingFiles) {
            $rel = $file.FullName.Substring($WatchFolder.TrimEnd('\', '/').Length + 1)
            Write-Log "Processing existing file: $rel"
            Process-SingleFile -FilePath $file.FullName
        }
        Write-Log "Finished processing existing files"
        Write-Log ""
    }
}

function Start-SynchronousWatcher {
    <#
    .SYNOPSIS
        Monitors folder using synchronous WaitForChanged() method.
        Simple and reliable, but blocks during file processing.
    #>
    
    Write-Log "Starting SYNCHRONOUS watcher (WaitForChanged mode)"
    Write-Log ""
    
    # Create the FileSystemWatcher
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $WatchFolder
    $watcher.Filter = $FileFilter
    $watcher.IncludeSubdirectories = $IncludeSubdirectories
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
    
    try {
        while ($true) {
            # Wait for a file creation event (1 second timeout for responsiveness)
            try {
                $result = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Created, 1000)
            }
            catch {
                # Watcher died (e.g. network drop to NAS) - recreate it
                Write-Log "Watcher error ($_) - recreating in 30s" "WARNING"
                try { $watcher.Dispose() } catch {}
                Start-Sleep -Seconds 30
                $watcher = New-Object System.IO.FileSystemWatcher
                $watcher.Path = $WatchFolder
                $watcher.Filter = $FileFilter
                $watcher.IncludeSubdirectories = $IncludeSubdirectories
                $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
                continue
            }

            if (-not $result.TimedOut) {
                # Skip files created in Processed or Failed subfolders
                if ($result.Name -match '^(Processed|Failed)(\\|/)') { continue }
                
                $filePath = Join-Path $WatchFolder $result.Name
                Write-Log ""
                Write-Log "New file detected: $($result.Name)"
                
                # Small delay to ensure file write is complete
                Start-Sleep -Milliseconds 500
                
                # Process the file
                Process-SingleFile -FilePath $filePath
                
                Write-Log ""
                Write-Log "Waiting for files... (Press Ctrl+C to stop)"
            }
        }
    }
    finally {
        $watcher.Dispose()
        Write-Log "Synchronous watcher stopped."
    }
}

function Start-AsynchronousWatcher {
    <#
    .SYNOPSIS
        Monitors folder using event-based asynchronous method with a queue.
        Non-blocking, handles rapid file creation without missing events.
    #>
    
    Write-Log "Starting ASYNCHRONOUS watcher (Event Queue mode)"
    Write-Log ""

    # Thread-safe queue for detected files
    $global:FileQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    # Set by the watcher's Error event when it dies (e.g. NAS connection drop).
    # A dead FileSystemWatcher on a UNC path silently stops raising Created
    # events forever - without this flag the script would keep running but
    # never notice another file.
    $global:WatcherFailed = $false

    # Event handler - just queues the file path (fast, no scope issues)
    # Skips files created in Processed or Failed subfolders
    $action = {
        $name = $Event.SourceEventArgs.Name
        if ($name -notmatch '^(Processed|Failed)(\\|/)') {
            $filePath = $Event.SourceEventArgs.FullPath
            $global:FileQueue.Enqueue($filePath)
        }
    }

    $errorAction = {
        $global:WatcherFailed = $true
    }

    function New-TNCWatcher {
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $WatchFolder
        $w.Filter = $FileFilter
        $w.IncludeSubdirectories = $IncludeSubdirectories
        $w.NotifyFilter = [System.IO.NotifyFilters]::FileName
        Register-ObjectEvent -InputObject $w -EventName Created -Action $action -SourceIdentifier "FileCreated" | Out-Null
        Register-ObjectEvent -InputObject $w -EventName Error -Action $errorAction -SourceIdentifier "WatcherError" | Out-Null
        $w.EnableRaisingEvents = $true
        return $w
    }

    function Remove-TNCWatcher([System.IO.FileSystemWatcher]$w) {
        Unregister-Event -SourceIdentifier "FileCreated" -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "WatcherError" -ErrorAction SilentlyContinue
        Remove-Job -Name "FileCreated" -Force -ErrorAction SilentlyContinue
        Remove-Job -Name "WatcherError" -Force -ErrorAction SilentlyContinue
        if ($w) {
            try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch {}
        }
    }

    $watcher = New-TNCWatcher
    $lastRescan = Get-Date
    $lastHeartbeat = Get-Date

    try {
        while ($true) {
            # Recreate the watcher if it died (network drop to the NAS, etc.)
            if ($global:WatcherFailed) {
                Write-Log "FileSystemWatcher reported an error (network drop to NAS?). Recreating..." "WARNING"
                Remove-TNCWatcher $watcher
                $watcher = $null
                $global:WatcherFailed = $false
                while (-not $watcher) {
                    try {
                        Connect-NASShare
                        if (-not (Test-Path $WatchFolder)) { throw "watch folder unreachable" }
                        $watcher = New-TNCWatcher
                        Write-Log "Watcher recreated successfully." "SUCCESS"
                    }
                    catch {
                        Write-Log "Watch folder still unreachable ($_) - retrying in 30s" "WARNING"
                        Start-Sleep -Seconds 30
                    }
                }
                # Force an immediate rescan to pick up files dropped during the outage
                $lastRescan = (Get-Date).AddHours(-1)
            }

            # Process any files in the queue
            $filePath = $null
            while ($global:FileQueue.TryDequeue([ref]$filePath)) {
                $fileName = [System.IO.Path]::GetFileName($filePath)
                Write-Log ""
                Write-Log "New file detected: $fileName"

                # Small delay to ensure file write is complete
                Start-Sleep -Milliseconds 500

                # Process the file
                Process-SingleFile -FilePath $filePath

                Write-Log ""
                Write-Log "Waiting for files... (Press Ctrl+C to stop)"
            }

            # Fallback rescan every 5 minutes: catches files whose Created event
            # was missed (watcher hiccup, file dropped during processing burst).
            # Only picks up files that have sat untouched for 60s so it never
            # races the event-driven path.
            if (((Get-Date) - $lastRescan).TotalMinutes -ge 5) {
                $lastRescan = Get-Date
                try {
                    $gciParams = @{
                        Path        = $WatchFolder
                        Filter      = $FileFilter
                        File        = $true
                        ErrorAction = 'SilentlyContinue'
                    }
                    if ($IncludeSubdirectories) { $gciParams['Recurse'] = $true }
                    $cutoff = (Get-Date).AddSeconds(-60)
                    $watchBase = $WatchFolder.TrimEnd('\', '/')
                    $missed = Get-ChildItem @gciParams | Where-Object {
                        $rel = $_.FullName.Substring($watchBase.Length + 1)
                        ($rel -notmatch '^(Processed|Failed)(\\|/)') -and
                        ($_.LastWriteTime -lt $cutoff) -and
                        ($global:FileQueue -notcontains $_.FullName)
                    }
                    foreach ($f in $missed) {
                        Write-Log "Rescan found unprocessed file: $($f.Name)" "WARNING"
                        $global:FileQueue.Enqueue($f.FullName)
                    }
                }
                catch {
                    Write-Log "Fallback rescan failed: $_" "WARNING"
                }
            }

            # Heartbeat so the log shows the watcher is alive
            if (((Get-Date) - $lastHeartbeat).TotalMinutes -ge 30) {
                $lastHeartbeat = Get-Date
                Write-Log "Heartbeat: watcher running, waiting for files." "DEBUG"
            }

            # Small sleep to prevent CPU spinning
            # This keeps PowerShell responsive to events while not burning CPU
            Start-Sleep -Milliseconds 200
        }
    }
    finally {
        # Cleanup
        Remove-TNCWatcher $watcher
        Write-Log "Asynchronous watcher stopped."
    }
}

function Start-FolderWatcher {
    <#
    .SYNOPSIS
        Main entry point - initializes and starts the folder watcher.
    #>
    
    Write-Log "=============================================="
    Write-Log "Heidenhain TNCcmd Folder Watcher v1.6.0"
    Write-Log "=============================================="
    if ($ConfigOverridesActive) {
        Write-Log "Config File:     $ConfigFile (overrides active)"
    }
    Write-Log "Watcher Mode:    $WatcherMode"
    Write-Log "Machine IP:      $MachineIP"
    Write-Log "Watch Folder:    $WatchFolder"
    Write-Log "Destination:     $DestinationFolder"
    Write-Log "File Filter:     $FileFilter"
    Write-Log "Subdirectories:  $IncludeSubdirectories"
    Write-Log "Retry Settings:  $MaxRetries attempts, ${RetryDelaySeconds}s delay"
    Write-Log "Tool Tables:     [$($ToolTableFiles -join ', ')] -> $ToolTableDestination (mode: $ToolTableTransferMode, backups: $ToolTableBackupCount in '$ToolTableBackupFolder')"
    Write-Log "=============================================="
    
    # Initialize folders
    Initialize-WatchFolder
    
    # Process any existing files
    Process-ExistingFiles
    
    Write-Log "Waiting for files... (Press Ctrl+C to stop)"
    Write-Log ""
    
    # Start the appropriate watcher based on configuration
    switch ($WatcherMode) {
        "Synchronous" {
            Start-SynchronousWatcher
        }
        "Asynchronous" {
            Start-AsynchronousWatcher
        }
        default {
            Write-Log "Invalid WatcherMode: $WatcherMode. Use 'Synchronous' or 'Asynchronous'." "ERROR"
            exit 1
        }
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Detect whether we're running interactively (terminal window) or headless
# (Windows service via NSSM / scheduled task). Console-only operations like
# Clear-Host and ReadKey crash or hang forever in a headless session.
$IsInteractiveSession = [Environment]::UserInteractive

# Clear screen and show header
if ($IsInteractiveSession) {
    try { Clear-Host } catch {}
}
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Heidenhain TNCcmd Automatic File Transfer - Folder Watcher   " -ForegroundColor Cyan
Write-Host "  Mode: $WatcherMode" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Verify TNCcmd is installed
if (-not (Test-TNCcmd)) {
    if ($IsInteractiveSession) {
        Write-Host ""
        Write-Host "Press any key to exit..."
        try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch {}
    }
    exit 1
}

# Optional: Test connection to machine (uncomment to enable)
# if (-not (Test-MachineConnection -IP $MachineIP)) {
#     Write-Log "Cannot connect to machine. Check IP address and network." "ERROR"
#     Write-Host "Press any key to exit..."
#     $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
#     exit 1
# }

# Start the folder watcher
try {
    Start-FolderWatcher
}
catch {
    Write-Log "Fatal error: $_" "ERROR"
    exit 1
}
