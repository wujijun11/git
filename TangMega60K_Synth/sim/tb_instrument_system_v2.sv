`timescale 1ns/1ps

module tb_instrument_system_v2 #(parameter integer TIMBRE = 0);
    reg clk = 0;
    // 49.152 MHz audio clock (rounded to the simulator's 1 ps resolution).
    always #10.172526 clk = ~clk;
    reg test_passed = 0;

    reg rst_n = 0;
    reg key_valid = 0, key_on = 0;
    reg [5:0] key_source = 0;
    reg [6:0] key_note = 0, key_velocity = 0;
    reg [1:0] key_timbre = 0;
    wire key_ready;
    reg chord_valid = 0, chord_on = 0;
    reg [2:0] chord_id = 0;
    reg [5:0] chord_source = 0;
    reg [3:0] chord_count = 0;
    reg [55:0] chord_notes_flat = 0;
    reg [6:0] chord_velocity = 0;
    reg [1:0] chord_timbre = 0;
    wire chord_ready;
    reg expr_update_valid = 0;
    reg [2:0] expr_update_mask = 0;
    reg [11:0] expr_update_gain = 2048;
    reg signed [12:0] expr_update_bend_cents = 0;
    reg [7:0] expr_update_vibrato_cents = 0;
    wire expr_update_ready;
    wire i2s_bclk, i2s_lrclk, i2s_data;
    wire [6:0] active_count;
    wire voice_full_pulse, done_error_pulse;
    wire [31:0] i2s_underrun_count;
    wire [5:0] event_fifo_level;
    wire event_fifo_full, event_backpressure;
    wire event_overflow_pulse, event_overflow_sticky;
    wire [31:0] event_overflow_count, events_pushed, events_delivered;
    wire [11:0] current_expr_gain;
    wire signed [12:0] current_expr_bend_cents;
    wire [7:0] current_expr_vibrato_cents;

    instrument_system_v2 #(.FM_ENABLE(TIMBRE == 3)) dut (
        .clk(clk), .rst_n(rst_n),
        .key_valid(key_valid), .key_ready(key_ready), .key_on(key_on),
        .key_source(key_source), .key_note(key_note),
        .key_velocity(key_velocity), .key_timbre(key_timbre),
        .chord_valid(chord_valid), .chord_ready(chord_ready),
        .chord_on(chord_on), .chord_id(chord_id),
        .chord_source(chord_source), .chord_count(chord_count),
        .chord_notes_flat(chord_notes_flat),
        .chord_velocity(chord_velocity), .chord_timbre(chord_timbre),
        .expr_update_valid(expr_update_valid),
        .expr_update_ready(expr_update_ready),
        .expr_update_mask(expr_update_mask),
        .expr_update_gain(expr_update_gain),
        .expr_update_bend_cents(expr_update_bend_cents),
        .expr_update_vibrato_cents(expr_update_vibrato_cents),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .active_count(active_count), .voice_full_pulse(voice_full_pulse),
        .done_error_pulse(done_error_pulse),
        .i2s_underrun_count(i2s_underrun_count),
        .event_fifo_level(event_fifo_level), .event_fifo_full(event_fifo_full),
        .event_backpressure(event_backpressure),
        .event_overflow_pulse(event_overflow_pulse),
        .event_overflow_sticky(event_overflow_sticky),
        .event_overflow_count(event_overflow_count),
        .events_pushed(events_pushed), .events_delivered(events_delivered),
        .current_expr_gain(current_expr_gain),
        .current_expr_bend_cents(current_expr_bend_cents),
        .current_expr_vibrato_cents(current_expr_vibrato_cents)
    );

    integer bclk_edges = 0, lrclk_edges = 0, data_ones = 0;
    integer cycle = 0, last_bclk = 0, last_lrclk = 0;
    reg release_seen = 0;
    reg old_bclk = 0, old_lrclk = 0;
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (rst_n && i2s_bclk != old_bclk) begin
            if (last_bclk != 0 && cycle - last_bclk != 8)
                $fatal(1, "BCLK half-period is not 8 audio clocks");
            last_bclk <= cycle;
        end
        if (rst_n && i2s_lrclk != old_lrclk) begin
            if (last_lrclk != 0 && cycle - last_lrclk != 512)
                $fatal(1, "LRCLK half-period is not 512 audio clocks");
            last_lrclk <= cycle;
        end
        if (rst_n && dut.u_audio.cmd_valid && dut.u_audio.cmd_ready) begin
            if (dut.u_audio.cmd_note !== 7'd69 || dut.u_audio.cmd_timbre !== TIMBRE[1:0])
                $fatal(1, "saved note/timbre did not reach the audio engine");
            if (!dut.u_audio.cmd_on) release_seen <= 1;
        end
        old_bclk <= i2s_bclk;
        old_lrclk <= i2s_lrclk;
        if (rst_n && i2s_bclk != old_bclk) bclk_edges <= bclk_edges + 1;
        if (rst_n && i2s_lrclk != old_lrclk) lrclk_edges <= lrclk_edges + 1;
        if (rst_n && i2s_data) data_ones <= data_ones + 1;
        if (done_error_pulse) $fatal(1, "unexpected allocator done error");
    end

    task automatic send_key(input bit on_v, input integer note_v, input integer velocity_v);
        begin
            @(negedge clk);
            key_valid = 1;
            key_on = on_v;
            key_source = 6'd3;
            key_note = note_v[6:0];
            key_velocity = velocity_v[6:0];
            key_timbre = on_v ? TIMBRE[1:0] : 2'd1;
            do @(posedge clk); while (!key_ready);
            @(negedge clk);
            key_valid = 0;
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);
        if (current_expr_gain !== 12'd2048 || current_expr_bend_cents !== 0 ||
            current_expr_vibrato_cents !== 0)
            $fatal(1, "expression reset defaults mismatch");

        send_key(1'b1, 69, 127);
        wait (active_count == 1);

        @(negedge clk);
        expr_update_valid = 1;
        expr_update_mask = 3'b111;
        expr_update_gain = 12'd1800;
        expr_update_bend_cents = 13'sd25;
        expr_update_vibrato_cents = 8'd7;
        do @(posedge clk); while (!expr_update_ready);
        @(negedge clk);
        expr_update_valid = 0;

        repeat (20000) @(posedge clk);
        if (events_pushed !== 1 || events_delivered !== 1 || event_fifo_level !== 0)
            $fatal(1, "event FIFO conservation failed");
        if (current_expr_gain !== 12'd1800 || current_expr_bend_cents !== 13'sd25 ||
            current_expr_vibrato_cents !== 8'd7)
            $fatal(1, "expression update did not reach integration boundary");
        if (dut.u_audio.active_gain !== 12'd1800 ||
            dut.u_audio.active_bend_cents !== 13'sd25 ||
            dut.u_audio.active_vibrato_cents !== 8'd7)
            $fatal(1, "expression update did not reach the audio engine");
        if (i2s_underrun_count !== 0)
            $fatal(1, "startup or running I2S underrun after merge");
        if (bclk_edges < 100 || lrclk_edges < 2)
            $fatal(1, "I2S clocks did not run");
        if (data_ones == 0)
            $fatal(1, "I2S data remained silent after note-on");
        if (event_overflow_sticky || event_overflow_count != 0)
            $fatal(1, "unexpected input FIFO overflow");

        send_key(1'b0, 100, 0); // release must use the saved note 69
        wait (events_pushed == 2 && events_delivered == 2);
        wait (release_seen);
        @(negedge clk);
        if (event_fifo_level !== 0 || i2s_underrun_count !== 0)
            $fatal(1, "release left pending events or caused an underrun");
        test_passed = 1;
        $display("ALL INSTRUMENT V2 INTEGRATION TESTS PASSED timbre=%0d active=%0d bclk_edges=%0d lrclk_edges=%0d underrun=%0d",
                 TIMBRE, active_count, bclk_edges, lrclk_edges, i2s_underrun_count);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "instrument integration watchdog expired");
    end
endmodule
