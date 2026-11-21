@echo off
rem One-time setup: puts a "Grumpy Shark Updater" shortcut (with the shark icon) on your desktop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"
pause
