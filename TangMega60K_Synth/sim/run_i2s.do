onerror {quit -f -code 1}
# First cd to this project's sim directory; keep the shared GW5A mapping intact.
if {![file isdirectory work]} {vlib work}
vlog -work work ../rtl/voice_allocator.v ../rtl/captain_control_top.v ../rtl/i2s_tx.v ../rtl/captain_system_top.v
vlog -sv -work work tb_i2s_tx.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_i2s_tx
onbreak {quit -f -code 1}
run -all
quit -f -code 0
