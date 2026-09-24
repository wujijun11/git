`timescale 1ns/1ps

module tb_interaction_v2;
    localparam integer DEPTH = 8;
    localparam integer AWIDTH = 3;
    localparam integer EVW = 23;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;

    reg in_valid = 0, in_on = 0;
    reg [5:0] in_source = 0;
    reg [6:0] in_note = 0, in_velocity = 0;
    reg [1:0] in_timbre = 0;
    wire in_ready;

    reg chord_valid = 0, chord_on = 0;
    reg [2:0] chord_id = 0;
    reg [5:0] chord_source = 0;
    reg [3:0] chord_count = 0;
    reg [55:0] chord_notes_flat = 0;
    reg [6:0] chord_velocity = 0;
    reg [1:0] chord_timbre = 0;
    wire chord_ready;

    wire event_valid, event_ready, event_on;
    wire [5:0] event_source;
    wire [6:0] event_note, event_velocity;
    wire [1:0] event_timbre;

    reg expr_update_valid = 0;
    reg [2:0] expr_update_mask = 0;
    reg [11:0] expr_update_gain = 12'd2048;
    reg signed [12:0] expr_update_bend_cents = 13'sd0;
    reg [7:0] expr_update_vibrato_cents = 8'd0;
    wire expr_update_ready;
    wire expr_valid, expr_ready;
    wire [11:0] expr_gain;
    wire signed [12:0] expr_bend_cents;
    wire [7:0] expr_vibrato_cents;

    wire [AWIDTH:0] fifo_level;
    wire fifo_full, event_backpressure, overflow_pulse, overflow_sticky;
    wire [31:0] overflow_count, pushed_count, event_count;
    wire [11:0] current_expr_gain;
    wire signed [12:0] current_expr_bend_cents;
    wire [7:0] current_expr_vibrato_cents;

    reg engine_sample_begin = 0;
    wire [11:0] active_gain;
    wire signed [12:0] active_bend_cents;
    wire [7:0] active_vibrato_cents;
    wire expr_applied;

    wire cmd_valid, cmd_on;
    reg cmd_ready = 1;
    wire [5:0] cmd_voice;
    wire [6:0] cmd_note, cmd_velocity;
    wire [1:0] cmd_timbre;
    reg done_valid = 0;
    reg [5:0] done_voice = 0;
    wire done_ready;
    wire [6:0] active_count;
    wire [63:0] active_mask, held_mask;
    wire full_pulse, ignored_pulse, done_error_pulse;

    interaction_top_v2 #(.DEPTH(DEPTH), .AWIDTH(AWIDTH)) u_b (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready), .in_on(in_on),
        .in_source(in_source), .in_note(in_note),
        .in_velocity(in_velocity), .in_timbre(in_timbre),
        .chord_valid(chord_valid), .chord_ready(chord_ready),
        .chord_on(chord_on), .chord_id(chord_id),
        .chord_source(chord_source), .chord_count(chord_count),
        .chord_notes_flat(chord_notes_flat),
        .chord_velocity(chord_velocity), .chord_timbre(chord_timbre),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_source(event_source),
        .event_note(event_note), .event_velocity(event_velocity),
        .event_timbre(event_timbre),
        .expr_update_valid(expr_update_valid),
        .expr_update_ready(expr_update_ready),
        .expr_update_mask(expr_update_mask),
        .expr_update_gain(expr_update_gain),
        .expr_update_bend_cents(expr_update_bend_cents),
        .expr_update_vibrato_cents(expr_update_vibrato_cents),
        .expr_valid(expr_valid), .expr_ready(expr_ready),
        .expr_gain(expr_gain), .expr_bend_cents(expr_bend_cents),
        .expr_vibrato_cents(expr_vibrato_cents),
        .fifo_level(fifo_level), .fifo_full(fifo_full),
        .event_backpressure(event_backpressure),
        .overflow_pulse(overflow_pulse), .overflow_sticky(overflow_sticky),
        .overflow_count(overflow_count),
        .pushed_count(pushed_count), .event_count(event_count),
        .current_expr_gain(current_expr_gain),
        .current_expr_bend_cents(current_expr_bend_cents),
        .current_expr_vibrato_cents(current_expr_vibrato_cents)
    );

    captain_control_top_v2 u_captain (
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_source(event_source),
        .event_note(event_note), .event_velocity(event_velocity),
        .event_timbre(event_timbre),
        .expr_valid(expr_valid), .expr_ready(expr_ready),
        .expr_gain(expr_gain), .expr_bend_cents(expr_bend_cents),
        .expr_vibrato_cents(expr_vibrato_cents),
        .engine_sample_begin(engine_sample_begin),
        .active_gain(active_gain), .active_bend_cents(active_bend_cents),
        .active_vibrato_cents(active_vibrato_cents), .expr_applied(expr_applied),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_on(cmd_on), .cmd_voice(cmd_voice), .cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity), .cmd_timbre(cmd_timbre),
        .done_valid(done_valid), .done_ready(done_ready), .done_voice(done_voice),
        .active_count(active_count), .active_mask(active_mask),
        .held_mask(held_mask), .full_pulse(full_pulse),
        .ignored_pulse(ignored_pulse), .done_error_pulse(done_error_pulse)
    );

    reg prev_event_stall = 0;
    reg [EVW-1:0] held_event = 0;
    wire [EVW-1:0] event_payload =
        {event_on, event_source, event_note, event_velocity, event_timbre};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_event_stall <= 0;
            held_event <= 0;
        end else begin
            if (prev_event_stall && (event_valid !== 1'b1 || event_payload !== held_event))
                $fatal(1, "event payload changed while event_ready was low");
            prev_event_stall <= event_valid && !event_ready;
            held_event <= event_payload;
        end
    end

    reg prev_expr_stall = 0;
    reg [32:0] held_expr = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_expr_stall <= 0;
            held_expr <= 0;
        end else begin
            if (prev_expr_stall &&
                (expr_valid !== 1'b1 ||
                 {expr_gain, expr_bend_cents, expr_vibrato_cents} !== held_expr))
                $fatal(1, "expression payload changed while expr_ready was low");
            prev_expr_stall <= expr_valid && !expr_ready;
            held_expr <= {expr_gain, expr_bend_cents, expr_vibrato_cents};
        end
    end

    task automatic reset_system;
        begin
            @(negedge clk);
            rst_n = 0;
            in_valid = 0;
            chord_valid = 0;
            expr_update_valid = 0;
            cmd_ready = 1;
            engine_sample_begin = 0;
            repeat (5) @(negedge clk);
            rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic mark(input integer id);
        begin
            $display("  V2 interaction case %0d", id);
        end
    endtask

    task automatic send_raw(input bit on_v, input integer src_v,
                            input integer note_v, input integer vel_v,
                            input integer timb_v);
        begin
            @(negedge clk);
            in_valid = 1;
            in_on = on_v;
            in_source = src_v[5:0];
            in_note = note_v[6:0];
            in_velocity = vel_v[6:0];
            in_timbre = timb_v[1:0];
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 0;
        end
    endtask

    task automatic expect_cmd(input bit on_v, input integer note_v);
        integer guard;
        begin
            guard = 0;
            while (!cmd_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 1000) $fatal(1, "timeout waiting for cmd");
            end
            if (cmd_on !== on_v || cmd_note !== note_v[6:0])
                $fatal(1, "cmd mismatch: on=%0d note=%0d, want on=%0d note=%0d",
                       cmd_on, cmd_note, on_v, note_v);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic send_chord(input bit on_v, input integer id_v,
                              input integer src_v, input integer count_v,
                              input integer n0, input integer n1,
                              input integer n2);
        begin
            @(negedge clk);
            chord_valid = 1;
            chord_on = on_v;
            chord_id = id_v[2:0];
            chord_source = src_v[5:0];
            chord_count = count_v[3:0];
            chord_notes_flat = 0;
            chord_notes_flat[6:0] = n0[6:0];
            chord_notes_flat[13:7] = n1[6:0];
            chord_notes_flat[20:14] = n2[6:0];
            chord_velocity = 7'd100;
            chord_timbre = 2'd1;
            do @(posedge clk); while (!chord_ready);
            @(negedge clk);
            chord_valid = 0;
            // Once the request is accepted, the producer may immediately
            // reuse its payload bus. Emitted notes must come from the saved
            // chord snapshot rather than these deliberately changed values.
            chord_source = 6'd63;
            chord_notes_flat = '1;
            chord_velocity = 7'd1;
            chord_timbre = 2'd3;
        end
    endtask

    task automatic update_expr(input [2:0] mask_v, input integer gain_v,
                               input integer bend_v, input integer vib_v);
        begin
            @(negedge clk);
            expr_update_valid = 1;
            expr_update_mask = mask_v;
            expr_update_gain = gain_v[11:0];
            expr_update_bend_cents = bend_v;
            expr_update_vibrato_cents = vib_v[7:0];
            do @(posedge clk); while (!expr_update_ready);
            @(negedge clk);
            expr_update_valid = 0;
        end
    endtask

    task automatic apply_expr;
        begin
            @(negedge clk);
            engine_sample_begin = 1;
            @(negedge clk);
            engine_sample_begin = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic wait_counts_equal;
        integer guard;
        begin
            guard = 0;
            while (pushed_count != event_count || fifo_level != 0) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000) $fatal(1, "drain timeout");
            end
        end
    endtask

    initial begin
        reset_system();

        mark(1);
        if (current_expr_gain !== 12'd2048 || current_expr_bend_cents !== 13'sd0 ||
            current_expr_vibrato_cents !== 8'd0 || active_gain !== 12'd2048 ||
            active_bend_cents !== 13'sd0 || active_vibrato_cents !== 8'd0)
            $fatal(1, "reset defaults are wrong");

        mark(2);
        send_raw(1'b1, 1, 60, 100, 0);
        expect_cmd(1'b1, 60);
        if (cmd_voice !== 0) $fatal(1, "first C4 voice was %0d", cmd_voice);
        send_raw(1'b1, 2, 60, 100, 0);
        expect_cmd(1'b1, 60);
        if (cmd_voice !== 1) $fatal(1, "same note from source 2 reused voice %0d", cmd_voice);
        send_raw(1'b0, 1, 60, 0, 0);
        expect_cmd(1'b0, 60);
        if (cmd_voice !== 0) $fatal(1, "release source 1 targeted voice %0d", cmd_voice);
        if (held_mask[1] !== 1'b1) $fatal(1, "source 2 same-note voice was released");
        send_raw(1'b0, 2, 60, 0, 0);
        expect_cmd(1'b0, 60);
        if (cmd_voice !== 1) $fatal(1, "release source 2 targeted voice %0d", cmd_voice);

        // A key release may arrive after the key/scale mapping has changed.
        // The interaction boundary must release the note captured at key-down.
        send_raw(1'b1, 3, 62, 100, 2);
        expect_cmd(1'b1, 62);
        send_raw(1'b0, 3, 75, 0, 0);
        expect_cmd(1'b0, 62);

        mark(3);
        send_chord(1'b1, 0, 10, 3, 60, 64, 67);
        expect_cmd(1'b1, 60);
        expect_cmd(1'b1, 64);
        expect_cmd(1'b1, 67);
        send_chord(1'b1, 1, 11, 3, 60, 64, 67);
        expect_cmd(1'b1, 60);
        expect_cmd(1'b1, 64);
        expect_cmd(1'b1, 67);
        send_chord(1'b0, 0, 10, 3, 62, 65, 69);
        expect_cmd(1'b0, 60);
        expect_cmd(1'b0, 64);
        expect_cmd(1'b0, 67);
        send_chord(1'b0, 1, 11, 3, 72, 76, 79);
        expect_cmd(1'b0, 60);
        expect_cmd(1'b0, 64);
        expect_cmd(1'b0, 67);

        // A repeated down event while a physical key/chord is still held is
        // acknowledged but must not replace the original release snapshot.
        send_raw(1'b1, 4, 65, 100, 2);
        expect_cmd(1'b1, 65);
        wait_counts_equal();
        begin : duplicate_raw_check
            integer before_push;
            before_push = pushed_count;
            send_raw(1'b1, 4, 76, 100, 1);
            repeat (4) @(negedge clk);
            if (pushed_count !== before_push)
                $fatal(1, "duplicate key-down emitted an event");
        end
        send_raw(1'b0, 4, 76, 0, 1);
        expect_cmd(1'b0, 65);

        send_chord(1'b1, 2, 12, 3, 65, 69, 72);
        expect_cmd(1'b1, 65);
        expect_cmd(1'b1, 69);
        expect_cmd(1'b1, 72);
        wait_counts_equal();
        begin : duplicate_chord_check
            integer before_push;
            before_push = pushed_count;
            send_chord(1'b1, 2, 12, 3, 66, 70, 73);
            repeat (4) @(negedge clk);
            if (pushed_count !== before_push)
                $fatal(1, "duplicate chord-down emitted an event");
        end
        send_chord(1'b0, 2, 12, 3, 66, 70, 73);
        expect_cmd(1'b0, 65);
        expect_cmd(1'b0, 69);
        expect_cmd(1'b0, 72);

        mark(4);
        cmd_ready = 0;
        send_raw(1'b1, 20, 70, 80, 0);
        expect_cmd(1'b1, 70);
        @(negedge clk);
        in_valid = 1;
        in_on = 1'b0;
        in_source = 6'd20;
        in_note = 7'd70;
        in_velocity = 7'd0;
        in_timbre = 2'd0;
        repeat (DEPTH + 20) @(negedge clk);
        if (!event_backpressure || !overflow_sticky || overflow_count == 0)
            $fatal(1, "FIFO backpressure/overflow telemetry did not assert");
        if ({in_on, in_source, in_note, in_velocity, in_timbre} !==
            {1'b0, 6'd20, 7'd70, 7'd0, 2'd0})
            $fatal(1, "held note-off changed while backpressured");
        cmd_ready = 1;
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        in_valid = 0;
        expect_cmd(1'b0, 70);
        wait_counts_equal();

        mark(5);
        update_expr(3'b001, 12'd1024, 0, 0);
        if (current_expr_gain !== 12'd1024 || current_expr_bend_cents !== 13'sd0 ||
            current_expr_vibrato_cents !== 8'd0)
            $fatal(1, "gain-only update disturbed other expression fields");
        update_expr(3'b010, 12'd3000, -13'sd120, 8'd50);
        if (current_expr_gain !== 12'd1024 || current_expr_bend_cents !== -13'sd120 ||
            current_expr_vibrato_cents !== 8'd0)
            $fatal(1, "bend-only update did not preserve gain/vibrato");
        repeat (5) @(negedge clk);
        if (!expr_valid || expr_ready)
            $fatal(1, "expression channel did not hold a pending snapshot");
        apply_expr();
        apply_expr();
        if (active_gain !== 12'd1024 || active_bend_cents !== -13'sd120 ||
            active_vibrato_cents !== 8'd0)
            $fatal(1, "active expression snapshot mismatch after gain/bend");
        update_expr(3'b100, 12'd1, 13'sd99, 8'd33);
        apply_expr();
        if (active_gain !== 12'd1024 || active_bend_cents !== -13'sd120 ||
            active_vibrato_cents !== 8'd33)
            $fatal(1, "vibrato-only update did not preserve gain/bend");

        mark(6);
        reset_system();
        if (current_expr_gain !== 12'd2048 || current_expr_bend_cents !== 13'sd0 ||
            current_expr_vibrato_cents !== 8'd0 || fifo_level !== 0 ||
            pushed_count !== 0 || event_count !== 0 || overflow_count !== 0 ||
            overflow_sticky !== 1'b0)
            $fatal(1, "reset did not restore V2 interaction defaults");

        $display("ALL V2 INTERACTION TESTS PASSED");
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "V2 interaction watchdog expired");
    end
endmodule
