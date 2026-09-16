set project_dir [file normalize [file join [file dirname [info script]] ..]]
cd $project_dir
open_project ToneDemo.gprj
set_option -top_module tone_demo_top
run syn
