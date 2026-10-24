# Temporary C3 TX pad observer

Prepared from the accepted production bridge without building, uploading, or operating hardware. The sketch directory contains only `ble_bridge.ino` and `bridge_uart_io.h`. Do not promote this interrupt observer into a release without separate review.

The candidate preserves RX GPIO6, TX GPIO7, UART1 115200 8N1, the existing byte-for-byte forwarding helpers, all BLE session and notification handling, and the exact existing 40-byte TB-v1 diagnostic characteristic. It adds no commands, replies, UART bytes, periodic UART traffic, pin scans, or rewiring.

## Narrow observation changes

1. After the original `Serial1.begin` and preparation, the observer snapshots GPIO7 IOMUX, GPIO7 output matrix, UART1 RX input matrix, and GPIO7 output enable. It calls the pinned ESP32-C3 `gpio_ll_input_enable(&GPIO,7)`, whose implementation sets only the IOMUX FUN_IE bit. It never calls `pinMode`, `gpio_config`, `gpio_set_direction`, `uart_set_pin`, or any output/matrix mutator.
2. A per-pin GPIO7 negative-edge ISR increments a `volatile uint32_t` inside the RISC-V port critical section. The ISR is IRAM attributed; it performs no logging, allocation, UART calls, or atomic-library operations. The object and counter are ordinary DRAM globals. All four ISR setup statuses are logged; `ESP_ERR_INVALID_STATE` from service installation means a service already existed, not that its allocation flags were inspected.
3. Before and after the original `bridgeUartTransmit` call, short register/counter snapshots are retained. These observations do not affect the send result, forwarding decision, session state, or response parser.
4. Only the existing five-second statistics branch formats and publishes a USB-only observation line. There is no new loop polling task, synthetic TX test, or per-transmit logging. `Serial` remains native USB CDC, not UART1.
5. The native USB TX ring is allocated at 1024 bytes before `Serial.begin`. The pinned HWCDC implementation otherwise defaults to 256 bytes; `availableForWrite` returns ring free space, not the 64-byte USB endpoint size. The long observation line plus the existing counters fit 1024 bytes. Each observation write is skipped unless the complete formatted line currently fits, and the existing 1 ms USB timeout remains. The `usb` field reports the allocation result; allocation failure or a nonreading host makes absent USB output inconclusive.

## Log fields

- `irq`: all ISR setup operations succeeded, or the ISR service already existed and remaining setup succeeded.
- `keep=init/tx`: IOMUX (except the deliberate FUN_IE change), complete TX and RX matrix words, and GPIO7 output enable matched across observer initialization / the most recent TX attempt. No TX yet yields `keep` TX=true by definition; inspect `n`.
- `route`: current GPIO7 IOMUX function is GPIO matrix, output signal is U1TXD without signal/OE inversion, GPIO7 OE is enabled, and U1RX reads GPIO6 without inversion.
- `edge`: cumulative GPIO7 negative-edge ISR count; `d`: the most recent send's unsigned after-minus-before count. Both wrap modulo 2^32.
- `L=pre/post`, `idle`: GPIO7 input-buffer feedback before/after the last send and at statistics time. `IE=0` yields level `-1`, never a fictitious zero. The before/after values are normally both high for idle 8N1, even when the packet transmitted correctly.
- `TX7`, `U1RX`, `MUX7`, `OE7`: current raw routing/enable registers and enable bit. `bootMUX`, `bootTX`, `bootRX`, `bootOE` are raw snapshots before/after observer initialization, allowing `keep` to be audited.
- `n`, `seq`, `op`: send attempt count and most recent packet sequence/opcode. `svc`, `type`, `add`, `en`: exact SDK results for setup.

Positive `d` with expected routing proves that the C3 input buffer observed activity at GPIO7 during that send. It does not prove the wire delivers it to FPGA, the analog voltage/noise margin, decoded bytes, or an ACK. A zero count is not itself proof of no physical TX: failed setup, masked/interrupted servicing, or external pad conditions must be considered. Under high interrupt/RF load individual edges can coalesce; this is not an exact UART decoder.

## Pinned local primary evidence

Paths below are relative to `C:/Users/asus/Desktop/Git/tmp/ble-build/data/packages/esp32`.

- `hardware/esp32/3.3.5/cores/esp32/esp32-hal-uart.c:396–414`: UART matrix TX selects GPIO function and connects U1TXD output, without ensuring the pad input buffer is enabled.
- `hardware/esp32/3.3.5/cores/esp32/esp32-hal-gpio.c:117–125`: Arduino `pinMode` clears the previous peripheral-manager bus, so it is deliberately avoided.
- `hardware/esp32/3.3.5/cores/esp32/esp32-hal-gpio.c:244–251`: Arduino's interrupt attachment explicitly enables the input buffer for peripheral outputs without changing the output signal.
- `tools/esp32-arduino-libs/idf-release_v5.5-9bb7aa84-v2/esp32c3/include/hal/esp32c3/include/hal/gpio_ll.h:199–202`: input enable only invokes `PIN_INPUT_ENABLE` on the pad IOMUX register; `:732–749` reads actual configuration registers.
- The same IDF include root, `esp_driver_gpio/include/driver/gpio.h:142–155`: input-disabled `gpio_get_level` always returns zero; `:296–340` documents ISR-service installation and pin handlers.
- The same root, `soc/esp32c3/include/soc/gpio_sig_map.h:26–27`: U1RXD and U1TXD matrix signal indexes are both 9. `soc/esp32c3/register/soc/gpio_struct.h:183–191,320–329` defines matrix fields. `soc/io_mux_reg.h:119–120` sets GPIO function to 1.
- The same root, `freertos/FreeRTOS-Kernel/portable/riscv/include/freertos/portmacro.h:529–541`: single-core critical and ISR-critical macros share the port critical API.
- `hardware/esp32/3.3.5/cores/esp32/HWCDC.cpp:304–320,399–432`: default 256-byte TX ring, explicit ring allocation, and free-space query.

No esptool runtime-register reading is proposed: entering its ROM/stub loader would reset/replace the running application state. No eFuse or JTAG selection is changed.

## Build only, if root chooses to use the candidate

Use Arduino-ESP32 3.3.5 and the project-local patched BridgeBLE library. The standard build script hardcodes the production sketch; do not use it for this isolated candidate. Before the command, create the sketch-relative `build/esp32.esp32.waveshare_esp32_c3_zero` directory needed by the pinned Windows savehex hook.

```powershell
$project='C:/Users/asus/Desktop/Git/TangMega60K_Synth'
$sketch="$project/verification/uart-live-debug-20261023/c3-tx-observation-source/ble_bridge"
New-Item -ItemType Directory -Force -Path "$sketch/build/esp32.esp32.waveshare_esp32_c3_zero" | Out-Null
& 'C:/Users/asus/Desktop/Git/tmp/ble-build/arduino-cli.exe' --no-color --config-file 'C:/Users/asus/Desktop/Git/tmp/ble-build/arduino-cli.yaml' compile --fqbn 'esp32:esp32:waveshare_esp32_c3_zero:CDCOnBoot=default,FlashSize=4M' --jobs 4 --warnings more --library "$project/firmware/libraries/BridgeBLE" --build-path "$project/verification/uart-live-debug-20261023/c3-tx-observation-build" --output-dir "$project/verification/uart-live-debug-20261023/c3-tx-observation-output" $sketch
```

The uncompiled source has only static/source review. Compilation must confirm API/format compatibility and the final ELF/map should confirm the observer ISR and critical-section call path are IRAM-safe. Never infer successful physical observation from an unbuilt candidate. The accepted production C3 app remains available for exact app-only restoration in `verification/ble-connection-fix-20261023/c3-firmware/ble_bridge.ino.bin`; preserve that file and its existing recorded digest.
