`timescale 1ps/1ps
module tb_board_instrument_b_48k_gao;
    reg sys_clk = 0;
    always #10000 sys_clk = ~sys_clk;
    reg [2:0] key_n = 3'b111;
    wire rgb_data, pa_disable;
    board_instrument_b_48k_gao_top #(
        .RESET_CYCLES(64), .HOLD_CYCLES(32768),
        .TIMEOUT_CYCLES(500000), .DEBOUNCE_CYCLES(8)
    ) dut (
        .sys_clk(sys_clk), .key_n(key_n),
        .rgb_data(rgb_data), .pa_disable(pa_disable)
    );
    // Only the simulation shortens the envelope tail; hardware keeps 100 ms.
    defparam dut.u_instrument.u_audio.u_engine.RELEASE_MS = 1;

    integer on_mask = 0, off_mask = 0;
    integer serial_ones = 0, lrclk_edges = 0;
    reg old_lrclk = 0;
    time last_bclk_edge = 0;
    always @(posedge dut.audio_clk) begin
        if (dut.rst_n) begin
            if (dut.serial_data) serial_ones = serial_ones + 1;
            if (dut.lrclk != old_lrclk) lrclk_edges = lrclk_edges + 1;
            if (dut.u_instrument.u_audio.cmd_valid &&
                dut.u_instrument.u_audio.cmd_ready) begin
                case (dut.u_instrument.u_audio.cmd_note)
                    7'd69: if (dut.u_instrument.u_audio.cmd_on) on_mask = on_mask | 1;
                           else off_mask = off_mask | 1;
                    7'd60: if (dut.u_instrument.u_audio.cmd_on) on_mask = on_mask | 2;
                           else off_mask = off_mask | 2;
                    7'd64: if (dut.u_instrument.u_audio.cmd_on) on_mask = on_mask | 4;
                           else off_mask = off_mask | 4;
                    7'd67: if (dut.u_instrument.u_audio.cmd_on) on_mask = on_mask | 8;
                           else off_mask = off_mask | 8;
                    default: $fatal(1, "Unexpected or unsaved B event note %0d",
                                    dut.u_instrument.u_audio.cmd_note);
                endcase
                if (dut.u_instrument.u_audio.cmd_timbre != 2'd2)
                    $fatal(1, "B event lost the saved piano timbre");
            end
            old_lrclk <= dut.lrclk;
        end else old_lrclk <= 0;
        if (dut.fault) $fatal(1, "B board self-test failed at phase %0d", dut.phase);
    end
    always @(posedge dut.bclk or negedge dut.rst_n) begin
        if (!dut.rst_n) last_bclk_edge = 0;
        else begin
            if (last_bclk_edge != 0 &&
                ($time-last_bclk_edge < 325500 || $time-last_bclk_edge > 325600))
                $fatal(1, "BCLK period is not 16 audio clocks");
            last_bclk_edge = $time;
        end
    end

    initial begin
        wait(dut.phase == 7 && dut.rst_n); // HOLD, after the chord expanded.
        repeat (2) @(posedge dut.audio_clk);
        if (!dut.pll_locked || !pa_disable || dut.active_count != 4 ||
            dut.events_pushed != 4 || dut.events_delivered != 4 ||
            dut.event_fifo_level != 0 || dut.underruns != 0 ||
            dut.current_expr_gain != 1800 ||
            dut.current_expr_bend_cents != 25 ||
            dut.current_expr_vibrato_cents != 7)
            $fatal(1, "B board note/chord/expression check failed");
        wait(dut.completed_runs == 1);
        if (on_mask != 15 || off_mask != 15 || serial_ones == 0 ||
            lrclk_edges < 8 || dut.underruns != 0 || dut.fault)
            $fatal(1, "B board first pass failed on=%0d off=%0d bits=%0d frames=%0d",
                   on_mask, off_mask, serial_ones, lrclk_edges);
        wait(dut.completed_runs == 2);
        if (dut.fault || dut.underruns != 0)
            $fatal(1, "B board repeat pass failed");
        key_n = 3'b011; // KEY2 is the normal board key, not the PWR key.
        wait(dut.pressed_sync[2]);
        repeat (3) @(posedge dut.audio_clk);
        if (dut.rst_n || dut.completed_runs != 0 || dut.fault)
            $fatal(1, "KEY2 did not restart the B board check");
        $display("BOARD B 48K GAO PASSED runs=2 on_mask=%0d off_mask=%0d data_ones=%0d lrclk_edges=%0d",
                 on_mask, off_mask, serial_ones, lrclk_edges);
        $finish;
    end
    initial begin
        #100000000000;
        $fatal(1, "B board GAO simulation timed out");
    end
endmodule
