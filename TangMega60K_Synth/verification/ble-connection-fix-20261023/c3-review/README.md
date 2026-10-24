# C3 connection lifecycle review

Scope: deterministic host execution of the actual production bridge sketch.
No target board, COM port, BLE radio, network service or installed SDK was used
 or changed by these tests. The initial review did not edit production code;
 the following authorized fix changes only `firmware/ble_bridge/ble_bridge.ino`.

Run `run_lifecycle_tests.py` with the bundled Python and MSVC available.
The runner reuses the previous transport harness and adapts a private copy.
It leaves historical evidence unchanged. Each case is a separate process.

Baseline result: `run_20261023_220128_762131/summary.json`.

- Actual sketch SHA-256 before/after:
  `ade217ace2cc8042333ba7195b04cbd8ca2f7cb0b64e4952952d005be55bbce7`.
- All 29 previous lifecycle/framing cases pass.
- Two additional lifecycle cases fail, as expected for the reviewed source.

## Failed close chooses a replacement connection

`failed_close_reconnect` interleaves an old disconnect and a new connect at
`server->getConnId()`. The sketch has already read the old failed state. Its
`server->disconnect(server->getConnId())` then requests closure of the new
connection ID, 9. `failSession(oldGeneration)` is guarded, but the actual close
call is not associated with its generation.

This is a deterministic scheduling proof of an unchecked lifetime boundary;
it does not claim this interleave occurred on the user's board. `getConnId()`
is a nonblocking getter in the actual library, but task preemption can occur
between its caller's state snapshot and the getter/disconnect operation.

An additional generation check in `loop()` narrows this window but leaves a
check/use race. A robust NimBLE solution should execute the generation check
and close selection on the host event task, where connection callbacks run.
The installed ESP32-C3 SDK exposes `nimble_port_get_dflt_eventq()` and
`ble_npl_event_init` / `ble_npl_eventq_put`. A persistent event with an atomic
requested failed state can avoid allocation and application locks. Do not
hold an application mutex while entering BLE host functions.

## Delayed UART error is attributed to its execution-time session

`queued_uart_error_reconnect` models an old UART error that was dequeued by
`HardwareSerial::_uartEventTask`, then delayed before invoking the error
callback. After disconnect/reconnect, the callback calls
`failSession(sessionGeneration())`, poisoning the replacement generation.

The actual installed `HardwareSerial.cpp` lines 281–321 dequeues an untagged
UART event and invokes `_onReceiveErrorCB(currentErr)`. It carries no bridge
session generation. This demonstrates the bridge cannot attribute that
callback to the event's origin session. It does not prove such delayed error
occurred during the user's ACK timeout; the root agent's current hardware
probe reports no UART errors. Changing its fail-close policy needs a separate
decision and fault-model validation.

## Authorized NimBLE close fix

The bridge now posts a persistent `ble_npl_event` to the default NimBLE host
queue. Its handler reads the atomic requested failed state and checks the
complete generation plus flags before choosing and terminating the connection.
Connect/disconnect callbacks run on that same host task. No bridge lock spans
the host call. `setup()` initializes the event after BLE initialization and
before advertising. The nonselected Bluedroid backend retains its old behavior.

UART callback attribution and its fail-close policy are unchanged and remain a
known limitation. Pins, UART speed, packet bytes, queue sizes and notification
behavior are unchanged.

`run_host_close_tests.py` executes the real before/after sketch with a private
host event queue shim. The shim models queued event deduplication, event
initialization, host task identity, and queued lifecycle callbacks before close
dispatch. Lifecycle changes cannot interrupt a host callback with another host
callback. It does not claim to simulate the controller, ESP32 scheduler, RF,
NPL allocation failures, or hardware UART delivery.

Accepted result:
`host-close_20261023_220707_498936/result.json`.

- Before: all 56 existing transport/diagnostic cases pass; the new different
  handle and reused handle close cases fail; the host-task assertion fails.
- After: 62/62 cases pass, including normal error close once, duplicate posts,
  reconnect after a completed host close, and replacing an old queued close
  with a new generation's own failure.
- Exact selected local SDK WRITE callback plus actual new sketch: 60/60 cases
  pass. The SDK was read-only; its WRITE functions were extracted unchanged
  into the deterministic test harness.
- Production freeze: `production-freeze.json`. Sketch SHA-256:
  `b46c363a91c186e388c3075e862e1b9b4a2bcc0d3cdcfa1afa65bcdc4d8c646e`.

No ESP32 target compilation, flashing or live BLE test was performed by this
review agent; the root agent owns those steps.
