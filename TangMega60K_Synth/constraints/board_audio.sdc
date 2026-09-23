create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
// Raw human inputs are asynchronous; only paths INTO the first stage are cut.
set_false_path -from [get_ports {key_n[*]}] -to [get_cells {u_board/key_meta*}]
// WS2812 has no synchronous external clock; pulse widths are RTL-cycle defined.
set_output_delay -clock sys_clk -max 0.0 [get_ports {rgb_data pa_disable}]
set_output_delay -clock sys_clk -min 0.0 [get_ports {rgb_data pa_disable}]
