@echo off
setlocal
title Conexion remota (configure-remote)

rem ------------------------------------------------------------
rem  Lanzador de configure-remote.ps1
rem  - Debe estar en la MISMA carpeta que el .ps1
rem  - Se eleva solo a administrador (el .ps1 lo exige)
rem  - Aplica ExecutionPolicy Bypass SOLO a este proceso
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
rem -NoExit es imprescindible: mantiene abierta la consola para que
rem la sesion de Enter-PSSession siga activa al terminar el script.
powershell -NoProfile -NoExit -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b

:noscript
echo No se encontro el script:
echo   %SCRIPT%
echo Coloca este .bat junto a configure-remote.ps1
pause
exit /b 1
