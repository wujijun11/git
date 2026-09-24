onerror {quit -f -code 1}
if {![file isdirectory work]} {vlib work}
vlog -modelsimini modelsim_local.ini -work work ../rtl/event_fifo_v2.v ../rtl/interaction_top_v2.v
vlog -modelsimini modelsim_local.ini -work work ../rtl/voice_allocator_v2.v ../rtl/expression_controls_v2.v ../rtl/captain_control_top_v2.v
vlog -modelsimini modelsim_local.ini -sv -work work tb_interaction_v2.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_interaction_v2
onbreak {quit -f -code 1}
run -all
quit -f -code 0
