`timescale 1ps/1ps
module tb_board_instrument_b_48k_i2s;
    reg sys_clk = 0;
    always #10000 sys_clk = ~sys_clk;
    reg [2:0] key_n = 3'b111;
    wire rgb_data, pa_disable, i2s_bclk, i2s_lrclk, i2s_data;
    board_instrument_b_48k_i2s_top #(.DEBOUNCE_CYCLES(8)) dut (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .i2s_bclk(i2s_bclk),
        .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data)
    );
    // Hardware retains its 100 ms release. Only this simulation uses 1 ms.
    defparam dut.u_instrument.u_audio.u_engine.RELEASE_MS = 1;

    integer on_count [0:3];
    integer off_count [0:3];
    integer note_index;
    integer command_count = 0, complete_slots = 0, active_bits = 0;
    integer i, bits_before_reset;
    reg injecting_overflow = 0;
    reg last_lrclk = 1, aligned = 0;
    integer slot_bit = 0;
    time last_bclk_edge = 0;

    // Decode the externally exported pins, including the Philips I2S delay
    // and seven padding bits in each 32-bit channel slot.
    always @(posedge i2s_bclk or negedge dut.instrument_rst_n) begin
        if (!dut.instrument_rst_n) begin
            last_lrclk = 1;
            aligned = 0;
            slot_bit = 0;
            last_bclk_edge = 0;
        end else begin
            if (last_bclk_edge != 0 &&
                ($time-last_bclk_edge < 325500 || $time-last_bclk_edge > 325600))
                $fatal(1, "BCLK period is not 16 clocks at 49.152 MHz");
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
                if (slot_bit >= 1 && slot_bit <= 24 && i2s_data === 1'b1)
                    active_bits = active_bits + 1;
                if (i2s_data !== 1'b0 && i2s_data !== 1'b1)
                    $fatal(1, "I2S data is unknown");
            end
        end
    end

    // Monitor commands accepted by the audio engine, so a correct FIFO total
    // alone cannot hide missing notes, duplicate transitions or lost timbre.
    always @(posedge dut.audio_clk) begin
        if (dut.rst_n && dut.input_overflow_sticky && !injecting_overflow)
            $fatal(1, "Unexpected board key queue overflow");
        if (dut.instrument_rst_n) begin
            if (dut.u_instrument.i2s_underrun_count != 0 ||
                dut.u_instrument.event_overflow_sticky ||
                dut.u_instrument.voice_full_pulse ||
                dut.u_instrument.done_error_pulse)
                $fatal(1, "Board instrument audio/FIFO/allocator error");
            if (dut.u_instrument.u_audio.cmd_valid &&
                dut.u_instrument.u_audio.cmd_ready) begin
                case (dut.u_instrument.u_audio.cmd_note)
                    7'd69: note_index = 0;
                    7'd60: note_index = 1;
                    7'd64: note_index = 2;
                    7'd67: note_index = 3;
                    default: $fatal(1, "Unexpected board note %0d",
                                    dut.u_instrument.u_audio.cmd_note);
                endcase
                if (dut.u_instrument.u_audio.cmd_timbre !== 2'd2)
                    $fatal(1, "Board note lost its saved piano timbre");
                if (dut.u_instrument.u_audio.cmd_on) begin
                    if (dut.u_instrument.u_audio.cmd_velocity == 0)
                        $fatal(1, "Board note-on has zero velocity");
                    on_count[note_index] = on_count[note_index] + 1;
                end else off_count[note_index] = off_count[note_index] + 1;
                command_count = command_count + 1;
            end
        end
    end

    task automatic set_keys(input [2:0] value);
        begin
            @(negedge sys_clk);
            key_n = value;
        end
    endtask

    task automatic expect_state(input integer voices, input integer events,
                                 input string label_text);
        integer cycles;
        begin
            cycles = 0;
            while (dut.u_instrument.active_count !== voices ||
                   dut.u_instrument.events_pushed !== events ||
                   dut.u_instrument.events_delivered !== events ||
                   dut.u_instrument.event_fifo_level !== 0) begin
                @(negedge dut.audio_clk);
                cycles = cycles + 1;
                if (cycles >= 196608)
                    $fatal(1, "%s: voices=%0d pushed=%0d delivered=%0d fifo=%0d",
                           label_text, dut.u_instrument.active_count,
                           dut.u_instrument.events_pushed,
                           dut.u_instrument.events_delivered,
                           dut.u_instrument.event_fifo_level);
            end
            repeat (128) @(negedge dut.audio_clk);
            if (dut.u_instrument.active_count !== voices ||
                dut.u_instrument.events_pushed !== events ||
                dut.u_instrument.events_delivered !== events ||
                dut.u_instrument.event_fifo_level !== 0)
                $fatal(1, "%s: extra or unstable key transition", label_text);
        end
    endtask

    task automatic expect_audio(input integer voices, input integer events,
                                 input string label_text);
        integer bits_before;
        begin
            bits_before = active_bits;
            repeat (16384) @(negedge dut.audio_clk);
            expect_state(voices, events, label_text);
            if (active_bits <= bits_before)
                $fatal(1, "%s: I2S remained silent while held", label_text);
        end
    endtask

    task automatic expect_silence(input integer events, input string label_text);
        integer bits_before;
        begin
            expect_state(0, events, label_text);
            // Allow both queued stereo pairs to leave the transmitter.
            repeat (4096) @(negedge dut.audio_clk);
            bits_before = active_bits;
            repeat (2048) @(negedge dut.audio_clk);
            if (active_bits != bits_before)
                $fatal(1, "%s: I2S did not drain to digital silence", label_text);
        end
    endtask

    initial begin
        for (i=0; i<4; i=i+1) begin
            on_count[i] = 0;
            off_count[i] = 0;
        end
        wait(dut.rst_n);
        if (!pa_disable || !dut.pll_locked)
            $fatal(1, "Board amp or audio clock is not ready");
        expect_silence(0, "power-up");
        $display("BOARD B 48K I2S: startup clock and silence passed");

        // A pulse shorter than the debounce interval must not play a note.
        set_keys(3'b110);
        repeat (3) @(negedge sys_clk);
        key_n = 3'b111;
        repeat (128) @(negedge dut.audio_clk);
        expect_state(0, 0, "short key bounce");

        set_keys(3'b110);
        expect_state(1, 1, "KEY0 single note");
        expect_audio(1, 1, "KEY0 held once");
        set_keys(3'b111);
        expect_silence(2, "KEY0 release");

        set_keys(3'b101);
        expect_state(3, 5, "KEY1 three-note chord");
        expect_audio(3, 5, "KEY1 held once");
        set_keys(3'b111);
        expect_silence(8, "KEY1 release");
        $display("BOARD B 48K I2S: individual single/chord press and release passed");

        set_keys(3'b100);
        expect_state(4, 12, "both keys together");
        expect_audio(4, 12, "four simultaneous voices");
        set_keys(3'b101);
        expect_state(3, 13, "release KEY0 while chord held");
        expect_audio(3, 13, "chord remains sounding");
        set_keys(3'b111);
        expect_silence(16, "release remaining chord");

        set_keys(3'b100);
        expect_state(4, 20, "repeat both keys");
        expect_audio(4, 20, "repeated four voices");
        set_keys(3'b110);
        expect_state(1, 23, "release chord while KEY0 held");
        expect_audio(1, 23, "single note remains sounding");
        set_keys(3'b111);
        expect_silence(24, "release remaining single note");
        $display("BOARD B 48K I2S: four voices and independent releases passed");

        // Repress before the release tail finishes: the old allocation must
        // eventually drain while the new note remains held.
        set_keys(3'b110);
        expect_state(1, 25, "single note before rapid repress");
        expect_audio(1, 25, "single note before release tail");
        set_keys(3'b111);
        wait(off_count[0] == 4);
        @(negedge dut.audio_clk);
        if (dut.u_instrument.active_count == 0)
            $fatal(1, "KEY0 release tail ended before its note-off command");
        set_keys(3'b110);
        expect_state(1, 27, "KEY0 repress during release tail");
        expect_audio(1, 27, "KEY0 repress sounds");
        set_keys(3'b111);
        expect_silence(28, "KEY0 repress release");

        set_keys(3'b101);
        expect_state(3, 31, "chord before rapid repress");
        expect_audio(3, 31, "chord before release tail");
        set_keys(3'b111);
        wait(off_count[1] == 4 && off_count[2] == 4 && off_count[3] == 4);
        set_keys(3'b101);
        expect_state(3, 37, "KEY1 repress during release tail");
        expect_audio(3, 37, "KEY1 repress sounds");
        set_keys(3'b111);
        expect_silence(40, "KEY1 repress release");
        for (i=0; i<4; i=i+1)
            if (on_count[i] != 5 || off_count[i] != 5)
                $fatal(1, "Note %0d has duplicate/missing on/off: %0d/%0d",
                       i, on_count[i], off_count[i]);
        $display("BOARD B 48K I2S: single/chord repress during release tails passed");

        // Reset four sounding voices, hold reset, then release the playing
        // keys before releasing reset and verify a fresh silent session.
        set_keys(3'b100);
        expect_state(4, 44, "four voices before reset");
        expect_audio(4, 44, "audio before KEY2 reset");
        set_keys(3'b000);
        wait(!dut.rst_n);
        repeat (4) @(negedge dut.audio_clk);
        if (i2s_bclk !== 0 || i2s_data !== 0 ||
            dut.u_instrument.active_count !== 0 ||
            dut.u_instrument.events_pushed !== 0)
            $fatal(1, "KEY2 failed to reset sounding voices and I2S");
        repeat (128) @(negedge dut.audio_clk);
        if (dut.rst_n) $fatal(1, "Reset was not held while KEY2 is down");
        set_keys(3'b011);
        wait(dut.pressed_sync == 3'b100);
        set_keys(3'b111);
        wait(dut.rst_n);
        bits_before_reset = active_bits;
        expect_silence(0, "reset recovery");
        if (active_bits != bits_before_reset)
            $fatal(1, "Reset recovery played a stale note");

        set_keys(3'b101);
        expect_state(3, 3, "chord after reset");
        expect_audio(3, 3, "chord restarted after reset");
        set_keys(3'b111);
        expect_silence(6, "chord release after reset");
        set_keys(3'b110);
        expect_state(1, 7, "single note after reset");
        expect_audio(1, 7, "single note restarted after reset");
        set_keys(3'b111);
        expect_silence(8, "single note release after reset");
        $display("BOARD B 48K I2S: KEY2 silence and fresh single/chord session passed");

        // Keys that remain down when reset is released become new gestures.
        set_keys(3'b100);
        expect_state(4, 12, "both keys before held-key reset");
        expect_audio(4, 12, "held keys before KEY2");
        set_keys(3'b000);
        wait(!dut.rst_n);
        repeat (4) @(negedge dut.audio_clk);
        if (dut.u_instrument.active_count !== 0 || i2s_data !== 0)
            $fatal(1, "Held-key reset did not silence old voices");
        set_keys(3'b100);
        wait(dut.rst_n);
        expect_state(4, 4, "held keys rebuilt after KEY2 release");
        expect_audio(4, 4, "held-key reset recovery sounds");
        set_keys(3'b111);
        expect_silence(8, "held-key reset recovery release");
        $display("BOARD B 48K I2S: held-key rebuild after reset passed");

        // Inject loss of the top-level lock indication without stopping the
        // simulated oscillator. This isolates asynchronous reset assertion
        // and synchronized reset release from the vendor PLL model.
        set_keys(3'b110);
        expect_state(1, 9, "single note before PLL loss");
        expect_audio(1, 9, "single note before clock reset");
        force dut.pll_locked = 1'b0;
        wait(!dut.rst_n);
        repeat (4) @(negedge dut.audio_clk);
        if (dut.instrument_rst_n !== 0 || i2s_bclk !== 0 ||
            i2s_data !== 0 || dut.u_instrument.active_count !== 0)
            $fatal(1, "PLL loss did not immediately reset audio");
        repeat (32) @(negedge sys_clk);
        release dut.pll_locked;
        wait(dut.rst_n);
        expect_state(1, 1, "held note rebuilt after PLL lock recovery");
        expect_audio(1, 1, "PLL reset recovery sounds");
        set_keys(3'b111);
        expect_silence(2, "PLL reset recovery release");
        $display("BOARD B 48K I2S: injected PLL loss reset/rebuild passed");

        // The adapter's real capacity/overflow path has its own standalone
        // test. Here inject the sticky flag to verify the board's fail-silent
        // wiring and that only KEY2 clears it and enables another session.
        set_keys(3'b101);
        expect_state(3, 5, "chord before injected key queue overflow");
        expect_audio(3, 5, "chord before overflow mute");
        injecting_overflow = 1;
        force dut.u_keys.overflow_sticky = 1'b1;
        wait(!dut.instrument_rst_n);
        repeat (4) @(negedge dut.audio_clk);
        if (dut.rst_n !== 1 || i2s_bclk !== 0 || i2s_data !== 0 ||
            dut.u_instrument.active_count !== 0)
            $fatal(1, "Key queue overflow did not independently mute audio");
        release dut.u_keys.overflow_sticky;
        repeat (128) @(negedge dut.audio_clk);
        if (!dut.input_overflow_sticky || dut.instrument_rst_n)
            $fatal(1, "Key queue overflow mute did not persist until KEY2");
        set_keys(3'b011);
        wait(!dut.rst_n);
        repeat (4) @(negedge dut.audio_clk);
        if (dut.input_overflow_sticky || dut.u_keys.pending_count != 0)
            $fatal(1, "KEY2 did not clear the key queue overflow");
        injecting_overflow = 0;
        wait(dut.pressed_sync == 3'b100);
        set_keys(3'b111);
        wait(dut.rst_n);
        expect_silence(0, "overflow reset recovery");
        set_keys(3'b110);
        expect_state(1, 1, "single note after overflow reset");
        expect_audio(1, 1, "overflow reset recovery sounds");
        set_keys(3'b111);
        expect_silence(2, "overflow reset recovery release");

        if (command_count != 72 || complete_slots < 100 || active_bits == 0 ||
            dut.u_instrument.i2s_underrun_count != 0)
            $fatal(1, "Final board I2S command/clock/data check failed");
        $display("BOARD B 48K EXTERNAL I2S PASSED single/chord/combined/repress/reset/held-reset/pll-loss/overflow-mute commands=%0d slots=%0d active_bits=%0d underruns=0",
                 command_count, complete_slots, active_bits);
        $finish;
    end

    initial begin
        #100000000000;
        $fatal(1, "B 48 kHz external I2S simulation timed out");
    end
endmodule
