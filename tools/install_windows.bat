@echo off
rem WitcherPadBridge -- double-click installer for Windows.
rem On Steam Deck / Bazzite / Proton use tools/install_win.sh instead.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1" %*
echo.
pause
