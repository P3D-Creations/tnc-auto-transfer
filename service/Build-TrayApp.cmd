@echo off
REM Compiles TNCWatcher-Tray.cs into TNCWatcher-Tray.exe in the project root.
REM Uses the C# compiler that ships with Windows (.NET Framework) - no SDK needed.
set CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /out:"%~dp0..\TNCWatcher-Tray.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.ServiceProcess.dll /r:System.Security.dll /r:System.Web.Extensions.dll "%~dp0TNCWatcher-Tray.cs"
if %errorlevel% equ 0 (
    echo Built: %~dp0..\TNCWatcher-Tray.exe
) else (
    echo BUILD FAILED
)
pause
