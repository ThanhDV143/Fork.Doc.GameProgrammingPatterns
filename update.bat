@echo off
title Update Game Programming Patterns
color 0A
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"

echo.
echo ======================================================
echo   FINISHED. Press any key to close...
echo ======================================================
pause > nul
