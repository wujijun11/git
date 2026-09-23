onerror {quit -f -code 1}
onbreak {resume}
if {![file isdirectory sim/eight_work]} {vlib sim/eight_work}
vlog -sv -work sim/eight_work rtl/audio/voice_state_ram.v rtl/audio/wavetable_rom.v rtl/audio/dds_lane.v rtl/audio/adsr.v rtl/audio/pitch_expression.v rtl/audio/stereo_mixer.v rtl/audio/gain_saturator.v rtl/audio/audio_fx.v rtl/audio/fm_piano_lane.v rtl/audio/polar_lane.v rtl/audio/voice_engine.v rtl/audio/audio_system_v2.v rtl/voice_allocator_v2.v rtl/expression_controls_v2.v rtl/captain_control_top_v2.v rtl/captain_system_top_v2.v rtl/i2s_tx.v sim/tb_eight_regions.sv sim/tb_audio_engine.sv sim/tb_audio_i2s.sv sim/tb_fm_keyboard.sv
vsim -onfinish stop -voptargs=+acc sim/eight_work.tb_eight_regions
run -all
if {[examine -radix unsigned /tb_eight_regions/test_passed] != 1} {quit -f -code 1}
quit -sim
foreach n {4 64} {
    vsim -onfinish stop -voptargs=+acc sim/eight_work.tb_audio_engine -gN=$n -gPOLAR=1
    run -all
    if {[examine -radix unsigned /tb_audio_engine/test_passed] != 1} {quit -f -code 1}
    quit -sim
}
vsim -onfinish stop -voptargs=+acc sim/eight_work.tb_audio_i2s -gTIMBRE_OVERRIDE=2
run -all
if {[examine -radix unsigned /tb_audio_i2s/test_passed] != 1} {quit -f -code 1}
quit -sim
vsim -onfinish stop -voptargs=+acc sim/eight_work.tb_fm_keyboard -gTIMBRE=2 -gHOLD_FRAMES=48000 -gRELEASE_FRAMES=9600
run -all
if {[examine -radix unsigned /tb_fm_keyboard/test_passed] != 1} {quit -f -code 1}
quit -sim
# Pure FM retains its own path. Recheck the existing 4/64 voice regressions.
foreach n {4 64} {
    vsim -onfinish stop -voptargs=+acc sim/eight_work.tb_audio_engine -gN=$n -gFM=1
    run -all
    if {[examine -radix unsigned /tb_audio_engine/test_passed] != 1} {quit -f -code 1}
    quit -sim
}
quit -f -code 0
