@echo off
rem Wrapper so Windows Task Scheduler can run the PowerShell dispatcher
rem without dealing with quoting. Keep this file next to dispatch_daily.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dispatch_daily.ps1" %*
exit /b %ERRORLEVEL%
