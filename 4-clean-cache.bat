@echo off
title Majestic Cache Cleaner - by Bayra ^& Kavel1n
echo =============================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File -ErrorAction SilentlyContinue"
echo  Majestic cache cleaner - by Bayra ^& Kavel1n
echo =============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clean-majestic-cache.ps1"
