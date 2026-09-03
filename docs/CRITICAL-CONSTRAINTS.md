# Critical constraints (hard-won, do not relearn)

Things that broke in production or cost hours to diagnose. Read before touching
the watcher, the STL pipeline, or the build.

## PowerShell 5.1 landmines

- **`TNCcmd-FolderWatcher.ps1` must stay UTF-8 *with BOM* + CRLF.** Without the
  BOM, PS 5.1 reads the file as cp1252: the em-dash becomes `â€”` where the `”`
  character *terminates strings* and the script explodes far from the real
  cause. Python rewrites have destroyed the BOM twice. If patching with Python:
  read `utf-8-sig` with `newline=''`, normalize to `\n`, patch, re-expand to
  `\r\n`, write with `﻿` prepended.
- **Native-exe argument quoting is mangled** by PS 5.1 (`Start-Process`, NSSM
  `AppParameters`, `schtasks /TR`). Fixes used: write NSSM parameters straight
  into the registry; create scheduled tasks via `schtasks /XML` (the XML must
  be UTF-16; UTF-8 gives "unable to switch the encoding").
- **`$args` is an automatic variable** — never use it as your own.
- **`,` binds tighter than `*`**: `@($x * $k, ...)` multiplies an array.
  Parenthesize arithmetic inside array literals.
- `[TimeSpan]::MaxValue` in a scheduled-task Duration is rejected ("out of
  range").
- Scheduled tasks created for SYSTEM can be invisible to non-admin PowerShell;
  check `HKLM:\...\Schedule\TaskCache\Tree\<name>`.

## Config precedence trap

`TNCWatcher-Config.json` (written by the tray Save button, gitignored)
**overrides the script defaults silently**. A stale value there wins over any
edit to the `.ps1`. This bit production AND every test harness (`$ScriptDir`
is the cwd when dot-sourced). Harnesses must redirect the config filename
(they use `TNCWatcher-Config.HARNESS-IGNORED.json`). When adding a config
variable: script default + JSON override line + tray field (if user-facing) +
remember the runtime json may need updating on deploy.

## Logs

- **Never MSYS `tail -f` the watcher log** — it locks the file and
  `Add-Content` in the service fails silently. Use shared-read viewers
  (console viewer / tray do this correctly). NSSM's console log is the
  fallback source of truth.
- Windows toast notifications are disabled machine-wide here
  (`ToastEnabled=0`); the tray draws its own `ToastForm`
  (WS_EX_NOACTIVATE, bottom-right of the primary monitor).

## TNCcmd / TNC 640

- **E20001714 on PUT** = the file has long runs of bytes without a line break.
  TNCcmd's `/b` mode is still record-oriented. This is why **STL output is
  ASCII** (`--ascii`, `$StlAsciiOutput = $true`). Root-caused by on-machine
  bisection: 620B binary ok, 1.5MB of 'A's without newlines fails, same data
  with newlines ok.
- `TNC:\table\` paths: single backslash. A doubled `\\` broke tool-table GET.
- Retryable vs connection errors are classified in `Test-RetryableError` /
  `Test-ConnectionError` (E20001508 etc.).
- The control **requires closed (watertight) meshes** for simulation import.
  Non-manifold seams (shells touching along an edge) have been accepted;
  boundary/hole edges are the real problem.

## NAS auth under LocalSystem

- Credential stored DPAPI-LocalMachine in `service\nas-credential.bin`
  (SYSTEM+Admins ACL). Set with `Set-NASCredential`.
- Map the share with `net.exe use` — `New-SmbMapping` fails under LocalSystem
  ("logon session does not exist").
- `New-Item -Force` can "succeed" while `Test-Path` stays false on a flaky
  mapping: always verify-after-create or you get a spam loop.

## Build

- In-box compiler only: `%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`
  — **C# 5 syntax** (no interpolation, no inline `out var`, no null-coalescing
  assignment).
- From MSYS bash use `MSYS2_ARG_CONV_EXCL='*'` and Windows paths.
- From PS 5.1, pass `/out:` via a variable: `"/out:$exe"` (inline
  subexpressions split the arg).
- Tray references: System.Windows.Forms, System.Drawing, System.ServiceProcess,
  System.Security, System.Web.Extensions.
- The service and any running test hold a lock on their EXE — build to a
  scratch name if something is still running.

## Git

- Push to **origin** (the user's fork) only, never upstream.
