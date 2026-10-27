onerror {quit -f -code 1}
onbreak {quit -f -code 1}
catch {log /tb_remote_note_watchdog/clk}
catch {log /tb_remote_note_watchdog/rn}
catch {log /tb_remote_note_watchdog/hb}
catch {log /tb_remote_note_watchdog/expire}
catch {log /tb_remote_note_watchdog/acc}
catch {log /tb_remote_note_watchdog/on}
catch {log /tb_remote_note_watchdog/note}
catch {log /tb_remote_note_watchdog/rel}
catch {log /tb_remote_note_watchdog/ev}
catch {log /tb_remote_note_watchdog/eon}
catch {log /tb_remote_note_watchdog/ready}
catch {log /tb_remote_note_watchdog/en}
catch {log /tb_remote_note_watchdog/source}
catch {log /tb_remote_note_watchdog/vel}
catch {log /tb_remote_note_watchdog/timbre}
catch {log /tb_remote_note_watchdog/count}
catch {log /tb_remote_note_watchdog/offs}
catch {log /tb_remote_note_watchdog/released}
catch {log /tb_remote_note_watchdog/stalled}
catch {log /tb_remote_note_watchdog/stalled_payload}
catch {log /tb_remote_note_watchdog/dut/held}
catch {log /tb_remote_note_watchdog/dut/any_held}
catch {log /tb_remote_note_watchdog/dut/other_held}
catch {log /tb_remote_note_watchdog/dut/held_after_accept_any}
catch {log /tb_remote_note_watchdog/dut/silence}
catch {log /tb_remote_note_watchdog/dut/scan}
catch {log /tb_remote_note_watchdog/dut/event_valid}
run -all
quit -f -code 0
