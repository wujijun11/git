set project_dir [file normalize [file join [file dirname [info script]] ..]]
cd $project_dir
open_project TangMega60K_Synth_V2.gprj
set_option -top_module captain_system_top_v2
run syn
