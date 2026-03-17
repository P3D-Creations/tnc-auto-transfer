@echo off
REM ============================================================================
REM  TNCcmd Simple File Transfer
REM  Version: 1.0.0
REM  Date:    2026-03-12
REM  Author:  Xander Luciano
REM ============================================================================
REM Heidenhain TNCcmd - Simple File Transfer Batch Script
REM ============================================================================
REM This is a simpler alternative to the PowerShell watcher.
REM It sends all files from a folder to the CNC machine when run.
REM 
REM Usage: 
REM   - Edit the settings below
REM   - Double-click to run, or schedule with Windows Task Scheduler
REM   - For continuous monitoring, use the PowerShell script instead
REM ============================================================================

REM ====================== CONFIGURATION ======================================

REM Machine IP address
set MACHINE_IP=192.168.1.100

REM Source folder (folder containing files to send)
REM Use %~dp0 for the same folder as this batch file
set SOURCE_FOLDER=%~dp0WatchFolder

REM Destination folder on the CNC machine
set DEST_FOLDER=TNC:\

REM File pattern to send (*.h for NC programs, *.* for all)
set FILE_PATTERN=*.*

REM TNCcmd.exe location
set TNCCMD="C:\Program Files (x86)\HEIDENHAIN\TNCremo\TNCcmd.exe"

REM Transfer mode: /b for binary (recommended), /c for convert NC programs
set TRANSFER_MODE=/b

REM Delete files after successful transfer? (YES or NO)
set DELETE_AFTER=NO

REM ====================== END CONFIGURATION ==================================

echo.
echo ============================================
echo  Heidenhain TNCcmd File Transfer
echo ============================================
echo  Machine: %MACHINE_IP%
echo  Source:  %SOURCE_FOLDER%
echo  Dest:    %DEST_FOLDER%
echo ============================================
echo.

REM Check if TNCcmd exists
if not exist %TNCCMD% (
    echo ERROR: TNCcmd.exe not found at %TNCCMD%
    echo Please install TNCremo from Heidenhain website.
    echo.
    pause
    exit /b 1
)

REM Check if source folder exists
if not exist "%SOURCE_FOLDER%" (
    echo Creating source folder: %SOURCE_FOLDER%
    mkdir "%SOURCE_FOLDER%"
)

REM Create processed folder
if not exist "%SOURCE_FOLDER%\Processed" (
    mkdir "%SOURCE_FOLDER%\Processed"
)

REM Count files
set FILE_COUNT=0
for %%f in ("%SOURCE_FOLDER%\%FILE_PATTERN%") do (
    if exist "%%f" set /a FILE_COUNT+=1
)

if %FILE_COUNT%==0 (
    echo No files found in %SOURCE_FOLDER%
    echo.
    pause
    exit /b 0
)

echo Found %FILE_COUNT% file(s) to transfer...
echo.

REM Process each file
for %%f in ("%SOURCE_FOLDER%\%FILE_PATTERN%") do (
    if exist "%%f" (
        echo Transferring: %%~nxf
        
        REM Execute the transfer
        %TNCCMD% PUT "%%f" "%DEST_FOLDER%%%~nxf" %TRANSFER_MODE% -I %MACHINE_IP%
        
        if %ERRORLEVEL%==0 (
            echo   SUCCESS: %%~nxf transferred
            
            if /i "%DELETE_AFTER%"=="YES" (
                del "%%f"
                echo   Deleted source file
            ) else (
                move "%%f" "%SOURCE_FOLDER%\Processed\" >nul 2>&1
                echo   Moved to Processed folder
            )
        ) else (
            echo   FAILED: %%~nxf - Error code %ERRORLEVEL%
        )
        echo.
    )
)

echo ============================================
echo  Transfer complete
echo ============================================
echo.
pause
