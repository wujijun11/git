`timescale 1ns/1ps

// Independent receiver: it observes only BCLK, WS and DATA, skips the I2S
// one-bit delay, and reconstructs both signed words. No DUT shift state used.
module i2s_case #(parameter integer HALF_DIV = 8) (output reg finished = 0);
    localparam real CLK_PERIOD = 1000.0 / 49.152;
    localparam integer FRAME_CLKS = 128 * HALF_DIV;
    reg clk = 0;
    always #(CLK_PERIOD / 2.0) clk = !clk;
    reg rst_n = 0;
    reg sample_valid = 0;
    reg signed [23:0] sample_left = 0, sample_right = 0;
    wire sample_ready, bclk, ws, data_out, frame_tick;
    wire [1:0] fifo_level;
    wire underrun_pulse, underrun_sticky;
    wire [31:0] underrun_count;
    reg event_valid = 0, event_on = 0;
    reg [6:0] event_note = 0, event_velocity = 0;
    reg [1:0] event_timbre = 0;
    wire event_ready, cmd_valid, cmd_on;
    reg cmd_ready = 0, done_valid = 0;
    wire done_ready;
    reg [5:0] done_voice = 0;
    wire [5:0] cmd_voice;
    wire [6:0] cmd_note, cmd_velocity, active_count;
    wire [1:0] cmd_timbre;
    wire [63:0] active_mask, held_mask;
    wire full_pulse, ignored_pulse, done_error_pulse;

`ifdef V2_INTERFACE_TEST
    // Reuse the exact external I2S scoreboard for the V2 integration boundary.
    // A constant expression producer exercises its parallel control path;
    // the sample producer below is still a protocol model, not a synth engine.
    wire [11:0] checked_gain;
    wire signed [12:0] checked_bend;
    wire [7:0] checked_vibrato;
    integer expr_settled=0;
    always @(negedge clk) begin
        if(!rst_n) expr_settled=0;
        else begin
            expr_settled=expr_settled+1;
            if(expr_settled>2 && {checked_gain,checked_bend,checked_vibrato} !==
               {12'd1024,13'sd100,8'd25}) $fatal(1,"V2 integrated expression wiring");
        end
    end
    captain_system_top_v2 #(.BCLK_HALF_DIV(HALF_DIV)) dut (
        .event_source(6'd0),
        .expr_valid(1'b1), .expr_ready(), .expr_gain(12'd1024),
        .expr_bend_cents(13'sd100), .expr_vibrato_cents(8'd25),
        .engine_sample_begin(1'b1),
        .active_gain(checked_gain), .active_bend_cents(checked_bend),
        .active_vibrato_cents(checked_vibrato), .expr_applied(),
`else
    captain_system_top #(.BCLK_HALF_DIV(HALF_DIV)) dut (
`endif
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_note(event_note),
        .event_velocity(event_velocity), .event_timbre(event_timbre),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_on(cmd_on),
        .cmd_voice(cmd_voice), .cmd_note(cmd_note), .cmd_velocity(cmd_velocity),
        .cmd_timbre(cmd_timbre),
        .done_valid(done_valid), .done_ready(done_ready), .done_voice(done_voice),
        .active_count(active_count), .active_mask(active_mask), .held_mask(held_mask),
        .full_pulse(full_pulse), .ignored_pulse(ignored_pulse),
        .done_error_pulse(done_error_pulse),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .i2s_bclk(bclk), .i2s_lrclk(ws), .i2s_data(data_out),
        .frame_tick(frame_tick), .fifo_level(fifo_level),
        .underrun_pulse(underrun_pulse), .underrun_sticky(underrun_sticky),
        .underrun_count(underrun_count)
    );

    reg [47:0] expected_queue [0:511];
    integer written = 0, consumed = 0;
    reg [47:0] expected_frame = 0;
    integer expected_underruns = 0;
    integer frames_started = 0, frames_checked = 0;
    integer nonzero_checked = 0, total_checked = 0;
    integer stall_cycles = 0, full_exchanges = 0;
    reg previous_stall = 0;
    reg [47:0] held_sample = 0;
    reg expected_missing = 0;
    reg expected_started = 0;

    // Capture only accepted input transactions. Each pair is one transaction.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            written = 0;
            previous_stall = 0;
        end else begin
            if (previous_stall && (!sample_valid ||
                {sample_left, sample_right} !== held_sample))
                $fatal(1, "Source violated ready/valid stability");
            previous_stall = sample_valid && !sample_ready;
            held_sample = {sample_left, sample_right};
            if (sample_valid && !sample_ready) stall_cycles = stall_cycles + 1;
            if (sample_valid && sample_ready) begin
                if (written >= 512) $fatal(1, "Scoreboard overflow");
                expected_queue[written] = {sample_left, sample_right};
                written = written + 1;
                if (fifo_level == 2) full_exchanges = full_exchanges + 1;
            end
        end
    end

    // WS falling is the externally observable frame boundary. The tiny delay
    // lets the input handshake on the same system edge reach the scoreboard.
    always @(negedge ws or negedge rst_n) begin
        if (!rst_n) begin
            consumed = 0;
            expected_started = 0;
            expected_underruns = 0;
            expected_missing = 0;
            frames_started = 0;
            expected_frame = 0;
        end else begin
            #0.001;
            frames_started = frames_started + 1;
            expected_missing = expected_started && (consumed == written);
            if (consumed < written) begin
                expected_started = 1;
                expected_frame = expected_queue[consumed];
                consumed = consumed + 1;
            end else begin
                expected_frame = 0;
                if (expected_started) expected_underruns = expected_underruns + 1;
            end
        end
    end

    // Scoreboard level/status checks, including simultaneous full pop/push.
    always @(negedge clk) begin
        #0.01; // Let asynchronous-reset and test-driver assignments settle.
        if (rst_n) begin
            if (fifo_level !== (written - consumed))
                $fatal(1, "DIV=%0d FIFO level mismatch", HALF_DIV);
            if (underrun_count !== expected_underruns)
                $fatal(1, "DIV=%0d underrun count mismatch", HALF_DIV);
            if (underrun_sticky !== (expected_underruns != 0))
                $fatal(1, "Underrun sticky mismatch");
            if (underrun_pulse !== (frame_tick && expected_missing))
                $fatal(1, "Underrun pulse must last exactly one system clock");
        end else if (sample_ready !== 0 || fifo_level !== 0)
            $fatal(1, "Reset must clear FIFO and block input");
    end

    reg locked = 0, previous_ws = 1;
    integer slot_bit = 0;
    reg [23:0] receive_word = 0, decoded_left = 0;
    realtime last_bclk = 0;
    realtime last_frame = 0;
    realtime measured;
    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            locked = 0;
            previous_ws = 1;
            slot_bit = 0;
            receive_word = 0;
            decoded_left = 0;
            frames_checked = 0;
            last_bclk = 0;
            last_frame = 0;
        end else begin
            if (last_bclk != 0) begin
                measured = $realtime - last_bclk;
                if (measured < 2*HALF_DIV*CLK_PERIOD - 0.02 ||
                    measured > 2*HALF_DIV*CLK_PERIOD + 0.02)
                    $fatal(1, "BCLK period mismatch");
            end
            last_bclk = $realtime;
            if (ws !== previous_ws) begin
                if (locked && slot_bit != 31)
                    $fatal(1, "Channel did not contain exactly 32 bit clocks");
                locked = 1;
                slot_bit = 0;
                receive_word = 0;
                previous_ws = ws;
                if (!ws) begin
                    if (last_frame != 0) begin
                        measured = $realtime - last_frame;
                        // Account for rounding every clock half-period to 1 ps.
                        if (measured < FRAME_CLKS*CLK_PERIOD - FRAME_CLKS*0.001 - 0.001 ||
                            measured > FRAME_CLKS*CLK_PERIOD + FRAME_CLKS*0.001 + 0.001)
                            $fatal(1, "Stereo sample rate mismatch: %0.3f ns", measured);
                    end
                    last_frame = $realtime;
                end
            end else if (locked) slot_bit = slot_bit + 1;

            if (locked) begin
                if (slot_bit > 31) $fatal(1, "Missing WS transition");
                if ((slot_bit == 0 || slot_bit > 24) && data_out !== 0)
                    $fatal(1, "I2S delay/padding bit was not zero");
                if (slot_bit >= 1 && slot_bit <= 24) begin
                    receive_word = {receive_word[22:0], data_out};
                    if (slot_bit == 24) begin
                        if (!ws) decoded_left = receive_word;
                        else if ({decoded_left, receive_word} !== expected_frame)
                            $fatal(1, "DIV=%0d frame %0d expected %h got %h %h",
                                HALF_DIV, frames_checked, expected_frame,
                                decoded_left, receive_word);
                    end
                end
                if (ws && slot_bit == 31) begin
                    frames_checked = frames_checked + 1;
                    total_checked = total_checked + 1;
                    if (expected_frame != 0) nonzero_checked = nonzero_checked + 1;
                end
            end
        end
    end

    // Serial signals may only change while BCLK is low (falling-edge launch).
    always @(ws or data_out) begin
        if (rst_n && bclk !== 0) $fatal(1, "Serial output changed with BCLK high");
    end

    task automatic reset_system;
        begin
            @(negedge clk);
            rst_n = 0;
            sample_valid = 0;
            event_valid = 0;
            done_valid = 0;
            cmd_ready = 0;
            repeat (4) @(negedge clk);
            rst_n = 1;
        end
    endtask

    task automatic send_sample(input reg [23:0] l, input reg [23:0] r);
        begin
            @(negedge clk);
            sample_valid = 1;
            sample_left = l;
            sample_right = r;
            do @(posedge clk); while (!sample_ready);
            @(negedge clk);
            sample_valid = 0;
        end
    endtask

    task automatic wait_frames(input integer count);
        integer target;
        begin
            target = frames_checked + count;
            wait (frames_checked >= target);
            @(negedge clk);
        end
    endtask

    task automatic send_event(input reg on_value);
        begin
            @(negedge clk);
            event_valid = 1;
            event_on = on_value;
            event_note = 60;
            event_velocity = 100;
            event_timbre = 2;
            do @(posedge clk); while (!event_ready);
            @(negedge clk);
            event_valid = 0;
            wait (cmd_valid);
            repeat (12) @(negedge clk); // Stall engine, audio must continue.
            if (cmd_on !== on_value || cmd_voice !== 0 || cmd_note !== 60 ||
                cmd_velocity !== 100 || cmd_timbre !== 2)
                $fatal(1, "Control command changed during audio streaming");
            cmd_ready = 1;
            @(negedge clk);
            cmd_ready = 0;
        end
    endtask

    task automatic exercise_control;
        begin
            send_event(1);
            if (active_count !== 1 || held_mask !== 64'd1)
                $fatal(1, "Note-on allocation failed during audio");
            send_event(0);
            if (active_count !== 1 || held_mask !== 0)
                $fatal(1, "Release tail should retain allocation");
            @(negedge clk);
            done_valid = 1;
            do @(posedge clk); while (!done_ready);
            @(negedge clk);
            done_valid = 0;
            if (active_count !== 0) $fatal(1, "Voice did not finish");
        end
    endtask

    integer i, underruns_before;
    reg [31:0] prng = 32'h725361af;
    reg [23:0] random_l, random_r;
    initial begin
        // Force a reset edge even on simulators that initialize regs before
        // scheduling asynchronous-reset blocks.
        #1 rst_n = 1;
        reset_system();
        wait_frames(3); // Delayed producer: clocks and silence continue without underrun.
        if (underrun_count !== 0 || underrun_sticky || underrun_pulse)
            $fatal(1, "Priming incorrectly counted as underrun");

        // Distinct signed endpoints make channel swaps / sign / bit shifts fail.
        send_sample(24'h7fffff, 24'h800000);
        send_sample(24'hffffff, 24'h000001);
        send_sample(24'h123456, 24'habcdef);
        send_sample(24'h000000, 24'hffffff);
        wait_frames(5);
        if (underrun_count == 0 || !underrun_sticky)
            $fatal(1, "Real starvation after playback was not detected");

        // Input arrives exactly at an empty frame boundary: direct consumption,
        // no extra frame of delay and no false underrun.
        @(negedge ws);
        repeat (FRAME_CLKS) @(negedge clk);
        underruns_before = underrun_count;
        sample_valid = 1;
        sample_left = 24'h400001;
        sample_right = 24'hc00002;
        @(posedge clk);
        #0.01;
        if (!frame_tick || fifo_level !== 0 || underrun_count !== underruns_before)
            $fatal(1, "Empty frame-boundary bypass failed");
        @(negedge clk);
        sample_valid = 0;
        wait_frames(2);

        // Arrive one clock after an empty boundary: current frame stays silence,
        // sample is preserved for the next frame, never half old / half new.
        @(negedge ws);
        send_sample(24'h800001, 24'h7ffffe);
        wait_frames(3);

        // Burst source saturates the FIFO; the receiver must see exact order.
        // Concurrent control handshake stalls are deliberately unrelated.
        fork
            begin
                for (i = 0; i < 40; i = i + 1) begin
                    prng = {prng[30:0], prng[31]^prng[21]^prng[1]^prng[0]};
                    random_l = prng[23:0];
                    prng = {prng[30:0], prng[31]^prng[21]^prng[1]^prng[0]};
                    random_r = prng[23:0];
                    send_sample(random_l, random_r);
                end
            end
            exercise_control();
        join
        wait_frames(4);
        if (stall_cycles == 0 || full_exchanges == 0)
            $fatal(1, "FIFO full/stall/simultaneous exchange coverage missing");
        if (nonzero_checked < 45) $fatal(1, "Insufficient decoded sample coverage");

        // Reset while a word is being sent and two future samples are queued.
        @(negedge ws);
        send_sample(24'h222222, 24'hdddddd);
        send_sample(24'h333333, 24'hcccccc);
        repeat (5) @(posedge bclk);
        reset_system();
        wait_frames(2); // Old queued audio and armed state must not leak through reset.
        if (underrun_count !== 0 || underrun_sticky) $fatal(1, "Reset did not re-prime");
        send_sample(24'h654321, 24'hfedcba);
        wait_frames(3);
        $display("I2S CASE PASSED DIV=%0d frames=%0d nonzero=%0d stalls=%0d full_exchange=%0d",
            HALF_DIV, total_checked, nonzero_checked, stall_cycles, full_exchanges);
        finished = 1;
    end
endmodule

module tb_i2s_tx;
    wire default_finished, fast_finished;
    i2s_case #(.HALF_DIV(8)) normal (default_finished);
    i2s_case #(.HALF_DIV(1)) divider_edge_case (fast_finished);
    initial begin
        wait (default_finished && fast_finished);
`ifdef V2_INTERFACE_TEST
        $display("ALL V2 I2S TESTS PASSED");
`else
        $display("ALL I2S TESTS PASSED");
`endif
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1, "I2S watchdog expired");
    end
endmodule
