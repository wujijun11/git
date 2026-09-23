onerror {quit -f -code 1}
onbreak {resume}
if {![file isdirectory sim/live64_work]} {vlib sim/live64_work}
vlog -sv -work sim/live64_work rtl/audio/voice_state_ram.v rtl/audio/wavetable_rom.v rtl/audio/dds_lane.v rtl/audio/adsr.v rtl/audio/pitch_expression.v rtl/audio/stereo_mixer.v rtl/audio/gain_saturator.v rtl/audio/audio_fx.v rtl/audio/polar_lane.v rtl/audio/voice_engine.v rtl/audio/audio_system_v2.v rtl/voice_allocator_v2.v rtl/expression_controls_v2.v rtl/captain_control_top_v2.v rtl/captain_system_top_v2.v rtl/i2s_tx.v rtl/diagnostics/live64_event_source.v rtl/diagnostics/live64_system_top.v
vlog -sv -work sim/live64_work sim/tb_live64_source.sv sim/tb_live64_spectrum.sv sim/tb_audio_edgecases.sv
vsim -onfinish stop -voptargs=+acc sim/live64_work.tb_live64_source
run -all
if {[examine -radix unsigned /tb_live64_source/test_passed] != 1} {quit -f -code 1}
quit -sim
vsim -onfinish stop -voptargs=+acc sim/live64_work.tb_audio_edgecases
run -all
if {[examine -radix unsigned /tb_audio_edgecases/test_passed] != 1} {quit -f -code 1}
quit -sim
vsim -onfinish stop -voptargs=+acc sim/live64_work.tb_live64_spectrum
run -all
if {[examine -radix unsigned /tb_live64_spectrum/test_passed] != 1} {quit -f -code 1}
quit -f -code 0
