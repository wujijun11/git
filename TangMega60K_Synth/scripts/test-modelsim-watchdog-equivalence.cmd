@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-modelsim-watchdog-equivalence.ps1" %*
exit /b %ERRORLEVEL%
