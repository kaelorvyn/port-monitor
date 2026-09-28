@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Port Monitor
powershell -NoProfile -ExecutionPolicy Bypass -File "server.ps1"
echo.
echo Server stopped. Press any key to close this window.
pause >nul
