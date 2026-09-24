// Autonomous 48 kHz digital board check of teammate B's interaction path.
// No external DAC or musical input hardware is required. KEY2 restarts it.
module board_instrument_b_48k_gao_top #(
    parameter integer RESET_CYCLES = 65536,
    parameter integer HOLD_CYCLES = 245760,
    parameter integer TIMEOUT_CYCLES = 49152000,
    parameter integer DEBOUNCE_CYCLES = 500000
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output wire rgb_data,
    output wire pa_disable
);
    wire board_ready;
    wire [2:0] pressed_50;
    wire audio_clk, pll_locked;
    reg ready_meta = 0, ready_sync = 0;
    reg [2:0] pressed_meta = 0, pressed_sync = 0;
    reg fault_meta_50 = 0, fault_sync_50 = 0;
    reg complete_meta_50 = 0, complete_sync_50 = 0;
    wire [23:0] status_grb = fault_sync_50 ? 24'h002000 :
                             complete_sync_50 ? 24'h200000 : 24'h000020;

    audio_clock_48k u_audio_clock (
        .clk_50(sys_clk), .clk_audio(audio_clk), .locked(pll_locked)
    );
    board_bringup_top #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES), .STATUS_MODE(1)) u_board (
        .sys_clk(sys_clk), .key_n(key_n), .rgb_data(rgb_data),
        .pa_disable(pa_disable), .board_ready(board_ready),
        .keys_pressed(pressed_50), .status_grb(status_grb)
    );
    // The WS2812 runs in the 50 MHz domain. Only stable one-bit status
    // flags cross back from the audio domain; fault has display priority.
    always @(posedge sys_clk) begin
        fault_meta_50 <= fault;
        fault_sync_50 <= fault_meta_50;
        complete_meta_50 <= complete_sticky;
        complete_sync_50 <= complete_meta_50;
    end

    // Assert on PLL loss; release board-ready and key status in the audio domain.
    always @(posedge audio_clk or negedge pll_locked) begin
        if (!pll_locked) begin
            ready_meta <= 0;
            ready_sync <= 0;
            pressed_meta <= 0;
            pressed_sync <= 0;
        end else begin
            ready_meta <= board_ready;
            ready_sync <= ready_meta;
            pressed_meta <= pressed_50;
            pressed_sync <= pressed_meta;
        end
    end

    localparam [3:0] RESET = 0, KEY_ON = 1, KEY_ACTIVE = 2,
        EXPR = 3, EXPR_APPLIED = 4, CHORD_ON = 5, CHORD_ACTIVE = 6,
        HOLD = 7, CHORD_OFF = 8, CHORD_RELEASED = 9,
        KEY_OFF = 10, DRAIN = 11, FAILED = 12;
    reg [3:0] phase = RESET;
    reg [31:0] timer = 0;
    reg [15:0] completed_runs = 0;
    reg complete_sticky = 0;
    reg fault = 0, serial_seen = 0;
    // Registered reset avoids asynchronous-reset glitches from FSM decoding.
    reg rst_n = 0;

    wire key_valid = phase == KEY_ON || phase == KEY_OFF;
    wire key_on = phase == KEY_ON;
    wire key_ready;
    wire chord_valid = phase == CHORD_ON || phase == CHORD_OFF;
    wire chord_on = phase == CHORD_ON;
    wire chord_ready;
    wire expr_update_valid = phase == EXPR;
    wire expr_update_ready;
    wire bclk, lrclk, serial_data;
    wire [6:0] active_count;
    wire voice_full_pulse, done_error_pulse;
    wire [31:0] underruns;
    wire [5:0] event_fifo_level;
    wire event_fifo_full, event_backpressure;
    wire event_overflow_pulse, event_overflow_sticky;
    wire [31:0] event_overflow_count, events_pushed, events_delivered;
    wire [11:0] current_expr_gain;
    wire signed [12:0] current_expr_bend_cents;
    wire [7:0] current_expr_vibrato_cents;

    instrument_system_v2 u_instrument (
        .clk(audio_clk), .rst_n(rst_n),
        .key_valid(key_valid), .key_ready(key_ready), .key_on(key_on),
        .key_source(6'd1), .key_note(key_on ? 7'd69 : 7'd100),
        .key_velocity(key_on ? 7'd100 : 7'd0),
        .key_timbre(key_on ? 2'd2 : 2'd0),
        .chord_valid(chord_valid), .chord_ready(chord_ready),
        .chord_on(chord_on), .chord_id(3'd0), .chord_source(6'd2),
        .chord_count(4'd3),
        .chord_notes_flat(chord_on ? {35'd0, 7'd67, 7'd64, 7'd60} : 56'd0),
        .chord_velocity(chord_on ? 7'd100 : 7'd0),
        .chord_timbre(chord_on ? 2'd2 : 2'd0),
        .expr_update_valid(expr_update_valid),
        .expr_update_ready(expr_update_ready),
        .expr_update_mask(3'b111), .expr_update_gain(12'd1800),
        .expr_update_bend_cents(13'sd25),
        .expr_update_vibrato_cents(8'd7),
        .i2s_bclk(bclk), .i2s_lrclk(lrclk), .i2s_data(serial_data),
        .active_count(active_count), .voice_full_pulse(voice_full_pulse),
        .done_error_pulse(done_error_pulse),
        .i2s_underrun_count(underruns),
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

    // Valid is decoded from phase, so every request remains stable until its
    // matching ready is sampled. Chord expansion may take several cycles.
    always @(posedge audio_clk or negedge pll_locked) begin
        if (!pll_locked || !ready_sync || pressed_sync[2]) begin
            rst_n <= 0;
            phase <= RESET;
            timer <= 0;
            completed_runs <= 0;
            complete_sticky <= 0;
            fault <= 0;
            serial_seen <= 0;
        end else begin
            timer <= timer + 1'b1;
            if (rst_n && serial_data) serial_seen <= 1;
            case (phase)
                RESET: if (timer >= RESET_CYCLES-1) begin
                    rst_n <= 1;
                    serial_seen <= 0;
                    timer <= 0;
                    phase <= KEY_ON;
                end
                KEY_ON: if (key_ready) begin phase <= KEY_ACTIVE; timer <= 0; end
                KEY_ACTIVE: if (active_count == 1 && events_delivered == 1) begin
                    phase <= EXPR; timer <= 0;
                end
                EXPR: if (expr_update_ready) begin
                    phase <= EXPR_APPLIED; timer <= 0;
                end
                EXPR_APPLIED: if (current_expr_gain == 12'd1800 &&
                                  current_expr_bend_cents == 13'sd25 &&
                                  current_expr_vibrato_cents == 8'd7) begin
                    phase <= CHORD_ON; timer <= 0;
                end
                CHORD_ON: if (chord_ready) begin
                    phase <= CHORD_ACTIVE; timer <= 0;
                end
                CHORD_ACTIVE: if (active_count == 4 &&
                                  events_pushed == 4 &&
                                  events_delivered == 4 &&
                                  event_fifo_level == 0) begin
                    phase <= HOLD; timer <= 0;
                end
                HOLD: if (timer >= HOLD_CYCLES-1) begin
                    if (!serial_seen || active_count != 4) begin
                        fault <= 1; phase <= FAILED;
                    end else begin
                        phase <= CHORD_OFF; timer <= 0;
                    end
                end
                CHORD_OFF: if (chord_ready) begin
                    phase <= CHORD_RELEASED; timer <= 0;
                end
                CHORD_RELEASED: if (events_pushed == 7 &&
                                    events_delivered == 7 &&
                                    event_fifo_level == 0) begin
                    phase <= KEY_OFF; timer <= 0;
                end
                KEY_OFF: if (key_ready) begin phase <= DRAIN; timer <= 0; end
                DRAIN: if (active_count == 0 &&
                           events_pushed == 8 && events_delivered == 8 &&
                           event_fifo_level == 0) begin
                    completed_runs <= completed_runs + 1'b1;
                    complete_sticky <= 1;
                    rst_n <= 0;
                    phase <= RESET;
                    timer <= 0;
                end
                FAILED: timer <= 0;
                default: begin fault <= 1; phase <= FAILED; end
            endcase
            if (rst_n && (voice_full_pulse || done_error_pulse ||
                          underruns != 0 || event_overflow_sticky)) begin
                fault <= 1;
                phase <= FAILED;
            end
            if (phase != RESET && phase != HOLD && phase != FAILED &&
                timer >= TIMEOUT_CYCLES-1) begin
                fault <= 1;
                phase <= FAILED;
            end
        end
    end
endmodule
