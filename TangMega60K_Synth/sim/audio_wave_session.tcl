# Loaded completely before simulation starts; do not edit an active run.
namespace eval ::audio_wave {
    # The public .do entry requires the project root as the working directory.
    variable root [file normalize [pwd]]
    variable result_dir ""
}

proc ::audio_wave::save {} {
    variable result_dir
    if {$result_dir eq "" || ![file isdirectory $result_dir]} {error "Run waves_audio_v2.do first."}
    if {[examine -radix unsigned /tb_audio_i2s/test_passed] != 1} {error "Audio self-check is not complete; no PASS summary saved."}
    dataset save sim [file join $result_dir checked.wlf]
    write format wave [file join $result_dir layout.do]
    set summary [open [file join $result_dir summary.txt] w]
    puts $summary "ModelSim GUI audio/I2S check - [clock format [clock seconds]]"
    foreach sig {test_passed active_count checked nonzero underruns steady_underruns full_pulse done_error} {
        puts $summary "$sig=[examine -radix unsigned /tb_audio_i2s/$sig]"
    }
    puts $summary "PASS: 64 voices, delay enabled, PCM24/I2S equality and release completion."
    close $summary
    puts "AUDIO GUI VERIFIED AND WAVEFORM SAVED: $result_dir"
}

proc ::audio_wave::run {} {
    variable root
    variable result_dir
    set sources {rtl/audio/voice_state_ram.v rtl/audio/wavetable_rom.v rtl/audio/dds_lane.v rtl/audio/adsr.v rtl/audio/pitch_expression.v rtl/audio/stereo_mixer.v rtl/audio/gain_saturator.v rtl/audio/audio_fx.v rtl/audio/polar_lane.v rtl/audio/voice_engine.v rtl/audio/audio_system_v2.v rtl/voice_allocator_v2.v rtl/expression_controls_v2.v rtl/captain_control_top_v2.v rtl/captain_system_top_v2.v rtl/i2s_tx.v sim/tb_audio_i2s.sv}
    foreach relative [concat $sources {sim/modelsim_local.ini rtl/audio/rom/waves.hex rtl/audio/rom/midi.hex rtl/audio/rom/velocity.hex rtl/audio/rom/sine.hex rtl/audio/rom/ratio.hex rtl/audio/rom/piano.hex rtl/audio/rom/polar_lane0.hex rtl/audio/rom/polar_lane1.hex rtl/audio/rom/polar_ratios.hex}] {
        if {![file isfile [file join $root $relative]]} {error "Missing required file: $relative"}
    }
    set result_dir [file join $root sim audio_results gui_[clock format [clock seconds] -format %Y%m%d_%H%M%S]_[clock clicks]]
    file mkdir $result_dir
    catch {quit -sim}
    cd $root
    transcript file [file join $result_dir transcript.log]
    transcript on
    puts "AUDIO GUI RUN START: $result_dir"
    set library [file join $result_dir work]
    set status [catch {
        vlib $library
        eval vlog -modelsimini [list [file join $root sim modelsim_local.ini]] -sv -work [list $library] $sources
        vsim -modelsimini [file join $root sim modelsim_local.ini] -onfinish stop -voptargs=+acc -wlf [file join $result_dir live.wlf] $library.tb_audio_i2s
view wave
delete wave *
add wave -divider {64 voices and test status}
add wave sim:/tb_audio_i2s/rst_n
add wave -radix unsigned sim:/tb_audio_i2s/active_count
add wave sim:/tb_audio_i2s/test_passed sim:/tb_audio_i2s/full_pulse sim:/tb_audio_i2s/done_error
add wave -radix unsigned sim:/tb_audio_i2s/underruns sim:/tb_audio_i2s/checked
add wave -divider {Synthesized stereo PCM and handshake}
add wave -radix decimal sim:/tb_audio_i2s/dut/sample_left sim:/tb_audio_i2s/dut/sample_right
add wave sim:/tb_audio_i2s/dut/sample_valid sim:/tb_audio_i2s/dut/sample_ready
add wave -divider {I2S: 24 data bits in 32-bit slots; WS low=left}
add wave sim:/tb_audio_i2s/bclk sim:/tb_audio_i2s/ws sim:/tb_audio_i2s/data_out
add wave -divider {Expression snapshot}
add wave -radix unsigned sim:/tb_audio_i2s/dut/active_gain
add wave -radix decimal sim:/tb_audio_i2s/dut/active_bend_cents
add wave -radix unsigned sim:/tb_audio_i2s/dut/active_vibrato_cents
configure wave -signalnamewidth 1 -namecolwidth 230 -valuecolwidth 110 -timelineunits us

        onbreak {if {[examine -radix unsigned /tb_audio_i2s/test_passed] == 1} {resume} else {abort}}
        ::run -all
        onbreak {}
        if {[examine -radix unsigned /tb_audio_i2s/test_passed] != 1} {error "Audio I2S self-check did not pass"}
        wave zoom range 2000us 2065us
        wave cursor time -time 2017us
        ::audio_wave::save
        puts "GUI AUDIO WAVE CHECK PASSED: 64 voices, delay enabled, PCM24/I2S matched."
        puts "Cursor is near 2 ms (test_passed=0 there); final test_passed=1 is in summary.txt."
    } message]
    onbreak {}
    if {$status != 0} {
        puts "AUDIO GUI RUN FAILED OR INTERRUPTED: $message"
        return -code error $message
    }
}
