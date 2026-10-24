@echo off
start "" conhost.exe --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Settings.ps1"
