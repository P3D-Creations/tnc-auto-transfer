# Heidenhain TNCcmd Automatic File Transfer

> **Version:** 1.6.0 | **Date:** 2026-07-02 | **Author:** [Xander Luciano](https://notes.xanderluciano.com/heidenhain-tnccmd-auto-transfer)

Scripts for automatically sending files to Heidenhain CNC controllers over the network.

Drop an NC program into a watched folder and it is uploaded to the machine automatically. Version 1.6.0 adds unattended **Windows service** operation, a **system-tray monitor** with desktop notifications, and a set of reliability fixes so it can run 24/7 on a shop-floor PC.

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.6.0 | 2026-07-02 | Runs as a **Windows service** at boot (no login required); **system-tray monitor** with desktop toast notifications, settings GUI, live-log viewer, and "last sent file" status; fixed a transfer **hang** when the machine was unreachable (async I/O with a hard timeout); watcher **auto-recovery** from NAS/network drops plus a fallback rescan and heartbeat; distinct handling for **machine-unreachable vs. file-locked** retries; **DPAPI-encrypted NAS authentication** so the service can run as LocalSystem and still reach a network share; **JSON config overrides** editable from the tray; 3-hour service auto-restart safety net; log rotation |
| 1.5.0 | 2026-03-23 | Tool-table routing to `TNC:\table\` with Merge or Overwrite modes and automatic timestamped backups |
| 1.2.0 | 2026-03-21 | Added support for subdirectories, UNC paths, and overwriting existing programs on the machine |
| 1.1.0 | 2026-03-16 | Added dual watcher modes (Synchronous/Asynchronous), fixed event handling reliability, improved code structure |
| 1.0.0 | 2026-03-12 | Initial release with folder watcher and batch file scripts |

> **Upgrading from 1.1.0?** The folder watcher still runs standalone exactly as before — just double-click or run the `.ps1`. Everything in 1.6.0 (service, tray, notifications) is optional and layered on top. See [Running as a Windows Service](#running-as-a-windows-service-recommended-for-24-7) and [System Tray Monitor](#system-tray-monitor).

---

## What is TNCcmd?

**TNCcmd** is a command-line tool included with Heidenhain's free **TNCremo** software package. It allows automated file transfers between a PC and Heidenhain CNC controllers over the network.

### Supported Controllers
- TNC 320, TNC 620, TNC 640
- iTNC 530
- TNC 426, TNC 430
- Other Heidenhain controls with network capability

### Protocol
- **LSV2** (over TCP/IP, default port 19000)
- Binary and ASCII transfer modes supported

---

## Prerequisites

### 1. Install TNCremo (Free)

Download from Heidenhain:
- **Official download**: https://www.heidenhain.com/products/cnc-controls/software/tncremo
- Create a free account if required
- During installation, TNCcmd.exe is included automatically
- Default install location: `C:\Program Files (x86)\HEIDENHAIN\TNCremo\`

### 2. Network Connectivity

- CNC machine must be on the same network as your PC
- Machine needs a configured IP address
- Firewall must allow TCP port 19000 (LSV2 protocol)

### 3. CNC Controller Requirements

- Controller must have network option enabled
- DNC (Remote Data Transfer) must be activated
- Check with your machine manufacturer if unsure

---

## Quick Start

1. Download both scripts below
2. Edit the configuration variables at the top (machine IP, folders)
3. Create a `WatchFolder` subfolder next to the script
4. Run the PowerShell script — it watches for new files and auto-uploads them

---

## Script 1: PowerShell Folder Watcher (Recommended)

**Best for**: Continuous automated monitoring

### Features

- **Two watcher modes** — choose the best approach for your environment:
  - **Asynchronous (default)**: Non-blocking, handles rapid file creation, uses event queue
  - **Synchronous**: Simple and reliable, blocks during file transfer
- Watches a folder in real-time for new files
- Automatically transfers files as soon as they appear
- **Subdirectory mirroring** — watch subfolders and recreate the same folder tree on the controller (creates remote directories as needed)
- **UNC / network-share watch folders** (e.g. a NAS path) supported
- **Overwrite existing programs** on the control (`$DeleteBeforeTransfer`)
- **Tool-table routing** — files such as `tool.t` are sent to `TNC:\table\` with Merge or Overwrite handling and an automatic timestamped backup of the current table first
- **Retry logic** — if the file is locked on the controller, retries up to 150 times (30s intervals)
- **Machine-unreachable handling** — if the machine is off/unreachable, the file stays queued and transfers automatically once it returns (instead of failing), with a hard per-operation timeout so the script can never hang
- Handles file locking (waits for files to finish copying)
- Optional: Delete source files or move to "Processed" folder
- Failed transfers moved to "Failed" folder after max retries
- Handles duplicate filenames (adds timestamp)
- Detailed logging with automatic rotation at 10 MB
- Processes existing files on startup

### New in 1.6.0 — Unattended operation

- **Runs as a Windows service** at boot, before any user logs in — see [Running as a Windows Service](#running-as-a-windows-service-recommended-for-24-7)
- **System-tray monitor** with desktop toast notifications (transfer complete / machine unreachable / file locked), a settings GUI, a live-log viewer, and a "last sent file" readout — see [System Tray Monitor](#system-tray-monitor)
- **Authenticated NAS access** via a Windows DPAPI-encrypted credential, so the service can reach a login-protected network share while running as LocalSystem — see [NAS / Network-Share Authentication](#nas--network-share-authentication)
- **Self-healing** — recreates the folder watcher if the NAS connection drops, rescans every 5 minutes as a safety net, logs a periodic heartbeat, and is auto-restarted every 3 hours as a belt-and-suspenders guard against hangs

### Watcher Mode Selection

At the top of the script, set the `$WatcherMode` variable:

```powershell
$WatcherMode = "Asynchronous"  # Options: "Synchronous" or "Asynchronous"
```

| Mode | Pros | Cons | Best For |
|------|------|------|----------|
| **Asynchronous** | Non-blocking, handles rapid file drops, won't miss files during transfers | Slightly more complex | Production environments, frequent file drops |
| **Synchronous** | Simple, reliable, no scope issues | Blocks during transfer (can't detect new files while transferring) | Infrequent file drops, simple setups |

### Configuration

Edit these variables at the top of the script:

```powershell
$WatcherMode = "Asynchronous"          # "Synchronous" or "Asynchronous"
$MachineIP = "192.168.1.100"           # Your machine's IP address
$WatchFolder = ".\WatchFolder"         # Folder to watch (relative, absolute, or a UNC \\NAS\share path)
$DestinationFolder = "TNC:\"           # Destination on CNC machine. Watched subdirectories are mirrored here.
$FileFilter = "*.*"                    # File types to watch
$IncludeSubdirectories = $true         # Watch subfolders and mirror their structure on the controller
$DeleteBeforeTransfer = $true          # DEL existing file on the control before PUT (clean overwrite)
$MoveToProcessedFolder = $true         # Move files after successful transfer
$MoveToFailedFolder = $true            # Move files to Failed after max retries

# Timeouts
$ConnectionTimeout = 30                # Seconds for quick ops (DEL, MKDIR, connection test)
$TransferTimeoutSeconds = 600          # Seconds for a PUT/GET before TNCcmd is killed and retried

# Retry settings (locked files on controller, or machine temporarily unreachable)
$MaxRetries = 150                      # Maximum retry attempts
$RetryDelaySeconds = 30                # Seconds between retries

# Tool-table routing (optional)
$ToolTableFiles = @("tool.t")          # Filenames routed to TNC:\table\ with backup + merge/overwrite
$ToolTableTransferMode = "Merge"       # "Merge" (needs TNCcmdPlus + Option 18) or "Overwrite"

# NAS credential (optional) — see "NAS / Network-Share Authentication"
$NASCredentialFile = ".\service\nas-credential.bin"
```

> **Tip:** When running as a service, you don't have to edit the script for the common settings — machine IP, folders, filter, retries, and timeouts can be changed from the tray **Settings** dialog, which writes a `TNCWatcher-Config.json` file that overrides the values above.

### Folder Structure

```
WatchFolder/
├── (incoming files)      # Drop files here
├── Processed/            # Successful transfers go here
└── Failed/               # Failed after max retries
```

### Usage

```powershell
# Option 1: Right-click > Run with PowerShell

# Option 2: From PowerShell command line
.\TNCcmd-FolderWatcher.ps1

# Option 3: If execution policy blocks it
powershell -ExecutionPolicy Bypass -File "C:\path\to\TNCcmd-FolderWatcher.ps1"
```

### The Script: TNCcmd-FolderWatcher.ps1

The full script is [`TNCcmd-FolderWatcher.ps1`](TNCcmd-FolderWatcher.ps1) in this repository — open it directly to read or edit. All settings are in the `CONFIGURATION` block at the top; see the [Configuration](#configuration) reference above for the commonly-changed values.

---

## Script 2: Simple Batch File Alternative

**Best for**: Manual transfers or scheduled tasks (runs once and exits)

### The Script: TNCcmd-SendFile.bat

See [`TNCcmd-SendFile.bat`](TNCcmd-SendFile.bat) in this repository. Edit the `CONFIGURATION` block at the top (machine IP, source folder, destination), then double-click to run or schedule it with Task Scheduler.

---

## TNCcmd Command Reference

### Basic Commands

```bash
# Connect to machine
TNCcmd.exe CONNECT -I 192.168.1.100

# Upload file to machine
TNCcmd.exe PUT "C:\file.h" "TNC:\file.h" -I 192.168.1.100

# Upload with binary mode (recommended)
TNCcmd.exe PUT "C:\file.h" "TNC:\file.h" /b -I 192.168.1.100

# Download file from machine
TNCcmd.exe GET "TNC:\file.h" "C:\file.h" -I 192.168.1.100

# Create directory on machine
TNCcmd.exe MKDIR "TNC:\MyFolder" -I 192.168.1.100

# List files on machine
TNCcmd.exe DIR "TNC:\*.*" -I 192.168.1.100
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `-I <IP>` | Machine IP address |
| `-P <port>` | Port number (default 19000) |
| `/b` | Binary transfer mode (recommended) |
| `/c` | Convert NC programs (.H, .I) during transfer |
| `-C <name>` | Connection name from TNCremo |

### Machine Paths

The CNC machine uses paths starting with `TNC:\`:
- `TNC:\` - Root directory
- `TNC:\nc_prog\` - Common program folder
- `TNC:\table\` - Tables folder
- `TNC:\Programs\` - Another common location

**Note**: Path structure varies by controller model and configuration.

---

## Common File Types

| Extension | Description |
|-----------|-------------|
| `.H` | Heidenhain conversational NC program |
| `.I` | ISO/DIN NC program |
| `.T` | Tool table |
| `.D` | Datum/fixture table |
| `.TCH` | TNCguide technology data |

---

## Troubleshooting

### "TNCcmd.exe not found"
- Install TNCremo from the Heidenhain website
- Check the installation path in the script configuration

### "Connection timeout" or "Cannot connect"
1. Verify machine IP address is correct
2. Ping the machine: `ping 192.168.1.100`
3. Check firewall allows port 19000
4. Verify machine's network settings
5. Ensure DNC option is enabled on controller

### "Access denied" or "File locked" errors
- The PowerShell script will automatically retry for up to 75 minutes (150 attempts × 30 seconds)
- Machine may require DNC to be enabled manually
- Check machine's security/access settings
- Some operations require the machine to be in specific mode

### Files not transferring
- Check file extensions match the filter
- Verify source files aren't locked by another program
- Check the log file for error details

### PowerShell script won't run
```powershell
# Allow script execution (run as Administrator)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Or run with bypass
powershell -ExecutionPolicy Bypass -File ".\TNCcmd-FolderWatcher.ps1"
```

### File watcher doesn't detect pasted files (v1.0.0 issue)
**Fixed in v1.1.0** — The original async event handler had scope issues that could cause it to miss events. Solutions:
1. **Upgrade to v1.1.0** (recommended)
2. Set `$WatcherMode = "Synchronous"` for simpler event handling
3. Use the new async queue mode (default in v1.1.0) which properly decouples detection from processing

### Tray toast notifications don't appear
- These are self-drawn windows, so they work even when Windows notifications are turned off. Confirm the tray app is running (status dot in the notification area) and preview with `TNCWatcher-Tray.exe --toasttest`.
- Toasts appear on the **primary** monitor, bottom-right. On a multi-monitor setup, check the monitor that has the clock/notification area.

### Service (TNCWatcher) won't start
- **Watch folder is on a NAS:** the service can't reach the share. Store a NAS credential with `service/Set-NASCredential.cmd`, or run the service as your own user with `service/Set-TNCWatcherAccount.cmd`.
- **Used the "run as my user" option and later changed your Windows password:** re-run `service/Set-TNCWatcherAccount.cmd` with the new password. (Not needed if you used the DPAPI NAS-credential method — that's unaffected by Windows password changes.)
- Check the log via `TNCWatcher-Console.cmd`, or `service/service-console.log` for fatal startup errors.

### A file is stuck "Waiting to retry"
- If the toast/log says **locked on controller**, the program is open or the machine is in **Running** mode — set it to **Manual** or close the program on the control to free it. The file transfers automatically once it's free.
- If it says **machine unreachable**, the control is off or off the network; the file will send itself when the machine returns. No action needed.

---

## Running as a Windows Service (Recommended for 24-7)

For unattended shop-floor use, install the watcher as a Windows **service** so it starts at boot, runs with no user logged in, and stays available to everyone as long as the PC is on. All of the setup is scripted in the [`service/`](service/) folder — you don't need to run NSSM by hand.

### Install

1. Double-click **`service/Install-TNCWatcher-Service.cmd`** (it self-elevates via UAC).
2. That's it. The installer:
   - Registers a service named **TNCWatcher** using a bundled copy of [NSSM](https://nssm.cc/).
   - Sets it to **start at boot** (delayed, so the network/NAS is up first) and to **auto-restart** if the script ever crashes.
   - Creates a scheduled task **`TNCWatcher-3h-Restart`** that restarts the service every 3 hours as a safety net against hangs.
   - Starts the service and prints the last lines of the log so you can confirm it connected.

Restarts are safe: any file that hasn't transferred yet stays in the watch folder and is picked up again on startup.

### If the watch folder is on a NAS

A service running as **LocalSystem** authenticates to the network as the *computer* account, which many NAS boxes reject. Two options:

- **Recommended:** leave the service as LocalSystem and store a NAS login for it — run **`service/Set-NASCredential.cmd`** (see [NAS / Network-Share Authentication](#nas--network-share-authentication)). This is unaffected by Windows password changes.
- **Alternative:** run the service as your own Windows user — run **`service/Set-TNCWatcherAccount.cmd`**. You must re-run it whenever your Windows password changes, or the service will fail to start.

### Management scripts (in `service/`)

| Script | Purpose |
|--------|---------|
| `Install-TNCWatcher-Service.cmd` | Install (or reinstall) the service + 3-hour restart task |
| `Uninstall-TNCWatcher-Service.cmd` | Remove the service and the restart task |
| `Set-NASCredential.cmd` | Store/replace the DPAPI-encrypted NAS credential and restart the service |
| `Set-TNCWatcherAccount.cmd` | Run the service as a specific Windows user instead of LocalSystem |
| `Build-TrayApp.cmd` | Recompile the tray monitor EXE from source |

All of these self-elevate (UAC) and are safe to re-run.

---

## System Tray Monitor

**`TNCWatcher-Tray.exe`** is a lightweight system-tray app so you can see what the service is doing without opening a terminal. It auto-registers to start at login for the current user (toggle via its menu) and is a single self-contained EXE — no runtime to install.

- **Status dot** — the tray icon shows service state at a glance: **green** = running, **orange** = starting/paused, **red** = stopped or not installed. Hover for the latest log line.
- **Desktop toast notifications** pop up in the bottom-right corner on:
  - **Transfer complete** — names the file that was sent.
  - **Machine unreachable** — once per file; the file will send itself automatically when the machine comes back online.
  - **Waiting to retry** — the file is *locked* on a reachable control (e.g. the NC program is still in **Running** mode); a reminder repeats every few minutes until it clears.

  > These are self-drawn windows, **not** Windows notifications, so they appear even if Settings → System → Notifications is turned off. Preview them any time with `TNCWatcher-Tray.exe --toasttest`.
- **Settings dialog** (left-click the icon, or right-click → *Settings…*) — edit the watch folder (with a Browse button), machine IP, destination, file filter, retry counts, timeouts, and the NAS credential. *Save & Restart Service* applies everything with a single UAC prompt. Settings are written to `TNCWatcher-Config.json`, which overrides the values in the script.
- **Last sent file** — the right-click menu shows the most recently transferred file and its timestamp.
- **Quick actions** — open the live log window, open the watch folder, restart the service, or toggle start-with-Windows.

To (re)build the EXE from source after editing `service/TNCWatcher-Tray.cs`, run **`service/Build-TrayApp.cmd`** (uses the C# compiler that ships with Windows — no SDK required).

---

## Live Log Console

Double-click **`TNCWatcher-Console.cmd`** to open a colorized, read-only, live-tailing view of the log (`TNCcmd-Watcher.log`) — handy for watching a transfer or seeing why a file is waiting. Open as many as you like on any account; closing the window never affects the service.

> Don't tail the log with a Unix `tail -f` (e.g. from Git Bash) — it can lock the file and cause the watcher's log writes to be silently dropped. The console viewer and tray app open the log in shared mode and are safe. NSSM also mirrors all output to `service/service-console.log` as a fallback.

---

## NAS / Network-Share Authentication

If the watch folder lives on a login-protected network share, store the share's credential once so the service can authenticate itself:

1. Run **`service/Set-NASCredential.cmd`** (self-elevates).
2. Enter the **NAS account** username/password — the account defined *on the NAS* that can access the share (not necessarily your Windows login).

The credential is encrypted with Windows **DPAPI**, bound to this machine, and saved to `service/nas-credential.bin` with an ACL that only SYSTEM and Administrators can read. At startup the watcher decrypts it and authenticates to the share, so the service can run as LocalSystem and still reach the NAS. Re-run the script only if the **NAS** account's password changes — your Windows password is never involved.

---

## Using Task Scheduler

A lighter-weight alternative to the [Windows service](#running-as-a-windows-service-recommended-for-24-7) if you'd rather not install one. Note this runs only when a user is logged in and does not include the auto-restart/self-healing behavior of the service.

1. Open Task Scheduler
2. Create Basic Task
3. Set trigger (e.g., "At startup" for continuous monitoring)
4. Action: Start a program
5. Program: `powershell.exe`
6. Arguments: `-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\TNCcmd-FolderWatcher.ps1"`

---

## Resources

- **TNCremo Download**: https://www.heidenhain.com/products/cnc-controls/software/tncremo
- **Heidenhain Support**: https://www.heidenhain.com/service-support
- **LSV2 Protocol Info**: Included in TNCremo documentation
