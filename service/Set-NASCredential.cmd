@echo off
REM Stores the NAS credential for the TNCWatcher service (DPAPI-encrypted). Self-elevates if needed.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-NASCredential.ps1"
