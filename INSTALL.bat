@echo off
setlocal EnableDelayedExpansion
title AGY RIG - Installer

echo.
echo  ==============================================================
echo     AGY RIG - ONE-CLICK INSTALLER
echo     Antigravity Account Switcher + Live Quota Dock
echo  ==============================================================
echo.
echo  Menjalankan installer otomatis...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"

echo.
echo  ==============================================================
echo  Tekan sembarang tombol untuk keluar...
pause >nul
