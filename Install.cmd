@echo off
REM Installs Network Control Center to Program Files (asks for UAC once) with a Start menu entry
REM that opens the app elevated with one click, ready to pin to the taskbar.
REM Add -Desktop for a desktop shortcut too.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Shortcut.ps1" %*
echo.
pause
