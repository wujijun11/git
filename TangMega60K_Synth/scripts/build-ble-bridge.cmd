@echo off
setlocal
for %%I in ("%~dp0..") do set "BLE_PROJECT_DIR=%%~fI"
for %%I in ("%~dp0..\..\tmp\ble-build") do set "BLE_TOOL_DIR=%%~fI"
if not exist "%BLE_TOOL_DIR%\arduino-cli.exe" (
    echo Arduino CLI is missing: %BLE_TOOL_DIR%\arduino-cli.exe
    exit /b 2
)
if not exist "%BLE_TOOL_DIR%\arduino-cli.yaml" (
    echo Local Arduino configuration is missing.
    exit /b 2
)
rem Bypass applies only to this child process; no machine/user policy is changed.
rem Reuse the checked builder so cmd and PowerShell emit the same fresh manifest.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BLE_PROJECT_DIR%\scripts\build-ble-bridge.ps1" -ArduinoCli "%BLE_TOOL_DIR%\arduino-cli.exe" -ConfigFile "%BLE_TOOL_DIR%\arduino-cli.yaml"
exit /b %ERRORLEVEL%
