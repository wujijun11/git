@echo off
setlocal
rem Defaults to 33 Core cases. Add -Suite Full for the legacy N64 long test.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-modelsim-full.ps1" %*
exit /b %ERRORLEVEL%
