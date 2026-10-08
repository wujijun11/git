# Interactive 6 ms preview of the integrated 64-voice piano and I2S path.
# Run with: do sim/view_eight_piano_wave.do
# This preview does not replace the full release/delay regression.
onerror {abort}
onbreak {abort}
set piano_root [file normalize [pwd]]
if {![file exists [file join $piano_root sim tb_audio_i2s.sv]]} {
    error "Run this script from the TangMega60K_Synth project directory."
}
cd $piano_root
set piano_result [file join $piano_root sim audio_results piano_preview_[clock format [clock seconds] -format %Y%m%d_%H%M%S]_[pid]]
file mkdir $piano_result
transcript file [file join $piano_result transcript.log]
transcript on
puts "PIANO PREVIEW DIRECTORY: $piano_result"
set piano_lib [file join $piano_result work]
vlib $piano_lib
set piano_sources {rtl/audio/voice_state_ram.v rtl/audio/wavetable_rom.v rtl/audio/dds_lane.v rtl/audio/adsr.v rtl/audio/pitch_expression.v rtl/audio/stereo_mixer.v rtl/audio/gain_saturator.v rtl/audio/audio_fx.v rtl/audio/fm_piano_lane.v rtl/audio/polar_lane.v rtl/audio/voice_engine.v rtl/audio/audio_system_v2.v rtl/voice_allocator_v2.v rtl/expression_controls_v2.v rtl/captain_control_top_v2.v rtl/captain_system_top_v2.v rtl/i2s_tx.v sim/tb_audio_i2s.sv}
eval vlog -modelsimini [list [file join $piano_root sim modelsim_local.ini]] -sv -work [list $piano_lib] $piano_sources
vsim -modelsimini [file join $piano_root sim modelsim_local.ini] -onfinish stop -voptargs=+acc -wlf [file join $piano_result live.wlf] $piano_lib.tb_audio_i2s -gTIMBRE_OVERRIDE=2
view wave
add wave -divider {64-voice piano: startup and errors}
add wave sim:/tb_audio_i2s/rst_n
add wave -radix unsigned sim:/tb_audio_i2s/timbre sim:/tb_audio_i2s/active_count sim:/tb_audio_i2s/underruns sim:/tb_audio_i2s/checked
add wave sim:/tb_audio_i2s/full_pulse sim:/tb_audio_i2s/done_error
add wave -divider {24-bit signed stereo PCM}
add wave -radix decimal sim:/tb_audio_i2s/dut/sample_left sim:/tb_audio_i2s/dut/sample_right
add wave sim:/tb_audio_i2s/dut/sample_valid sim:/tb_audio_i2s/dut/sample_ready
add wave -divider {Philips I2S: 1-bit delay + 24 data + 7 padding}
add wave sim:/tb_audio_i2s/bclk sim:/tb_audio_i2s/ws sim:/tb_audio_i2s/data_out
add wave -radix unsigned sim:/tb_audio_i2s/dut/u_captain/u_audio/bit_index
add wave -radix hexadecimal sim:/tb_audio_i2s/expected_frame
add wave -divider {Expression changes after frame 200}
add wave -radix unsigned sim:/tb_audio_i2s/dut/active_gain
add wave -radix decimal sim:/tb_audio_i2s/dut/active_bend_cents
add wave -radix unsigned sim:/tb_audio_i2s/dut/active_vibrato_cents
configure wave -signalnamewidth 1 -namecolwidth 250 -valuecolwidth 120 -timelineunits us
vcd file [file join $piano_result i2s_preview.vcd]
vcd add /tb_audio_i2s/rst_n /tb_audio_i2s/active_count /tb_audio_i2s/underruns /tb_audio_i2s/full_pulse /tb_audio_i2s/done_error /tb_audio_i2s/bclk /tb_audio_i2s/ws /tb_audio_i2s/data_out /tb_audio_i2s/expected_frame /tb_audio_i2s/dut/sample_left /tb_audio_i2s/dut/sample_right
run 6 ms
vcd flush
vcd off
set piano_checked [examine -radix unsigned /tb_audio_i2s/checked]
if {$piano_checked < 200 || [examine -radix unsigned /tb_audio_i2s/active_count] != 64 || [examine -radix unsigned /tb_audio_i2s/underruns] != 0 || [examine -radix unsigned /tb_audio_i2s/nonzero] == 0} {
    error "Piano preview checkpoint failed; inspect the transcript."
}
dataset save sim [file join $piano_result preview.wlf]
wave zoom range 2000us 2065us
wave cursor time -time 2017us
write format wave [file join $piano_result layout.do]
set piano_summary [open [file join $piano_result summary.txt] w]
puts $piano_summary "6 ms preview only; full release/delay regression is not complete."
foreach piano_sig {active_count checked nonzero underruns full_pulse done_error test_passed} {
    puts $piano_summary "$piano_sig=[examine -radix unsigned /tb_audio_i2s/$piano_sig]"
}
close $piano_summary
puts "PIANO 6 MS PREVIEW CHECKPOINT PASSED: $piano_result"
puts "The full test_passed flag remains 0 until the complete regression finishes."
onbreak {}
