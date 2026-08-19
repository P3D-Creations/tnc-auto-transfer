#Requires -Version 5.1
<#
================================================================================
  TNCcmd Folder Watcher
  Version: 1.8.0
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

# Files with these names (case-insensitive), OR any file placed in the tool
# table folder below, are routed to $ToolTableDestination instead of
# $DestinationFolder and receive special handling (backup + merge/overwrite).
$ToolTableFiles       = @("tool.t")    # Filenames that always trigger tool-table handling
$ToolTableDestination = "TNC:\table\"  # Destination folder on the CNC for tool tables

# Dedicated subfolder INSIDE the watch folder for tool tables. Any file dropped
# here is treated as a tool table and routed to $ToolTableDestination (never to
# the NC-program location). Timestamped backups of the remote table are kept in
# its "Backups" subfolder. The whole folder is excluded from normal watching so
# a downloaded backup is never sent back to the machine.
$ToolTableFolder = "ToolTables"        # Relative to the watch folder, or an absolute path

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
# saved locally as a timestamped backup. Backups are stored in the "Backups"
# subfolder of $ToolTableFolder (set automatically below). Older backups are
# pruned automatically.
$ToolTableBackupCount  = 20                      # Max number of backups to keep

# ------------------------------
# STL TRANSFER (machine simulation / collision monitoring)
# ------------------------------

# The Kern post (kern_beta.cps) can emit STOCK/PART/FIXTURE meshes plus a
# metadata sidecar alongside each program. Schema: p3d.kern.fixture-stl-meta.
# See Kern\Documentation\Fixture-STL-Handoff.md.
$EnableStlTransfer = $true

$StlPrepExe        = ".\TNCWatcher-StlPrep.exe"  # relative to this script, or absolute
$StlMaxTriangles   = 19500      # control's limit is 20000; margin for safety
$FixtureClearanceMM = 1.5       # each fixture face moves inward this far, to stop DCM tripping

# Send meshes as ASCII STL rather than binary. The TNC 640 rejects a long run
# of bytes containing no line break during PUT, even in /b (binary 1:1) mode,
# with "E20001714: Formatting error". Measured on this machine: a 1.5MB binary
# STL fails; the identical 1.5MB with a newline every 80 bytes succeeds, as
# does a 25MB NC program. ASCII STL is ~4.6x larger but line-based, so it
# transfers reliably. Only set this false if a future control firmware fixes
# binary PUT.
$StlAsciiOutput    = $true

# Hard limit on one mesh's processing. File handling is single-threaded, so an
# unbounded wait here stalls every other transfer. An in-process stock mesh for
# a later operation can be enormous - 1.66M triangles / 83MB has been seen - so
# this needs headroom, but not forever. On timeout that mesh is skipped and the
# others still go.
$StlPrepTimeoutSeconds = 600

# How often to echo the converter's current stage to the log while it works.
$StlProgressIntervalSeconds = 10

# The post writes the NC file at the parent level while posting, then moves it
# into the per-program subfolder in onTerminate(). Without a delay the watcher
# grabs that transient copy, uploads it to the wrong place, and can even move it
# to Processed out from under the post's own move.
#
# Two guards, belt and braces:
#   1. Wait this long before sending an NC program, then re-check it is still
#      there. If the post moved it away, that copy is skipped silently.
#   2. Structural check: if a SUBFOLDER of this file's folder holds a sidecar
#      naming this NC file, the copy in hand is the transient one and the
#      subfolder copy is authoritative.
# Set the delay to 0 to disable both.
#   3. Once a bundle has been sent, any leftover transient copy is retired to
#      Processed. Skipping alone is not enough: the file stays in the watch
#      folder, and by the time the fallback rescan finds it the sidecar has
#      been archived, so nothing is left to recognise it by and it gets sent.
#
# The wait POLLS rather than sleeping once, so it reacts the moment the post
# moves the file or writes the sidecar, however long that takes. Measured on
# this machine: 19s between the transient appearing and the sidecar landing,
# so a single 15s sleep-then-check missed it. A program already sitting in its
# own program folder (sidecar beside it) is authoritative and skips the wait
# entirely. Set the delay to 0 to disable all of this.
$NcSettleDelaySeconds = 45
$NcSettleExtensions   = @(".h", ".i")

# Use the subfolder-sidecar structure to recognise a transient copy. Turn off
# if the post is changed to write the program straight into its final folder.
$StlUseSubfolderSidecarCheck = $true

$StlMetaSchema           = "p3d.kern.fixture-stl-meta"
$StlMetaMaxSchemaVersion = 1    # refuse anything newer rather than guess

# The post documents the STL vertex frame as INFERRED, not measured, so the
# STOCK mesh's bounds are compared against stockBounds_wcs as a diagnostic. A
# real frame error shows up as a huge offset (the doc's own example differs by
# 153mm), not a sub-millimetre one, so the tolerance only has to clear triangle
# reduction and the odd stray polygon.
#
# This WARNS but never blocks: the control needs the referenced STL files to
# run the program at all, so withholding one is a worse failure than shipping a
# suspect one. Stock and part meshes are display-only anyway.
$StlValidateStockBounds  = $true
$StlBoundsToleranceMM    = 0.5

# ------------------------------
# IGNORED FILES (system / hidden junk)
# ------------------------------

# When $true, any file or folder whose name (in ANY path segment) matches one of
# $IgnoreFilePatterns is silently ignored: never transmitted to the machine, and
# never written to the log or shown in a toast. This keeps OS metadata that a
# Mac/Windows/NAS sprinkles into shared folders from cluttering things up.
# Covers macOS (.DS_Store, ._ resource forks, .Spotlight-V100, .Trashes,
# .fseventsd, ...), Windows (Thumbs.db, desktop.ini, ~$ Office lock files), and
# Synology (@eaDir index folders, @SynoResource / @SynoEAStream). Any file whose
# Hidden or System attribute is set is also skipped. Matched case-insensitively.
$IgnoreSystemFiles  = $true
$IgnoreFilePatterns = @(
    '(^|[\\/])\.',                                     # any dotfile / dotfolder (hidden)
    '(^|[\\/])~\$',                                    # Office temp / lock files (~$...)
    '(^|[\\/])(Thumbs\.db|ehthumbs\.db|desktop\.ini)([\\/]|$)',
    '(^|[\\/])@eaDir([\\/]|$)',                        # Synology index folder
    '@Syno',                                           # @SynoResource / @SynoEAStream suffixes
    '\.(tmp|bak|old|part|partial|crdownload|swp)$'     # editor / half-written leftovers
)

# Files that are NEVER sent to the machine but ARE worth keeping: they get
# filed into the Processed folder alongside the program they came from, so a
# failed post can still be reviewed afterwards instead of being left loose in
# the watch folder. Matched on extension, case-insensitively.
$ArchiveOnlyExtensions = @(".failed", ".log")

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
        if ($cfg.ToolTableTransferMode)  { $ToolTableTransferMode  = [string]$cfg.ToolTableTransferMode }
        if ($cfg.ToolTableFolder)        { $ToolTableFolder        = [string]$cfg.ToolTableFolder }
        if ($null -ne $cfg.FixtureClearanceMM)     { $FixtureClearanceMM     = [double]$cfg.FixtureClearanceMM }
        if ($null -ne $cfg.NcSettleDelaySeconds)   { $NcSettleDelaySeconds   = [int]$cfg.NcSettleDelaySeconds }
        if ($null -ne $cfg.StlUseSubfolderSidecarCheck) { $StlUseSubfolderSidecarCheck = [bool]$cfg.StlUseSubfolderSidecarCheck }
        if ($null -ne $cfg.EnableStlTransfer)      { $EnableStlTransfer      = [bool]$cfg.EnableStlTransfer }
        $ConfigOverridesActive = $true
    }
    catch {
        # Malformed config file - ignore and use script defaults
    }
}
$WatchFolder = if ([System.IO.Path]::IsPathRooted($WatchFolder)) { $WatchFolder } else { Join-Path $ScriptDir $WatchFolder }
$LogFile = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }
$NASCredentialFile = if ([System.IO.Path]::IsPathRooted($NASCredentialFile)) { $NASCredentialFile } else { Join-Path $ScriptDir $NASCredentialFile }
$StlPrepExe = if ([System.IO.Path]::IsPathRooted($StlPrepExe)) { $StlPrepExe } else { Join-Path $ScriptDir $StlPrepExe }

# Tool table folder lives inside the watch folder unless an absolute path was
# given; backups go in its "Backups" subfolder.
$ToolTableFolder = if ([System.IO.Path]::IsPathRooted($ToolTableFolder)) { $ToolTableFolder } else { Join-Path $WatchFolder $ToolTableFolder }
$ToolTableBackupFolder = Join-Path $ToolTableFolder "Backups"

# Build the exclusion regex used by every watcher entry point. Files whose path
# (relative to the watch folder) matches this are NOT processed as NC programs:
# the Processed/Failed folders always, plus the tool-table Backups folder when
# it lives inside the watch folder (so downloaded backups are never re-sent).
$WatchBaseForExclude = $WatchFolder.TrimEnd('\', '/')
$excludeNames = @('Processed', 'Failed')
$backupTrim = $ToolTableBackupFolder.TrimEnd('\', '/')
if ($backupTrim.ToLower().StartsWith(($WatchBaseForExclude + '\').ToLower())) {
    $backupRel = $backupTrim.Substring($WatchBaseForExclude.Length + 1)
    $excludeNames += [regex]::Escape($backupRel)
}
$global:WatchExcludeRegex = '^(' + ($excludeNames -join '|') + ')(\\|/)'

# Regex matching system/hidden junk to ignore entirely (see $IgnoreFilePatterns).
# '(?!)' never matches, so setting $IgnoreSystemFiles = $false disables it.
$global:IgnoreRegex = if ($IgnoreSystemFiles -and $IgnoreFilePatterns.Count -gt 0) {
    '(?i)' + ($IgnoreFilePatterns -join '|')
} else {
    '(?!)'
}

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

function Get-RemoteDestinationFor {
    <#
    .SYNOPSIS
        Maps a file in the watch folder to its destination folder on the
        control, mirroring any subfolder structure. Optionally creates the
        remote directory tree.
    #>
    param(
        [string]$FilePath,
        [bool]$CreateRemote = $false
    )

    $watchBase = $WatchFolder.TrimEnd('\', '/')
    $relativePath = $FilePath.Substring($watchBase.Length + 1)
    $relativeDir = [System.IO.Path]::GetDirectoryName($relativePath)

    if ($relativeDir) {
        $destPath = $DestinationFolder.TrimEnd('\', '/') + '\' + $relativeDir.Replace('/', '\')
        if ($CreateRemote) {
            Write-Log "Creating remote directory: $destPath"
            New-RemoteDirectory -RemotePath $destPath
        }
        return $destPath
    }
    return $DestinationFolder
}

function Get-StlMeta {
    <#
    .SYNOPSIS
        Parses a post-generated STL metadata sidecar and gates it on schema and
        version. Returns $null if the file is not one of ours or is unusable.
    #>
    param([string]$Path)

    try { $j = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { return $null }

    if (-not $j -or $j.schema -ne $StlMetaSchema) { return $null }   # not our sidecar

    if ($null -eq $j.schemaVersion -or [int]$j.schemaVersion -gt $StlMetaMaxSchemaVersion) {
        Write-Log "STL metadata schemaVersion $($j.schemaVersion) is newer than supported ($StlMetaMaxSchemaVersion): $Path" "ERROR"
        Write-Log "Refusing to guess. Update the watcher before using this post." "ERROR"
        return $null
    }
    return $j
}

function Invoke-StlPrep {
    <#
    .SYNOPSIS
        Runs TNCWatcher-StlPrep.exe and returns its JSON report as an object,
        or $null on failure. Extra arguments are passed through.
    .OUTPUTS
        PSCustomObject from the tool's JSON report, plus an ExitCode property.
    #>
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string[]]$ExtraArgs = @()
    )

    if (-not (Test-Path $StlPrepExe)) {
        Write-Log "STL prep tool not found at $StlPrepExe - build it with service\Build-StlPrep.cmd" "ERROR"
        return $null
    }

    $argList = @("`"$InputFile`"", "`"$OutputFile`"") + $ExtraArgs
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $StlPrepExe
    $psi.Arguments              = ($argList -join " ")
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    # Async pipe reads plus a hard timeout - same reasoning as Invoke-TNCcmd.
    # A synchronous ReadToEnd() before WaitForExit() can deadlock, and an
    # unbounded WaitForExit() blocks the whole watcher: file processing is
    # single-threaded, so one enormous mesh would stall every other transfer
    # indefinitely. On timeout the mesh is skipped and the rest still go.
    # Sign of life while a dense mesh is converted: the tool writes its current
    # stage to a progress file, and that is echoed to the log every few seconds
    # so the tray tooltip and live console show something is happening. A 1.66M
    # triangle in-process stock mesh is not unusual and takes a while.
    $progressFile = [System.IO.Path]::GetTempFileName()
    $psi.Arguments = $psi.Arguments + " --progress-file `"$progressFile`""

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $name = [System.IO.Path]::GetFileName($InputFile)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $nextBeat = $StlProgressIntervalSeconds
        $timedOut = $false

        while (-not $p.WaitForExit(500)) {
            if ($sw.Elapsed.TotalSeconds -ge $StlPrepTimeoutSeconds) { $timedOut = $true; break }
            if ($sw.Elapsed.TotalSeconds -ge $nextBeat) {
                $nextBeat += $StlProgressIntervalSeconds
                $stage = ""
                try { $stage = (Get-Content -LiteralPath $progressFile -Raw -ErrorAction SilentlyContinue) } catch {}
                if ($stage) { $stage = $stage.Trim() }
                if (-not $stage) { $stage = "working" }
                Write-Log ("    {0}: {1} ({2}s elapsed)" -f $name, $stage, [int]$sw.Elapsed.TotalSeconds)
            }
        }

        if ($timedOut) {
            try { $p.Kill() } catch {}
            $p.WaitForExit(5000) | Out-Null
            $p.Dispose()
            Write-Log "STL prep timed out after ${StlPrepTimeoutSeconds}s and was killed: $name" "ERROR"
            Write-Log "  The mesh is probably far too dense for this budget. Raise the timeout, or export it more coarsely." "ERROR"
            return $null
        }

        $out = ""; $err = ""
        try { if ($outTask.Wait(5000)) { $out = $outTask.Result } } catch {}
        try { if ($errTask.Wait(5000)) { $err = $errTask.Result } } catch {}
        $code = $p.ExitCode
        $p.Dispose()

        if ($code -ne 0) {
            Write-Log "STL prep failed (exit $code) for ${name}: $($err.Trim())" "ERROR"
            return $null
        }
        $rep = $out.Trim() | ConvertFrom-Json
        return $rep
    }
    catch {
        Write-Log "STL prep exception for $([System.IO.Path]::GetFileName($InputFile)): $_" "ERROR"
        return $null
    }
    finally {
        Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-StlFrameHypothesis {
    <#
    .SYNOPSIS
        The post documents the STL vertex frame as inferred-unverified. Compare
        the STOCK mesh's actual bounds against stockBounds_wcs from the JSON as
        a diagnostic.

        Reports only - the caller still uploads. A real frame error is a large
        offset and will be obvious in the log and on the control; withholding
        the file instead would stop the program running at all.
    .OUTPUTS
        $true if the bounds agree (or cannot be checked), $false on mismatch.
    #>
    param(
        [string]$StockFile,
        $Meta
    )

    if (-not $StlValidateStockBounds) { return $true }
    if (-not $Meta.stockBounds_wcs -or -not (Test-Path $StockFile)) { return $true }

    $rep = Invoke-StlPrep -InputFile $StockFile -OutputFile "$StockFile.probe" -ExtraArgs @("--probe")
    if (-not $rep) { return $true }   # already logged; don't block on a probe failure

    # stockBounds_wcs is in NC units; the mesh is in frames.stlUnits.
    $stlUnits = if ($Meta.frames -and $Meta.frames.stlUnits) { [string]$Meta.frames.stlUnits } else { "mm" }
    $lo = $Meta.stockBounds_wcs.lower
    $hi = $Meta.stockBounds_wcs.upper
    $k = 1.0
    if ($lo.units -and ([string]$lo.units) -ne $stlUnits) {
        $k = if ($stlUnits -eq "mm") { 25.4 } else { 1.0 / 25.4 }
    }

    $tol = if ($stlUnits -eq "mm") { $StlBoundsToleranceMM } else { $StlBoundsToleranceMM / 25.4 }
    # Parenthesise every element: PowerShell's comma binds tighter than '*',
    # so an unparenthesised list would try to multiply an array.
    $want = @(([double]$lo.x * $k), ([double]$lo.y * $k), ([double]$lo.z * $k),
              ([double]$hi.x * $k), ([double]$hi.y * $k), ([double]$hi.z * $k))
    $got = $rep.bboxIn

    $worst = 0.0
    for ($i = 0; $i -lt 6; $i++) {
        $d = [Math]::Abs([double]$got[$i] - $want[$i])
        if ($d -gt $worst) { $worst = $d }
    }

    if ($worst -le $tol) {
        Write-Log "STL frame check OK (stock bounds match within $([Math]::Round($worst,4)) $stlUnits)" "DEBUG"
        return $true
    }

    Write-Log "STL FRAME MISMATCH: stock mesh bounds differ from stockBounds_wcs by $([Math]::Round($worst,4)) $stlUnits (tolerance $tol)" "WARNING"
    Write-Log "  mesh:     $($got -join ', ')" "WARNING"
    Write-Log "  expected: $($want -join ', ')" "WARNING"
    Write-Log "  Uploading anyway. If the offset is large the fixture may be placed in the wrong frame -" "WARNING"
    Write-Log "  check it in simulation, and see Fixture-STL-Handoff.md section 6." "WARNING"
    return $false
}

function Send-StlBundle {
    <#
    .SYNOPSIS
        Processes and uploads the STL meshes described by a post metadata
        sidecar. Called after the program itself has been sent, so the meshes
        always arrive after the program they belong to.

        STOCK/PART are decimated only. FIXTURE is additionally re-origined about
        the attach point (the control places it by putting the mesh origin on
        its own attach location) and shrunk for DCM clearance.
    #>
    param(
        [string]$MetaFile,
        [string]$RemotePath
    )

    $meta = Get-StlMeta -Path $MetaFile
    if (-not $meta) { return }

    $folder = [System.IO.Path]::GetDirectoryName($MetaFile)

    Write-Log ""
    Write-Log "STL bundle detected: $([System.IO.Path]::GetFileName($MetaFile))"
    if ($meta.program -and $meta.program.fileStem) { Write-Log "  program stem:  $($meta.program.fileStem)" }
    if ($meta.generated -and $meta.generated.post) { Write-Log "  post:          $($meta.generated.post)" }

    # Surface every warning the post raised - never swallow these.
    if ($meta.warnings) {
        foreach ($w in $meta.warnings) { Write-Log "  POST WARNING: $w" "WARNING" }
    }
    # Multiple work offsets are normal here - several presets on one plate or
    # pallet, one physical fixture - so this is informational only.
    if ($meta.wcs -and $meta.wcs.workOffsetsUsed -and @($meta.wcs.workOffsetsUsed).Count -gt 1) {
        Write-Log "  Work offsets: $(@($meta.wcs.workOffsetsUsed) -join ', ')" "DEBUG"
    }

    $stlUnits = if ($meta.frames -and $meta.frames.stlUnits) { [string]$meta.frames.stlUnits } else { "mm" }
    if ($meta.frames -and -not $meta.frames.camDocumentUnits) {
        Write-Log "  CAM document unit undetermined; STL unit fell back to the NC unit. Verify before relying on this." "WARNING"
    }

    # Which meshes actually exist? Only act on written:true.
    $exports = @()
    if ($meta.exports) { $exports = @($meta.exports | Where-Object { $_.written -eq $true }) }
    if ($exports.Count -eq 0) {
        Write-Log "  No meshes were written (CLI post or nothing to export) - nothing to upload."
        return
    }

    # Frame sanity: validate against the STOCK mesh before trusting the fixture.
    $fixtureOk = $true
    $stockRec = $exports | Where-Object { $_.role -eq "STOCK" } | Select-Object -First 1
    if ($stockRec) {
        $stockPath = Join-Path $folder $stockRec.file
        $fixtureOk = Test-StlFrameHypothesis -StockFile $stockPath -Meta $meta
    }

    $tempDir = Join-Path $env:TEMP ("TNCWatcher-stl\" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction SilentlyContinue | Out-Null

    try {
        # Fixture last: it is the one that can be skipped, and STOCK/PART are
        # cheap. Order among the meshes is not otherwise significant.
        $order = @("STOCK", "PART", "FIXTURE")
        foreach ($role in $order) {
            $rec = $exports | Where-Object { $_.role -eq $role } | Select-Object -First 1
            if (-not $rec) { continue }

            $src = Join-Path $folder $rec.file
            if (-not (Test-Path $src)) {
                Write-Log "  $role listed as written but missing on disk: $($rec.file)" "WARNING"
                continue
            }

            $prepArgs = @("--max-tris", "$StlMaxTriangles", "--stl-units", $stlUnits)
            if ($StlAsciiOutput) { $prepArgs += "--ascii" }

            if ($role -eq "FIXTURE") {
                $A = $meta.fixtureAttachPoint_inFixtureFrame_stlUnits
                if (-not $A -or $null -eq $A.x -or $null -eq $A.y -or $null -eq $A.z) {
                    # No attach point selected in the Setup. That is legitimate
                    # when the fixture's attach point already sits on the
                    # document origin, in which case no translation is needed
                    # and the origin is the right anchor. If it was simply
                    # forgotten, the WCS checks elsewhere catch it - so warn and
                    # ship rather than withhold a file the program needs to run.
                    $attachArg = "0,0,0"
                    Write-Log "  FIXTURE has no attach point in the metadata; assuming it already sits on the mesh origin." "WARNING"
                    Write-Log "  Verify the fixture position in simulation. Selecting an attach point in the Setup avoids this." "WARNING"
                } else {
                    $attachArg = ("{0},{1},{2}" -f [double]$A.x, [double]$A.y, [double]$A.z)
                    Write-Log "  FIXTURE attach point ($stlUnits): $attachArg -> re-origined to 0,0,0"
                }
                if (-not $fixtureOk) {
                    Write-Log "  FIXTURE frame is suspect (see mismatch above) - uploading anyway, check it in simulation." "WARNING"
                }
                $prepArgs += @("--attach", $attachArg, "--clearance", "$FixtureClearanceMM")
            }

            $prepped = Join-Path $tempDir $rec.file
            $rep = Invoke-StlPrep -InputFile $src -OutputFile $prepped -ExtraArgs $prepArgs
            if (-not $rep) { continue }

            foreach ($w in @($rep.warnings)) { if ($w) { Write-Log "  STL PREP: $w" "WARNING" } }
            Write-Log ("  {0}: {1} -> {2} triangles (deviation {3} {4}){5}" -f `
                $role, $rep.trianglesIn, $rep.trianglesOut, $rep.maxDeviation, $stlUnits,
                $(if ($rep.scaled) { ", shrunk ${FixtureClearanceMM}mm/face" } else { "" }))

            $result = Send-FileToMachine -SourceFile $prepped -DestinationPath $RemotePath
            if ($result.Success) { Write-Log "  $role uploaded: $($rec.file)" "SUCCESS" }
            else { Write-Log "  $role upload FAILED: $($rec.file)" "ERROR" }
        }
        # Retire the sidecar and the source meshes. Without this the fallback
        # rescan would find them again every few minutes and re-upload the whole
        # set forever.
        foreach ($rec in $exports) {
            $src = Join-Path $folder $rec.file
            if (Test-Path $src) { Move-ProcessedFile -FilePath $src -Success $true }
        }
        Move-ProcessedFile -FilePath $MetaFile -Success $true

        # Retire the post's leftover transient program copy one level up. The
        # bundle is done, so the authoritative copy has already been sent. If
        # this is left behind, the fallback rescan finds it later - after the
        # sidecar has been archived, so nothing identifies it as transient
        # any more - and uploads it to the wrong place on the control.
        if ($meta.program -and $meta.program.ncFile) {
            $parent = [System.IO.Path]::GetDirectoryName($folder.TrimEnd('\', '/'))
            $watchBase = $WatchFolder.TrimEnd('\', '/')
            if ($parent -and $parent.Length -ge $watchBase.Length) {
                $stray = Join-Path $parent ([string]$meta.program.ncFile)
                if (Test-Path $stray) {
                    Write-Log "Retiring the post's leftover transient copy: $([string]$meta.program.ncFile)" "WARNING"
                    Move-ProcessedFile -FilePath $stray -Success $true
                }
            }
        }
    }
    finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $folder "*.probe") -Force -ErrorAction SilentlyContinue
    }
}

function Test-NcAuthoritative {
    <#
    .SYNOPSIS
        True if this NC file is in its final resting place: a metadata sidecar
        naming it sits in the SAME folder. Such a file needs no settle wait.
    #>
    param([string]$FilePath)

    $dir  = [System.IO.Path]::GetDirectoryName($FilePath)
    $name = [System.IO.Path]::GetFileName($FilePath)

    foreach ($j in @(Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $m = Get-StlMeta -Path $j.FullName
        if ($m -and $m.program -and ([string]$m.program.ncFile -ieq $name)) { return $true }
    }
    return $false
}

function Test-TransientNcCopy {
    <#
    .SYNOPSIS
        True if this NC file is the post's transient pre-move copy: a SUBFOLDER
        of its own folder contains a metadata sidecar naming this NC file, which
        means the authoritative copy lives in that subfolder.
    #>
    param([string]$FilePath)

    $dir  = [System.IO.Path]::GetDirectoryName($FilePath)
    $name = [System.IO.Path]::GetFileName($FilePath)

    foreach ($sub in @(Get-ChildItem -Path $dir -Directory -ErrorAction SilentlyContinue)) {
        if ($sub.Name -ieq 'Processed' -or $sub.Name -ieq 'Failed') { continue }
        foreach ($j in @(Get-ChildItem -Path $sub.FullName -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            $m = Get-StlMeta -Path $j.FullName
            if ($m -and $m.program -and ([string]$m.program.ncFile -ieq $name)) { return $true }
        }
    }
    return $false
}

function Find-StlMetaFor {
    <#
    .SYNOPSIS
        Finds the STL metadata sidecar that belongs to a given NC file, in the
        same folder. Handles both post layouts: bare FIXTURE.json (per-program
        subfolder) and <stem>_FIXTURE.json (flat).
    #>
    param([string]$NcFilePath)

    $dir = [System.IO.Path]::GetDirectoryName($NcFilePath)
    $ncName = [System.IO.Path]::GetFileName($NcFilePath)

    foreach ($cand in @(Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $m = Get-StlMeta -Path $cand.FullName
        if (-not $m) { continue }
        if ($m.program -and $m.program.ncFile -and ([string]$m.program.ncFile -ieq $ncName)) { return $cand.FullName }
    }
    return $null
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

    # Silently ignore system/hidden junk (never log or transmit). This is a
    # safety net; the watchers already filter these out before logging. Matches
    # on the path relative to the watch folder so junk in subfolders is caught.
    $watchBaseIg = $WatchFolder.TrimEnd('\', '/')
    $relIg = if ($FilePath.Length -gt ($watchBaseIg.Length + 1)) { $FilePath.Substring($watchBaseIg.Length + 1) } else { $fileName }
    if ($relIg -match $global:IgnoreRegex) { return }

    # Also skip anything the OS has flagged Hidden or System (belt-and-suspenders)
    try {
        $item = Get-Item -LiteralPath $FilePath -Force -ErrorAction Stop
        if ($item.Attributes -band ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) { return }
    }
    catch {}

    # Verify file still exists
    if (-not (Test-Path $FilePath)) {
        Write-Log "File no longer exists, skipping: $fileName" "WARNING"
        return
    }
    
    # Meshes are never uploaded on their own - they go with their program via
    # Send-StlBundle. Returning before the readiness log keeps them out of the
    # log entirely; the prep tool re-checks completeness exactly when it reads
    # them (a binary STL's size must equal 84 + 50*triangleCount).
    if ($EnableStlTransfer -and ([System.IO.Path]::GetExtension($fileName) -ieq ".stl")) { return }

    # Wait for file to be fully written
    Write-Log "Waiting for file to be ready: $fileName"
    $ready = Wait-FileReady -FilePath $FilePath -TimeoutSeconds 30
    
    if (-not $ready) {
        Write-Log "File still locked after 30s, skipping: $fileName" "WARNING"
        return
    }
    
    # ---- STL bundle companions -------------------------------------------
    # .stl and the post's .json sidecar are never uploaded on their own. They
    # belong to a program and are handled by Send-StlBundle, which runs AFTER
    # that program transfers so the meshes always follow it.
    #
    # The post writes them in a different order depending on its layout:
    #   subfolder layout (default): STLs -> JSON -> NC file (NC last)
    #   flat layout:                NC file -> STLs -> JSON (JSON last)
    # so neither file is a universal "everything is here" signal. Both are used
    # as triggers instead: whichever of (program, sidecar) completes last kicks
    # off the upload, and the program is only sent once.
    $ext = [System.IO.Path]::GetExtension($fileName)

    if ($EnableStlTransfer -and $ext -ieq ".json") {
        $meta = Get-StlMeta -Path $FilePath
        if (-not $meta) { return }     # someone else's json - ignore, never upload

        # If the NC file is still sitting here, it has not transferred yet; the
        # program's own completion will trigger the bundle. Otherwise it already
        # went (flat layout), so send the meshes now.
        $ncName = if ($meta.program) { [string]$meta.program.ncFile } else { $null }
        $ncPath = if ($ncName) { Join-Path ([System.IO.Path]::GetDirectoryName($FilePath)) $ncName } else { $null }

        # In the subfolder layout the sidecar is written before the NC file is
        # moved in, so "not there yet" and "already transferred" look identical
        # at this instant. Give the move the same settle window before deciding,
        # otherwise the meshes could be sent ahead of their program.
        if ($ncPath -and -not (Test-Path $ncPath) -and $NcSettleDelaySeconds -gt 0) {
            Start-Sleep -Seconds $NcSettleDelaySeconds
        }

        if ($ncPath -and (Test-Path $ncPath)) {
            Write-Log "STL sidecar staged; waiting for its program to transfer first: $ncName" "DEBUG"
            return
        }

        $remote = Get-RemoteDestinationFor -FilePath $FilePath
        Send-StlBundle -MetaFile $FilePath -RemotePath $remote
        return
    }

    # ---- archive-only files ----------------------------------------------
    # Never transmitted, but kept: filed into Processed with the rest of the
    # program's files so a failed post is still there to look at.
    if ($ArchiveOnlyExtensions -contains $ext.ToLower()) {
        Write-Log "Archiving for review (not sent to the machine): $fileName"
        Move-ProcessedFile -FilePath $FilePath -Success $true
        return
    }

    # ---- NC program settle gate ------------------------------------------
    # Let the post finish relocating the program before touching it, then make
    # sure the copy in hand is the real one and not the pre-move transient.
    if ($NcSettleDelaySeconds -gt 0 -and ($NcSettleExtensions -contains $ext.ToLower())) {

        # A program sitting in its own program folder - sidecar right beside it -
        # is the authoritative copy. No need to wait for anything.
        if (-not (Test-NcAuthoritative -FilePath $FilePath)) {
            $deadline = (Get-Date).AddSeconds($NcSettleDelaySeconds)
            $settled = $false
            while ((Get-Date) -lt $deadline) {
                if (-not (Test-Path $FilePath)) {
                    Write-Log "Program was relocated by the post; skipping that copy: $fileName" "DEBUG"
                    return
                }
                if ($StlUseSubfolderSidecarCheck -and (Test-TransientNcCopy -FilePath $FilePath)) {
                    Write-Log "Skipping transient copy of $fileName - the authoritative copy is in its program subfolder." "DEBUG"
                    return
                }
                if (Test-NcAuthoritative -FilePath $FilePath) { $settled = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $settled -and -not (Test-Path $FilePath)) { return }
        }
    }

    # Check if this is a tool table needing special routing: either the filename
    # matches $ToolTableFiles, or it was dropped in the tool table folder (but
    # not in that folder's Backups subfolder).
    $ttFolder    = $ToolTableFolder.TrimEnd('\', '/')
    $ttBackup    = $ToolTableBackupFolder.TrimEnd('\', '/')
    $lowerPath   = $FilePath.ToLower()
    $inToolTableFolder = $lowerPath.StartsWith(($ttFolder + '\').ToLower()) -and
                         -not $lowerPath.StartsWith(($ttBackup + '\').ToLower())
    $isToolTableByName = @($ToolTableFiles | Where-Object { $_ -ieq $fileName }).Count -gt 0

    if ($inToolTableFolder -or $isToolTableByName) {
        Write-Log "Tool table file detected: $fileName -> $ToolTableDestination (mode: $ToolTableTransferMode)"
        $result = Send-ToolTableFile -SourceFile $FilePath -DestinationPath $ToolTableDestination
        Move-ProcessedFile -FilePath $FilePath -Success $result.Success
        return
    }

    # Compute destination path, preserving subfolder structure
    $destPath = Get-RemoteDestinationFor -FilePath $FilePath -CreateRemote $true

    # Transfer the file
    $result = Send-FileToMachine -SourceFile $FilePath -DestinationPath $destPath

    # A program with an STL sidecar beside it: now that the program itself has
    # landed, send its meshes so they arrive after it.
    if ($EnableStlTransfer -and $result.Success) {
        $meta = Find-StlMetaFor -NcFilePath $FilePath
        if ($meta) { Send-StlBundle -MetaFile $meta -RemotePath $destPath }
    }

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

    # Create the tool table folder and its Backups subfolder. Files dropped in
    # the tool table folder are sent as tool tables; the Backups subfolder holds
    # timestamped downloads of the remote table and is excluded from watching.
    foreach ($folder in @($ToolTableFolder, $ToolTableBackupFolder)) {
        if (-not (Test-Path $folder)) {
            try {
                New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Log "Created tool table folder: $folder" "DEBUG"
            }
            catch {
                Write-Log "Could not create tool table folder '$folder': $_" "WARNING"
            }
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
    
    # Exclude Processed/Failed, the tool-table Backups folder, and system/hidden junk
    $existingFiles = Get-ChildItem @gciParams | Where-Object {
        $rel = $_.FullName.Substring($WatchFolder.TrimEnd('\', '/').Length + 1)
        ($rel -notmatch $global:WatchExcludeRegex) -and ($rel -notmatch $global:IgnoreRegex)
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
                # Skip Processed/Failed, tool-table Backups, and system/hidden junk
                if ($result.Name -match $global:WatchExcludeRegex -or $result.Name -match $global:IgnoreRegex) { continue }
                
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
    # Skips Processed/Failed, the tool-table Backups folder, and system/hidden
    # junk (so junk never even reaches the log).
    $action = {
        $name = $Event.SourceEventArgs.Name
        if ($name -notmatch $global:WatchExcludeRegex -and $name -notmatch $global:IgnoreRegex) {
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
                        ($rel -notmatch $global:WatchExcludeRegex) -and
                        ($rel -notmatch $global:IgnoreRegex) -and
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
    Write-Log "Heidenhain TNCcmd Folder Watcher v1.8.0"
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
    Write-Log "Tool Tables:     [$($ToolTableFiles -join ', ')] + folder '$ToolTableFolder' -> $ToolTableDestination (mode: $ToolTableTransferMode)"
    Write-Log "Tool Backups:    $ToolTableBackupCount kept in '$ToolTableBackupFolder'"
    Write-Log "Ignore Junk:     $(if ($IgnoreSystemFiles) { 'on (system/hidden files silently skipped)' } else { 'off' })"
    Write-Log "STL Transfer:    $(if ($EnableStlTransfer) { "on (max $StlMaxTriangles tris, fixture shrink ${FixtureClearanceMM}mm/face, $(if ($StlAsciiOutput) {'ASCII'} else {'binary'}))" } else { 'off' })"
    Write-Log "NC Settle:       ${NcSettleDelaySeconds}s, subfolder-sidecar check $(if ($StlUseSubfolderSidecarCheck) { 'on' } else { 'off' })"
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
