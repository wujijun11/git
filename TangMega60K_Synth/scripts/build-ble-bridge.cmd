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
echo Compiling the ESP32-C3 bridge. This does not upload firmware.
echo Build log: %BLE_TOOL_DIR%\compile-local.log
if not exist "%BLE_PROJECT_DIR%\firmware\ble_bridge\build\esp32.esp32.esp32c3" mkdir "%BLE_PROJECT_DIR%\firmware\ble_bridge\build\esp32.esp32.esp32c3"
"%BLE_TOOL_DIR%\arduino-cli.exe" --config-file "%BLE_TOOL_DIR%\arduino-cli.yaml" compile --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc --jobs 4 --warnings more --build-path "%BLE_TOOL_DIR%\build" --output-dir "%BLE_PROJECT_DIR%\firmware\ble_bridge\output" "%BLE_PROJECT_DIR%\firmware\ble_bridge" > "%BLE_TOOL_DIR%\compile-local.log" 2>&1
set "BLE_RESULT=%ERRORLEVEL%"
> "%BLE_TOOL_DIR%\compile-local.exit.txt" echo %BLE_RESULT%
type "%BLE_TOOL_DIR%\compile-local.log"
echo Compile exit code: %BLE_RESULT%
exit /b %BLE_RESULT%
