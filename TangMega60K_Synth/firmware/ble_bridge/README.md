# ESP32-C3 BLE UART bridge

This firmware only transports existing 16-byte packets. FPGA synthesis and
score/record timing remain on the FPGA. It neither streams PCM nor creates
NOTE/PANIC commands. There is no Bluetooth module in the supplied setup;
hardware connection and RF latency have not been measured.

Target: Espressif Arduino-ESP32 **3.3.5**, board `ESP32C3 Dev Module`.
The included BLE wrapper uses Espressif's host stack; no ArduinoBLE or third
party NimBLE library is required. Use USB CDC for the debug `Serial` where
your C3 development board supports it. Arduino CLI 1.3.1 and the official
3.3.5 C3 compiler/core archives were downloaded, checksum verified and
installed in the workspace. The current source completed the user's local
`.cmd` build on 2026-10-11 at 16:16 (UTC+8), exit 0 with no warnings. Program
storage is 664570 / 1310720 bytes (50%); static RAM is 23940 / 327680 bytes
(7%). The generated sketch matches the current source after removing the
Arduino-generated line markers and setup/loop declarations. Shared
callback/loop state uses atomic variables. The earlier Windows metadata
export failure was fixed by creating the SDK's sketch-relative directory.
No firmware has been flashed or tested on a physical BLE module.

The application binary is `output/ble_bridge.ino.bin` (664720 bytes), SHA256
`580eacfa0f1985c7457109c257e5e28dafbb782140b4ef1fdec44d9f0d216598`.
`output/build-manifest.json` records the source, tool versions, exit status,
memory summary and hashes of all six generated artifacts. The 4MB merged
image also includes the bootloader and partition data; select the actual
ESP32-C3 development board and flash size before choosing an upload method.

| Bridge | FPGA wrapper |
| --- | --- |
| GPIO7 / Serial1 TX | UART RX, 3.3V |
| GPIO6 / Serial1 RX | UART TX, 3.3V |
| GND | GND |

GPIO6/7 are defaults and must be checked against the chosen C3 board's
schematic. Override `FPGA_RX_GPIO` / `FPGA_TX_GPIO` if required. Power the
bridge using the development board's specified supply. Do not connect 5V
logic to either UART. FPGA pin assignment belongs to the board constraints.

The advertised name is `Tang-Synth-C3`. Fixed UUIDs:

- Service: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- Write-with-response, phone -> bridge: `6e400002-b5a3-f393-e0a9-e50e24dcca9e`
- Notify, bridge -> phone: `6e400003-b5a3-f393-e0a9-e50e24dcca9e`
- Read diagnostics: `6e400004-b5a3-f393-e0a9-e50e24dcca9e`

A BLE write must contain exactly 16 bytes; CRC/version are preserved for FPGA
validation. Each notification contains one unchanged 16-byte UART frame.
The standard ATT payload is sufficient. Diagnostics holds four little-endian
uint32 counters: BLE write/queue errors, UART errors/response queue overflow,
notify errors, UART resynchronization bytes/timeouts. Debug Serial logs these
as well. On malformed BLE writes, queue overflow or UART errors the bridge
disconnects; the client visibly reports the failure. A source63 communication
watchdog on FPGA is required to release notes after an RF/bridge failure.
Queued packets and partial responses are discarded at connection transitions,
so old notifications are not delivered into a new session.

The application sends only one request at a time. Notify attempts keep the
response queued until the BLE host accepts it, with a bounded three-attempt
failure path. Loss after host acceptance is recovered by the phone retrying
the exact packet and FPGA replaying its cached ACK/readback. This is a control
prototype without pairing/encryption policy; operate with one nearby client.

API references checked against the official sources on 2026-10-11:

- [Espressif BLE UART example](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/ble.html)
- [Espressif UART API and error callbacks](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/serial.html)
- [BLECharacteristic header, 3.3.5](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLECharacteristic.h)
- [BLEServer header, 3.3.5](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLEServer.h)

## Reproduce the build

In the supplied Windows workspace, run from a normal local PowerShell:

```powershell
Set-Location 'C:\Users\asus\Desktop\Git\TangMega60K_Synth'
.\scripts\build-ble-bridge.ps1
```

The script checks Arduino-ESP32 3.3.5, compiles
`esp32:esp32:esp32c3:CDCOnBoot=cdc` and writes binaries plus their SHA256
manifest to `firmware/ble_bridge/output/`. It does not upload firmware.
The local tool configuration keeps SDK/download/build files under
`../tmp/ble-build/`. Only the official tools required for C3 compilation
were installed; compilers for other ESP32 variants are not installed.

If Windows disables PowerShell `.ps1` scripts, use the native-command wrapper
without changing the execution policy:

```powershell
.\scripts\build-ble-bridge.cmd
```

This wrapper saves compiler output and exit status to
`../tmp/ble-build/compile-local.log` and `compile-local.exit.txt`.
Both wrappers pre-create the 3.3.5 SDK's metadata export directory. The
PowerShell wrapper also creates `build-manifest.json` after success; local
`.cmd` results are verified from the exit file/log before packaging.

On another computer, install the official 3.3.5 core with Arduino CLI first,
then provide `-ArduinoCli` and `-ConfigFile` as appropriate. The equivalent
compile command is:

```powershell
arduino-cli compile --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc firmware/ble_bridge
```

No hardware was purchased or binary uploaded by this task. Confirm the
chosen development board and GPIO6/7 before uploading a successful build.
