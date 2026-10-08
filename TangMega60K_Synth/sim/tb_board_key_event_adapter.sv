`timescale 1ns/1ps
module tb_board_key_event_adapter;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0;
    reg [1:0] pressed = 0;
    reg key_ready = 0, chord_ready = 0;
    wire key_valid, key_on, chord_valid, chord_on;
    wire [5:0] key_source, chord_source;
    wire [6:0] key_note, key_velocity, chord_velocity;
    wire [1:0] key_timbre, chord_timbre;
    wire [2:0] chord_id;
    wire [3:0] chord_count;
    wire [55:0] chord_notes_flat;
    wire overflow_pulse, overflow_sticky;
    wire [4:0] pending_count;

    board_key_event_adapter dut (.*);

    // Independent shallow queue verifies full occupancy and overflow reporting.
    reg small_rst_n = 0;
    reg [1:0] small_pressed = 0;
    reg small_key_ready = 0, small_chord_ready = 0;
    wire small_key_valid, small_key_on, small_chord_valid, small_chord_on;
    wire small_overflow_pulse, small_overflow_sticky;
    wire [2:0] small_pending_count;
    board_key_event_adapter #(.QUEUE_DEPTH(4), .QUEUE_AWIDTH(2)) small_dut (
        .clk(clk), .rst_n(small_rst_n), .pressed(small_pressed),
        .key_valid(small_key_valid), .key_ready(small_key_ready), .key_on(small_key_on),
        .key_source(), .key_note(), .key_velocity(), .key_timbre(),
        .chord_valid(small_chord_valid), .chord_ready(small_chord_ready),
        .chord_on(small_chord_on), .chord_id(), .chord_source(),
        .chord_count(), .chord_notes_flat(), .chord_velocity(), .chord_timbre(),
        .overflow_pulse(small_overflow_pulse), .overflow_sticky(small_overflow_sticky),
        .pending_count(small_pending_count)
    );

    reg [1:0] expected [0:2047];
    integer enqueued = 0, delivered = 0, total_delivered = 0;
    reg [1:0] prior_pressed = 0;
    reg key_held = 0, chord_held = 0;
    integer logical_voices;
    reg key_was_stalled = 0, chord_was_stalled = 0;
    reg [24:0] stalled_key_payload;
    reg [79:0] stalled_chord_payload;
    wire [24:0] key_payload = {key_on, key_source, key_note, key_velocity, key_timbre};
    wire [79:0] chord_payload = {chord_on, chord_id, chord_source, chord_count,
                                chord_notes_flat, chord_velocity, chord_timbre};

    task check_delivery;
        input [1:0] actual;
        begin
            if (delivered >= enqueued || actual !== expected[delivered])
                $fatal(1, "Out of order event %0d: expected %b, got %b", delivered,
                       expected[delivered], actual);
            if (!actual[1]) begin
                if (key_held === actual[0]) $fatal(1, "Duplicate KEY0 transition");
                key_held = actual[0];
            end else begin
                if (chord_held === actual[0]) $fatal(1, "Duplicate KEY1 transition");
                chord_held = actual[0];
            end
            delivered = delivered + 1;
            total_delivered = total_delivered + 1;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            enqueued = 0;
            delivered = 0;
            prior_pressed = 0;
            key_held = 0;
            chord_held = 0;
            key_was_stalled = 0;
            chord_was_stalled = 0;
        end else begin
            if (key_was_stalled && (!key_valid || key_payload !== stalled_key_payload))
                $fatal(1, "KEY0 valid or payload changed under backpressure");
            if (chord_was_stalled && (!chord_valid || chord_payload !== stalled_chord_payload))
                $fatal(1, "KEY1 valid or payload changed under backpressure");
            if (pressed[0] != prior_pressed[0]) begin
                expected[enqueued] = {1'b0, pressed[0]};
                enqueued = enqueued + 1;
            end
            if (pressed[1] != prior_pressed[1]) begin
                expected[enqueued] = {1'b1, pressed[1]};
                enqueued = enqueued + 1;
            end
            prior_pressed = pressed;
            if (key_valid && chord_valid) $fatal(1, "Both gesture channels valid");
            if (key_valid) begin
                if (key_source !== 6'd1 || key_note !== 7'd69 || key_timbre !== 2'd2 ||
                    key_velocity !== (key_on ? 7'd100 : 7'd0))
                    $fatal(1, "Wrong KEY0 payload");
                if (key_ready) check_delivery({1'b0, key_on});
            end
            if (chord_valid) begin
                if (chord_source !== 6'd2 || chord_id !== 3'd0 || chord_count !== 4'd3 ||
                    chord_timbre !== 2'd2 || chord_velocity !== (chord_on ? 7'd100 : 7'd0) ||
                    chord_notes_flat !== {35'd0, 7'd67, 7'd64, 7'd60})
                    $fatal(1, "Wrong KEY1 payload");
                if (chord_ready) check_delivery({1'b1, chord_on});
            end
            key_was_stalled = key_valid && !key_ready;
            chord_was_stalled = chord_valid && !chord_ready;
            stalled_key_payload = key_payload;
            stalled_chord_payload = chord_payload;
            if (overflow_sticky) $fatal(1, "Unexpected default queue overflow");
        end
        logical_voices = (key_held ? 1 : 0) + (chord_held ? 3 : 0);
    end

    task drive;
        input [1:0] levels;
        input raw_ready, gesture_ready;
        input integer cycles;
        begin
            @(negedge clk);
            pressed = levels;
            key_ready = raw_ready;
            chord_ready = gesture_ready;
            repeat (cycles) begin @(posedge clk); #1; end
        end
    endtask

    task drain;
        integer timeout;
        begin
            @(negedge clk);
            key_ready = 1;
            chord_ready = 1;
            timeout = 0;
            while (pending_count != 0 && timeout < 100) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end
            if (pending_count != 0 || delivered != enqueued)
                $fatal(1, "Queue failed to drain: %0d pending, %0d/%0d events",
                       pending_count, delivered, enqueued);
        end
    endtask

    task small_expect;
        input [1:0] entry;
        begin
            if (entry[1]) begin
                if (!small_chord_valid || small_key_valid || small_chord_on !== entry[0])
                    $fatal(1, "Shallow queue order: expected chord %b", entry[0]);
            end else begin
                if (!small_key_valid || small_chord_valid || small_key_on !== entry[0])
                    $fatal(1, "Shallow queue order: expected key %b", entry[0]);
            end
            small_key_ready = 1;
            small_chord_ready = 1;
            @(posedge clk); #1;
            @(negedge clk);
        end
    endtask

    integer i, seed = 32'h412db37;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        drive(2'b00, 1, 1, 3);
        if (key_valid || chord_valid) $fatal(1, "Spurious idle event");
        drive(2'b01, 1, 1, 12);
        if (logical_voices != 1 || delivered != 1) $fatal(1, "KEY0 hold mismatch");
        drive(2'b00, 1, 1, 6);
        if (logical_voices != 0) $fatal(1, "KEY0 failed to release");
        drive(2'b10, 1, 1, 12);
        if (logical_voices != 3) $fatal(1, "KEY1 chord hold mismatch");
        drive(2'b00, 1, 1, 6);
        if (logical_voices != 0) $fatal(1, "KEY1 failed to release");

        // Together they create four voices; each gesture releases independently.
        drive(2'b11, 1, 1, 8);
        if (logical_voices != 4) $fatal(1, "Simultaneous press did not create four voices");
        drive(2'b10, 1, 1, 5);
        if (logical_voices != 3) $fatal(1, "KEY0 release disturbed chord");
        drive(2'b00, 1, 1, 5);
        drive(2'b11, 1, 1, 8);
        drive(2'b01, 1, 1, 5);
        if (logical_voices != 1) $fatal(1, "Chord release disturbed KEY0");
        drive(2'b00, 1, 1, 5);

        // Release and re-press while the first press remains blocked.
        drive(2'b01, 0, 0, 2);
        drive(2'b11, 0, 0, 2);
        drive(2'b10, 0, 0, 2);
        drive(2'b00, 0, 0, 2);
        drive(2'b11, 0, 0, 2);
        drive(2'b00, 0, 0, 2);
        if (pending_count != 8) $fatal(1, "Lost a press/release under backpressure");
        drive(2'b00, 1, 0, 12);
        if (pending_count != 7 || !chord_valid || !chord_on)
            $fatal(1, "A later event bypassed the blocked chord");
        drain();
        if (logical_voices != 0) $fatal(1, "Backpressure left a gesture held");

        // Many wraps, simultaneous enqueue/dequeue, and independent ready values.
        for (i = 0; i < 500; i = i + 1) begin
            @(negedge clk);
            if (i % 7 == 0) pressed = $random(seed);
            key_ready = (($random(seed) & 7) != 0);
            chord_ready = (($random(seed) & 7) != 0);
            @(posedge clk); #1;
        end
        drive(2'b00, 1, 1, 3);
        drain();
        if (logical_voices != 0) $fatal(1, "Random sequence left a gesture held");

        // Instrument reset discards queued gestures. A key still held at reset
        // release becomes a new press, so the board remains playable afterwards.
        drive(2'b11, 0, 0, 3);
        @(negedge clk); rst_n = 0;
        repeat (3) @(negedge clk);
        if (pending_count != 0 || key_valid || chord_valid || overflow_sticky)
            $fatal(1, "Reset did not clear adapter");
        rst_n = 1;
        drive(2'b11, 1, 1, 5);
        if (logical_voices != 4) $fatal(1, "Held keys were not restored after reset");
        drive(2'b00, 1, 1, 5);
        drain();

        // Fill four slots with two double-edge samples, then pop/enqueue at full.
        @(negedge clk); small_rst_n = 1; small_pressed = 2'b11;
        @(negedge clk); small_pressed = 2'b00;
        @(negedge clk);
        if (small_pending_count != 4 || small_overflow_sticky)
            $fatal(1, "Shallow queue did not fill cleanly");
        small_key_ready = 1;
        small_pressed = 2'b01;
        @(negedge clk);
        if (small_pending_count != 4 || small_overflow_sticky)
            $fatal(1, "Full queue failed simultaneous pop/enqueue");
        small_key_ready = 0;
        small_chord_ready = 1;
        small_pressed = 2'b10;
        @(negedge clk);
        if (!small_overflow_pulse || !small_overflow_sticky || small_pending_count != 4)
            $fatal(1, "Full pop plus two edges must accept KEY0 and report rejected KEY1");
        small_chord_ready = 0;
        @(negedge clk);
        if (small_overflow_pulse || !small_overflow_sticky)
            $fatal(1, "Overflow pulse/sticky behavior incorrect");
        small_expect(2'b00);
        small_expect(2'b10);
        small_expect(2'b01);
        small_expect(2'b00);
        if (small_pending_count != 0) $fatal(1, "Shallow queue did not drain in order");
        small_rst_n = 0;
        small_pressed = 0;
        small_key_ready = 0;
        small_chord_ready = 0;
        @(negedge clk);
        if (small_pending_count != 0 || small_overflow_sticky)
            $fatal(1, "Overflow fault did not clear on reset");

        // Three occupied entries plus a pop leave room for both new edges.
        small_rst_n = 1;
        small_pressed = 2'b11;
        @(negedge clk); small_pressed = 2'b10;
        @(negedge clk);
        if (small_pending_count != 3) $fatal(1, "Expected three queued transitions");
        small_key_ready = 1;
        small_pressed = 2'b01;
        @(negedge clk);
        small_key_ready = 0;
        if (small_pending_count != 4 || small_overflow_sticky)
            $fatal(1, "Near-full pop plus two edges did not admit both transitions");
        small_expect(2'b11);
        small_expect(2'b00);
        small_expect(2'b01);
        small_expect(2'b10);
        if (small_pending_count != 0 || small_overflow_sticky)
            $fatal(1, "Near-full double enqueue did not drain correctly");

        $display("PASS board_key_event_adapter: %0d ordered handshakes, held/released keys, four voices, backpressure, wrap, reset, overflow", total_delivered);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Simulation timeout");
    end
endmodule
