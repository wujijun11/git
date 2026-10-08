`timescale 1ps/1ps
// Production-parameter digital latency regression. The PLL model supplies the
// actual nominal audio clock; debounce and ADSR are deliberately not overridden.
// This measures input pins -> externally decoded I2S, not physical switch,
// touch-controller, DAC-filter, amplifier or acoustic latency.
module tb_board_key_latency;
    reg sys_clk = 0;
    always #10000 sys_clk = ~sys_clk;
    reg [2:0] key_n = 3'b111;
    wire rgb_data, pa_disable, i2s_bclk, i2s_lrclk, i2s_data;
    board_instrument_b_48k_i2s_top dut (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data)
    );

    localparam time RESPONSE_LIMIT_PS = 5000000000; // 5 ms
    localparam time DEBOUNCE_PS = 2000000000;       // 100000 / 50 MHz
    integer on_count = 0, off_count = 0;
    integer slots = 0, nonzero_slots = 0;
    integer single_on_count = 0, chord_on_count = 0;
    reg measure_single = 0;
    reg startup_checked = 0, expecting_reset = 0;
    time raw_press_time = 0, stable_press_time = 0;
    time cmd_press_time = 0, serial_first_time = 0;
    time raw_off_time = 0, cmd_off_time = 0;
    time raw_combined_time = 0, last_on_time = 0;
    time raw_reset_time = 0, reset_time = 0;
    time sampled_max_i2s_latency = 0;
    reg last_lrclk = 1, aligned = 0;
    integer slot_bit = 0;
    reg [23:0] payload = 0;

    always @(negedge dut.rst_n) begin
        if (startup_checked && !expecting_reset)
            $fatal(1, "A sub-threshold input glitch unexpectedly reset the instrument");
    end

    always @(posedge dut.pressed_50[0]) begin
        if (measure_single && stable_press_time == 0)
            stable_press_time = $time;
    end

    always @(posedge dut.audio_clk) begin
        if (dut.instrument_rst_n) begin
            if (dut.input_overflow_sticky ||
                dut.u_instrument.event_overflow_sticky ||
                dut.u_instrument.voice_full_pulse ||
                dut.u_instrument.done_error_pulse ||
                dut.u_instrument.i2s_underrun_count != 0)
                $fatal(1, "Unexpected input/audio/allocator error in latency test");
            if (dut.u_instrument.u_audio.cmd_valid &&
                dut.u_instrument.u_audio.cmd_ready) begin
                if (dut.u_instrument.u_audio.cmd_timbre !== 2'd2)
                    $fatal(1, "Latency test lost the production piano timbre");
                if (dut.u_instrument.u_audio.cmd_on) begin
                    on_count = on_count + 1;
                    last_on_time = $time;
                    case (dut.u_instrument.u_audio.cmd_note)
                        7'd69: single_on_count = single_on_count + 1;
                        7'd60, 7'd64, 7'd67: chord_on_count = chord_on_count + 1;
                        default: $fatal(1, "Unexpected note-on in latency test");
                    endcase
                    if (measure_single && cmd_press_time == 0)
                        cmd_press_time = $time;
                end else begin
                    off_count = off_count + 1;
                    if (raw_off_time != 0 && cmd_off_time == 0)
                        cmd_off_time = $time;
                end
            end
        end
    end

    // Decode a complete 24-bit channel sample from exported pins. Counting a
    // high data bit alone is insufficient to establish a valid sample time.
    always @(posedge i2s_bclk or negedge dut.instrument_rst_n) begin
        if (!dut.instrument_rst_n) begin
            last_lrclk = 1;
            aligned = 0;
            slot_bit = 0;
            payload = 0;
        end else begin
            if (i2s_lrclk != last_lrclk) begin
                if (aligned && slot_bit != 31)
                    $fatal(1, "I2S channel does not have 32 bit times");
                last_lrclk = i2s_lrclk;
                aligned = 1;
                slot_bit = 0;
                payload = 0;
            end else if (aligned) slot_bit = slot_bit + 1;
            if (aligned) begin
                if (i2s_data !== 1'b0 && i2s_data !== 1'b1)
                    $fatal(1, "Unknown external I2S data");
                if ((slot_bit == 0 || slot_bit > 24) && i2s_data !== 0)
                    $fatal(1, "I2S delay/padding bit is nonzero");
                if (slot_bit >= 1 && slot_bit <= 24)
                    payload = {payload[22:0], i2s_data};
                if (slot_bit == 24) begin
                    slots = slots + 1;
                    if (payload != 0) begin
                        nonzero_slots = nonzero_slots + 1;
                        if (measure_single && serial_first_time == 0)
                            serial_first_time = $time;
                    end
                end
            end
        end
    end

    task automatic set_keys(input [2:0] value);
        begin
            @(negedge sys_clk);
            key_n = value;
        end
    endtask

    task automatic expect_no_events(input string label_text);
        begin
            if (on_count != 0 || off_count != 0 ||
                dut.pressed_50 !== 0 ||
                dut.u_instrument.events_pushed != 0 ||
                dut.u_instrument.events_delivered != 0 ||
                nonzero_slots != 0)
                $fatal(1, "%s: unstable input produced a gesture or audio", label_text);
        end
    endtask

    task automatic wait_on_count(input integer target, input time start_time,
                                 input string label_text);
        begin
            while (on_count < target) begin
                @(negedge dut.audio_clk);
                if ($time - start_time > RESPONSE_LIMIT_PS)
                    $fatal(1, "%s: note-on response exceeded 5 ms", label_text);
            end
            if (on_count != target)
                $fatal(1, "%s: duplicate note-on", label_text);
        end
    endtask

    function integer held_voice_count;
        input [63:0] mask;
        integer bit_number;
        begin
            held_voice_count = 0;
            for (bit_number = 0; bit_number < 64; bit_number = bit_number + 1)
                if (mask[bit_number]) held_voice_count = held_voice_count + 1;
        end
    endfunction

    task automatic check_single_timestamps(input integer phase_case);
        begin
            if (stable_press_time - raw_press_time < DEBOUNCE_PS ||
                stable_press_time - raw_press_time > DEBOUNCE_PS + 500000 ||
                cmd_press_time < stable_press_time || serial_first_time < cmd_press_time ||
                serial_first_time - raw_press_time > RESPONSE_LIMIT_PS)
                $fatal(1, "Unexpected raw/stable/command/I2S timestamp ordering");
            if (serial_first_time - raw_press_time > sampled_max_i2s_latency)
                sampled_max_i2s_latency = serial_first_time - raw_press_time;
            $display("PRODUCTION KEY LATENCY: cold_phase_case=%0d KEY0 stable=%.3f us command=%.3f us complete_nonzero_I2S=%.3f us",
                phase_case, (stable_press_time - raw_press_time) / 1000000.0,
                (cmd_press_time - raw_press_time) / 1000000.0,
                (serial_first_time - raw_press_time) / 1000000.0);
        end
    endtask

    // Enter with KEY2 held. Release musical keys while reset remains asserted,
    // then release reset and sample a different I2S bit position. Using the real
    // KEY2 debounce keeps every tested path on production timing parameters.
    task automatic cold_phase_case(input integer phase_case,
                                   input integer requested_bit,
                                   input integer target_on_count);
        time operation_time;
        integer quiet_before;
        begin
            set_keys(3'b011);
            operation_time = $time;
            while (dut.pressed_sync !== 3'b100) begin
                @(negedge dut.audio_clk);
                if ($time - operation_time > RESPONSE_LIMIT_PS)
                    $fatal(1, "Musical keys failed to release while KEY2 held");
            end
            set_keys(3'b111);
            operation_time = $time;
            while (!dut.rst_n) begin
                @(negedge dut.audio_clk);
                if ($time - operation_time > RESPONSE_LIMIT_PS)
                    $fatal(1, "KEY2 release failed to restore the instrument");
            end
            expecting_reset = 0;
            quiet_before = nonzero_slots;
            repeat (4096) @(negedge dut.audio_clk);
            if (nonzero_slots != quiet_before || dut.u_instrument.active_count != 0)
                $fatal(1, "Reset left stale audio before cold phase measurement");
            while (dut.u_instrument.u_audio.u_captain.u_audio.bit_index != requested_bit)
                @(negedge dut.audio_clk);
            stable_press_time = 0;
            cmd_press_time = 0;
            serial_first_time = 0;
            measure_single = 1;
            set_keys(3'b110);
            raw_press_time = $time;
            wait_on_count(target_on_count, raw_press_time, "cold phase KEY0");
            while (serial_first_time == 0) begin
                @(negedge dut.audio_clk);
                if ($time - raw_press_time > RESPONSE_LIMIT_PS)
                    $fatal(1, "Cold phase first nonzero I2S sample exceeded 5 ms");
            end
            check_single_timestamps(phase_case);
            measure_single = 0;
            expecting_reset = 1;
            set_keys(3'b010);
            operation_time = $time;
            while (dut.rst_n) begin
                @(negedge dut.audio_clk);
                if ($time - operation_time > RESPONSE_LIMIT_PS)
                    $fatal(1, "Cold phase KEY2 reset exceeded 5 ms");
            end
            repeat (128) @(negedge dut.audio_clk);
            if (i2s_data !== 0 || i2s_bclk !== 0 || dut.u_instrument.active_count !== 0)
                $fatal(1, "Cold phase reset did not silence the instrument");
        end
    endtask

    initial begin
        if (dut.DEBOUNCE_CYCLES != 100000)
            $fatal(1, "This regression must run the production 2 ms debounce default");
        if (dut.u_instrument.u_audio.u_engine.ATTACK_MS != 10 ||
            dut.u_instrument.u_audio.u_engine.DECAY_MS != 80 ||
            dut.u_instrument.u_audio.u_engine.RELEASE_MS != 100)
            $fatal(1, "Production ADSR parameters were overridden");
        wait (dut.rst_n);
        repeat (4096) @(negedge dut.audio_clk);
        if (!pa_disable || !dut.pll_locked) $fatal(1, "Board startup not ready");
        expect_no_events("startup");
        startup_checked = 1;

        // Sub-threshold pulses must remain invisible, including one only
        // 100 us shorter than the production continuous-stability threshold.
        set_keys(3'b000);
        repeat (5000) @(negedge sys_clk); // 100 us
        key_n = 3'b111;
        repeat (2500) @(negedge sys_clk);
        expect_no_events("100 us glitch");
        set_keys(3'b000);
        repeat (95000) @(negedge sys_clk); // 1.9 ms
        key_n = 3'b111;
        repeat (2500) @(negedge sys_clk);
        expect_no_events("1.9 ms glitch");

        // Synthetic bounce: each interval is less than 2 ms. This verifies
        // the HDL filter; it does not characterize the mechanical key.
        set_keys(3'b110);
        repeat (25000) @(negedge sys_clk); // 0.5 ms
        key_n = 3'b111;
        repeat (1000) @(negedge sys_clk);  // 20 us
        key_n = 3'b110;
        repeat (75000) @(negedge sys_clk); // 1.5 ms
        key_n = 3'b111;
        repeat (1000) @(negedge sys_clk);
        expect_no_events("bounce before final stable press");

        measure_single = 1;
        set_keys(3'b110);
        raw_press_time = $time;
        wait_on_count(1, raw_press_time, "KEY0 stable press");
        while (serial_first_time == 0) begin
            @(negedge dut.audio_clk);
            if ($time - raw_press_time > RESPONSE_LIMIT_PS)
                $fatal(1, "First complete nonzero external I2S sample exceeded 5 ms");
        end
        check_single_timestamps(0);
        repeat (10240) @(negedge dut.audio_clk);
        if (on_count != 1 || off_count != 0 ||
            dut.u_instrument.events_pushed != 1)
            $fatal(1, "Holding KEY0 produced repeated events");
        measure_single = 0;

        set_keys(3'b111);
        raw_off_time = $time;
        while (off_count == 0) begin
            @(negedge dut.audio_clk);
            if ($time - raw_off_time > RESPONSE_LIMIT_PS)
                $fatal(1, "KEY0 note-off command exceeded 5 ms");
        end
        // Wait four complete audio frames so the accepted off has reached the
        // engine, rather than mistaking an as-yet-unapplied command for a tail.
        repeat (4096) @(negedge dut.audio_clk);
        if (off_count != 1 || dut.u_instrument.active_count == 0 ||
            held_voice_count(dut.u_instrument.u_audio.u_captain.u_control.u_allocator.held_mask) != 0)
            $fatal(1, "Release event duplicated or the production release tail was removed");
        $display("PRODUCTION KEY LATENCY: KEY0 note_off_command=%.3f us release_tail_retained=1",
            (cmd_off_time - raw_off_time) / 1000000.0);

        // Repress without waiting for the natural 100 ms release: the held
        // mask must contain one single note and the three-note chord.
        set_keys(3'b100);
        raw_combined_time = $time;
        wait_on_count(5, raw_combined_time, "KEY0 plus KEY1");
        repeat (10240) @(negedge dut.audio_clk);
        if (single_on_count != 2 || chord_on_count != 3 ||
            on_count != 5 || off_count != 1 ||
            held_voice_count(dut.u_instrument.u_audio.u_captain.u_control.u_allocator.held_mask) != 4)
            $fatal(1, "Combined keys lost/duplicated a note or ownership");
        $display("PRODUCTION KEY LATENCY: combined_fourth_note_command=%.3f us held_voices=4",
            (last_on_time - raw_combined_time) / 1000000.0);

        expecting_reset = 1;
        set_keys(3'b000);
        raw_reset_time = $time;
        while (dut.rst_n) begin
            @(negedge dut.audio_clk);
            if ($time - raw_reset_time > RESPONSE_LIMIT_PS)
                $fatal(1, "KEY2 reset response exceeded 5 ms");
        end
        reset_time = $time;
        repeat (128) @(negedge dut.audio_clk);
        if (i2s_bclk !== 0 || i2s_data !== 0 ||
            dut.u_instrument.active_count !== 0 ||
            dut.u_instrument.events_pushed !== 0 || dut.instrument_rst_n !== 0)
            $fatal(1, "KEY2 failed to reset and silence the instrument");
        $display("PRODUCTION KEY LATENCY: KEY2 reset=%.3f us",
            (reset_time - raw_reset_time) / 1000000.0);
        cold_phase_case(1, 21, 6);
        cold_phase_case(2, 42, 7);
        if (on_count != 7 || off_count != 1)
            $fatal(1, "Cold phase measurements introduced duplicate key events");
        $display("PRODUCTION KEY LATENCY: sampled_cold_phases=3 sampled_max_complete_nonzero_I2S=%.3f us (not an exhaustive worst-case bound)",
            sampled_max_i2s_latency / 1000000.0);
        $display("BOARD KEY LATENCY PASSED production_debounce=100000 production_ADSR=10/80/100 ms glitch_filter=100us/1.9ms bounce_filter=1 held_no_repeat=1 on=7 off=1 reset_silence=1 slots=%0d nonzero_slots=%0d underruns=0 scope=simulation_input_pin_to_I2S_only", slots, nonzero_slots);
        $finish;
    end

    initial begin
        #100000000000;
        $fatal(1, "Production key latency simulation timed out");
    end
endmodule
