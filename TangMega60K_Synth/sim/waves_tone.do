if {![file isdirectory work]} {vlib work}
vlog -modelsimini modelsim_local.ini -work work ../rtl/i2s_tx.v ../rtl/test_tone_source.v ../rtl/tone_demo_top.v
vlog -modelsimini modelsim_local.ini -sv -work work tb_tone_demo.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_tone_demo
view wave
add wave sim:/tb_tone_demo/rst_n
add wave sim:/tb_tone_demo/dut/valid sim:/tb_tone_demo/dut/ready
add wave -radix decimal sim:/tb_tone_demo/dut/left_sample sim:/tb_tone_demo/dut/right_sample
add wave sim:/tb_tone_demo/bclk sim:/tb_tone_demo/ws sim:/tb_tone_demo/serial
add wave -radix decimal sim:/tb_tone_demo/decoded_l sim:/tb_tone_demo/decoded_r
add wave -radix unsigned sim:/tb_tone_demo/frames sim:/tb_tone_demo/underruns
configure wave -signalnamewidth 1 -timelineunits us
run 5 ms
wave zoom range 1400us 4000us
