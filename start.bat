@echo off
REM Double-click launcher for start.ps1
powershell -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
pause
