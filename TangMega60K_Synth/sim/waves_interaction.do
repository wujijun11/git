# First cd to this project's sim directory in ModelSim Transcript.
if {![file isdirectory work]} {vlib work}
vlog -modelsimini modelsim_local.ini -work work ../rtl/event_fifo.v ../rtl/interaction_top.v
vlog -modelsimini modelsim_local.ini -sv -work work tb_interaction.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_interaction
view wave
add wave -divider {DEPTH=2 boundary instance}
add wave sim:/tb_interaction/depth_edge_case/clk sim:/tb_interaction/depth_edge_case/rst_n
add wave sim:/tb_interaction/depth_edge_case/push_valid sim:/tb_interaction/depth_edge_case/push_ready
add wave sim:/tb_interaction/depth_edge_case/pop_valid sim:/tb_interaction/depth_edge_case/pop_ready
add wave -radix unsigned sim:/tb_interaction/depth_edge_case/level
add wave -radix hexadecimal sim:/tb_interaction/depth_edge_case/expected
add wave -radix unsigned sim:/tb_interaction/depth_edge_case/pushed
add wave -radix unsigned sim:/tb_interaction/depth_edge_case/delivered
add wave -divider {DEPTH=32 default instance}
add wave sim:/tb_interaction/depth_default_case/clk sim:/tb_interaction/depth_default_case/rst_n
add wave sim:/tb_interaction/depth_default_case/push_valid sim:/tb_interaction/depth_default_case/push_ready
add wave sim:/tb_interaction/depth_default_case/pop_valid sim:/tb_interaction/depth_default_case/pop_ready
add wave -radix unsigned sim:/tb_interaction/depth_default_case/level
add wave -radix hexadecimal sim:/tb_interaction/depth_default_case/push_on sim:/tb_interaction/depth_default_case/push_note
add wave -radix hexadecimal sim:/tb_interaction/depth_default_case/push_velocity sim:/tb_interaction/depth_default_case/push_timbre
add wave -radix hexadecimal sim:/tb_interaction/depth_default_case/pop_on sim:/tb_interaction/depth_default_case/pop_note
add wave -radix hexadecimal sim:/tb_interaction/depth_default_case/pop_velocity sim:/tb_interaction/depth_default_case/pop_timbre
add wave -radix unsigned sim:/tb_interaction/depth_default_case/pushed
add wave -radix unsigned sim:/tb_interaction/depth_default_case/delivered
add wave -radix unsigned sim:/tb_interaction/depth_default_case/full_exchanges
add wave -divider {FIFO internals}
add wave -radix unsigned sim:/tb_interaction/depth_default_case/dut/wptr
add wave -radix unsigned sim:/tb_interaction/depth_default_case/dut/rptr
add wave -radix unsigned sim:/tb_interaction/depth_default_case/dut/count
configure wave -signalnamewidth 1 -namecolwidth 240 -valuecolwidth 120 -timelineunits us
run -all
