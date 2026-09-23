create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
// Gowin derives the 38.4 and 49.152 MHz clocks from the PLLA primitives.
// Only the first synchronizer stages have asynchronous input paths.
set_false_path -from [get_ports {key_n[*]}] -to [get_cells {u_board/key_meta*}]
set_false_path -to [get_cells {ready_meta*}]
set_false_path -to [get_cells {pressed_meta*}]
set_output_delay -clock sys_clk -max 0.0 [get_ports {rgb_data pa_disable}]
set_output_delay -clock sys_clk -min 0.0 [get_ports {rgb_data pa_disable}]
// External I2S skew and DAC setup/hold are pending board-level measurement.
// The fabric's 49.152 MHz timing is still checked via Gowin's derived clock.
