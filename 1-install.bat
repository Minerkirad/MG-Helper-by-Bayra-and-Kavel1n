@echo off
title Majestic Settings Pack - by Bayra ^& Kavel1n
echo =============================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File -ErrorAction SilentlyContinue"
echo  Majestic settings pack - by Bayra ^& Kavel1n
echo =============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-gta-watcher.ps1"
