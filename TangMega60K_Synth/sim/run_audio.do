onerror {quit -f -code 1}
onbreak {resume}
if {![file isdirectory sim/audio_work]} {vlib sim/audio_work}
vlog -work sim/audio_work rtl/audio/voice_state_ram.v rtl/audio/wavetable_rom.v rtl/audio/dds_lane.v rtl/audio/adsr.v rtl/audio/pitch_expression.v rtl/audio/stereo_mixer.v rtl/audio/gain_saturator.v rtl/audio/audio_fx.v rtl/audio/polar_lane.v rtl/audio/voice_engine.v rtl/audio/audio_system_v2.v
vlog -work sim/audio_work rtl/voice_allocator_v2.v rtl/expression_controls_v2.v rtl/captain_control_top_v2.v rtl/captain_system_top_v2.v rtl/i2s_tx.v
vlog -sv -work sim/audio_work sim/tb_audio_engine.sv sim/tb_audio_units.sv sim/tb_audio_i2s.sv
vsim -onfinish stop -voptargs=+acc sim/audio_work.tb_audio_units
run -all
if {[examine -radix unsigned /tb_audio_units/test_passed] != 1} {quit -f -code 1}
quit -sim
vsim -onfinish stop -voptargs=+acc -gN=4 sim/audio_work.tb_audio_engine
run -all
if {[examine -radix unsigned /tb_audio_engine/test_passed] != 1} {quit -f -code 1}
quit -sim
vsim -onfinish stop -voptargs=+acc -gN=64 sim/audio_work.tb_audio_engine
run -all
if {[examine -radix unsigned /tb_audio_engine/test_passed] != 1} {quit -f -code 1}
quit -sim
vsim -onfinish stop -voptargs=+acc sim/audio_work.tb_audio_i2s
run -all
if {[examine -radix unsigned /tb_audio_i2s/test_passed] != 1} {quit -f -code 1}
quit -sim
puts "ALL AUDIO TESTS PASSED"
quit -f -code 0
