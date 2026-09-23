`timescale 1ps/1ps
module tb_board_audio_48k_i2s;
    reg sys_clk = 0;
    always #10000 sys_clk = ~sys_clk;
    reg [2:0] key_n = 3'b111;
    wire rgb_data, pa_disable, i2s_bclk, i2s_lrclk, i2s_data;
    board_audio_48k_i2s_top #(.DEBOUNCE_CYCLES(8)) dut (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data)
    );
    // Keep the production 100 ms release unchanged; shorten only this test's
    // envelope tail so a full stop-and-restart check finishes promptly.
    defparam dut.u_live64.u_audio.u_engine.RELEASE_MS = 1;

    reg last_lrclk = 1, aligned = 0;
    integer slot_bit = 0, complete_slots = 0, active_bits = 0;
    integer verified_slots, verified_bits, bits_before_restart;
    time last_bclk_edge = 0;
    always @(posedge i2s_bclk or negedge dut.rst_n) begin
        if (!dut.rst_n) begin
            last_lrclk = 1;
            aligned = 0;
            slot_bit = 0;
            complete_slots = 0;
            active_bits = 0;
            last_bclk_edge = 0;
        end else begin
            if (last_bclk_edge != 0 &&
                ($time-last_bclk_edge < 325500 || $time-last_bclk_edge > 325600))
                $fatal(1, "BCLK period is not 16 audio clocks");
            last_bclk_edge = $time;
            if (i2s_lrclk != last_lrclk) begin
                if (aligned && slot_bit != 31)
                    $fatal(1, "I2S channel slot has %0d bits", slot_bit+1);
                if (aligned) complete_slots = complete_slots + 1;
                aligned = 1;
                slot_bit = 0;
                last_lrclk = i2s_lrclk;
            end else if (aligned) slot_bit = slot_bit + 1;
            if (aligned) begin
                if ((slot_bit == 0 || slot_bit > 24) && i2s_data !== 1'b0)
                    $fatal(1, "I2S delay or padding bit is nonzero");
                if (dut.holding && slot_bit >= 1 && slot_bit <= 24 && i2s_data)
                    active_bits = active_bits + 1;
            end
        end
    end

    initial begin
        wait(dut.rst_n);
        if (!pa_disable || !dut.pll_locked)
            $fatal(1, "Board amp or audio clock is not ready");
        key_n = 3'b110; // Key 0 starts the existing 64-voice source.
        wait(dut.holding);
        repeat (32768) @(posedge dut.audio_clk);
        if (dut.active_count != 64 || dut.error || dut.underruns != 0 ||
            complete_slots < 20 || active_bits == 0)
            $fatal(1, "External I2S check failed: voices=%0d underruns=%0d slots=%0d active_bits=%0d",
                   dut.active_count, dut.underruns, complete_slots, active_bits);
        key_n = 3'b101; // Release start and press stop (key 1).
        wait(dut.released);
        if (dut.active_count != 0 || dut.error || dut.underruns != 0)
            $fatal(1, "I2S stop failed: voices=%0d underruns=%0d error=%0d",
                   dut.active_count, dut.underruns, dut.error);
        key_n = 3'b111;
        wait(!dut.pressed_sync[1]);
        wait(dut.start_ready);
        bits_before_restart = active_bits;
        key_n = 3'b110; // A new key-0 press must start a second session.
        wait(dut.holding);
        repeat (32768) @(posedge dut.audio_clk);
        if (dut.active_count != 64 || dut.error || dut.underruns != 0 ||
            active_bits <= bits_before_restart)
            $fatal(1, "I2S restart failed: voices=%0d underruns=%0d error=%0d",
                   dut.active_count, dut.underruns, dut.error);
        verified_slots = complete_slots;
        verified_bits = active_bits;
        key_n = 3'b011; // Release start and press reset (key 2).
        wait(!dut.rst_n);
        if (i2s_bclk !== 0 || i2s_data !== 0)
            $fatal(1, "I2S did not reset to silence");
        $display("BOARD 48K EXTERNAL I2S PASSED stop/restart/reset slots=%0d active_bits=%0d",
                 verified_slots, verified_bits);
        $finish;
    end
    initial begin
        #100000000000;
        $fatal(1, "48 kHz external I2S simulation timed out");
    end
endmodule
