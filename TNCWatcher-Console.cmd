@echo off
REM Opens a live, read-only view of the TNCWatcher service log.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TNCWatcher-Console.ps1"
pause
