onerror {quit -f -code 1}
onbreak {quit -f -code 1}
catch {log /tb_ws2812_matrix/identity/clk}
catch {log /tb_ws2812_matrix/identity/rst_n}
catch {log /tb_ws2812_matrix/identity/led_data}
catch {log /tb_ws2812_matrix/identity/busy}
catch {log /tb_ws2812_matrix/identity/frame_done}
catch {log /tb_ws2812_matrix/identity/guide_mask}
catch {log /tb_ws2812_matrix/identity/touch_mask}
catch {log /tb_ws2812_matrix/identity/done}
catch {log /tb_ws2812_matrix/identity/frames}
catch {log /tb_ws2812_matrix/serpentine/clk}
catch {log /tb_ws2812_matrix/serpentine/rst_n}
catch {log /tb_ws2812_matrix/serpentine/led_data}
catch {log /tb_ws2812_matrix/serpentine/busy}
catch {log /tb_ws2812_matrix/serpentine/frame_done}
catch {log /tb_ws2812_matrix/serpentine/guide_mask}
catch {log /tb_ws2812_matrix/serpentine/touch_mask}
catch {log /tb_ws2812_matrix/serpentine/done}
catch {log /tb_ws2812_matrix/serpentine/frames}
catch {log /tb_ws2812_matrix/rotated/clk}
catch {log /tb_ws2812_matrix/rotated/rst_n}
catch {log /tb_ws2812_matrix/rotated/led_data}
catch {log /tb_ws2812_matrix/rotated/busy}
catch {log /tb_ws2812_matrix/rotated/frame_done}
catch {log /tb_ws2812_matrix/rotated/guide_mask}
catch {log /tb_ws2812_matrix/rotated/touch_mask}
catch {log /tb_ws2812_matrix/rotated/done}
catch {log /tb_ws2812_matrix/rotated/frames}
catch {log /tb_ws2812_matrix/identity_done}
catch {log /tb_ws2812_matrix/serpentine_done}
catch {log /tb_ws2812_matrix/rotated_done}
run -all
quit -f -code 0
