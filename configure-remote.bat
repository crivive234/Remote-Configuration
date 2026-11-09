@echo off
setlocal
title Conexion remota (configure-remote)

rem ------------------------------------------------------------
rem  Lanzador de configure-remote.ps1
rem  - Debe estar en la MISMA carpeta que el .ps1
rem  - Se eleva solo a administrador (el .ps1 lo exige)
rem  - Aplica ExecutionPolicy Bypass SOLO a este proceso
rem  - Al terminar cierra la ventana; si el script falla, hace una pausa
rem  - Pasa los argumentos al script:
rem        configure-remote.bat 10.158.131.20 -SkipServiceSetup
rem ------------------------------------------------------------

set "SCRIPT=%~dp0configure-remote.ps1"

if not exist "%SCRIPT%" goto :noscript

rem --- Comprobar si ya somos administrador ---
net session >nul 2>&1
if %errorlevel% equ 0 goto :run

rem --- No lo somos: relanzar este .bat con UAC ---
echo Solicitando permisos de administrador...
if "%~1"=="" goto :elevate_noargs
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
exit /b

:elevate_noargs
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
rem Sin -NoExit: al terminar el script (salir + confirmacion) la ventana
rem se cierra sola. El script ya no usa Enter-PSSession, asi que no hace
rem falta mantener la consola abierta.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%errorlevel%"

rem Si el script termina con error (codigo distinto de 0) se hace una pausa
rem para poder leer el mensaje antes de que se cierre la ventana.
if not "%RC%"=="0" (
    echo.
    echo El script termino con codigo %RC%.
    pause
)
exit /b %RC%

:noscript
echo No se encontro el script:
echo   %SCRIPT%
echo Coloca este .bat junto a configure-remote.ps1
pause
exit /b 1
