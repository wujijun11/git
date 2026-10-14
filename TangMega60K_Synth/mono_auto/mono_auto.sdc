create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
// Gowin derives the 38.4 and 49.152 MHz clocks from the PLLA primitives.
// Exempt only asynchronous paths into the first flip-flop of each 2FF chain.
// Exact first-stage FFs: pll_meta* also matches a synthesized inverter.
// Keep every second-stage synchronizer and all clock-domain timing checked.
set_false_path -from [get_ports {key_n[*]}] -to [get_cells {
    u_board/key_meta_0_s1 u_board/key_meta_1_s1 u_board/key_meta_2_s1
}]
set_false_path -to [get_cells {
    pll_meta_s0 ready_meta_s0
    pressed_meta_0_s0 pressed_meta_1_s0 pressed_meta_2_s0
    auto_due_meta_s0 auto_ack_meta_s0 audio_ready_meta_s0
    busy_meta_s0 piano_meta_s0 underrun_meta_s0
}]
set_output_delay -clock sys_clk -max 0.0 [get_ports {rgb_data pa_disable}]
set_output_delay -clock sys_clk -min 0.0 [get_ports {rgb_data pa_disable}]
// External I2S skew and DAC setup/hold still require board-level measurement.
