# Only mono_diag receives build artifacts; preserve Windows caller spelling.
set script_path [info script]
if {[file pathtype $script_path] ne "absolute"} { set script_path [file join [pwd] $script_path] }
set project_root [file dirname [file dirname $script_path]]
set diag_root [file join $project_root mono_diag]
file mkdir [file join $diag_root rtl audio rom]
foreach rom {waves.hex midi.hex velocity.hex sine.hex ratio.hex piano.hex polar_lane0.hex polar_lane1.hex polar_ratios.hex} {
    file copy -force [file join $project_root rtl audio rom $rom] [file join $diag_root rtl audio rom $rom]
}
open_project [file join $diag_root MonoDiagnostic.gprj]
set_option -top_module board_mono_diagnostic_top
# Same VCCX rail as the existing validated Tang Mega 60K project.
set_option -vccx 1.8
set_option -gen_text_timing_rpt 1
run all
set timing_path [file join $diag_root impl pnr MonoDiagnostic.tr]
if {![file exists $timing_path]} { error "Diagnostic build has no timing report" }
set timing_file [open $timing_path r]
set timing_text [read $timing_file]
close $timing_file
foreach kind {Setup Hold} {
    set pattern [format {<Numbers of %s Violated Endpoints>:[[:space:]]*([0-9]+)} $kind]
    if {![regexp $pattern $timing_text matched violations] || $violations != 0} {
        error "Diagnostic build failed $kind timing"
    }
}
puts "MONO DIAGNOSTIC BUILD TIMING PASS"
