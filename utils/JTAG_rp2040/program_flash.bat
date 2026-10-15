@echo off
REM Programs ..\output\<project>.mcs into the board's flash through the Pico JTAG.
REM Starts xvcd-pico in the background, runs program_flash.tcl in Vivado, stops xvcd-pico.

REM --------- USER INPUTS ----------
set VIVADO_PATH=C:\Xilinx\Vivado\2022.1
set XVCD_DIR=C:\Users\ramuj\Documents\design-verification_handbook\utils\JTAG_rp2040\program_files
REM --------------------------------

if not exist "%VIVADO_PATH%" (
    echo ERROR: Vivado not found in "%VIVADO_PATH%"
    echo Make sure the external disk is connected.
    pause
    exit /b 1
)
if not exist "%XVCD_DIR%\xvcd-pico.exe" (
    echo ERROR: xvcd-pico.exe not found in "%XVCD_DIR%"
    pause
    exit /b 1
)

REM xvcd-pico needs the cygwin DLLs next to it, so start it from its own folder
tasklist /FI "IMAGENAME eq xvcd-pico.exe" | find /I "xvcd-pico.exe" >nul
if errorlevel 1 (
    start "xvcd-pico" /MIN /D "%XVCD_DIR%" xvcd-pico.exe
    set STARTED_XVCD=1
    timeout /t 2 /nobreak >nul
) else (
    echo xvcd-pico is already running, using it
    set STARTED_XVCD=0
)

call "%VIVADO_PATH%\settings64.bat"
call vivado -mode batch -nojournal -log program_flash.log -source program_flash.tcl
set RESULT=%ERRORLEVEL%

if "%STARTED_XVCD%"=="1" taskkill /IM xvcd-pico.exe /F >nul 2>&1

echo.
if "%RESULT%"=="0" (
    echo ==========================================================
    echo  Flash programmed. POWER CYCLE THE BOARD to run the new design.
    echo ==========================================================
) else (
    echo ERROR: programming failed, see program_flash.log
)
pause
exit /b %RESULT%
