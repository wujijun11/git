# First cd to this project's sim directory in the Transcript.
if {![file isdirectory work]} {vlib work}
vlog -modelsimini modelsim_local.ini -work work ../rtl/voice_allocator.v ../rtl/captain_control_top.v
vlog -modelsimini modelsim_local.ini -sv -work work tb_voice_allocator.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_voice_allocator
view wave
add wave -divider {Input from teammate B}
add wave sim:/tb_voice_allocator/full_case/clk
add wave sim:/tb_voice_allocator/full_case/rst_n
add wave sim:/tb_voice_allocator/full_case/event_*
add wave -divider {Commands to teammate A}
add wave sim:/tb_voice_allocator/full_case/cmd_*
add wave -divider {Release completion and occupancy}
add wave sim:/tb_voice_allocator/full_case/done_*
add wave -radix unsigned sim:/tb_voice_allocator/full_case/active_count
add wave -radix hexadecimal sim:/tb_voice_allocator/full_case/active_mask
add wave sim:/tb_voice_allocator/full_case/full_pulse
add wave sim:/tb_voice_allocator/full_case/dut/state
run 10 us
wave zoom full
