@echo off
REM Launches Network Control Center without installing it. The script self-elevates, so you
REM get ONE UAC prompt. For a pinnable taskbar / Start menu entry run "Install.cmd" instead.
REM "conhost --headless": no console window, even when Windows Terminal is the default terminal.
start "" "%SystemRoot%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0NetworkControlCenter.ps1"
