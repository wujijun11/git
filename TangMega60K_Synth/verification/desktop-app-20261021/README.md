# TANG NEON STUDIO 1.0 verification

The Windows software was implemented for the current project's Remote Control
V1 wire protocol. Its UI design follows the supplied 8.14-second demonstration's
keyboard playing, virtual keys, sound presets and parameter controls, with a new
dark neon layout. Reference frames remain under `desktop/reference`, outside the
portable release.

## Checks completed

- `controller-tests.log`: real controller and protocol simulator, including full
  handshake, ACK/data ordering, duplicate sequence retry, generation isolation,
  errors, same-pitch references, release, expression coalescing, score cancellation
  and recorder semantics.
- `protocol-tests.log`: existing shared protocol CRC, framing, range checks,
  retries, sequence wrap, bounded queues and UUID parity.
- `native-tests.log`: ten host tests for native BLE/serial sequencing, stale
  generations, write deadlines, file operations and local resource isolation.
- `ui-smoke-result.json`: actual Chrome rendering and DOM operations against the
  shipped frontend plus controller demo. Includes 25 keys / 10 black keys, C4/C6
  command pitch, presets, expression, source63 recording, new-record cache
  invalidation, upload, built-in/custom source switching, cancelling a pending
  play, remapping, disconnect and responsive layout. No browser page errors.
  The final 1428x904 test also checks that the all-stop footer is visible.
- `packaged-smoke-test.json`: bundled executable imports its BLE, serial,
  WebView2 and Python components and finds the packaged frontend and icon.
- `build-manifest.json`: native host, executable and all shipped UI/asset/doc
  hashes. The executable hash alone is not enough to identify a release because
  frontend resources are external files inside `_internal`.

Screenshots include the actual Chromium UI at desktop/laptop sizes, curve
animation, connection dialog, score library and recorder. The live Windows
executable was separately launched and visually inspected using the computer-use
skill: the actual WebView2 window rendered the UI, opened the native connection
dialog and completed the explicitly labelled demo handshake.

## Hardware limits of this verification

The actual Windows app's native BLE scan completed and returned no matching
Tang-Synth-C3 devices during this run. No device was connected and no physical
FPGA command/ACK/audio path was validated from the new app. Protocol and transport
tests use explicit doubles; they are not radio or sound acceptance.

The FPGA hardware was left on the previously read-back full main user code0111.
No FPGA/C3 firmware was downloaded for this software task. The pre-existing
FPGA audio noise/key issues remain a separate hardware acceptance task.

The current protocol does not stream PCM, live physical touch masks or per-note
events. The UI correctly labels its normal canvas as event animation and its
optional audio spectrum as computer microphone input. Local preview sound is
computer synthesis, distinct from the FPGA sound engine.
