`timescale 1ns/1ps
// 从OLED实际I2C引脚解码128字节连续写，核对波形/菜单切换及NACK恢复。
module tb_oled_wave_display;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    tri1 scl, sda;
    reg ack_low = 0;
    reg nack = 0;
    assign sda = ack_low ? 1'b0 : 1'bz;
    reg activity = 0;
    reg [7:0] volume = 37;
    reg signed [23:0] audio = 327680;
    always @(negedge clk) audio = -audio;
    wire fault;
    wire [31:0] frames;
    oled_status_display #(.CLK_HZ(1000000), .I2C_HZ(100000), .PERFORMANCE_UI_ENABLE(1),
        .POWER_WAIT_CYCLES(8), .FRAME_WAIT_CYCLES(8), .WAVEFORM_ENABLE(1),
        .WAVE_IDLE_CYCLES(8), .WAVE_FRAME_WAIT_CYCLES(8)) dut (
        .clk(clk), .rst_n(rst_n), .main_menu(1'b0), .menu_page(2'd0), .zone(2'd0),
        .recording(1'b0), .playing(1'b0), .guide(1'b0), .busy(1'b0), .error(8'd0),
        .record_count(16'd0), .performance_mode(1'b1), .volume_percent(volume),
        .ui_activity(activity), .audio_sample_valid(1'b1), .audio_sample(audio),
        .scl(scl), .sda(sda), .fault(fault), .completed_frames(frames)
    );
    reg [7:0] image[0:1023];
    reg [7:0] font[0:2047];
    reg [7:0] address, control, value;
    integer pixel_count = 0, command_count = 0, stream_count = 0, screen_page = 0;
    integer b, index, x, p, bit_number, y;
    reg [7:0] expected;
    task receive_byte(output reg [7:0] byte_value);
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                @(posedge scl);
                byte_value[k] = sda;
            end
            @(negedge scl);
            ack_low = !nack;
            @(posedge scl);
            @(negedge scl);
            ack_low = 0;
        end
    endtask
    initial forever begin
        @(negedge sda);
        if (scl === 1'b1 && rst_n) begin
            receive_byte(address);
            if (!nack) begin
                if (address !== 8'h78) $fatal(1, "wrong OLED address");
                receive_byte(control);
                if (!nack && control == 0) begin
                    receive_byte(value);
                    command_count = command_count + 1;
                    if (value >= 8'hb0 && value <= 8'hb7)
                        screen_page = value - 8'hb0;
                end else if (!nack && control == 8'h40) begin
                    for (b = 0; b < 128; b = b + 1) begin
                        receive_byte(value);
                        image[screen_page*128+b] = value;
                        pixel_count = pixel_count + 1;
                    end
                    stream_count = stream_count + 1;
                end else if (!nack) $fatal(1, "wrong OLED control");
            end
        end
    end
    initial begin
        $readmemh("rtl/audio/rom/menu_font.hex", font);
        repeat (5) @(negedge clk);
        rst_n = 1;
        wait (frames == 1);
        @(negedge clk);
        if (pixel_count != 1024 || stream_count != 8 || command_count != 49 || fault)
            $fatal(1, "stream frame count mismatch");
        for (p = 2; p < 8; p = p + 1) begin
            expected = 0;
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                y = (p-2)*8+bit_number;
                if (y >= 14 && y <= 34) expected[bit_number] = 1;
            end
            for (x = 0; x < 128; x = x + 1)
                if (image[p*128+x] !== expected) $fatal(1, "serial waveform byte p=%d x=%d", p, x);
        end
        $writememh("sim/audio_results/oled_idle_wave_frame.hex", image);
        activity = 1;
        volume = 60;
        wait (frames == 2);
        @(negedge clk);
        if (dut.snap_wave) $fatal(1, "touch did not return to UI");
        // 音量条的独立边界参考，确认唤醒后确实恢复原菜单像素。
        for (x = 0; x < 128; x = x + 1) begin
            if (x == 4 || x == 123)
                expected = 8'hfc;
            else if (x > 4 && x < 123)
                expected = x >= 6 && x <= 121 && (x-6)*100 < 60*116 ? 8'hfc : 8'h04;
            else expected = 0;
            if (image[4*128+x] !== expected) $fatal(1, "restored volume bar %d", x);
        end
        $writememh("sim/audio_results/oled_awake_menu_frame.hex", image);
        activity = 0;
        wait (dut.snap_wave && dut.screen_page == 2 && dut.column > 20);
        @(negedge clk);
        activity = 1;
        wait (!dut.snap_wave);
        wait (frames >= 3);
        if (fault) $fatal(1, "mid-frame wake fault");
        nack = 1;
        wait (fault);
        repeat (100) @(negedge clk);
        nack = 0;
        wait (frames >= 4);
        if (fault) $fatal(1, "NACK recovery failed");
        rst_n = 0;
        repeat (5) @(negedge clk);
        if (scl !== 1 || sda !== 1 || frames != 0) $fatal(1, "reset did not release lines");
        $display("OLED WAVE DISPLAY PASS burst pixels, wake, row-boundary abort, NACK/recovery and reset");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1, "wave display timeout frames=%d pixels=%d", frames, pixel_count);
    end
endmodule
