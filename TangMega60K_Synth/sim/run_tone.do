onerror {quit -f -code 1}
if {![file isdirectory work]} {vlib work}
vlog -modelsimini modelsim_local.ini -work work ../rtl/i2s_tx.v ../rtl/test_tone_source.v ../rtl/tone_demo_top.v
vlog -modelsimini modelsim_local.ini -sv -work work tb_tone_demo.sv
vsim -modelsimini modelsim_local.ini work.tb_tone_demo
onbreak {quit -f -code 1}
run -all
quit -f -code 0
