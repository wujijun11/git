# Resolve paths before open_project/run changes Gowin's working directory.
# This build does not replace the proven boardkeys48.
set script_path [info script]
if {[file pathtype $script_path] ne "absolute"} { set script_path [file join [pwd] $script_path] }
# Preserve the caller's path spelling: normalize can resolve Windows sandbox
# redirected Desktop paths to a different, inaccessible directory.
set project_root [file dirname [file dirname $script_path]]
set full_root [file join $project_root full]
file mkdir [file join $full_root rtl audio rom]
foreach rom {waves.hex midi.hex velocity.hex sine.hex ratio.hex piano.hex polar_lane0.hex polar_lane1.hex polar_ratios.hex} {
    file copy -force [file join $project_root rtl audio rom $rom] [file join $full_root rtl audio rom $rom]
}
file mkdir [file join $full_root rtl visual]
file copy -force [file join $project_root rtl visual goertzel_1024_64.hex] [file join $full_root rtl visual goertzel_1024_64.hex]
open_project [file join $full_root ContestFull.gprj]
set_option -top_module board_contest_full_top
# Sipeed Tang Mega 60K hardware uses a 1.8 V VCCX rail (official cam_dvi).
set_option -vccx 1.8
set_option -gen_text_timing_rpt 1
run all
# A generated bitstream alone is not a successful build. Check all timing
# endpoints (including recovery/removal), not just the Fmax table.
set timing_path [file join $full_root impl pnr ContestFull.tr]
if {![file exists $timing_path]} { error "Full build has no text timing report" }
set timing_file [open $timing_path r]
set timing_text [read $timing_file]
close $timing_file
foreach kind {Setup Hold} {
    set pattern [format {<Numbers of %s Violated Endpoints>:[[:space:]]*([0-9]+)} $kind]
    if {![regexp $pattern $timing_text matched violations]} {
        error "Cannot read $kind timing violation count"
    }
    if {$violations != 0} { error "Full build failed $kind timing: $violations violated endpoints" }
}
puts "FULL BUILD TIMING PASS: zero setup/recovery and hold/removal violations"
