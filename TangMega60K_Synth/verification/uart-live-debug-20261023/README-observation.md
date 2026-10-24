# Passive full-main UART GAO observation

`observation-source/` is a frozen copy of all 81 enabled full-main inputs.
Production files and earlier build snapshots were not modified. The three RTL
changes add observation outputs/counters; the fourth changed input gives the
same 48-wire analyzer a distinct GAO configuration ID, `0x5544`.

The ID is the analyzer configuration ID, not the compiled FPGA UserCode.
`source-inputs.json`, `baseline-inputs.json` and `observation.diff` identify the
exact frozen inputs and changes. `prepare_uart_gao.py` refuses an existing copy.

## Behavior and CDC

All 25 touch keys, 64-voice synthesis, score, audio/video, command router, UART
parser/FIFO/transmitter and pin constraints remain the existing main system.
There is no diagnostic UART sender, generated ACK, pin substitution, modified
clock/reset, or changed timing exception. The observation outputs never drive
functional state or an external pin.

Event counters run in the existing UART/audio clock domain. RX falling edges
use the receiver's existing second synchronizer stage, so there is no new raw
RX-to-counter path. UART RX/TX levels and counters pass through the original
`debug_status_meta`/`debug_status` two-stage observation sampler at `sys_clk`.
As before, multi-bit values may tear during transitions: compare stable runs
after a transaction is finished. The original bounded first-stage CDC timing
exception remains unchanged. Second-stage/capture paths remain timed.

## Packed `debug_status[47:0]`

| Bits | Meaning | Increment/reset |
| --- | --- | --- |
| 0 | Board ready | Existing state |
| 1 | Audio PLL locked | Existing state |
| 2 | Ready synchronized into audio domain | Existing state |
| 3 | Main reset released (`rst_n`) | Existing state |
| 4 | Physical UART RX input level | Normally 1 when idle |
| 5 | UART TX output level | Normally 1 when idle |
| 13:6 | Synchronized RX falling-edge count | Modulo 256 |
| 21:14 | Valid received UART-byte count | Modulo 256 |
| 29:22 | Last valid UART byte | Most recent byte, reset 0 |
| 32:30 | Commands consumed by router | `cmd_valid && cmd_ready`, modulo 8 |
| 35:33 | Responses accepted by transport | `rsp_valid && rsp_ready`, modulo 8 |
| 43:36 | Physical UART bytes started | `tx_start && !tx_busy`, modulo 256 |
| 44 | CRC error count is nonzero | Existing transport count |
| 45 | Framing/version error count is nonzero | Existing transport count |
| 46 | Command FIFO overflow count is nonzero | Existing transport count |
| 47 | Partial-packet timeout count is nonzero | Existing transport count |

All observation totals reset with the transport's existing reset. Error flags
reflect the existing 32-bit counts; only a 32-bit rollover could clear one
without reset. Idle with cleared counters and low four ready bits set is
`00000000003F`.

## Acquire before and after one existing BLE READBACK

1. Build the frozen source with the existing isolated build script, using the
   current accepted full-main report as baseline. Root agent owns compilation
   and device actions. Require strict build/GAO/STA acceptance before loading.
2. Open this copy's `main_status.rao` with its actual generated bitstream; keep
   programmer disabled during capture. Start and export an idle snapshot.
3. Run one existing BLE READBACK request, let it finish or time out, then start
   and export a second snapshot. Do not reset/reprogram between captures.
4. Decode and compare stable runs with `decode_uart_gao.py`. It specifically
   finds the CSV Data/time-unit header, skips unknown samples and does not
   misread the preceding Groups declaration as sample data.

At 50 MHz the 2048 samples span approximately 40.96 us. CSV export clock period
is a display setting, not a measured board clock; counters retain the complete
transaction evidence after the frame has passed.

For exactly one 16-byte READBACK (`0x08`, selector 0), the normal path should
increase RX valid bytes by 16, router commands by 1, transport responses by 2
(ACK plus telemetry), and TX started bytes by 32. The recent RX byte should be
the request CRC. Physical falling-edge delta depends on the actual request
sequence/CRC bytes. A desktop retry may send three requests, so compare the
actual C3 diagnostic sent-frame delta and actual wire request(s).

| Stable change | Interpretation |
| --- | --- |
| No RX edges or bytes while C3 says UART frames sent | FPGA's assigned RX input sees no toggling; investigate actual physical endpoint/path and pad configuration |
| Edges increase, valid bytes do not | RX activity reaches the pin but receiver does not decode; check line level, baud, clock and framing evidence |
| Valid bytes increase, commands do not | Check request bytes/CRC, parser errors, partial-packet timeout, or router acceptance/backpressure |
| Commands increase, responses do not | Router/control response path stalls |
| Responses increase, TX started bytes do not | Transport/transmitter scheduling stalls |
| TX started bytes increase by 32 but C3 still receives zero bytes | Response leaves FPGA UART logic; inspect physical TX pad/header-to-C3 RX path |

The final row proves internal TX scheduling, not electrical voltage or correct
external wiring by itself. The RX/TX static level bits similarly do not replace
an oscilloscope measurement.

## Commands

From the project directory (PowerShell):

```powershell
& 'tmp/desktop-python/Scripts/python.exe' 'scripts/build-contest-isolated.py' --variant uart-gao-passive --source-root 'verification/uart-live-debug-20261023/observation-source' --output-root 'verification/uart-live-debug-20261023/fpga-build' --baseline 'verification/code-hardening-20261023/fpga-build/build_uart-prefix-recovery_20261023_094225_1ccb041d/build-results.json'
& 'tmp/desktop-python/Scripts/python.exe' 'verification/uart-live-debug-20261023/decode_uart_gao.py' --before 'BEFORE_CORE0.csv' --after 'AFTER_CORE0.csv' --output 'NEW_RESULT.json'
```

`passive-equivalence.log` records the UART-only cycle comparison against the
namespaced untouched current main transport. This simulation is distinct from
the required Gowin full-main STA and actual hardware capture.
