# ESP32-C3 BLE UART bridge

This firmware only transports existing 16-byte packets. FPGA synthesis and
score/record timing remain on the FPGA. It neither streams PCM nor creates
NOTE/PANIC commands. There is no Bluetooth module in the supplied setup;
hardware connection and RF latency have not been measured.

Target: Espressif Arduino-ESP32 **3.3.5**, board **Waveshare ESP32-C3-Zero**.
The Zero-M variant has soldered headers and uses the same board profile.
The included BLE wrapper uses Espressif's host stack; no ArduinoBLE or third
party NimBLE library is required. Native USB CDC is used for debug `Serial`.
Arduino CLI 1.3.1 and the official
3.3.5 C3 compiler/core archives were downloaded, checksum verified and
installed in the workspace. The current source completed the `.cmd` build
on 2026-10-13 at 19:16 (UTC+8), exit 0 with no warnings. Program
storage is 665242 / 1310720 bytes (50%); static RAM is 23964 / 327680 bytes
(7%). This is static memory reported by the linker, not measured peak RAM.
The builder compares source hashes before and after compilation. Shared
callback/loop state uses atomic variables. The Windows metadata
export directory is created for the selected Waveshare board profile.
No firmware has been flashed or tested on a physical BLE module.

The application binary is `output/ble_bridge.ino.bin` (665392 bytes), SHA256
`7dee453d5dce0eac52dbffb96c859205223df60bd0ff8568953b6e1c928eb28d`.
`output/build-manifest.json` records the source, tool versions, exit status,
UART pin assignments, 4MB flash profile and hashes of all six generated
artifacts. The 4MB merged image also includes the bootloader and partition
data. No artifact has been uploaded to a physical ESP32-C3.

| Bridge | FPGA wrapper |
| --- | --- |
| GPIO7 / Serial1 TX | UART RX, 3.3V |
| GPIO6 / Serial1 RX | UART TX, 3.3V |
| GND | GND |

GPIO6/7 are exposed, free GPIOs on the selected Zero board and UART1 is
explicitly remapped to them. The board's **RX/TX silk labels are GPIO20/21
(UART0)** and are not the connection points for this firmware. Compile-time
checks reject identical UART pins and the board's occupied or reserved pins:
BOOT/straps 2/8/9, onboard RGB 10, stacked flash 12..17, USB 18/19 and
unexposed GPIO11. Override `FPGA_RX_GPIO` / `FPGA_TX_GPIO` only with other
free exposed GPIOs. Power through USB-C for first testing and join GND with
the FPGA. UART logic is 3.3V. FPGA header positions must be confirmed against
the actual dock revision before wiring.

The onboard RGB is GPIO10, kept separate from the 25-pixel FPGA guide panel.
At dim brightness 8/255 it shows blue while disconnected/advertising, green
while BLE is connected, and red for approximately two seconds after a bridge
transport error. Green shows a BLE connection, not proof of FPGA ACK receipt.
The firmware starts without waiting for a USB serial monitor; debug writes
are emitted only when there is buffer capacity, with a 1ms USB timeout.

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
Queues use internal session tags. Stale queued commands/responses and partial
responses are discarded at connection transitions, including reconnects
between two loop iterations. A command queued immediately after connection
is retained; a later loop transition no longer clears that first command.
Tags are never added to the 16-byte wire protocol. UART bytes already in
flight and real radio reconnect timing still require hardware testing.

The application sends only one request at a time. Notify attempts keep the
response queued until the BLE host accepts it, with a bounded three-attempt
failure path. In core 3.3.5, `onStatus` runs both synchronously inside `notify()`
and asynchronously on the BLE host task. Only the synchronous loop-task
result completes the queued attempt; asynchronous results contribute error
counters and cannot remove a newer response. Loss after host acceptance is recovered by the phone retrying
the exact packet and FPGA replaying its cached ACK/readback. This is a control
prototype without pairing/encryption policy; operate with one nearby client.

Hardware/API references checked against the official sources on 2026-10-13:

- [Espressif BLE UART example](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/ble.html)
- [Espressif UART API and error callbacks](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/serial.html)
- [BLECharacteristic header, 3.3.5](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLECharacteristic.h)
- [BLEServer header, 3.3.5](https://github.com/espressif/arduino-esp32/blob/3.3.5/libraries/BLE/src/BLEServer.h)
- [Waveshare Zero / Zero-M hardware: GPIO10 RGB, GPIO20/21 UART0, 4MB flash](https://docs.waveshare.net/ESP32-C3-Zero/)
- [Waveshare Arduino board selection and native USB CDC](https://docs.waveshare.net/ESP32-C3-Zero/Arduino/)
- [Espressif USB and boot strap reservations](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32c3/schematic-checklist.html)

## Reproduce the build

In the supplied Windows workspace, run from a normal local PowerShell:

```powershell
Set-Location 'C:\Users\asus\Desktop\Git\TangMega60K_Synth'
.\scripts\build-ble-bridge.ps1
```

The script checks Arduino-ESP32 3.3.5, compiles
`esp32:esp32:waveshare_esp32_c3_zero:CDCOnBoot=default,FlashSize=4M` and writes binaries plus their SHA256
manifest to `firmware/ble_bridge/output/`. It does not upload firmware.
The local tool configuration keeps SDK/download/build files under
`../tmp/ble-build/`. Only the official tools required for C3 compilation
were installed; compilers for other ESP32 variants are not installed.

If Windows disables PowerShell `.ps1` scripts, use the command wrapper:

```powershell
.\scripts\build-ble-bridge.cmd
```

This wrapper starts PowerShell with `-ExecutionPolicy Bypass` only for its
child process; it does not change the computer's stored execution policy.
Both entry points use the same builder and save compiler output and exit status to
`../tmp/ble-build/compile-local.log` and `compile-local.exit.txt`.
Both entry points pre-create the 3.3.5 SDK's metadata export directory and
create `build-manifest.json` only after a successful compile with unchanged
source. Hashing uses .NET directly, including in Windows PowerShell without
`Get-FileHash`. The manifest records root sketch `.ino`, `.h`, `.hpp`, `.cpp`
and `.c` files to detect changes before release export.

On another computer, install the official 3.3.5 core with Arduino CLI first,
then provide `-ArduinoCli` and `-ConfigFile` as appropriate. The equivalent
compile command is:

```powershell
arduino-cli compile --fqbn esp32:esp32:waveshare_esp32_c3_zero:CDCOnBoot=default,FlashSize=4M firmware/ble_bridge
```

**CDC option names differ by board profile:** on the selected Waveshare
profile `CDCOnBoot=default` means enabled, while `CDCOnBoot=cdc` means disabled.
The sketch rejects disabled CDC at compile time. Do not copy the old generic
ESP32C3 Dev Module option string into the Waveshare profile.

For first upload, hold **BOOT (GPIO9)** while connecting USB-C, or hold BOOT,
press/release RESET and release BOOT. Select the resulting USB COM port.
After successful upload, release BOOT and press RESET to run. These steps are
documented for later hardware arrival; no board has been flashed by this task.
