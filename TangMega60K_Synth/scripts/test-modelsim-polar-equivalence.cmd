@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-modelsim-polar-equivalence.ps1" %*
exit /b %ERRORLEVEL%
