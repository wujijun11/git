# Usage: do {path/to/view_full_modelsim.do} {path/to/verified/full_system.wlf}
# A successful regression also writes a self-contained view_full_system.do
# beside its manifest. This viewer uses only Tcl/ModelSim commands.
if {![info exists 1]} {
    error "Supply the full_system.wlf from a verified ModelSim regression run."
}
set verified_full_wave [set 1]
if {![file isfile $verified_full_wave]} {
    error "Verified waveform file does not exist: $verified_full_wave"
}
vsim -view $verified_full_wave
view wave
configure wave -namecolwidth 270
configure wave -valuecolwidth 120
configure wave -timelineunits us
add wave -divider {64 voices and audio stream}
foreach signal {clk rn voices underruns pcm_valid pl pr bc lr sd} {
    catch {add wave /tb_instrument_full_system/$signal}
}
add wave -divider {Local actions and performance}
foreach signal {local_v local_ready local_action playing recording guide overflow rx tx led} {
    catch {add wave /tb_instrument_full_system/$signal}
}
add wave -divider {Control, effects and global panic}
foreach signal {panic panic_request panic_quiescing panic_discard audio_rst_n gain bend vibrato fx cv cr co cs cmdv cmdr fx_valid fx_ready fx_l fx_r} {
    catch {add wave /tb_instrument_full_system/dut/$signal}
}
add wave -divider {Note arbitration and monitor CDC}
foreach signal {remote_ev remote_er sensor_ev sensor_er sensor_pending perf_ev perf_er watchdog_ev watchdog_er phone_releasing push_valid push_ready push_payload arb_selected vsample vl vr cdc_drops} {
    catch {add wave /tb_instrument_full_system/dut/$signal}
}
catch {wave zoom full}
puts "Opened saved full-system waveform: $verified_full_wave"
