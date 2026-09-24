onerror {quit -f -code 1}
onbreak {resume}
cd ..
# Keep paths relative: older Windows Tcl versions can mis-normalize Desktop.
set instrument_modelsim_ini sim/modelsim_local.ini
set env(MODELSIM) $instrument_modelsim_ini
if {![file isdirectory sim/instrument_work]} {vlib sim/instrument_work}
vlog -modelsimini $instrument_modelsim_ini -work sim/instrument_work rtl/event_fifo_v2.v rtl/interaction_top_v2.v rtl/voice_allocator_v2.v rtl/expression_controls_v2.v rtl/captain_control_top_v2.v rtl/i2s_tx.v rtl/captain_system_top_v2.v
vlog -modelsimini $instrument_modelsim_ini -work sim/instrument_work rtl/audio/voice_state_ram.v rtl/audio/wavetable_rom.v rtl/audio/dds_lane.v rtl/audio/adsr.v rtl/audio/pitch_expression.v rtl/audio/stereo_mixer.v rtl/audio/gain_saturator.v rtl/audio/audio_fx.v rtl/audio/polar_lane.v rtl/audio/fm_piano_lane.v rtl/audio/voice_engine.v rtl/audio/audio_system_v2.v rtl/instrument_system_v2.v
vlog -modelsimini $instrument_modelsim_ini -sv -work sim/instrument_work sim/tb_instrument_system_v2.sv
foreach timbre {0 2 3} {
    vsim -modelsimini $instrument_modelsim_ini -onfinish stop -voptargs="+acc" -gTIMBRE=$timbre sim/instrument_work.tb_instrument_system_v2
    run -all
    if {[examine -radix unsigned /tb_instrument_system_v2/test_passed] != 1} {quit -f -code 1}
    quit -sim
}
quit -f -code 0
