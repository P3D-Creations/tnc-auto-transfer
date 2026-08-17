@echo off
REM Compiles TNCWatcher-StlPrep.cs into TNCWatcher-StlPrep.exe in the project root.
REM Uses the C# compiler that ships with Windows (.NET Framework) - no SDK needed.
set CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /optimize+ /target:exe /out:"%~dp0..\TNCWatcher-StlPrep.exe" "%~dp0TNCWatcher-StlPrep.cs"
if %errorlevel% equ 0 (
    echo Built: %~dp0..\TNCWatcher-StlPrep.exe
) else (
    echo BUILD FAILED
)
pause
