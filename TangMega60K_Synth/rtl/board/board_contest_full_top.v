// NEO Dock 31004 Rev1.4. External sensor/LED/BLE hardware is optional at boot.
// KEY0 toggles built-in score audio; KEY1 toggles silent offline LED guide;
// KEY2 resets. Switching score/guide first releases all score-owned notes.
module board_contest_full_top #(
    parameter DEBOUNCE_CYCLES=100000,
    parameter SLIDER_VOLUME_ENABLE=1,
    // 仅本地排查分支启用，改用已有彩灯观察启动状态，不改变音频/通信功能。
    parameter BOOT_DIAGNOSTIC=1,
    // 四针128x64 SSD1306/SSD1315兼容OLED：独立I2C，使用既有音频时钟。
    // 首板默认100kHz以容忍较长接线；地址为7位0x3C，不是写地址0x78。
    parameter OLED_ENABLE=1, OLED_I2C_HZ=100000,
    parameter [6:0] OLED_ADDRESS=7'h3c,
    parameter integer OLED_POWER_WAIT_CYCLES=4915200,
    parameter integer OLED_FRAME_WAIT_CYCLES=1966080,
    parameter integer OLED_WAVE_ENABLE=1,
    parameter integer OLED_WAVE_IDLE_CYCLES=147456000,
    parameter [7:0] GUIDE_BRIGHTNESS=8'd32, GUIDE_TOUCH_BRIGHTNESS=8'd16,
    // Index0 is DIN's first pixel. Calibrate the purchased panel before
    // replacing this identity map; its row order is not shown by the listing.
    parameter [124:0] GUIDE_PIXEL_KEY_MAP={5'd24,5'd23,5'd22,5'd21,5'd20,
        5'd19,5'd18,5'd17,5'd16,5'd15,5'd14,5'd13,5'd12,5'd11,5'd10,
        5'd9,5'd8,5'd7,5'd6,5'd5,5'd4,5'd3,5'd2,5'd1,5'd0}
) (
    input wire sys_clk,input wire [2:0] key_n,
    inout wire [2:0] mpr_scl,mpr_sda,input wire [2:0] mpr_irq_n,
    inout wire oled_scl,oled_sda,
    input wire uart_rx,output wire uart_tx,
    output wire rgb_data,pa_disable,i2s_bclk,i2s_lrclk,i2s_data,guide_led_data,
    output wire tmds_clk_p,tmds_clk_n,output wire [2:0] tmds_data_p,tmds_data_n,
    output wire hdmi_enable
);
    assign hdmi_enable=1'b1;
    wire board_ready;wire [2:0] pressed_50;
    wire audio_clk,audio_locked;wire pixel_clk,serial_clk,video_locked;
    wire [7:0] debug_pll_status;
    wire [3:0] debug_audio_reset_status;
    wire [6:0] voices;wire [2:0] sensor_ready,sensor_fault;wire overflow,playing,recording,guide;
    wire [31:0] underruns;
    wire menu_main,menu_busy;wire [1:0] menu_page,menu_zone;
    wire [7:0] menu_error;wire [15:0] menu_record_count;
    wire menu_volume_mode;
    wire [7:0] menu_volume_percent;
    wire menu_touch_active;
    wire oled_fault;wire [31:0] oled_completed_frames;
    wire signed [23:0] debug_transmit_left;
    // LRCLK's rising edge is halfway through the transmitted stereo frame;
    // this held value was selected on its falling edge, 512 audio clocks ago.
    (* syn_keep=1 *) wire [15:0] debug_pcm=debug_transmit_left[23:8];
    (* syn_keep=1 *) wire [6:0] debug_note;
    (* syn_keep=1 *) wire [24:0] debug_touch;
    (* syn_keep=1 *) wire debug_underrun=|underruns;
    // 诊断模式仍保留原状态同步寄存器，保持原SDC对象及功能采样链存在。
    (* syn_keep=1, syn_preserve=1 *) reg [4:0] status_meta=0,status_sync=0;
    always @(posedge sys_clk)begin
        status_meta<={overflow || underruns!=0,|sensor_fault,guide,playing,|voices};status_sync<=status_meta;
    end
    wire [23:0] status_grb=status_sync[4] ? 24'h002000 :
        status_sync[3] ? 24'h081008 : status_sync[2] ? 24'h000020 :
        status_sync[1] ? 24'h200008 : status_sync[0] ? 24'h180000 : 24'h020000;
    wire [23:0] boot_status_grb;
    wire [23:0] selected_status_grb = BOOT_DIAGNOSTIC ? boot_status_grb : status_grb;
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.STATUS_MODE(1)) board(
        .sys_clk(sys_clk),.key_n(key_n),.rgb_data(rgb_data),.pa_disable(pa_disable),
        .board_ready(board_ready),.keys_pressed(pressed_50),.status_grb(selected_status_grb));
    audio_clock_48k audio_clock(.clk_50(sys_clk),.clk_audio(audio_clk),.locked(audio_locked),
        .debug_pll_status(debug_pll_status));
    video_clocking video_clock(.clk_50(sys_clk),.reset(1'b0),.clk_pixel(pixel_clk),.clk_serial(serial_clk),.locked(video_locked));
    reg ready_meta=0,ready_sync=0;reg [2:0] pressed_meta=0,pressed_sync=0;
    always @(posedge audio_clk or negedge audio_locked)begin
        if(!audio_locked)begin ready_meta<=0;ready_sync<=0;pressed_meta<=0;pressed_sync<=0;end
        else begin ready_meta<=board_ready;ready_sync<=ready_meta;pressed_meta<=pressed_50;pressed_sync<=pressed_meta;end
    end
    wire rst_n=ready_sync && !pressed_sync[2];
    // Keep status acquisition alive even when audio_clk or its reset is stuck.
    // Multi-bit fields are diagnostic only; interpret stable runs, not the
    // few samples spanning an asynchronous transition as a coherent event.
    reg [8:0] debug_audio_heartbeat=0;
    always @(posedge audio_clk)debug_audio_heartbeat<=debug_audio_heartbeat+1'b1;
    (* syn_preserve=1 *) reg [47:0] debug_status_meta=0;
    (* syn_keep=1, syn_preserve=1 *) reg [47:0] debug_status=0;
    always @(posedge sys_clk)begin
        debug_status_meta<={i2s_data,i2s_lrclk,i2s_bclk,debug_audio_heartbeat[8],
            debug_pll_status,debug_note,voices,sensor_fault,sensor_ready,
            guide,playing,pressed_sync,pressed_50,debug_audio_reset_status,
            rst_n,ready_sync,audio_locked,board_ready};
        debug_status<=debug_status_meta;
    end
    generate if (BOOT_DIAGNOSTIC) begin: boot_probe
        audio_boot_status status_monitor (
            .clk(sys_clk), .snapshot(debug_status), .status_grb(boot_status_grb)
        );
    end else begin: normal_status
        assign boot_status_grb = 24'd0;
    end endgenerate
    wire local_valid;wire [7:0] action;
    wire local_ready;
    board_local_actions local_actions(.clk(audio_clk),.rst_n(rst_n),
        .keys_pressed(pressed_sync[1:0]),.playing(playing),.guide(guide),
        .local_action_valid(local_valid),.local_action_ready(local_ready),.local_action(action));
    reg [1:0] video_reset=0;
    always @(posedge pixel_clk or negedge video_locked)begin
        if(!video_locked)video_reset<=0;else video_reset<={video_reset[0],rst_n};
    end
    wire [9:0] x,y;wire hs,vs,de,hs_aligned,vs_aligned,de_aligned;wire [23:0] rgb;
    video_timing_640x480 timing(.clk(pixel_clk),.reset(!video_reset[1]),.pixel_x(x),.pixel_y(y),.hsync(hs),.vsync(vs),.de(de));
    instrument_full_system #(.SLIDER_VOLUME_ENABLE(SLIDER_VOLUME_ENABLE),
        .MENU_ROOT_IDLE_CYCLES(OLED_ENABLE && OLED_WAVE_ENABLE ? 0 : 245760000),.GUIDE_BRIGHTNESS(GUIDE_BRIGHTNESS),
        .GUIDE_TOUCH_BRIGHTNESS(GUIDE_TOUCH_BRIGHTNESS),.GUIDE_PIXEL_KEY_MAP(GUIDE_PIXEL_KEY_MAP)) system(
        .clk(audio_clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .mpr_scl(mpr_scl),.mpr_sda(mpr_sda),.mpr_irq_n(mpr_irq_n),
        .local_action_valid(local_valid),.local_action_ready(local_ready),.local_action(action),
        .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data),.guide_led_data(guide_led_data),
        .active_count(voices),.touch_mask(debug_touch),.sensor_ready(sensor_ready),.sensor_fault(sensor_fault),.underrun_count(underruns),
        .overflow_sticky(overflow),.playing(playing),.recording(recording),.guide_active(guide),
        .video_clk(pixel_clk),.video_x(x),.video_y(y),.video_de(de),.video_rgb(rgb),
        .debug_transmit_left(debug_transmit_left),.debug_last_note(debug_note),
        .debug_audio_reset_status(debug_audio_reset_status),
        .menu_main(menu_main),.menu_page(menu_page),.menu_zone(menu_zone),
        .menu_busy(menu_busy),.menu_error(menu_error),.menu_record_count(menu_record_count),
        .menu_volume_mode(menu_volume_mode),.menu_volume_percent(menu_volume_percent),
        .menu_touch_active(menu_touch_active));
    // 在LRCLK下降后一拍采到本帧已选择的左声道PCM，含启动/欠载时真实发送的零值。
    reg oled_previous_lrclk;
    always @(posedge audio_clk or negedge rst_n) begin
        if (!rst_n)
            oled_previous_lrclk <= 1;
        else
            oled_previous_lrclk <= i2s_lrclk;
    end
    wire oled_audio_sample_valid = oled_previous_lrclk && !i2s_lrclk;
    // OLED只观察菜单/录放状态。NACK或掉线由显示驱动限速重试，
    // 不接入音频ready/reset链，也不复用三组MPR121的SCL/SDA。
    generate if(OLED_ENABLE) begin: oled_panel
        oled_status_display #(.CLK_HZ(49152000),.I2C_HZ(OLED_I2C_HZ),.PERFORMANCE_UI_ENABLE(SLIDER_VOLUME_ENABLE),
            .WAVEFORM_ENABLE(OLED_WAVE_ENABLE),.WAVE_IDLE_CYCLES(OLED_WAVE_IDLE_CYCLES),
            .POWER_WAIT_CYCLES(OLED_POWER_WAIT_CYCLES),
            .FRAME_WAIT_CYCLES(OLED_FRAME_WAIT_CYCLES),.ADDRESS(OLED_ADDRESS)) display(
            .clk(audio_clk),.rst_n(rst_n),.main_menu(menu_main),
            .menu_page(menu_page),.zone(menu_zone),.recording(recording),.playing(playing),
            .guide(guide),.busy(menu_busy),.error(menu_error),.record_count(menu_record_count),
            .performance_mode(menu_volume_mode),.volume_percent(menu_volume_percent),
            .scl(oled_scl),.sda(oled_sda),.fault(oled_fault),.completed_frames(oled_completed_frames),
            .ui_activity(menu_touch_active),.audio_sample_valid(oled_audio_sample_valid),
            .audio_sample(debug_transmit_left));
    end else begin: no_oled
        assign oled_scl=1'bz;assign oled_sda=1'bz;
        assign oled_fault=1'b0;assign oled_completed_frames=32'd0;
    end endgenerate
    video_sync_align #(.LATENCY(2)) align(.clk(pixel_clk),.reset(!video_reset[1]),
        .hsync_in(hs),.vsync_in(vs),.de_in(de),.hsync_out(hs_aligned),.vsync_out(vs_aligned),.de_out(de_aligned));
    video_tmds_tx video(.clk_pixel(pixel_clk),.clk_serial(serial_clk),.reset(!video_reset[1]),
        .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]),.hsync(hs_aligned),.vsync(vs_aligned),.de(de_aligned),
        .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),.tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n));
endmodule

// Board command source. Hold each command until accepted and retain the
// follow-up while score-owned notes finish releasing before a mode switch.
module board_local_actions (
    input wire clk,rst_n,input wire [1:0] keys_pressed,
    input wire playing,guide,
    output wire local_action_valid,input wire local_action_ready,
    output reg [7:0] local_action
);
    reg [1:0] previous_keys;
    reg local_pending,follow_valid;
    reg [7:0] follow_action;
    wire [1:0] new_press=keys_pressed & ~previous_keys;
    assign local_action_valid=local_pending;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            previous_keys<=0;local_pending<=0;follow_valid<=0;
            local_action<=0;follow_action<=0;
        end else begin
            previous_keys<=keys_pressed;
            if(local_action_valid && local_action_ready)begin
                if(follow_valid)begin local_action<=follow_action;follow_valid<=0;end
                else local_pending<=0;
            end
            if(!local_pending && |new_press)begin
                local_pending<=1;
                if(new_press[1])begin
                    if(playing)begin local_action<=0;follow_action<=6;follow_valid<=1;end
                    else local_action<=guide ? 7 : 6;
                end else begin
                    if(guide && !playing)begin local_action<=7;follow_action<=1;follow_valid<=1;end
                    else local_action<=playing ? 0 : 1;
                end
            end
        end
    end
endmodule
