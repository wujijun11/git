create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
// The two PLLA outputs are 38.4 MHz and 49.152 MHz; Gowin derives their
// generated clocks from the primitive parameters during timing analysis.
// Only synchronized status flags cross between the two clock domains.
set_false_path -from [get_ports {key_n[*]}] -to [get_cells {u_board/key_meta*}]
// board_ready is monotonic at startup; ready_meta is the first stage of its
// explicit two-flop transfer from the 50 MHz board domain to the audio domain.
set_false_path -to [get_cells {ready_meta*}]
set_false_path -to [get_cells {ref_toggle_meta*}]
set_output_delay -clock sys_clk -max 0.0 [get_ports {rgb_data pa_disable}]
set_output_delay -clock sys_clk -min 0.0 [get_ports {rgb_data pa_disable}]
create_clock -name tck_pad_i -period 50.000 [get_pins {gw_gao_inst_0/tck_ibuf/I}]
