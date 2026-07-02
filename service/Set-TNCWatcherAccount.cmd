@echo off
REM Changes the account the TNCWatcher service runs as. Self-elevates if needed.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-TNCWatcherAccount.ps1"
