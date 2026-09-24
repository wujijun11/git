create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
// Gowin derives 38.4 and 49.152 MHz clocks from the two PLLA primitives.
set_false_path -from [get_ports {key_n[*]}] -to [get_cells {u_board/key_meta*}]
set_false_path -to [get_cells {ready_meta*}]
set_false_path -to [get_cells {pressed_meta*}]
set_output_delay -clock sys_clk -max 0.0 [get_ports {rgb_data pa_disable}]
set_output_delay -clock sys_clk -min 0.0 [get_ports {rgb_data pa_disable}]
create_clock -name tck_pad_i -period 50.000 [get_pins {gw_gao_inst_0/tck_ibuf/I}]
