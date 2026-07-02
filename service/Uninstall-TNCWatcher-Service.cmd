@echo off
REM Removes the TNCWatcher Windows service and its 3-hour restart task. Self-elevates if needed.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo Stopping and removing the TNCWatcher service...
"%~dp0nssm.exe" stop TNCWatcher
"%~dp0nssm.exe" remove TNCWatcher confirm
echo Removing the scheduled restart task...
schtasks /Delete /F /TN "TNCWatcher-3h-Restart"
echo Done.
pause
