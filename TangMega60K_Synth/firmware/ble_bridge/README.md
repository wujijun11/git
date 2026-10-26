# ESP32-C3 BLE UART bridge

2026-10-25 local latency update: successful notifications no longer have an
artificial15ms gap; failed attempts retain15ms backoff. The bridge requests
7.5–15ms/latency0 and advertises optional WRITE_NR, while clients still wait for
the existing FPGA ACK. See `docs/蓝牙延迟优化与测量_20261025.md` in the project root
for actual measurements and the new build manifest. No C3 was flashed by this task.

This firmware only transports existing 16-byte packets. FPGA synthesis and
score/record timing remain on the FPGA. It neither streams PCM nor creates
NOTE/PANIC commands.

## Current bridge, BLE write and notification repair

The current sketch also queues error-triggered disconnect requests onto the
NimBLE host task. The host rechecks the complete failed session generation before
selecting a connection handle, so a late request from an old connection cannot
close its replacement, even if that handle is reused. The packet format and
GPIO6 RX / GPIO7 TX are unchanged. Deterministic lifecycle and selected-SDK tests
are recorded in `verification/ble-connection-fix-20261023/c3-review/`.
These tests do not establish an FPGA ACK or prove the physical return path.

The build now explicitly selects `firmware/libraries/BridgeBLE`, a pinned
project-local Arduino-ESP32 BLE 3.3.5 copy. The installed SDK remains unchanged.
Two source files differ from the pinned upstream copy: `BLECharacteristic.cpp`
and `BLECharacteristic.h`. The write handler invokes the NimBLE callback
synchronously while the original payload and connection still apply. This
bridge callback only validates
and enqueues with zero wait; it never notifies or waits for UART. The upstream
deferred callback retained a mutable characteristic pointer, so a later write
could overwrite an earlier packet or a delayed old callback could cross reconnect.

The notification repair protects subscription updates and copies a private
subscription snapshot before notifying. Its semaphore is released before BLE
host calls and user callbacks, including `onSubscribe`, so callback reentry cannot
deadlock the host task. All 9 deterministic notification/subscription model cases
pass; the previous revision passes 5. These models do not validate actual RF
delivery, physical task scheduling, or FPGA ACK receipt.

The exact SDK handler functions are tested together with the actual bridge:
the four new scheduling cases fail before the repair and all **60** transport
cases pass afterward. The builder hashes all 64 library files, checks they remain
unchanged, and verifies actual compiler inputs select all 30 local C++ files with
no unpatched SDK BLE source. Use the project build script or the explicit local
library argument below. Current artifacts and both repairs are recorded in
[the second code review](../../verification/second-code-review-20261023/README.md).
The earlier write/UART repair is preserved in
[the first hardening record](../../verification/code-hardening-20261023/README.md).

The current source checks the actual IDF UART1 write result and TX completion,
rather than trusting Arduino-ESP32 3.3.5's unconditional `HardwareSerial::write`
size return. Driver failure, short write and completion failure now close that
session without incrementing the successful-send counter. Initialization checks
115200 8N1, buffer capacities, and RX timeout/FIFO setup results.

The parser also preserves a partial response when its remaining bytes are
already buffered after a TX wait. It expires a partial frame after 20 ms only
when no unread UART bytes remain. CRC framing and the 16-byte wire protocol are
unchanged. USB diagnostics separately count bytes discarded outside a live
session. GPIO7 TX / GPIO6 RX and the 40-byte BLE diagnostic layout are unchanged.

The actual sketch passes 56 deterministic transport regressions; the low-level
helper passes 49 configuration/fault cases. The buffered-tail case failed before
the parser repair and passes afterward. Build artifacts, exact source hashes,
SDK audit and the hardware-verification status are recorded in
[the checked-UART verification record](../../verification/c3-uart-checked-20261022/README.md).
The new build has not yet been flashed or verified with an FPGA ACK. Earlier
flash records below describe earlier source revisions.

Target: Espressif Arduino-ESP32 **3.3.5**, board **Waveshare ESP32-C3-Zero**.
The Zero-M variant has soldered headers and uses the same board profile.
The included BLE wrapper uses Espressif's host stack; no ArduinoBLE or third
party NimBLE library is required. Native USB CDC is used for debug `Serial`.

## Historical initial build and flash

An ESP32-C3 with 4MB embedded flash was identified on COM3 and flashed on
2026-10-17; flash hash verification passed and a hard reset was issued. See the
[first hardware flash record](../../verification/c3-first-flash-20261017/README.md).
That record does not validate the current checked-UART repair.
Arduino CLI 1.3.1 and the official
3.3.5 C3 compiler/core archives were downloaded, checksum verified and
installed in the workspace. The initial source completed the `.cmd` build
on 2026-10-15 at 20:30 (UTC+8), exit 0 with no warnings. Program
storage is 665442 / 1310720 bytes (50%); static RAM is 23956 / 327680 bytes
(7%). This is static memory reported by the linker, not measured peak RAM.
The builder compares source hashes before and after compilation. Shared
callback/loop state uses atomic variables. The Windows metadata
export directory is created for the selected Waveshare board profile.
That initial merged firmware was flashed and its flash hash verified
on the physical ESP32-C3. This does not yet validate BLE or UART functionality.

The initial application binary is `output/ble_bridge.ino.bin` (665584 bytes), SHA256
`88c67fffd391257fd501bce0d78435944b4d3d59aa2e900fd1b21de2915d85b7`.
`output/build-manifest.json` records the source, tool versions, exit status,
UART pin assignments, 4MB flash profile and hashes of all six generated
artifacts. The 4MB merged image also includes the bootloader and partition
data. The merged image was uploaded at offset 0x0 with esptool 5.1.0; the build
manifest's `uploaded: false` describes the original compile/export stage.
The later physical flash event is recorded separately in the linked record.

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
validation. UART response framing additionally checks CRC-8/ATM (polynomial
07, initial 00, bytes 2..14), forwarding each intact frame as one unchanged
16-byte notification. A rejected window retains any later A5 5A header or
trailing A5. This prevents a dropped/inserted byte from locking framing onto
an A5 5A sequence inside repeated payloads. The bridge does not interpret
the version/opcode or change retry semantics. Corrupt responses are dropped
and counted; the phone's original request retry recovers a lost response.
The standard ATT payload is sufficient for each 16-byte notification. The
40-byte diagnostic read preserves four little-endian uint32 error counters at
bytes 0..15: BLE write/queue errors, UART errors/response queue overflow, notify
errors, and UART resynchronization bytes/timeouts. Bytes 16..19 are `TB`, version
1, and UART-ready flags; bytes 20..39 contain five uint32 success/observation
counters (BLE receive, completed UART send, UART received bytes, valid response,
and host-accepted notification). A completed UART send is not an FPGA ACK.
Debug Serial logs these counters and the separate `UARTdiscard` count. On
malformed BLE writes, queue overflow or UART errors the bridge
disconnects; the client visibly reports the failure. A source63 communication
watchdog on FPGA is required to release notes after an RF/bridge failure.
Queues use internal session tags. Stale queued commands/responses and partial
responses are discarded at connection transitions, including reconnects
between two loop iterations. A command queued immediately after connection
is retained; a later loop transition no longer clears that first command.
Tags are never added to the 16-byte wire protocol. UART bytes already in
flight and real radio reconnect timing still require hardware testing.

Connection generation, connected state and transport-failure state now share
one atomic 32-bit word. An error marks only the exact live generation through
compare-and-exchange. It remains failed until the next connection transition:
requesting an asynchronous BLE disconnect cannot accidentally resume queued
commands on the following loop iteration. Writes during that closing interval
are rejected without filling the queue. Response-queue overflow also stops
notifications in that same loop; three failed notify attempts close the session
without starting an extra attempt. A stale generation's error cannot replace
the current generation's failure flag.

The first 2026-10-15 review executes the earlier sketch with deterministic C++
host stubs. Its 17 cases passed; that review's preserved old sketch failed nine.
Cases cover delayed disconnect completion, malformed writes, queue overflow,
short UART writes, notify failure/late callbacks, reconnect-first commands,
partial-frame timeout and diagnostics. See
[`verification/ble-review-20261015/README.md`](../../verification/ble-review-20261015/README.md)
for raw logs, before/after hashes and reproduction. These are software scheduling
tests, not ESP32 radio, task-preemption or hardware latency measurements.

The UART framing follow-up runs the current sketch through 29 host cases.
All pass, including the original 17 with real protocol CRC fixtures. The
pre-resynchronization sketch fails four new cases: damaged CRC, one deleted
byte, one inserted byte and consecutive corrupt frames. Additional coverage
includes payload-embedded headers, all 15 split boundaries, noise, reconnect
with partial/queued responses and unchanged BLE request forwarding. Raw logs,
frozen source/stub hashes and the real ESP32 build manifest are in
[`verification/ble-resync-20261015/README.md`](../../verification/ble-resync-20261015/README.md).

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
arduino-cli compile --fqbn esp32:esp32:waveshare_esp32_c3_zero:CDCOnBoot=default,FlashSize=4M --library firmware/libraries/BridgeBLE firmware/ble_bridge
```

**CDC option names differ by board profile:** on the selected Waveshare
profile `CDCOnBoot=default` means enabled, while `CDCOnBoot=cdc` means disabled.
The sketch rejects disabled CDC at compile time. Do not copy the old generic
ESP32C3 Dev Module option string into the Waveshare profile.

For first upload, hold **BOOT (GPIO9)** while connecting USB-C, or hold BOOT,
press/release RESET and release BOOT. Select the resulting USB COM port.
After successful upload, release BOOT and press RESET to run. These steps are
documented for later hardware arrival; no board has been flashed by this task.
