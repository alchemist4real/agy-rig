@echo off
start powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AgySwitch-GUI.ps1"
exit
