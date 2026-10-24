# Project-local Arduino-ESP32 BLE 3.3.5

This is the `libraries/BLE/src` directory and unmodified Apache 2.0 `LICENSE`
from [Espressif Arduino-ESP32 tag 3.3.5](https://github.com/espressif/arduino-esp32/tree/3.3.5/libraries/BLE).
The original authors' source notices remain intact. Examples are omitted.
The Arduino metadata name is `BridgeBLE`; the C++ API and include names stay
unchanged. `scripts/build-ble-bridge.ps1` explicitly selects this library.

Two source files change: `BLECharacteristic.cpp` and `BLECharacteristic.h`.
On 2026-10-23 this project replaced NimBLE's per-write deferred callback task
with a synchronous `onWrite` callback after `setValue(buf, len)`, and protected
NimBLE's subscription vector during updates and notification snapshots.
All other source files are byte-identical to the pinned upstream copy.
`source-manifest.json` records upstream and local SHA-256 for every source
file, the license, and the library metadata.

The upstream delayed task retains the characteristic pointer and connection
description, but does not retain the write payload. Another write can replace
the characteristic value before the first callback reads it. A delayed task
can also outlive its connection. This bridge must consume the original bytes
and tag their session while the host processes that write.

This local change is suitable only for this bridge's bounded receive callback:
it validates the received length, copies a 16-byte packet, and calls
`xQueueSend(..., 0)`. It must not notify a BLE characteristic, perform a BLE
read/write, wait for UART transmission, or block inside `onWrite`. The main
loop retains all UART transmission and notification work. Upstream's separate
task was introduced to support callbacks that notify before the implicit ATT
write response; that compatibility behavior is not needed by this callback.

The original deferred helper remains in the source, unused by the patched
NimBLE write branch, to keep the change narrow. Bluedroid remains unchanged.
Do not install this library globally or use it
as a general substitute for upstream BLE.

The NimBLE host task may erase or append a subscription while the bridge loop
is notifying. Iterating the shared vector across BLE host calls can then use
invalid iterators or references. A dedicated semaphore now protects both
subscription updates and the copying of a private notification snapshot.
It is released before every BLE host call and user callback, including
`onSubscribe`, to avoid deadlocking callback reentry or the host task.
The snapshot can become stale when a client disconnects; existing MTU,
connection and GATT error checks still apply. This change does not establish
successful delivery to a client or an FPGA ACK.

Reproduction, exact SDK handler extraction, and scheduling regression tests:
`verification/code-hardening-20261023/c3-deferred-write/`. These are deterministic
host tests; they do not demonstrate successful RF delivery or FPGA ACKs.
Notification subscription/preemption tests are in
`verification/second-code-review-20261023/c3/`.
Changes to the SDK version or this library require re-auditing the patch,
rerunning these tests, and an actual ESP32-C3 build. The installed Espressif
SDK is never modified by this project.
