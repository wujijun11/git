onerror {quit -f -code 1}
if {![file isdirectory work]} {vlib work}
vlog -work work ../rtl/voice_allocator_v2.v ../rtl/expression_controls_v2.v ../rtl/captain_control_top_v2.v ../rtl/i2s_tx.v ../rtl/captain_system_top_v2.v
vlog -sv +define+V2_INTERFACE_TEST -work work tb_i2s_tx.sv
vsim -modelsimini modelsim_local.ini work.tb_i2s_tx
onbreak {quit -f -code 1}
run -all
quit -f -code 0
