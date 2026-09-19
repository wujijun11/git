# Load the newest verified Live64 waveform from the project root.
# Usage in ModelSim Transcript:
#   set live64_project_root {C:/path/to/TangMega60K_Synth}
#   do "$live64_project_root/sim/view_live64_wave.do"
onerror {abort}

set live64_wave_loaded 0
# Keep an explicit absolute path intact: old bundled Tcl versions can resolve
# redirected Windows Desktop paths differently from the file APIs.
if {[info exists live64_project_root]} {
    set project_root $live64_project_root
} else {
    set project_root [pwd]
}
if {![file isdirectory [file join $project_root rtl]] ||
    ![file isdirectory [file join $project_root sim]]} {
    error "Set live64_project_root to the absolute TangMega60K_Synth directory, then do \"\$live64_project_root/sim/view_live64_wave.do\""
}

set candidates [lsort [glob -nocomplain -types f \
    [file join $project_root sim live64_results wave_* checked.wlf]]]
set checked_wlf ""
foreach candidate [lreverse $candidates] {
    set summary_path [file join [file dirname $candidate] summary.txt]
    if {![file isfile $summary_path]} {continue}
    set summary_file [open $summary_path r]
    set summary_text [read $summary_file]
    close $summary_file
    if {[regexp -line {^test_passed=1\r?$} $summary_text]} {
        set checked_wlf $candidate
        break
    }
}
if {$checked_wlf eq ""} {
    error "No completed Live64 waveform found under sim/live64_results/wave_* (checked.wlf and summary.txt with test_passed=1 are required)."
}

catch {dataset close live64check}
dataset open $checked_wlf live64check
view wave
delete wave *

add wave -divider {64 voices - startup / hold / release}
foreach signal {rst_n start stop busy holding released error test_passed} {
    add wave live64check:/tb_live64_spectrum/$signal
}
foreach signal {active_count ons offs dones underruns checked captured} {
    add wave -radix unsigned live64check:/tb_live64_spectrum/$signal
}
add wave -divider {24-bit stereo PCM}
add wave -radix decimal \
    live64check:/tb_live64_spectrum/dut/u_audio/sample_left \
    live64check:/tb_live64_spectrum/dut/u_audio/sample_right
add wave live64check:/tb_live64_spectrum/dut/u_audio/sample_valid
add wave live64check:/tb_live64_spectrum/dut/u_audio/sample_ready
add wave -divider {Standard I2S - BCLK / WS / DATA}
add wave live64check:/tb_live64_spectrum/bclk
add wave live64check:/tb_live64_spectrum/ws
add wave live64check:/tb_live64_spectrum/data_out

configure wave -signalnamewidth 1 -namecolwidth 230 -valuecolwidth 110 -timelineunits us
wave zoom range 130000us 130065us
wave cursor time -time 130017us
set live64_wave_loaded 1
puts "LIVE64 VERIFIED WAVE LOADED: $checked_wlf"
puts {For the full lifecycle: wave zoom full}
puts {For I2S detail: wave zoom range 130000us 130025us}
