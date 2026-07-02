@echo off
REM Installs the TNCWatcher Windows service. Self-elevates if needed.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TNCWatcher-Service.ps1"
echo.
pause
