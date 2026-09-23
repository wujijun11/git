onerror {quit -f -code 1}
onbreak {resume}
if {![file isdirectory sim/fm_keyboard_work]} {vlib sim/fm_keyboard_work}
vlog -sv -work sim/fm_keyboard_work rtl/audio/voice_state_ram.v rtl/audio/wavetable_rom.v rtl/audio/dds_lane.v rtl/audio/adsr.v rtl/audio/pitch_expression.v rtl/audio/stereo_mixer.v rtl/audio/gain_saturator.v rtl/audio/audio_fx.v rtl/audio/fm_piano_lane.v rtl/audio/polar_lane.v rtl/audio/voice_engine.v rtl/voice_allocator_v2.v rtl/expression_controls_v2.v rtl/captain_control_top_v2.v sim/tb_fm_keyboard.sv
vsim -onfinish stop -voptargs=+acc sim/fm_keyboard_work.tb_fm_keyboard
run -all
if {[examine -radix unsigned /tb_fm_keyboard/test_passed] != 1} {quit -f -code 1}
quit -f -code 0
