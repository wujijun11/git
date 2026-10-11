# Remote control V1 integration contract

This is a new implementation contract, not a claim of hardware acceptance.
The FPGA owns synthesis, score timing, guide generation and event recording.
An optional BLE bridge only forwards control packets and notifications.
No PCM samples are uploaded or replayed as the sound source.

## Transport

UART: 115200 baud, 8 data bits, no parity, 1 stop bit, 3.3 V logic.
One packet is exactly 16 bytes and fits a default BLE ATT payload.

| Byte | Meaning |
| --- | --- |
| 0..1 | A5 5A synchronization |
| 2 | version = 01 |
| 3 | transaction sequence |
| 4 | opcode |
| 5..14 | payload p0..p9 |
| 15 | CRC-8, polynomial 07, init 00, no reflection/xorout, bytes 2..14 |

Multi-byte numbers are little endian. Unused payload bytes must be zero.
Send one request at a time and wait for ACK/NACK; transport errors do not
produce instrument events. The router caches the single most recent
sequence/opcode/payload and its ACK plus optional readback. An exact retry
returns that cached response without repeating mutation. The same sequence
with different data is rejected; new sequence values wrap modulo 256.
Reconnect probes readback, advances past a conflict, sends a new-sequence
PANIC and reapplies configuration. This is not an arbitrary reorder window.

ACK opcode 80: p0=request opcode, p1=status (0=accepted, 1=bad argument,
2=busy, 3=unsupported, 4=overflow). Remaining bytes are zero.
READBACK sends ACK 80 followed by telemetry 81 or record 82 with the same
sequence. The client waits for both packets before its next request.
Invalid version/CRC/framing is discarded and counted; never ACK as success.

## Commands

| Op | Name | Payload |
| --- | --- | --- |
| 01 | NOTE | p0=source 0..63; p1=MIDI 0..127; p2=velocity 0..127; p3=timbre 0..3; p4=on 0/1 |
| 02 | EXPRESSION | p0=mask (gain=1,bend=2,vibrato=4); p1..2=gain Q1.11; p3..4=signed int16 bend cents; p5=vibrato cents |
| 03 | CONFIG | p0=target (0=timbre,1=effect); p1=value (timbre0..3; effect0=dry,1=delay,2=reverb,3=chorus) |
| 04 | TRANSPORT | p0=action: 0=stop,1=score play,2=record start,3=record stop,4=record clear,5=panic,6=guide start,7=guide stop,8=record replay |
| 05 | MAP | p0=physical key0..24; p1=MIDI0..127 |
| 06 | SCORE_WRITE | p0..1=row index; p2..5=delta milliseconds; p6=key0..24; p7=velocity0..127; p8=on0/1 |
| 07 | SCORE_COMMIT | p0..1=row count; p2=source0=user RAM,1=built-in; must not activate partially written rows |
| 08 | READBACK | p0=selector0=telemetry,1=record row; p1..2=record index |

Recorded NOTE response 82: p0..1=index, p2..5=delta milliseconds,
p6=source, p7=MIDI, p8=velocity, p9=flags (bit0=on, bits2:1=timbre).
Telemetry 81: p0=active voices, p1=flags (bit0=playing,bit1=recording,
bit2=guide,bit3=overflow); p2..3=recorded row count;
p4..7=audio underrun count; p8..9=score position.

## RTL boundaries

All logic-level modules below run on a common clock; default audio clock is
49,152,000 Hz. Inputs and outputs use ready/valid with stable payload while
stalled. Board wrappers own asynchronous-input synchronization, PLL reset,
actual pin constraints and physical voltage checks.

- `remote_uart_transport`: `rx`, `tx`, `cmd_valid/ready`, `cmd_seq[7:0]`,
  `cmd_opcode[7:0]`, `cmd_payload[79:0]`, `rsp_valid/ready`, `rsp_seq`,
  `rsp_opcode`, `rsp_payload`; expose CRC/framing/overflow counters.
- Score/recorder/guide modules exchange existing note event fields:
  `on`, `source[5:0]`, `note[6:0]`, `velocity[6:0]`, `timbre[1:0]`.
  A 25-bit physical-key mask is the guide output; mapping uses MIDI60..84
  by default and all 25 map entries can be customized.
- MPR121 upstream produces validated per-module touch snapshots and
  filtered/baseline readings. The key eventizer maps 8/8/9 used electrodes
  to sources25..49. Score playback owns 0..24; the phone is forced to source63
  and may hold multiple different MIDI notes. Four slider electrodes are MPR1 ELE8..11 and produce
  an independent bend expression. A lost module releases only its own keys.

Every new module needs protocol/error/ready-backpressure/reset tests.
No module may silently drop a held note-off. A resource overflow must be
reported and trigger an explicit release/reset recovery path.

The phone sends a telemetry heartbeat every second while visible. Three
seconds without a valid command, or UART overflow, releases phone-owned
notes through the same backpressure-safe arbiter. New phone commands wait
until that release scan completes; physical and score notes remain owned.
Recording stores note events, not PCM. Readback supports every recorded
source. Local recorded replay accepts physical sources25..49, remapping them
to score sources0..24; a recording containing phone source63 is exportable
but its local replay is rejected as bad-argument.

Global PANIC resets the sound engine and drains old MPR, score, phone and
watchdog events through discard handshakes. New UART commands stay in their
FIFO until the producers are idle for 32 audio clocks. Router ACKs and score
RAM are retained. Physical keys held during PANIC are quarantined until
released; fresh presses and commands are then accepted normally. UART and
local PANIC share this behavior. This was tested with stalled producers and
an actual UART command FIFO, rather than only an empty idle system.
