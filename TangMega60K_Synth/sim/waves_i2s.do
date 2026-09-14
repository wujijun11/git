# First cd to this project's sim directory in ModelSim Transcript.
if {![file isdirectory work]} {vlib work}
vlog -modelsimini modelsim_local.ini -work work ../rtl/voice_allocator.v ../rtl/captain_control_top.v ../rtl/i2s_tx.v ../rtl/captain_system_top.v
vlog -modelsimini modelsim_local.ini -sv -work work tb_i2s_tx.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_i2s_tx
view wave
add wave -divider {System clock and reset}
add wave sim:/tb_i2s_tx/normal/clk sim:/tb_i2s_tx/normal/rst_n
add wave -divider {Stereo samples from teammate A}
add wave sim:/tb_i2s_tx/normal/sample_valid sim:/tb_i2s_tx/normal/sample_ready
add wave -radix hexadecimal sim:/tb_i2s_tx/normal/sample_left sim:/tb_i2s_tx/normal/sample_right
add wave -radix unsigned sim:/tb_i2s_tx/normal/fifo_level
add wave -divider {I2S to DAC}
add wave sim:/tb_i2s_tx/normal/bclk sim:/tb_i2s_tx/normal/ws sim:/tb_i2s_tx/normal/data_out
add wave sim:/tb_i2s_tx/normal/frame_tick sim:/tb_i2s_tx/normal/underrun_pulse
add wave -radix unsigned sim:/tb_i2s_tx/normal/underrun_count
add wave -divider {Independent receiver scoreboard}
add wave -radix hexadecimal sim:/tb_i2s_tx/normal/expected_frame sim:/tb_i2s_tx/normal/decoded_left sim:/tb_i2s_tx/normal/receive_word
add wave -radix unsigned sim:/tb_i2s_tx/normal/frames_checked
configure wave -signalnamewidth 1 -namecolwidth 220 -valuecolwidth 120 -timelineunits us
run 110 us
# Third frame contains the first nonzero pair (L=7fffff, R=800000).
wave zoom range 41us 64us
