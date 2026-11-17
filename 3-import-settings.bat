@echo off
title Import My Settings - by Bayra ^& Kavel1n
echo =============================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File -ErrorAction SilentlyContinue"
echo  Import My Settings - by Bayra ^& Kavel1n
echo =============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0import-settings.ps1"
