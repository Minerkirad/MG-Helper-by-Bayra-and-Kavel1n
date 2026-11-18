@echo off
title MG Helper - by Bayra ^& Kavel1n

:: remove Mark-of-the-Web from package files (downloaded archives get flagged)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

:menu
cls
echo ==========================================================
echo            MG Helper - by Bayra ^& Kavel1n
echo ==========================================================
echo.
echo   [1] Install            (run once - sets up everything)
echo   [2] Reset settings     (current game settings become protected)
echo   [3] Import settings    (use a settings.xml placed in this folder)
echo   [4] MAX FPS profile    (extreme performance graphics)
echo   [5] Cut shadows        (friend's shadow-removal values)
echo   [6] Clean Majestic cache  (WARNING: re-downloads tens of GB)
echo.
echo   [7] Diagnose           (if something does not work)
echo   [8] Uninstall
echo.
echo   [0] Exit
echo.
set /p choice="Choose: "
if "%choice%"=="1" goto install
if "%choice%"=="2" goto reset
if "%choice%"=="3" goto import
if "%choice%"=="4" goto maxfps
if "%choice%"=="5" goto shadows
if "%choice%"=="6" goto cleancache
if "%choice%"=="7" goto diagnose
if "%choice%"=="8" goto uninstall
if "%choice%"=="0" exit /b 0
goto menu

:install
call "%~dp01-install.bat"
echo.
pause
goto menu

:reset
call "%~dp02-reset-settings.bat"
goto menu

:import
call "%~dp03-import-settings.bat"
goto menu

:maxfps
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0max-fps.ps1"
goto menu

:shadows
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cut-shadows.ps1"
goto menu

:cleancache
call "%~dp04-clean-cache.bat"
goto menu

:diagnose
call "%~dp05-diagnose.bat"
goto menu

:uninstall
call "%~dp00-uninstall.bat"
echo.
echo Uninstalled. You can delete this folder now.
pause
exit /b 0
