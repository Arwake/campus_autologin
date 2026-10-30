@echo off
chcp 65001 >nul
if not exist "%~dp0monitor.pid" (
  echo Monitor is not running.
  pause
  exit /b
)
set /p MPID=<"%~dp0monitor.pid"
taskkill /PID %MPID% /F >nul 2>&1
del "%~dp0monitor.pid" >nul 2>&1
echo Monitor stopped (PID %MPID%).
pause
