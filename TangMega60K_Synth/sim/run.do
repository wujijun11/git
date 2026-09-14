onerror {quit -f -code 1}
# Run from this project's sim directory. ModelSim do is not Tcl source;
# info script can refer to ModelSim's own initialization script.
if {![file isdirectory work]} {vlib work}
vlog -work work ../rtl/voice_allocator.v ../rtl/captain_control_top.v
vlog -sv -work work tb_voice_allocator.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_voice_allocator
onbreak {quit -f -code 1}
run -all
quit -f -code 0
