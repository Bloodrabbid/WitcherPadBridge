@echo off
rem WitcherPadBridge -- double-click uninstaller for Windows.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_windows.ps1" %*
echo.
pause
