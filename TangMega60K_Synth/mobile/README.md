# Tang Synth phone control

`web/` is a complete control client with real Web Bluetooth connections,
capability detection and an explicitly labelled software simulator. `android/`
is a native Java Android BLE host for the same local UI. It scans the fixed
NUS service, lets you choose a peripheral, discovers GATT characteristics,
enables CCCD notifications and performs writes with response. The bridge
firmware lives in `../firmware/ble_bridge/`.

For a Huawei phone, use the native Android app **only if its actual system
supports Android APKs**. This project does not establish compatibility with
HarmonyOS NEXT; there is no native HarmonyOS NEXT implementation. No phone
device was tested. The user confirmed HarmonyOS4/EMUI with Android APK support
on 2026-10-11; installation and radio acceptance remain pending. The Android
source uses minSdk 23, requires a WebView with modern JavaScript support
(Chrome/WebView 76+ recommended), and handles pre-Android12 location permission
as well as Android12+ Bluetooth scan/connect permissions.

## Run without hardware

From `mobile/web`, run `python -m http.server 8080 --bind 127.0.0.1`, open
`http://localhost:8080`, then choose **协议模拟（无硬件）**. The simulator can
exercise mapping, note press/release, score upload, record retrieval/export and
guide commands. It does not generate instrument audio or emulate real LEDs.
`navigator.bluetooth` must be supported and the page must be HTTPS/localhost
for a browser to connect to BLE. A LAN HTTP address does not satisfy the
secure-context requirement. Browser score servers must allow CORS; the native
Android HTTPS downloader is available when running the APK.

## Native APK and reproducible build

Open `android/` in Android Studio with JDK 17, Android SDK 35 and Gradle 8.9.
The project pins Android Gradle Plugin 8.7.3 and uses no AndroidX dependency.
Assets are taken directly from `../../web` by the app module; there are no
duplicate UI copies. A real development APK is now at
`android/output/TangSynthRemote-debug.apk`. On 2026-10-11 the application was
compiled with JDK21, Gradle8.9, AGP8.7.3, SDK35/build-tools35.0.0. A fresh
`assembleDebug` + `lintDebug` run passed with zero lint errors and warnings;
`apksigner verify` passed the v1 and v2 signatures. SHA256:
`5470a25fb92913437d1f7245ec511b8da3bd01e0d38bbf1f1b15b4d9b731062f`.
The signer is a local development key, not a store release certificate.
No phone installation, RF connection or real GATT test has been performed.

From the repository root use:

```powershell
./scripts/build-android.ps1 -JavaHome 'C:/path/to/jdk-17-or-21' -Python python
```

The helper installs pinned tools in a workspace directory and verifies their
official archive checksums. Subsequent builds accept `-Offline`; add
`-RerunChecks` when a fresh lint report is needed. Android Studio's
`assembleDebug` / `lintDebug` workflow is also supported. The optional
`-InitScript` supports a local repository transport on machines with Java TLS
problems; it is not required on a normal network. Source and build scripts
belong in Git; tool caches, development keys and generated APKs are excluded.

BLE operations handle permission revocation during scan, service discovery,
write and disconnect. The native bridge is restricted to packaged assets on
both old and new WebView navigation APIs. Remote HTTPS score responses are
JSON data and cannot navigate the privileged WebView.

On Android 23..30 allow location permission and enable the system's location
switch for BLE discovery. On Android 31+ allow nearby Bluetooth devices.
Connect to `Tang-Synth-C3`; the app waits for notifications and a FPGA
readback handshake before marking the connection ready. Normal disconnect
sends Panic first. Reconnect performs a read-only probe, then a new-sequence
Panic to clear uncertain held notes, and reapplies all visible mappings,
timbre, effect and expression settings.

## Controls and data

- 25 independently editable key->MIDI mappings, default 60..84.
- Four timbres, gain Q1.11, signed bend cents, vibrato cents and four effects.
- Gain/bend/vibrato sliders transmit while dragging, at most once per 40ms.
  One request may be in flight; unsent updates merge into the latest snapshot.
  Only changed dimensions are masked in, so gain/vibrato do not overwrite a
  physical slider's bend. Disconnect cancels trailing updates, and window blur
  releases held phone notes.
- HTTPS online JSON loading or a selected local JSON file, strict row checks,
  sequential SCORE_WRITE and final SCORE_COMMIT. Capacity 256 rows.
- FPGA event recording, stop/readback of up to 1024 rows, JSON export and
  FPGA event replay for recordings of physical keys (sources25..49).
  Phone-note recordings remain exportable but local replay is rejected.
  Exported event JSON preserves MIDI/source/timbre;
  it differs from the key-based score upload schema and is not PCM.
- Built-in score selection, score playback and LED guide start/stop.

See `examples/score.json` for score input. Every `deltaMs` is the delay from
the preceding event. All numeric fields must be integers; key 0..24,
velocity 0..127, on 0/1, uint32 delta. A successfully submitted score activates
only after every row receives an ACK and SCORE_COMMIT is accepted.

One command is in flight. ACK timeout is 1500 ms, with two retries of the exact
same sequence/op/payload. GATT completion and ACK must both complete before
the next write. A transport write has a separate 4000 ms deadline, including
when its ACK arrives early; a stuck write closes the session without retrying
another GATT operation concurrently. Queued payloads are copied and validated
at send time, so invalid input cannot strand the queue. The sequence advances modulo 256 and is persisted when local
storage is available. FPGA caches the most recently accepted transaction:
identical repeats return the cached ACK and optional readback, while a same
sequence with different command data yields bad-argument. A reconnect's
read-only probe advances once more after a sequence conflict; it never
replays an uncertain NOTE command. The first telemetry sample may be cached
after a reconnect, so a new-sequence Panic and fresh telemetry follow it.
Readbacks wait for both ACK 80 and data 81/82 with the same sequence.
Score upload snapshots the loaded document; replacing that document midway
does not mix scores. Upload, handshake and record readback stay bound to their
original session and cannot continue sending to a replacement connection.
Browser notification/disconnect callbacks also retain their device and session;
late chooser or discovery results are discarded after cancellation. Phone keys
mapped to one MIDI pitch send one NoteOn and only the last pointer sends NoteOff,
using the original pitch even if the mapping changes while held. Map, Panic and
record-clear UI commits verify their original session after the ACK.

For native callback queue regression with an installed JDK and Android SDK:
`python mobile/tests/test_android_callbacks.py --java-home <JDK> --android-jar <SDK>/platforms/android-35/android.jar`.
This runs the actual compiled MainActivity callbacks with host UI/WebView
doubles. It checks reconnect ordering and late results after destruction, and
does not claim a phone or wireless test.

While the app is visible it sends telemetry readback every second. Background
apps do not continue holding phone notes through a stopped heartbeat. FPGA
must implement source 63 communication expiry to recover RF failures and
bridge/client overflow. Client queue overflow closes the session visibly.

## Checks actually run

`../scripts/test-remote-mobile.ps1` runs JavaScript syntax checks, protocol
CRC/frame/range/retry/wrap/queue tests, a minimal-DOM simulation of controller
workflows, and 2000 independent Python/JS CRC vectors. These passed. UUIDs
are checked for consistency across JS, Java codec and firmware. These checks
do not substitute for browser rendering, GATT RF testing or hardware timing
measurements. Native APK compilation and lint have additionally passed.

Official API references used:

- [Android GATT connection](https://developer.android.com/develop/connectivity/bluetooth/ble/connect-gatt-server)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Android Gradle Plugin 8.7 requirements](https://developer.android.com/build/releases/agp-8-7-0-release-notes)
- [Web Bluetooth specification](https://webbluetoothcg.github.io/web-bluetooth/)
- [Espressif BLE UART](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/ble.html)
