@echo off
REM WitcherPadBridge -- collect logs and settings for a bug report.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1" %*
pause
