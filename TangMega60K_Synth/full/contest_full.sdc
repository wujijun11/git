create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
// PLLA outputs are derived by Gowin. No broad false path hides audio/video logic.
set_false_path -from [get_ports {key_n[*]}] -to [get_cells {board/key_meta*}]
set_false_path -to [get_cells {ready_meta*}]
set_false_path -to [get_cells {pressed_meta*}]
set_false_path -to [get_cells {status_meta*}]
set_false_path -to [get_cells {system/irq_meta*}]
set_false_path -to [get_cells {system/uart/receiver/rx_meta*}]
set_false_path -to [get_cells {system/monitor/ack_meta*}]
set_false_path -to [get_cells {system/monitor/req_meta*}]
// Async assertion/synchronous release chains. Exempt only their async clear
// pins: their interstage data paths and downstream reset recovery remain timed.
set_false_path -to [get_pins {video_reset_*_s0/CLEAR}]
set_false_path -to [get_pins {video/*_lane/serial_ready_*_s0/CLEAR}]
set_false_path -from [get_ports {mpr_scl[*]}] -to [get_cells {system/sensors/*/bus/scl_sync_0_s0*}]
set_false_path -from [get_ports {mpr_sda[*]}] -to [get_cells {system/sensors/*/bus/sda_sync_0_s0*}]
// Coherent bundled-data mailbox: req is synchronized before sampling bundle.
// Two destination cycles precede capture: bound only this held data bundle.
set_max_delay 40.000 -from [get_cells {system/monitor/bundle*}] -to [get_cells {system/monitor/dst_left* system/monitor/dst_right*}]
// Physical I2C pull-up/rise time, DAC I2S skew and total sensor latency require measurement.
