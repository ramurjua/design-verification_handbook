@echo off
REM >>> Ruta a Vivado: AJUSTA ESTO según tu instalación <<<
set VIVADO_PATH=D:\Xilinx\Vivado\2022.1

REM >>> Verifica si el disco y carpeta de Vivado existen
if not exist "%VIVADO_PATH%" (
    echo ❌ ERROR: No se encontró Vivado en "%VIVADO_PATH%"
    echo Asegúrate de que el disco externo esté conectado.
    pause
    exit /b
)

REM >>> Inicializar entorno Vivado
call "%VIVADO_PATH%\settings64.bat"

REM >>> Ejecutar Vivado en modo batch
vivado -mode tcl -source build_project.tcl

pause
