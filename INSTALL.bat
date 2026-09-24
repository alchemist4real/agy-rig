@echo off
setlocal EnableDelayedExpansion
title AGY RIG - Installer

echo.
echo  ==============================================================
echo     AGY RIG - ONE-CLICK INSTALLER
echo     Antigravity Account Switcher + Live Quota Dock
echo  ==============================================================
echo.
echo  Running automated installer...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"

echo.
echo  ==============================================================
echo  Press any key to exit...
pause >nul
