# Resolve paths before open_project/run changes Gowin's working directory.
# This build does not replace the proven boardkeys48.
set script_path [info script]
if {[file pathtype $script_path] ne "absolute"} { set script_path [file join [pwd] $script_path] }
# Preserve the caller's path spelling: normalize can resolve Windows sandbox
# redirected Desktop paths to a different, inaccessible directory.
set project_root [file dirname [file dirname $script_path]]
set full_root [file join $project_root full]
file mkdir [file join $full_root rtl audio rom]
foreach rom {waves.hex midi.hex velocity.hex sine.hex ratio.hex piano.hex polar_lane0.hex polar_lane1.hex polar_ratios.hex menu_font.hex} {
    file copy -force [file join $project_root rtl audio rom $rom] [file join $full_root rtl audio rom $rom]
}
file mkdir [file join $full_root rtl visual]
file copy -force [file join $project_root rtl visual goertzel_1024_64.hex] [file join $full_root rtl visual goertzel_1024_64.hex]
set project_path [file join $full_root ContestFull.gprj]
set project_file [open $project_path r]
set project_text [read $project_file]
close $project_file
set gao_expected 0
set gao_config_paths {}
foreach project_entry [regexp -all -inline {<File[[:space:]][^>]*>} $project_text] {
    if {[regexp {type="file[.]gao"} $project_entry] && ![regexp {enable="0"} $project_entry]} {
        set gao_expected 1
        if {![regexp {path="([^"]+)"} $project_entry matched config_relative]} {
            error "Enabled GAO project entry has no configuration path"
        }
        lappend gao_config_paths [file join $full_root $config_relative]
    }
}
open_project $project_path
set_option -top_module board_contest_full_top
# Sipeed Tang Mega 60K hardware uses a 1.8 V VCCX rail (official cam_dvi).
set_option -vccx 1.8
set_option -gen_text_timing_rpt 1
run all
# A generated bitstream alone is not a successful build. Check all timing
# endpoints (including recovery/removal), not just the Fmax table.
set pnr_root [file join $full_root impl pnr]
# Post-synthesis GAO can emit ao_0; Gowin RTL GAO instead instruments the
# main ContestFull netlist before synthesis. Select a coherent report set,
# then prove the actual core/configuration instead of trusting its file name.
set result_name ContestFull
set report_name ContestFull
set netlist_name ContestFull
set result_command_text ""
if {[file exists [file join $pnr_root cmd.do]]} {
    set command_file [open [file join $pnr_root cmd.do] r]
    set result_command_text [read $command_file]
    close $command_file
}
set rtl_gao_mode [regexp -line {^-rtl_gao[[:space:]]*$} $result_command_text]
if {[file exists [file join $pnr_root ao_0.fs]]} {
    set result_name ao_0
    if {[file exists [file join $pnr_root ao_0.tr]] || [file exists [file join $pnr_root ao_0.rpt.txt]]} {
        set report_name ao_0
    } elseif {!$rtl_gao_mode} {
        error "ao_0 bitstream has no AO reports and no RTL-GAO naming evidence"
    }
    if {!$rtl_gao_mode} { set netlist_name ao_0 }
} elseif {[file exists [file join $pnr_root ao_0.tr]] || [file exists [file join $pnr_root ao_0.rpt.txt]]} {
    error "AO reports exist without ao_0.fs"
}
foreach result_file [list $result_name.fs $report_name.tr $report_name.rpt.txt] {
    if {![file exists [file join $pnr_root $result_file]]} {
        error "Full build has incomplete selected implementation: missing $result_file"
    }
}
set implementation_kind bare-main
if {$gao_expected} {
    if {[llength $gao_config_paths] != 1} { error "Strict GAO check requires exactly one enabled configuration" }
    proc read_build_evidence {path} {
        if {![file exists $path]} { error "Missing GAO evidence file: $path" }
        set handle [open $path r]
        set contents [read $handle]
        close $handle
        return $contents
    }
    set gao_config_text [read_build_evidence [lindex $gao_config_paths 0]]
    if {![regexp {<GAO_ID>[[:space:]]*([01]{16})[[:space:]]*</GAO_ID>} $gao_config_text matched config_crc]} {
        error "GAO configuration has no unambiguous 16-bit GAO_ID"
    }
    set command_text [read_build_evidence [file join $pnr_root cmd.do]]
    if {![regexp -line {^-gao_crc[[:space:]]+([01]{16})[[:space:]]*$} $command_text matched command_crc] || $command_crc ne $config_crc} {
        error "PnR GAO CRC does not match the enabled configuration"
    }
    if {$netlist_name eq "ContestFull" && ![regexp -line {^-rtl_gao[[:space:]]*$} $command_text]} {
        error "Main-name GAO output has no -rtl_gao PnR flag; bare ContestFull is not accepted"
    }
    set netlist_path [file join $full_root impl gwsynthesis $netlist_name.vg]
    if {![regexp -line {^-d[ \t]+([^\r\n]+)} $command_text matched command_netlist]} {
        error "Cannot identify GAO PnR input netlist"
    }
    set command_netlist [string trim [string trim $command_netlist] {"}]
    if {![string equal -nocase [string map {\\ /} $netlist_path] [string map {\\ /} $command_netlist]]} {
        error "GAO PnR -d input is not the selected implementation netlist"
    }
    set netlist_text [read_build_evidence $netlist_path]
    # Anchored declarations/instances cannot be satisfied by file-list comments.
    if {![regexp -line {^[ \t]*module[ \t]+gw_gao[ \t]*\(} $netlist_text] ||
        ![regexp -line {^[ \t]*gw_gao[ \t]+gw_gao_inst_[0-9]+[ \t]*\(} $netlist_text]} {
        error "Selected PnR netlist does not contain an instantiated GAO core"
    }
    if {![regexp {<AoCore[^>]*module_name="board_contest_full_top"} $gao_config_text] ||
        ![regexp {<AoCore[^>]*sample_clock="([^"]+)"} $gao_config_text matched gao_clock] ||
        ![regexp {<AoCore[^>]*storage_depth="([0-9]+)"} $gao_config_text matched gao_depth] ||
        ![regexp {<SignalList>(.*?)</SignalList>} $gao_config_text matched signal_xml]} {
        error "Cannot read expected GAO target/clock/storage/capture signals"
    }
    set capture_signals {}
    foreach {whole signal} [regexp -all -inline {<Signal>([^<]+)</Signal>} $signal_xml] {
        lappend capture_signals [string trim $signal]
    }
    set signal_bits [llength $capture_signals]
    if {$signal_bits == 0 || [llength [lsort -unique $capture_signals]] != $signal_bits} {
        error "GAO capture signals are empty or duplicate"
    }
    set wrapper_text [read_build_evidence [file join $full_root impl gwsynthesis RTL_GAO gw_gao_top.v]]
    if {[string first ".clk_i($gao_clock)" $wrapper_text] < 0 ||
        ![regexp {\.data_i[[:space:]]*\([[:space:]]*\{([^\}]+)\}} $wrapper_text matched wired_xml]} {
        error "Generated GAO wrapper has no matching capture clock/data port"
    }
    set wired_signals {}
    foreach signal [split $wired_xml ,] {
        lappend wired_signals [string trim [string trimleft [string trim $signal] "\\"]]
    }
    if {$capture_signals ne $wired_signals} { error "Generated GAO capture wiring/order differs from configuration" }
    set parameter_text [read_build_evidence [file join $full_root impl gwsynthesis RTL_GAO ao_0 gw_ao_parameter.v]]
    foreach {parameter expected_value} [list SIG_PORT_WIDTH $signal_bits MEM_DATA_WIDTH [expr {$signal_bits+1}] STORAGE_DEPTH $gao_depth] {
        set parameter_pattern [format {parameter[[:space:]]+%s[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;} $parameter]
        if {![regexp $parameter_pattern $parameter_text matched actual_value] || $actual_value != $expected_value} {
            error "Generated GAO $parameter differs from configuration"
        }
    }
    set implementation_kind [expr {$rtl_gao_mode ? "rtl-gao-in-main" : "separate-gao"}]
    puts "FULL BUILD GAO EVIDENCE PASS: CRC=$config_crc bits=$signal_bits depth=$gao_depth clock=$gao_clock"
} elseif {$result_name eq "ao_0"} {
    error "GAO output has no enabled project configuration"
}
puts "FULL BUILD IMPLEMENTATION: bitstream=$result_name.fs reports=$report_name ($implementation_kind; GAO expected: $gao_expected)"
set timing_path [file join $pnr_root $report_name.tr]
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
