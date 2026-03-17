#Requires -Version 5.1
<#
================================================================================
  TNCcmd Folder Watcher
  Version: 1.0.0
  Date:    2026-03-12
  Author:  Xander Luciano
================================================================================

.SYNOPSIS
    Watches a folder for new files and automatically sends them to a Heidenhain CNC machine using TNCcmd.

.DESCRIPTION
    This script monitors a specified folder for newly created files and automatically
    transfers them to a Heidenhain CNC controller over the network using the TNCcmd
    command-line tool (part of TNCremo software package).

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

# Machine IP address - Change this to your CNC machine's IP
$MachineIP = "192.168.1.100"

# Watch folder path
# - Use ".\WatchFolder" for a subfolder next to this script
# - Use $PSScriptRoot for the same folder as the script
# - Or specify a full path like "C:\NCPrograms\ToMachine"
$WatchFolder = ".\WatchFolder"

# Destination folder on the CNC machine
# - TNC:\ is the root of the machine's storage
# - Common paths: TNC:\nc_prog\, TNC:\Programs\, TNC:\
$DestinationFolder = "TNC:\"

# File filter - which files to watch for
# - "*.h" for Heidenhain NC programs only
# - "*.H" for uppercase extension
# - "*.*" for all files
# - "*.h,*.i,*.t" for multiple extensions (handled in code)
$FileFilter = "*.*"

# TNCcmd.exe path (usually auto-detected)
$TNCcmdPath = "C:\Program Files (x86)\HEIDENHAIN\TNCremo\TNCcmd.exe"

# Transfer options
$UseBinaryMode = $true           # Use /b flag for binary transfer (recommended)
$ConvertNCPrograms = $false      # Use /c flag to convert .H/.I files during transfer
$DeleteAfterTransfer = $false    # Delete source file after successful transfer
$MoveToProcessedFolder = $true   # Move files to "Processed" subfolder after transfer
$MoveToFailedFolder = $true      # Move files to "Failed" subfolder after max retries

# Retry settings (for locked files on controller)
$MaxRetries = 150                # Maximum retry attempts
$RetryDelaySeconds = 30          # Seconds between retries

# Logging
$EnableLogging = $true
$LogFile = ".\TNCcmd-Watcher.log"

# Connection timeout in seconds
$ConnectionTimeout = 30

# ============================================================================
# END OF CONFIGURATION
# ============================================================================

# Resolve paths to absolute paths
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$WatchFolder = if ([System.IO.Path]::IsPathRooted($WatchFolder)) { $WatchFolder } else { Join-Path $ScriptDir $WatchFolder }
$LogFile = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage }
    }
    
    # File logging
    if ($EnableLogging) {
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
    # We'll try to connect and immediately disconnect
    $cmdFile = [System.IO.Path]::GetTempFileName()
    try {
        @"
CONNECT -I $IP
EXIT
"@ | Set-Content $cmdFile -Encoding ASCII
        
        $result = & $TNCcmdPath < $cmdFile 2>&1
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
        "connection lost",
        "connection reset"
    )
    
    foreach ($pattern in $retryPatterns) {
        if ($ErrorOutput -match $pattern) {
            return $true
        }
    }
    return $false
}

function Send-FileToMachine {
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
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $TNCcmdPath
        $psi.Arguments = $arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit($ConnectionTimeout * 1000)
        
        $exitCode = $process.ExitCode
        $combinedOutput = "$stdout $stderr".ToLower()
        
        # Success case
        if ($exitCode -eq 0 -and $stderr -eq "") {
            if ($Attempt -gt 1) {
                Write-Log "Transfer successful after $Attempt attempts: $fileName" "SUCCESS"
            } else {
                Write-Log "Transfer successful: $fileName" "SUCCESS"
            }
            return @{ Success = $true; Retryable = $false }
        }
        
        # Check if this is a retryable error (file locked, etc.)
        $isRetryable = Test-RetryableError -ErrorOutput $combinedOutput
        
        if ($isRetryable -and $Attempt -lt $MaxRetries) {
            Write-Log "File appears locked on controller. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
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

function Start-FolderWatcher {
    # Create watch folder if it doesn't exist
    if (-not (Test-Path $WatchFolder)) {
        Write-Log "Creating watch folder: $WatchFolder"
        New-Item -Path $WatchFolder -ItemType Directory -Force | Out-Null
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
    
    Write-Log "=============================================="
    Write-Log "Heidenhain TNCcmd Folder Watcher Started"
    Write-Log "=============================================="
    Write-Log "Machine IP:      $MachineIP"
    Write-Log "Watch Folder:    $WatchFolder"
    Write-Log "Destination:     $DestinationFolder"
    Write-Log "File Filter:     $FileFilter"
    Write-Log "Retry Settings:  $MaxRetries attempts, ${RetryDelaySeconds}s delay"
    Write-Log "=============================================="
    Write-Log "Waiting for files... (Press Ctrl+C to stop)"
    Write-Log ""
    
    # Create FileSystemWatcher
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $WatchFolder
    $watcher.Filter = $FileFilter
    $watcher.IncludeSubdirectories = $false
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
    $watcher.EnableRaisingEvents = $true
    
    # Event handler for new files
    $action = {
        $path = $Event.SourceEventArgs.FullPath
        $name = $Event.SourceEventArgs.Name
        $changeType = $Event.SourceEventArgs.ChangeType
        
        # Wait a moment for the file to be fully written
        Start-Sleep -Milliseconds 500
        
        # Wait for file to be released (up to 30 seconds)
        $timeout = 30
        $waited = 0
        while ($waited -lt $timeout) {
            try {
                $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
                $stream.Close()
                break
            }
            catch {
                Start-Sleep -Seconds 1
                $waited++
            }
        }
        
        if ($waited -ge $timeout) {
            & $WriteLog "File still locked after ${timeout}s, skipping: $name" "WARNING"
            return
        }
        
        # Transfer the file (returns hashtable with Success and Retryable)
        $result = & $SendFile $path $DestinationFolder
        
        if ($result.Success) {
            if ($DeleteAfterTransfer) {
                Remove-Item $path -Force
                & $WriteLog "Deleted source file: $name"
            }
            elseif ($MoveToProcessedFolder) {
                $processedPath = Join-Path (Split-Path $path) "Processed\$name"
                Move-Item $path $processedPath -Force
                & $WriteLog "Moved to Processed: $name"
            }
        }
        else {
            # Transfer failed - move to Failed folder if enabled
            if ($MoveToFailedFolder) {
                $failedPath = Join-Path (Split-Path $path) "Failed\$name"
                Move-Item $path $failedPath -Force
                & $WriteLog "Moved to Failed folder: $name" "ERROR"
            }
        }
    }
    
    # Pass functions to the scriptblock scope
    $WriteLog = ${function:Write-Log}
    $SendFile = ${function:Send-FileToMachine}
    
    # Register the event
    $job = Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action `
        -MessageData @{
            WriteLog = $WriteLog
            SendFile = $SendFile
            DeleteAfterTransfer = $DeleteAfterTransfer
            MoveToProcessedFolder = $MoveToProcessedFolder
            MoveToFailedFolder = $MoveToFailedFolder
            DestinationFolder = $DestinationFolder
        }
    
    # Also check for existing files on startup
    $existingFiles = Get-ChildItem -Path $WatchFolder -Filter $FileFilter -File -ErrorAction SilentlyContinue
    if ($existingFiles.Count -gt 0) {
        Write-Log "Found $($existingFiles.Count) existing file(s) in watch folder"
        foreach ($file in $existingFiles) {
            Write-Log "Processing existing file: $($file.Name)"
            $result = Send-FileToMachine -SourceFile $file.FullName -DestinationPath $DestinationFolder
            
            if ($result.Success) {
                if ($DeleteAfterTransfer) {
                    Remove-Item $file.FullName -Force
                    Write-Log "Deleted source file: $($file.Name)"
                }
                elseif ($MoveToProcessedFolder) {
                    $processedPath = Join-Path $WatchFolder "Processed\$($file.Name)"
                    Move-Item $file.FullName $processedPath -Force
                    Write-Log "Moved to Processed: $($file.Name)"
                }
            }
            else {
                # Transfer failed - move to Failed folder if enabled
                if ($MoveToFailedFolder) {
                    $failedPath = Join-Path $WatchFolder "Failed\$($file.Name)"
                    Move-Item $file.FullName $failedPath -Force
                    Write-Log "Moved to Failed folder: $($file.Name)" "ERROR"
                }
            }
        }
    }
    
    # Keep script running
    try {
        while ($true) {
            Wait-Event -Timeout 1
            # Process any pending events
        }
    }
    finally {
        # Cleanup on exit
        Write-Log "Stopping folder watcher..."
        Unregister-Event -SourceIdentifier $job.Name -ErrorAction SilentlyContinue
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        Write-Log "Folder watcher stopped."
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Clear screen and show header
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Heidenhain TNCcmd Automatic File Transfer - Folder Watcher   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Verify TNCcmd is installed
if (-not (Test-TNCcmd)) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
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
