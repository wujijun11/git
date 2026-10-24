# Desktop first-READBACK review

No new reproducible desktop defect was found that explains a missing first
READBACK ACK. Production code was read only and its hashes are recorded in the
result files. These tests do not establish a working physical BLE/UART/FPGA link.

`test_first_notify.py` executes the actual `NativeHost` with a controlled BLE
client and callback window. All five cases pass: ACK before write completion,
32-byte ACK/status notification, single-byte fragments, a failed write after an
early response, and old-generation notification isolation. The client and serial
modules are substituted before any connection. It uses a 15-second faulthandler
guard; no adapters or devices are opened and no sound is produced.

`test_first_readback.js` executes the actual controller, Session and decoder with
an in-memory transport. All seven cases pass: early ACK, data before ACK, bundled
frames, bytewise fragments, exact-frame retry when the first ACK is dropped, and
safe connection failure for bad CRC or missing data. Valid responses complete
the entire 31-command handshake; a dropped first ACK adds one identical retry.

The source review confirms that notification subscription completes before the
native transport is marked connected; the JavaScript consumer is installed
before sending READBACK. ACK notifications arriving before write completion are
retained, and READBACK serialization covers both ACK and telemetry.

`first-notify-result.json`, `first-readback-result.json` and their logs contain the
results and source hashes. These are targeted software timing checks only.

If adding post-failure diagnostics, retain fail-closed behavior and read before
physical disconnect, since the current fatal path closes the transport before
the connect caller catches the error. Compare against a connection baseline:
cumulative UART counters alone do not prove that this request reached a physical
pin or that the FPGA acknowledged it.
