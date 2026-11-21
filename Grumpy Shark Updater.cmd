@echo off
rem Opens the updater window. For the old text-only version run Update-Addons.ps1 directly.
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Addon-Updater.ps1"
