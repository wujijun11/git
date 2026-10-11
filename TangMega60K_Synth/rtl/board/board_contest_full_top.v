// NEO Dock 31004 Rev1.4. External sensor/LED/BLE hardware is optional at boot.
// KEY0 toggles built-in score audio; KEY1 toggles silent offline LED guide;
// KEY2 resets. Switching score/guide first releases all score-owned notes.
module board_contest_full_top #(
    parameter DEBOUNCE_CYCLES=100000
) (
    input wire sys_clk,input wire [2:0] key_n,
    inout wire [2:0] mpr_scl,mpr_sda,input wire [2:0] mpr_irq_n,
    input wire uart_rx,output wire uart_tx,
    output wire rgb_data,pa_disable,i2s_bclk,i2s_lrclk,i2s_data,guide_led_data,
    output wire tmds_clk_p,tmds_clk_n,output wire [2:0] tmds_data_p,tmds_data_n,
    output wire hdmi_enable
);
    assign hdmi_enable=1'b1;
    wire board_ready;wire [2:0] pressed_50;
    wire audio_clk,audio_locked;wire pixel_clk,serial_clk,video_locked;
    wire [6:0] voices;wire [2:0] sensor_ready,sensor_fault;wire overflow,playing,recording,guide;
    wire [31:0] underruns;
    reg [4:0] status_meta=0,status_sync=0;
    always @(posedge sys_clk)begin
        status_meta<={overflow || underruns!=0,|sensor_fault,guide,playing,|voices};status_sync<=status_meta;
    end
    wire [23:0] status_grb=status_sync[4] ? 24'h002000 :
        status_sync[3] ? 24'h081008 : status_sync[2] ? 24'h000020 :
        status_sync[1] ? 24'h200008 : status_sync[0] ? 24'h180000 : 24'h020000;
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.STATUS_MODE(1)) board(
        .sys_clk(sys_clk),.key_n(key_n),.rgb_data(rgb_data),.pa_disable(pa_disable),
        .board_ready(board_ready),.keys_pressed(pressed_50),.status_grb(status_grb));
    audio_clock_48k audio_clock(.clk_50(sys_clk),.clk_audio(audio_clk),.locked(audio_locked));
    video_clocking video_clock(.clk_50(sys_clk),.reset(1'b0),.clk_pixel(pixel_clk),.clk_serial(serial_clk),.locked(video_locked));
    reg ready_meta=0,ready_sync=0;reg [2:0] pressed_meta=0,pressed_sync=0;
    always @(posedge audio_clk or negedge audio_locked)begin
        if(!audio_locked)begin ready_meta<=0;ready_sync<=0;pressed_meta<=0;pressed_sync<=0;end
        else begin ready_meta<=board_ready;ready_sync<=ready_meta;pressed_meta<=pressed_50;pressed_sync<=pressed_meta;end
    end
    wire rst_n=ready_sync && !pressed_sync[2];
    reg [1:0] previous_keys;reg local_valid,follow_valid;reg [7:0] action,follow_action;
    wire local_ready;
    wire [1:0] new_press=pressed_sync[1:0] & ~previous_keys;
    always @(posedge audio_clk or negedge rst_n)begin
        if(!rst_n)begin previous_keys<=0;local_valid<=0;follow_valid<=0;action<=0;follow_action<=0;end
        else begin
            previous_keys<=pressed_sync[1:0];
            if(local_valid && local_ready)begin
                if(follow_valid)begin action<=follow_action;follow_valid<=0;end
                else local_valid<=0;
            end
            if(!local_valid && |new_press)begin
                local_valid<=1;
                if(new_press[1])begin
                    if(playing)begin action<=0;follow_action<=6;follow_valid<=1;end
                    else action<=guide ? 7 : 6;
                end else begin
                    if(guide && !playing)begin action<=7;follow_action<=1;follow_valid<=1;end
                    else action<=playing ? 0 : 1;
                end
            end
        end
    end
    reg [1:0] video_reset=0;
    always @(posedge pixel_clk or negedge video_locked)begin
        if(!video_locked)video_reset<=0;else video_reset<={video_reset[0],rst_n};
    end
    wire [9:0] x,y;wire hs,vs,de,hs_aligned,vs_aligned,de_aligned;wire [23:0] rgb;
    video_timing_640x480 timing(.clk(pixel_clk),.reset(!video_reset[1]),.pixel_x(x),.pixel_y(y),.hsync(hs),.vsync(vs),.de(de));
    instrument_full_system system(.clk(audio_clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .mpr_scl(mpr_scl),.mpr_sda(mpr_sda),.mpr_irq_n(mpr_irq_n),
        .local_action_valid(local_valid),.local_action_ready(local_ready),.local_action(action),
        .i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data),.guide_led_data(guide_led_data),
        .active_count(voices),.sensor_ready(sensor_ready),.sensor_fault(sensor_fault),.underrun_count(underruns),
        .overflow_sticky(overflow),.playing(playing),.recording(recording),.guide_active(guide),
        .video_clk(pixel_clk),.video_x(x),.video_y(y),.video_de(de),.video_rgb(rgb));
    video_sync_align #(.LATENCY(2)) align(.clk(pixel_clk),.reset(!video_reset[1]),
        .hsync_in(hs),.vsync_in(vs),.de_in(de),.hsync_out(hs_aligned),.vsync_out(vs_aligned),.de_out(de_aligned));
    video_tmds_tx video(.clk_pixel(pixel_clk),.clk_serial(serial_clk),.reset(!video_reset[1]),
        .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]),.hsync(hs_aligned),.vsync(vs_aligned),.de(de_aligned),
        .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),.tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n));
endmodule
