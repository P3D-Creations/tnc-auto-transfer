# Watcher behavior notes (TNCcmd-FolderWatcher.ps1)

## Transient program copies (the settle gate)

Fusion's post writes the program at the WATCH ROOT first and moves it into the
program subfolder in `onTerminate`. The root copy is transient and sometimes
partial — it must never reach the control.

Defense layers:

1. **Size stability**: `$NcStableSeconds` (8) of unchanged size before any NC
   file is processed; a growing file resets the clock.
2. **Sidecar grace**: `$NcSettleDelaySeconds` (15) after stability, extended
   while a subfolder named like the program stem exists (cap 12s extra), so
   the sidecar structure has time to appear.
3. **Structural checks**: `Test-TransientNcCopy` / `Test-NcAuthoritative` —
   a root-level program whose stem-named subfolder holds the authoritative
   copy is skipped (and later retired).
4. **Post-bundle cleanup**: after a successful bundle, the leftover root copy
   is retired to Processed AND `Remove-RemoteFile` deletes any stray copy on
   the control (`$CleanupRemoteStray`). Without this the 5-minute rescan
   re-found the stray after the sidecar was archived and re-uploaded it to the
   wrong place.

## Bundle layouts (sidecar `p3d.kern.fixture-stl-meta` v1)

- Layout A (subfolder): STLs → JSON → NC last.
- Layout B: NC → STLs → JSON last.
- The JSON sidecar (`FIXTURE.json`) arriving marks the bundle; STLs are sent
  AFTER the program, order STOCK/PART/FIXTURE. Missing meshes warn, never
  block (a program without its STLs won't run on the control, so withholding
  is worse than shipping).

## Toast rules

- Machine unreachable: one toast per newly detected file, no repeats.
- File locked but machine reachable: repeat every ~4 minutes.

## Junk and archive files

- `$IgnoreFilePatterns` (`.DS_Store@SynoResource` etc.): fully ignored — no
  transfer, no log, no toast.
- `$ArchiveOnlyExtensions` (`.failed`, `.log`): moved to Processed for review,
  never sent.

## Tool tables

- `ToolTables\` inside the watch folder is excluded from normal watching;
  holds `Backups\`. Merge-mode send via tray controls; remote backup is taken
  before merge.

## Service

- NSSM wrapper, LocalSystem, delayed auto-start, AppExit restart, 3h restart
  task (`TNCWatcher-3h-Restart.xml`, must stay UTF-16).
- Config changes require a service restart (config is read at startup; the
  startup banner logs every effective setting — verify there).
- `Invoke-TNCcmd` and `Invoke-StlPrep` are async with kill timeouts —
  `ReadToEnd()` before `WaitForExit()` deadlocks (this was the original hang,
  and was reintroduced once in StlPrep before getting the same fix).
