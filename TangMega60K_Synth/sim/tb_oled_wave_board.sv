`timescale 1ns/1ps
// 生产完整顶层：真实合成/PLL模型/I2S引脚解码，核对OLED波形确实来自发声样本。
// FAST=0只完成真实100kHz引脚时序检查；FAST=1加快OLED等待以导出完整屏幕。
module tb_oled_wave_board #(parameter FAST=1);
    GSR GSR(.GSRI(1'b1));
    reg sys_clk = 0;
    always #10 sys_clk = ~sys_clk;
    reg [2:0] keys = 7;
    tri1 [2:0] mpr_scl, mpr_sda;
    tri1 scl, sda;
    reg ack_low = 0;
    reg nack = 0;
    reg slide = 0;
    reg [11:0] position = 0;
    assign sda = ack_low ? 1'b0 : 1'bz;
    wire bclk, lrclk, audio_data;
    board_contest_full_top #(.DEBOUNCE_CYCLES(8), .OLED_WAVE_ENABLE(1),
        .OLED_WAVE_IDLE_CYCLES(256), .OLED_POWER_WAIT_CYCLES(8), .OLED_FRAME_WAIT_CYCLES(8),
        .OLED_I2C_HZ(FAST ? 3000000 : 100000)) dut (
        .sys_clk(sys_clk), .key_n(keys), .mpr_scl(mpr_scl), .mpr_sda(mpr_sda),
        .mpr_irq_n(3'b111), .uart_rx(1'b1), .i2s_bclk(bclk), .i2s_lrclk(lrclk),
        .i2s_data(audio_data), .oled_scl(scl), .oled_sda(sda)
    );
    defparam dut.oled_panel.display.WAVE_FRAME_WAIT_CYCLES=8;
    defparam dut.system.MENU_DEBOUNCE_CYCLES=4;
    defparam dut.system.MENU_LONG_PRESS_CYCLES=12;
    reg [7:0] image[0:1023];
    reg signed [23:0] decoded_pcm[0:511];
    integer decoded = 0, nonzero = 0, pixel_count = 0, stream_count = 0;
    reg previous_ws = 1;
    reg locked = 0;
    integer bit_count = 0;
    reg [23:0] word_value = 0;
    // 独立解码Philips I2S，不读取wave_capture内存作参考。
    always @(posedge bclk) if (dut.rst_n) begin
        if (lrclk !== previous_ws) begin
            previous_ws = lrclk;
            locked = 1;
            bit_count = 0;
            word_value = 0;
        end else if (locked) bit_count = bit_count + 1;
        if (locked && bit_count >= 1 && bit_count <= 24) begin
            word_value = {word_value[22:0], audio_data};
            if (!lrclk && bit_count == 24) begin
                if (decoded < 512) decoded_pcm[decoded] = word_value;
                decoded = decoded + 1;
                if (word_value != 0) nonzero = nonzero + 1;
            end
        end
    end
    time last_fall = 0, last_rise = 0;
    integer checked_low = 0, checked_high = 0;
    always @(negedge scl) begin
        if (!FAST && last_rise != 0) begin
            if ($time-last_rise < 4000) $fatal(1, "OLED waveform I2C high time");
            checked_high = checked_high + 1;
        end
        last_fall = $time;
    end
    always @(posedge scl) if (dut.rst_n && last_fall != 0) begin
        if (!FAST) begin
            if ($time-last_fall < 4700) $fatal(1, "OLED waveform I2C low time");
            checked_low = checked_low + 1;
        end
        last_rise = $time;
    end
    reg [7:0] address, control, value;
    integer screen_page = 0, byte_index;
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
        if (scl === 1 && dut.rst_n) begin
            receive_byte(address);
            if (!nack) begin
                if (address !== 8'h78) $fatal(1, "board OLED address");
                receive_byte(control);
                if (control == 0) begin
                    receive_byte(value);
                    if (value >= 8'hb0 && value <= 8'hb7) screen_page = value - 8'hb0;
                end else if (control == 8'h40) begin
                    for (byte_index = 0; byte_index < 128; byte_index = byte_index + 1) begin
                        receive_byte(value);
                        image[screen_page*128+byte_index] = value;
                        pixel_count = pixel_count + 1;
                    end
                    stream_count = stream_count + 1;
                end else $fatal(1, "board OLED control");
            end
        end
    end
    function integer reference_y(input integer pcm);
        integer value;
        begin
            value = pcm >>> 15;
            if (value > 22) value = 22;
            if (value < -22) value = -22;
            reference_y = 24-value;
        end
    endfunction
    integer x, p, k, first, top, bottom, y, mismatch = 0, curve_columns = 0;
    integer pcm_file, before_audio;
    reg [7:0] expected;
    initial begin
        // 仅模拟触摸状态，发声由真实板载KEY0与原曲谱/音源链产生。
        force dut.system.sensor_ready=3'b111;
        force dut.system.sensor_fault=3'b000;
        force dut.system.slider_active=slide;
        force dut.system.slider_position=position;
        wait (dut.rst_n);
        @(negedge sys_clk);
        keys = 3'b110;
        repeat (40) @(negedge sys_clk);
        keys = 7;
        wait (dut.playing);
        if (!FAST) begin
            wait (pixel_count >= 16);
            if (checked_low < 100 || checked_high < 100 || dut.system.underrun_count != 0)
                $fatal(1, "100kHz waveform timing/audio check");
            $display("OLED WAVE BOARD TIMING PASS 100kHz external timings, burst transfer and zero underruns");
            $finish;
        end
        wait (dut.oled_completed_frames == 2);
        @(negedge dut.audio_clk);
        if (decoded < 512 || nonzero < 100 || dut.system.underrun_count != 0 || !dut.oled_panel.display.snap_wave)
            $fatal(1, "no genuine audio or waveform snapshot");
        for (x = 0; x < 128; x = x + 1) begin
            top = 47;
            bottom = 0;
            first = x == 0 ? 0 : x*4-1;
            for (k = first; k < x*4+4; k = k + 1) begin
                y = reference_y($signed(decoded_pcm[k]));
                if (y < top) top = y;
                if (y > bottom) bottom = y;
            end
            if (top != 24 || bottom != 24) curve_columns = curve_columns + 1;
            for (p = 2; p < 8; p = p + 1) begin
                expected = 0;
                for (k = 0; k < 8; k = k + 1) begin
                    y = (p-2)*8+k;
                    if ((y >= top && y <= bottom) || (y == 24 && x%8 == 0)) expected[k] = 1;
                end
                if (image[p*128+x] !== expected) mismatch = mismatch + 1;
            end
        end
        if (mismatch || curve_columns < 32) $fatal(1, "I2S to OLED mismatch=%d curve=%d", mismatch, curve_columns);
        $writememh("sim/audio_results/oled_real_audio_frame.hex", image);
        pcm_file = $fopen("sim/audio_results/oled_scope_pcm.csv", "w");
        $fdisplay(pcm_file, "frame,left");
        for (k = 0; k < 512; k = k + 1) $fdisplay(pcm_file, "%0d,%0d", k, $signed(decoded_pcm[k]));
        $fclose(pcm_file);
        // 同一滑条输入唤醒并长按，确认没有吞掉手势，随后空闲仍停留总菜单。
        slide = 1;
        position = 0;
        repeat (30) @(negedge dut.audio_clk);
        slide = 0;
        repeat (1200) @(negedge dut.audio_clk);
        if (!dut.menu_main || dut.menu_volume_mode || !dut.oled_panel.display.wave_requested)
            $fatal(1, "waveform idle changed menu state");
        // OLED拔掉不应影响真实音源持续供数。
        nack = 1;
        wait (dut.oled_fault);
        before_audio = decoded;
        repeat (20000) @(negedge dut.audio_clk);
        if (decoded < before_audio+10 || dut.system.underrun_count != 0)
            $fatal(1, "OLED disconnect disturbed audio");
        $display("OLED WAVE BOARD PASS decoded PCM to 768 pixel bytes, menu wake, idle preserve and audio fault isolation");
        $finish;
    end
    initial begin
        #300000000;
        $fatal(1, "wave board timeout FAST=%d frames=%d pcm=%d", FAST, dut.oled_completed_frames, decoded);
    end
endmodule
