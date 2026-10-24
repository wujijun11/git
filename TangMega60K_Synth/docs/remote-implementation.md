# Remote control implementation and limits

The packet contract is `remote-control-v1.md`. This implementation adds a
binary UART transport, real phone BLE client source and an ESP32-C3 bridge.
It does not claim a hardware acceptance result: no BLE module is currently
connected and no Huawei phone was tested. The Android APK has now been built
and signed; the current C3 sketch has completed compilation and export with
exit 0 and no warnings. Neither artifact has completed physical acceptance.

## FPGA transport

`rtl/remote/remote_uart_transport.sv` includes the byte receiver/transmitter.
Inputs: `clk`, active-high synchronous `reset`, asynchronous `rx`. RX has a
two-flop synchronizer. TX is idle-high. Default 49,152,000 Hz / 115,200 baud, 8N1 uses a
rounded 427-clock bit period (115,110.07 baud, -0.0781% error).

Command output is `cmd_valid/ready`, `cmd_seq[7:0]`, `cmd_opcode[7:0]`,
`cmd_payload[79:0]`. Payload byte 0 occupies bits7:0. A depth 4 FIFO preserves
data while stalled. A new completed packet can reuse a slot simultaneously
with a command handshake. Physical UART has no CTS/RTS; when the FIFO is
full a newly completed packet is discarded and `overflow_count` increments,
with a one-cycle `overflow_pulse`. Connect that pulse to explicit FPGA
release/recovery logic. The phone's one-request-at-a-time policy avoids
normal overflow but does not erase the need for the recovery path.

Response input is the symmetric `rsp_valid/ready`, `rsp_seq`, `rsp_opcode`,
`rsp_payload`. The producer must hold its response while ready is low. A
response is captured once, encoded with version 1 and CRC8 and sent over UART.
The next response can be captured while the previous packet's final byte is
physically transmitting; the next start bit still waits for that byte's full
stop interval. TX never changes captured data due to producer stalls.

Public 32-bit counters reset to zero:

| Counter | Trigger |
| --- | --- |
| `crc_error_count` | Completed packet CRC mismatch |
| `framing_error_count` | Bad UART stop bit or invalid packet version |
| `overflow_count` | Valid packet cannot enter the command FIFO |
| `timeout_count` | Partial packet idle for RX_TIMEOUT_BITS bit periods |

Default RX_TIMEOUT_BITS 32 gives about 278 microseconds between validated bytes.
The parser resets on bad UART framing and partial-packet timeout. Repeated
A5 before 5A is handled as overlapping sync. A break produces one framing
error and requires idle-high before another byte starts. Invalid CRC/version
and malformed UART frames never produce `cmd_valid`. Reset aborts partial
RX/TX packets and empties the FIFO. Counter rollover is modulo2^32.

Transport forwards duplicate sequences unchanged. The root command router
owns the most-recent exact seq/op/payload cache, command mutation suppression
and replay of ACK plus any readback. The client sends one command at a time;
out-of-order or multi-client traffic is outside that duplicate window.

## Phone and bridge

`mobile/web/` supports real Web Bluetooth and explicit software simulation.
`mobile/android/` uses native Java BLE scanning/GATT/CCCD/permissions and local
WebView assets. Its HTTPS loader and JSON export use native Android network
and Storage Access Framework APIs. This is for Huawei systems capable of
running Android APKs; HarmonyOS NEXT compatibility is unverified and is not
provided by this Android project. See `mobile/README.md` for setup.

Fixed NUS UUIDs are identical across Android, JS and bridge. Each BLE write
and notification carries 16 bytes. ESP32-C3 firmware is a transparent bridge
using Espressif Arduino core 3.3.5; it never creates audio/NOTE commands. Its
bounded queues, UART errors and notification failures are observable through
debug logs and a readable diagnostic characteristic. Queue/error failure
disconnects BLE so the app reports a visible failure. Reconnect clears stale
bridge packets; phone handshake probes telemetry, advances past any sequence
conflict, then sends Panic with a new sequence. Visible phone sessions emit
1 Hz telemetry heartbeat. FPGA source 63 expiry releases notes on bridge/RF
failure; normal note-off remains an acknowledged queued command.

The client validates score JSON version 1,1..256 rows and integer ranges
before upload. Every row uses SCORE_WRITE; SCORE_COMMIT is the final accepted
transaction. Recording is retrieved with telemetry count (up to 1024), then
one indexed READBACK per event. ACK and data responses both retain request
seq. Export saves event JSON, preserving FPGA timing/MIDI/source/timbre.

Expression sliders send continuously while dragging with a 40ms minimum
interval. A slow GATT/ACK retains one in-flight request and the latest pending
snapshot, not a queue of drag history. Masks include only changed dimensions;
gain/vibrato changes do not reset a physical slider bend. Session replacement
cancels pending expressions and rejects old upload/handshake/record operations.
Score uploads keep their initial document snapshot. Window blur/visibility
loss releases held phone notes. These behaviours passed controller tests,
including 300 rapid drag inputs under slow writes and immediate reconnect at
an ACK boundary; they are not an RF latency measurement.

## Real verification

On 2026-10-11 these commands passed in the supplied Windows environment:

- `scripts/test-remote-uart.ps1`: Icarus compile and default-divider serial
  simulation for CRC/version/stop errors, noise/overlapping sync, partial
  timeout, duplicate sequence forwarding, RX stalled payload, visible FIFO
  overflow, simultaneous full FIFO pop/push, sender baud deviation
  approximately+/-1.6%, response CRC/data ordering, TX backpressure and reset.
- `scripts/test-remote-mobile.ps1`: JS syntax, 1000 codec/error vectors,
  strict score/event ranges, ACK retries, sequence wrap, NACK handling,
  queue close/overflow, GATT completion vs ACK ordering, UUID parity;
  minimal-DOM workflows for 25 mappings, upload, key release, recording
  retrieval/export, guide commands and unsupported-Bluetooth detection;
  2000 independent Python/JS CRC/layout vectors.

Icarus output is in `sim/remote_results/uart.log`. The phone tests are
software controller/protocol tests, not a rendered browser or Android test.
The native Android APK was built with AGP 8.7.3, Gradle 8.9, Android SDK 35
and JDK 21. A fresh `assembleDebug lintDebug --rerun-tasks` passed with zero
lint errors and zero warnings; APK v1/v2 signature verification passed.
The artifact is `mobile/android/output/TangSynthRemote-debug.apk`, SHA256
`5470a25fb92913437d1f7245ec511b8da3bd01e0d38bbf1f1b15b4d9b731062f`.

The follow-up audit adds a separate 4-second transport-write deadline even
with an early ACK, snapshots and validates queued parameters, pins browser
device/notification/write callbacks to one connection, and cancels late chooser
or discovery results. Phone keys mapped to the same MIDI pitch share source63
ownership until the last pointer releases. Initial diagnostic failure resets
its running state, and old map/Panic/record-clear continuations cannot commit
into a new session. These cases pass executable controller/protocol tests.

`mobile/tests/test_android_callbacks.py --java-home <JDK> --android-jar <SDK>/platforms/android-35/android.jar`
compiles the actual MainActivity and drives its callbacks with a deterministic
host UI queue. Old notification/write completion, already stale callbacks,
background dispatch and WebView destruction pass. It verifies queue ordering
with runtime doubles, not real Android or RF behavior. UI-thread JS dispatch
now stays in the callback's guarded task rather than posting a second task
that can cross reconnect; background callers still post to the UI thread.

Arduino CLI 1.3.1 and the official Arduino-ESP32 3.3.5 C3 tool archives were
downloaded, checksum verified and installed. The SDK headers confirm the
bridge's String getValue, notification callback and UART error callback
signatures. The current atomic-state bridge completed the user's local
`.cmd` build on 2026-10-11 at 16:16 (UTC+8), exit 0 with no warnings. Program
storage is 664570 bytes (50%); static RAM is 23940 bytes (7%). The compiled
sketch was compared with the current source, and all six artifact hashes
are recorded in `firmware/ble_bridge/output/build-manifest.json`. Application
binary SHA256 is
`580eacfa0f1985c7457109c257e5e28dafbb782140b4ef1fdec44d9f0d216598`.
Both build wrappers create the directory required by the SDK's Windows
metadata export hook. The `.cmd` wrapper runs without changing the
PowerShell script execution policy. No firmware has been uploaded.

No RF latency, real notification loss, UART electrical level, phone background
behaviour, Android WebView rendering or physical hardware acceptance was measured.

Official APIs were checked using
[Android GATT](https://developer.android.com/develop/connectivity/bluetooth/ble/connect-gatt-server),
[Android permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions),
[Espressif BLE](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/ble.html)
and [Espressif UART](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/serial.html).
The bridge README also pins the official 3.3.5 source headers used to check
method signatures. These are engineering API references; the competition
requirement authority remains the user-specified Gowin competition page.
